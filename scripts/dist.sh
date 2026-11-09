#!/bin/sh
# Turns src/ into dist/, the folder that ships:
#
#   dist/.claude-plugin/marketplace.json   a marketplace listing one plugin
#   dist/desk-buddy/                       src/mod, versioned, plus app/DeskBuddy-macos.zip
#                                          and/or app/DeskBuddy-windows.zip, whichever of
#                                          build/macos and build/windows has a zip,
#                                          and tool-avatar-maker/assets/ (src/native/core/assets)
#
# The native app for this OS is rebuilt (as `make native` does) only when its zip is missing
# or src/native or src/mod/VERSION is newer than it, so a mod-only change takes about a
# second. The other OS's zip is shipped as it is, if it's there; at least one zip must exist.
# dist/ is replaced in one rename, so a session that starts mid-build never reads half a plugin.
#
#   scripts/dist.sh                 build
#   scripts/dist.sh --hook          read a PostToolUse event on stdin; build only if the
#                                   edited file is under src/
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "${1:-}" in
  --hook)
    file="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)"
    case "$file" in
      "$root"/src/*|src/*) ;;
      *) exit 0 ;;
    esac
    # A hook's stdout goes to the transcript; keep it short, and don't fail the edit.
    if out="$("$0" 2>&1)"; then echo "dist rebuilt: run /reload-plugins to load it"; else
      echo "dist build failed:" >&2; echo "$out" | tail -20 >&2; exit 2; fi
    exit 0 ;;
esac

version="$(tr -d '[:space:]' < src/mod/VERSION)"
macos_zip="build/macos/DeskBuddy.zip"
windows_zip="build/windows/DeskBuddy.zip"

case "$(uname)" in
  Darwin) host_zip="$macos_zip"; build_native() { src/native/macos/build.sh; } ;;
  MINGW*|MSYS*|CYGWIN*) host_zip="$windows_zip"
    build_native() { powershell -NoProfile -ExecutionPolicy Bypass -File src/native/windows/build.ps1; } ;;
  *) host_zip="" ;;
esac
if [ -n "$host_zip" ] && { [ ! -f "$host_zip" ] || [ -n "$(find src/native src/mod/VERSION -newer "$host_zip" -type f -print -quit)" ]; }; then
  build_native
fi

if [ ! -f "$macos_zip" ] && [ ! -f "$windows_zip" ]; then
  echo "no native build: neither $macos_zip nor $windows_zip exists" >&2
  echo "run make native-macos (on macOS) or make native-windows (on Windows) first" >&2
  exit 1
fi

stage="build/dist.tmp"
rm -rf "$stage"
mkdir -p "$stage/.claude-plugin" "$stage/desk-buddy/app"
rsync -a \
  --exclude '*.test.ts' --exclude 'tsconfig.json' --exclude '.claude-plugin/types/' --exclude '.DS_Store' \
  src/mod/ "$stage/desk-buddy/"
# The bundled avatars sit beside the maker's spec, as worked examples it can read.
rsync -a --exclude '.DS_Store' src/native/core/assets/ "$stage/desk-buddy/tool-avatar-maker/assets/"
sed -i '' "s/\"version\": *\"[^\"]*\"/\"version\": \"$version\"/" "$stage/desk-buddy/.claude-plugin/plugin.json"
# Each OS builds its own app; a zip copied in from the other machine ships too.
if [ -f "$macos_zip" ]; then cp "$macos_zip" "$stage/desk-buddy/app/DeskBuddy-macos.zip"; fi
if [ -f "$windows_zip" ]; then cp "$windows_zip" "$stage/desk-buddy/app/DeskBuddy-windows.zip"; fi
# dist/ becomes a repository of its own, so the license goes with it and with the plugin.
cp LICENSE "$stage/LICENSE"
cp LICENSE "$stage/desk-buddy/LICENSE"
cat > "$stage/README.md" <<'MD'
# Desk Buddy marketplace

Built from [kyle-ilantzis/desk-buddy](https://github.com/kyle-ilantzis/desk-buddy) by `make publish`. Don't edit this branch by hand.

Install in Claude Code:

```
/plugin marketplace add https://github.com/kyle-ilantzis/desk-buddy.git#dist
/plugin install desk-buddy@desk-buddy
```
MD
cat > "$stage/.claude-plugin/marketplace.json" <<JSON
{
  "name": "desk-buddy",
  "owner": { "name": "Kyle Ilantzis" },
  "plugins": [
    {
      "name": "desk-buddy",
      "source": "./desk-buddy",
      "version": "$version",
      "description": "A little avatar per working Claude session that walks around your screen."
    }
  ]
}
JSON

if ! report="$(scripts/claude.sh plugin validate "$stage/desk-buddy" 2>&1)"; then
  echo "$report" >&2
  echo "plugin validate failed; dist/ left as it was" >&2
  exit 1
fi

# Swap in place: the old dist stays whole until the rename.
rm -rf build/dist.old
[ -d dist ] && mv dist build/dist.old
mv "$stage" dist
rm -rf build/dist.old
echo "Built dist/desk-buddy ($version)"
