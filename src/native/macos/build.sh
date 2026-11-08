#!/bin/sh
# Builds DeskBuddy.app for Apple silicon and Intel, and a zip of it, in build/macos at
# the repo root. The version comes from src/mod/VERSION. It is signed ad hoc
# only: there is no Developer ID, so it isn't notarized.
# `build.sh --install` also puts it in /Applications and opens it, for development.
# scripts/dist.sh calls this and copies the zip into dist/.
set -eu
[ "$(uname)" = Darwin ] || { echo "DeskBuddy builds on macOS only" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found: run xcode-select --install" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="$root/build/macos"
app="$out/DeskBuddy.app"
version="$(tr -d '[:space:]' < "$root/src/mod/VERSION")"

rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" -framework AppKit -o "$out/DeskBuddy-$arch" "$here/DeskBuddy.swift"
done
lipo -create "$out/DeskBuddy-arm64" "$out/DeskBuddy-x86_64" -output "$app/Contents/MacOS/DeskBuddy"
rm "$out/DeskBuddy-arm64" "$out/DeskBuddy-x86_64"
cp "$here"/../core/assets/*.png "$here"/../core/assets/*.json "$app/Contents/Resources/"
cp "$here/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
ditto -c -k --keepParent "$app" "$out/DeskBuddy.zip"
echo "Built $out/DeskBuddy.zip ($version)"

if [ "${1:-}" = --install ]; then
  socket="$HOME/Library/Application Support/DeskBuddy/buddy.sock"
  curl -s -m 3 --unix-socket "$socket" -X POST http://desk-buddy/quit >/dev/null || true
  tries=0
  while pgrep -x DeskBuddy >/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 20 ] || pkill -x DeskBuddy || true
    sleep 0.25
  done
  rm -rf /Applications/DeskBuddy.app
  ditto "$app" /Applications/DeskBuddy.app
  open -g /Applications/DeskBuddy.app
  echo "Installed /Applications/DeskBuddy.app"
fi
