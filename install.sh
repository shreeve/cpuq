#!/usr/bin/env bash
#
# install.sh — install cpuq with one command (macOS and Linux):
#
#   curl -fsSL https://raw.githubusercontent.com/shreeve/cpuq/main/install.sh | bash
#
# It installs to ~/.local/bin, or /usr/local/bin when run as root; BIN=DIR
# picks another directory. Pin a version by passing its tag, and uninstall
# with --uninstall:
#
#   curl -fsSL .../install.sh | bash -s v1.2.3
#   curl -fsSL .../install.sh | sudo BIN=/usr/local/bin bash      # every user on the machine
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# It downloads the release archive for this platform, checks its sha256
# against the release's checksums file, and puts cpuq in place with an
# atomic rename. Every release publishes:
#
#   cpuq-vX.Y.Z-<plat>.tar.gz      unpacks to cpuq-vX.Y.Z-<plat>/cpuq ...
#   cpuq-vX.Y.Z-checksums.txt      sha256sum output over the archives
#
# with <plat> one of osx-arm64, osx-amd64, linux-amd64, linux-arm64.

set -euo pipefail

REPO=shreeve/cpuq
NAME=cpuq

Red='' Green='' Dim='' Bold='' Color_Off=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  Red='\033[0;31m' Green='\033[0;32m' Dim='\033[0;2m' Bold='\033[1m' Color_Off='\033[0m'
fi
info() { printf "${Dim}%s${Color_Off}\n" "$*"; }
fail() { printf "${Red}error${Color_Off}: %s\n" "$*" >&2; exit 1; }
tildify() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# Everything lives in main() so a truncated `curl | bash` download can
# never execute a half-delivered script.
main() {
  local explicit=${BIN:-}
  if [ -z "$explicit" ]; then
    if [ "$(id -u)" = 0 ]; then BIN=/usr/local/bin; else BIN="$HOME/.local/bin"; fi
  fi

  if [ "${1:-}" = --uninstall ]; then
    uninstall "$explicit"
    return
  fi

  command -v curl >/dev/null || fail "curl is required"
  command -v tar >/dev/null || fail "tar is required"

  local os arch plat
  os=$(uname -s) arch=$(uname -m)
  # A shell running under Rosetta reports x86_64 on Apple Silicon.
  if [ "$os" = Darwin ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    arch=arm64
  fi
  case "$os-$arch" in
    Darwin-arm64)              plat=osx-arm64 ;;
    Darwin-x86_64)             plat=osx-amd64 ;;
    Linux-x86_64)              plat=linux-amd64 ;;
    Linux-aarch64|Linux-arm64) plat=linux-arm64 ;;
    *) fail "$NAME runs on macOS and Linux (arm64, x86-64), not $os $arch" ;;
  esac

  # The tag: the argument, or the one `releases/latest` redirects to.
  local tag=${1:-}
  if [ -n "$tag" ]; then
    case "$tag" in v*) ;; *) tag="v$tag" ;; esac
  else
    tag=$(curl -fsSLI --retry 3 --retry-delay 1 -o /dev/null -w '%{url_effective}' \
      "https://github.com/$REPO/releases/latest") || fail "cannot reach github.com"
    tag=${tag##*/}
  fi
  # A typo, a stray flag, or .../latest redirecting to .../releases when
  # there are none: only a real tag shape goes further.
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "not a release tag: ${tag:-none} (expected vX.Y.Z)"

  local base="https://github.com/$REPO/releases/download/$tag"
  local asset="$NAME-$tag-$plat.tar.gz"
  tmp=$(mktemp -d)
  staged=""
  trap 'rm -rf "$tmp"; [ -z "$staged" ] || rm -f "$staged"' EXIT
  trap 'exit 1' HUP INT TERM

  curl -fsSL --retry 3 --retry-delay 1 -o "$tmp/checksums.txt" "$base/$NAME-$tag-checksums.txt" \
    || fail "no $NAME release $tag with a checksums file (see https://github.com/$REPO/releases)"
  local want
  want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/checksums.txt")
  [ -n "$want" ] || fail "no $plat build is published for $NAME $tag"

  info "$NAME $tag ($plat)"
  curl -fSL --retry 3 --retry-delay 1 --progress-bar -o "$tmp/$asset" "$base/$asset" \
    || fail "download failed: $base/$asset"
  local sum
  if command -v sha256sum >/dev/null; then
    sum=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
  else
    sum=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)
  fi
  [ "$sum" = "$want" ] || fail "checksum mismatch for $asset"

  tar -xzf "$tmp/$asset" -C "$tmp"
  local new="$tmp/$NAME-$tag-$plat/$NAME"
  [ -f "$new" ] || fail "$asset has no $NAME"
  "$new" --version >/dev/null 2>&1 || fail "the downloaded $NAME does not run on this machine"

  # A missing ~/.local reads as unwritable, so make it first.
  [ -d "$BIN" ] || mkdir -p "$BIN" 2>/dev/null || fail "cannot create $(tildify "$BIN"); set BIN= to a writable directory"
  [ -w "$BIN" ] || fail "$(tildify "$BIN") is not writable; re-run under sudo, or set BIN="

  # Stage beside the destination, then rename: atomic, and never a write
  # into a binary that running jobs are executing.
  local dest="$BIN/$NAME"
  staged=$(mktemp "$BIN/.$NAME.install.XXXXXX") || fail "cannot write to $(tildify "$BIN")"
  install -m 0755 "$new" "$staged" || fail "cannot write to $(tildify "$BIN")"
  mv -f "$staged" "$dest" || fail "cannot install to $(tildify "$dest")"
  staged=""
  printf "${Green}%s was installed to ${Bold}%s${Color_Off}\n" "$("$dest" --version)" "$(tildify "$dest")"

  case ":$PATH:" in
    *":$BIN:"*) info "Run '$NAME status' to see the machine's queue" ;;
    *)
      printf '\n'
      info "$(tildify "$BIN") is not on your PATH. Add it:"
      printf "  ${Bold}echo 'export PATH=\"%s:\$PATH\"' >> ~/.zshrc${Color_Off}${Dim}   # or ~/.bashrc${Color_Off}\n" "$BIN"
      ;;
  esac
}

# Removes only the binary; the state directory holds nothing that outlives
# its holders.
uninstall() {
  local explicit=$1
  # A root install and a user install land in different places; without
  # BIN=, look in both.
  if [ ! -e "$BIN/$NAME" ] && [ -z "$explicit" ]; then
    local dir
    for dir in "$HOME/.local/bin" /usr/local/bin; do
      if [ -e "$dir/$NAME" ]; then BIN=$dir; break; fi
    done
  fi
  [ -e "$BIN/$NAME" ] || fail "$NAME is not installed at $(tildify "$BIN/$NAME") (BIN= if it lives elsewhere)"
  # Never delete a file that is not cpuq.
  "$BIN/$NAME" --version 2>/dev/null | grep -q "^$NAME " \
    || fail "$(tildify "$BIN/$NAME") is not a $NAME binary; not removing it"
  rm -f "$BIN/$NAME" || fail "cannot remove $(tildify "$BIN/$NAME"); re-run under sudo if it was installed system-wide"
  printf "${Green}$NAME was removed from ${Bold}%s${Color_Off}\n" "$(tildify "$BIN")"
}

main "$@"
