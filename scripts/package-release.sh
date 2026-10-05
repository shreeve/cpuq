#!/usr/bin/env bash
# package-release.sh — pack one platform's release archive.
#
#   TAG=v1.2.3 PLAT=linux-amd64 BINARY=path/to/cpuq scripts/package-release.sh
#
# Writes OUT/cpuq-TAG-PLAT.tar.gz (OUT defaults to dist), which unpacks to
# cpuq-TAG-PLAT/ holding cpuq, README.md, CHANGELOG.md and LICENSE: the
# layout install.sh and the Homebrew formula read. PLAT is one of
# osx-arm64, osx-amd64, linux-amd64, linux-arm64.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${TAG:?set TAG, for example v1.2.3}
PLAT=${PLAT:?set PLAT}
BINARY=${BINARY:?set BINARY to the built cpuq}
OUT=${OUT:-dist}

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "package-release: TAG must look like v1.2.3, not $TAG" >&2; exit 2; }
case "$PLAT" in
  osx-arm64|osx-amd64|linux-amd64|linux-arm64) ;;
  *) echo "package-release: unsupported PLAT $PLAT" >&2; exit 2 ;;
esac
[ -f "$BINARY" ] || { echo "package-release: no binary at $BINARY" >&2; exit 2; }
# A binary this host can run must report the tag's version; a cross-built
# one that cannot run here is not checked.
if version=$("$BINARY" --version 2>/dev/null) && [ "$version" != "cpuq ${TAG#v}" ]; then
  echo "package-release: $BINARY reports '$version', not 'cpuq ${TAG#v}'" >&2
  exit 2
fi

name="cpuq-$TAG-$PLAT"
root="$OUT/$name"
rm -rf "$root"
mkdir -p "$root"
install -m 0755 "$BINARY" "$root/cpuq"
install -m 0644 README.md CHANGELOG.md LICENSE "$root/"
# macOS's bsdtar would add extended attributes and AppleDouble files that
# GNU tar warns about on unpacking; the archive carries plain files only.
flags=()
if tar --version 2>/dev/null | grep -q bsdtar; then flags=(--no-xattrs --no-mac-metadata); fi
COPYFILE_DISABLE=1 tar ${flags[@]+"${flags[@]}"} -C "$OUT" -czf "$OUT/$name.tar.gz" "$name"
rm -rf "$root"
printf '  %s (%s)\n' "$OUT/$name.tar.gz" "$(du -h "$OUT/$name.tar.gz" | cut -f1)"
