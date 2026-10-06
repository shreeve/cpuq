#!/bin/bash
# Builds Cpuq.app and prints its path, the only thing on stdout; the build's output goes to
# stderr. CONFIG=release for a release build (the default is debug). SCRATCH is the build folder
# (.build by default).
#
# Every build is signed with the Developer ID (SIGN names another identity; SIGN=- signs ad hoc,
# for a Mac without the certificate: such a bundle runs where it was built but cannot be
# released). A release build also signs with a secure timestamp, which notarization requires.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
scratch="${SCRATCH:-$root/.build}"
mkdir -p "$scratch"
scratch="$(cd "$scratch" && pwd)"

config="${CONFIG:-debug}"
swift build -c "$config" --scratch-path "$scratch" >&2
bin_dir="$(swift build -c "$config" --scratch-path "$scratch" --show-bin-path)"
app="$scratch/Cpuq.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/Cpuq" "$app/Contents/MacOS/Cpuq"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$app/Contents/Info.plist"
fi

# Sparkle is a binary framework that SwiftPM links from the build folder: the app carries its own
# copy, found through an rpath.
sparkle="$(find "$scratch/artifacts" -type d -name Sparkle.framework -path '*macos-arm64*' 2>/dev/null | head -1)"
[ -n "$sparkle" ] || { echo "error: no Sparkle.framework for macos-arm64 under $scratch/artifacts" >&2; exit 1; }
framework="$app/Contents/Frameworks/Sparkle.framework"
cp -R "$sparkle" "$framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Cpuq"
# Cpuq.app runs on Apple silicon: the framework keeps its arm64 slices and none of the headers it
# ships for building against it. Its XPC services and translations stay; an update needs them.
for binary in "$framework/Versions/B/Sparkle" "$framework/Versions/B/Autoupdate" \
              "$framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
              "$framework"/Versions/B/XPCServices/*.xpc/Contents/MacOS/*; do
    if lipo -archs "$binary" 2>/dev/null | grep -q x86_64; then lipo -thin arm64 "$binary" -output "$binary"; fi
done
rm -rf "$framework/Headers" "$framework/PrivateHeaders" "$framework/Modules" \
       "$framework/Versions/B/Headers" "$framework/Versions/B/PrivateHeaders" "$framework/Versions/B/Modules"

if [ "$config" = release ]; then
    dsymutil "$app/Contents/MacOS/Cpuq" -o "$scratch/Cpuq.app.dSYM" >&2
    strip -x "$app/Contents/MacOS/Cpuq"
fi

# One identity for every piece, inner components first, with the hardened runtime for a real
# identity (library validation refuses an ad-hoc framework from no team).
sign="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
options=()
if [ "$sign" != "-" ]; then options=(--options=runtime); fi
if [ "$sign" != "-" ] && [ "$config" = release ]; then options+=(--timestamp); fi
resign() { codesign --force --sign "$sign" ${options[@]+"${options[@]}"} "$@"; }
resign "$framework/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
resign "$framework/Versions/B/Autoupdate"
resign "$framework/Versions/B/Updater.app"
resign "$framework"
resign --entitlements "$root/Support/Cpuq.entitlements" "$app"
codesign --verify --deep --strict "$app"
identifier=$( (codesign -dv "$app" 2>&1 || true) | sed -n 's/^Identifier=//p')
expected=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[ "$identifier" = "$expected" ] || { echo "error: signed as '$identifier', not $expected" >&2; exit 1; }
echo "$app"
