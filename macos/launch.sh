#!/bin/sh
# Builds the overlay app if its source changed, then opens it. `open` hands it
# to launchd, so one copy serves every session and outlives any of them.
set -eu
[ "$(uname)" = Darwin ] || { echo "desk-buddy's overlay needs macOS" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/DeskBuddy.swift"
home="$HOME/.claude/desk-buddy"
app="$home/DeskBuddy.app"
stamp="$home/source.sha"
want="$(cat "$src" "$here/assets/buddy.png" "$here/assets/buddy.json" | shasum -a 256 | cut -d' ' -f1)"
mkdir -p "$home/sessions"

if [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ] || [ ! -x "$app/Contents/MacOS/DeskBuddy" ]; then
  lock="$home/build.lock"
  # Sessions starting together: one builds, the rest wait for it.
  tries=0
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || rm -rf "$lock"
    sleep 1
  done
  trap 'rm -rf "$lock"' EXIT
  if [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ] || [ ! -x "$app/Contents/MacOS/DeskBuddy" ]; then
    command -v swiftc >/dev/null || { echo "swiftc not found: run xcode-select --install" >&2; exit 1; }
    tmp="$home/build.tmp"
    rm -rf "$tmp"
    mkdir -p "$tmp/DeskBuddy.app/Contents/MacOS" "$tmp/DeskBuddy.app/Contents/Resources"
    cp "$here/assets/buddy.png" "$here/assets/buddy.json" "$tmp/DeskBuddy.app/Contents/Resources/"
    swiftc -O -target "$(uname -m)-apple-macos13" -framework AppKit -o "$tmp/DeskBuddy.app/Contents/MacOS/DeskBuddy" "$src"
    cat > "$tmp/DeskBuddy.app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.desk-buddy.overlay</string>
<key>CFBundleName</key><string>DeskBuddy</string>
<key>CFBundleExecutable</key><string>DeskBuddy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
    codesign --force --sign - "$tmp/DeskBuddy.app" >/dev/null 2>&1 || true
    pkill -x DeskBuddy 2>/dev/null || true
    rm -rf "$app"
    mv "$tmp/DeskBuddy.app" "$app"
    rm -rf "$tmp"
    printf '%s' "$want" > "$stamp"
  fi
fi

open -g "$app"
