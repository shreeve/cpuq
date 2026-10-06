#!/bin/bash
# update-cask.sh — point the Homebrew cask at a published Cpuq.app release.
#
#   app/scripts/update-cask.sh X.Y.Z
#
# Writes Casks/cpuq-app.rb in the shreeve/homebrew-tap checkout (TAP names another; the default is
# the tap beside this repository) with the release's archive and its sha256, commits it on a
# branch cpuq-app-X.Y.Z from the tap's main, pushes, and opens the pull request. Merging it makes
# `brew install --cask shreeve/tap/cpuq-app` install that version; Sparkle updates it from there.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "error: $*" >&2; exit 1; }

version="${1:?usage: app/scripts/update-cask.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, not $version"
repo="shreeve/cpuq"
tap="${TAP:-$root/../homebrew-tap}"
[ -d "$tap/Casks" ] || fail "no tap checkout at $tap (clone https://github.com/shreeve/homebrew-tap there, or set TAP)"
url="https://github.com/$repo/releases/download/app-v$version/Cpuq-$version.zip"

# The archive as published, so the sum matches what Homebrew downloads.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/Cpuq.zip" "$url" || fail "cannot download $url; is app-v$version published?"
sha=$(shasum -a 256 "$tmp/Cpuq.zip" | cut -d' ' -f1)

cd "$tap"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "the tap checkout has uncommitted changes"
git fetch -q origin main
branch="cpuq-app-$version"
git checkout -q -B "$branch" origin/main

cask="Casks/cpuq-app.rb"
new=1; [ ! -f "$cask" ] || new=0
cat > "$cask" <<CASK
cask "cpuq-app" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/app-v#{version}/Cpuq-#{version}.zip"
  name "Cpuq"
  desc "Menu-bar meter and graphs for the cpuq machine-wide jobserver"
  homepage "https://github.com/$repo"

  livecheck do
    url "https://github.com/$repo/releases/download/cpuq-app-updates/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on formula: "shreeve/tap/cpuq"

  app "Cpuq.app"

  zap trash: [
    "~/Library/Caches/com.github.shreeve.cpuq",
    "~/Library/HTTPStorages/com.github.shreeve.cpuq",
    "~/Library/Preferences/com.github.shreeve.cpuq.plist",
  ]
end
CASK

git add "$cask"
if [ "$new" = 1 ]; then title="Add cpuq-app $version"; else title="Update cpuq-app to $version"; fi
git commit -q -m "$title"
git push -q -u origin "$branch"
gh pr create --title "$title" --body "Points the cask at https://github.com/$repo/releases/tag/app-v$version." | tail -1
git checkout -q main
