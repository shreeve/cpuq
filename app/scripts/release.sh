#!/bin/bash
# release.sh — release Cpuq.app X.Y.Z: build it signed, notarize and staple it, zip it, sign the
# Sparkle feed, and publish.
#
#   app/scripts/release.sh X.Y.Z --dry-run   # everything but publishing; still sends the app to Apple
#   app/scripts/release.sh X.Y.Z             # publishes
#
# Publishing makes two changes on GitHub, never touching cpuq's own (CLI) releases:
#   app-vX.Y.Z          a release holding Cpuq-X.Y.Z.zip, for the cask and for people;
#                       never --latest, so /releases/latest stays the CLI's
#   cpuq-app-updates    the feed release Sparkle reads (SUFeedURL): appcast.xml and every
#                       Cpuq-*.zip on the feed; created once, a prerelease, never --latest
#
# The notes are the `## X.Y.Z — date` section of app/CHANGELOG.md. Everything the release signs
# with lives in the login keychain: the Developer ID, the notarytool profile `notary-tool`, and
# the Sparkle key under the account `cpuq`, whose public half is Support/sparkle-public-key.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
fail() { echo "error: $*" >&2; exit 1; }

version=${1:?usage: app/scripts/release.sh X.Y.Z [--dry-run]}
dry=false
[ "${2:-}" = --dry-run ] && dry=true
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, not $version"
repo=shreeve/cpuq
tag="app-v$version"
feed_release=cpuq-app-updates
sign="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
profile="${NOTARY_PROFILE:-notary-tool}"
out="$root/.build/release-$version"

# --- Preflight -------------------------------------------------------------------------------
security find-identity -v -p codesigning | grep -qF "\"$sign\"" || fail "the keychain has no \"$sign\""
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || fail "notarytool cannot sign in with keychain profile \"$profile\""
swift build -c release >&2
bin=$(find .build/artifacts -type d -path '*Sparkle/bin' | head -1)
[ -x "$bin/generate_keys" ] || fail "no Sparkle tools under .build/artifacts"
keychain_key=$("$bin/generate_keys" --account cpuq -p 2>/dev/null | tail -1)
[ "$keychain_key" = "$(cat Support/sparkle-public-key.txt)" ] || fail "the keychain's cpuq Sparkle key does not match Support/sparkle-public-key.txt"
[ "$keychain_key" = "$(plutil -extract SUPublicEDKey raw Support/Info.plist)" ] || fail "Support/Info.plist's SUPublicEDKey is not Support/sparkle-public-key.txt"
notes=$(awk -v v="$version" 'index($0, "## " v " ") == 1 { p = 1; next } /^## / && p { exit } p' CHANGELOG.md)
if [ -z "$(tr -d '[:space:]' <<<"$notes")" ]; then
    $dry && echo "warning: CHANGELOG.md has no '## $version' section" >&2 || fail "CHANGELOG.md has no '## $version — date' section"
fi
if ! $dry; then
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "not on main"
    [ -z "$(git status --porcelain)" ] || fail "the tree is not clean"
    git fetch -q origin
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in step with origin/main"
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag exists"
    ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1 || fail "a release $tag exists"
    last=$(git tag -l 'app-v*' | sed 's/^app-v//' | sort -V | tail -1)
    if [ -n "$last" ] && [ "$(printf '%s\n%s\n' "$last" "$version" | sort -V | tail -1)" != "$version" ] || [ "$last" = "$version" ]; then
        fail "$version is not higher than the last release, $last"
    fi
fi

# --- Build, notarize, staple -----------------------------------------------------------------
rm -rf "$out"
mkdir -p "$out/feed"
app=$(VERSION="$version" CONFIG=release SCRATCH="$out/build" scripts/package-app.sh)
[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$version" ] || fail "the bundle's version is not $version"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
echo "notarizing (a few minutes)..." >&2
result=$(xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait --output-format json || true)
status=$(sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' <<<"$result")
if [ "$status" != Accepted ]; then
    id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$result")
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    fail "notarization: ${status:-no answer}"
fi
xcrun stapler staple -q "$app"
assessment=$(spctl --assess --type execute -vv "$app" 2>&1) && grep -qx "source=Notarized Developer ID" <<<"$assessment" \
    || fail "Gatekeeper does not accept the stapled app: $assessment"
rm -f "$out/notarize.zip"

# The archive: the bundle exactly, without the AppleDouble files and extended attributes that
# make an unzipped app look damaged.
archive="Cpuq-$version.zip"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app" "$out/$archive"
printf '%s\n' "$notes" >"$out/notes.md"

# --- The feed --------------------------------------------------------------------------------
if gh release view "$feed_release" --repo "$repo" >/dev/null 2>&1; then
    gh release download "$feed_release" --repo "$repo" --dir "$out/feed" --clobber
fi
cp "$out/$archive" "$out/feed/$archive"
cp "$out/notes.md" "$out/feed/Cpuq-$version.md"
"$bin/generate_appcast" --account cpuq --embed-release-notes --maximum-deltas 2 \
    --download-url-prefix "https://github.com/$repo/releases/download/$feed_release/" \
    --link "https://github.com/$repo" "$out/feed"
# generate_appcast writes an UNSIGNED feed, and exits 0, when its key does not match the bundle's
# SUPublicEDKey; Sparkle refuses an unsigned enclosure, so check.
unsigned=$(grep -o '<enclosure[^>]*>' "$out/feed/appcast.xml" | grep -v 'sparkle:edSignature=' || true)
[ -z "$unsigned" ] || fail "the feed has unsigned enclosures: $unsigned"
grep -q "<sparkle:version>$version</sparkle:version>" "$out/feed/appcast.xml" || fail "the feed does not list $version"

if $dry; then
    echo "dry run: built, notarized and fed in $out; nothing published" >&2
    exit 0
fi

# --- Publish ---------------------------------------------------------------------------------
git tag -a "$tag" -m "Cpuq.app $version"
git push -q origin "$tag"
gh release create "$tag" "$out/$archive" --repo "$repo" --title "Cpuq.app $version" \
    --notes-file "$out/notes.md" --latest=false --verify-tag
if ! gh release view "$feed_release" --repo "$repo" >/dev/null 2>&1; then
    git tag -f "$feed_release" >/dev/null && git push -q -f origin "refs/tags/$feed_release"
    gh release create "$feed_release" --repo "$repo" --title "Cpuq.app update feed" --prerelease --latest=false \
        --notes "The Sparkle feed Cpuq.app reads; see app/README.md. Not a release to download by hand."
fi
find "$out/feed" -maxdepth 1 -type f ! -name appcast.xml ! -name '*.md' -exec gh release upload "$feed_release" --repo "$repo" --clobber {} +
gh release upload "$feed_release" --repo "$repo" --clobber "$out/feed/appcast.xml"
echo "released Cpuq.app $version: https://github.com/$repo/releases/tag/$tag" >&2
