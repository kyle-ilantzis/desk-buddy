#!/bin/sh
# Turns src/ into dist/, the folder that ships:
#
#   dist/.claude-plugin/marketplace.json   a marketplace listing one plugin
#   dist/desk-buddy/                       src/mod, versioned, plus app/DeskBuddy-macos.zip
#                                          and tool-avatar-maker/assets/ (src/native/core/assets)
#
# The native app is rebuilt only when src/native or src/mod/VERSION is newer than the last
# zip, so a mod-only change takes about a second. dist/ is replaced in one rename, so a
# session that starts mid-build never reads half a plugin.
#
#   scripts/dist.sh                 build
#   scripts/dist.sh --native        force a native rebuild
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
zip="build/macos/DeskBuddy.zip"

if [ "${1:-}" = --native ] || [ ! -f "$zip" ] || [ -n "$(find src/native src/mod/VERSION -newer "$zip" -type f -print -quit)" ]; then
  src/native/macos/build.sh
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
cp "$zip" "$stage/desk-buddy/app/DeskBuddy-macos.zip"
# dist/ becomes a repository of its own, so the license goes with it and with the plugin.
cp LICENSE "$stage/LICENSE"
cp LICENSE "$stage/desk-buddy/LICENSE"
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
