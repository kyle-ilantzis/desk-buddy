#!/bin/bash
# Removes the installed native app so the mod installs it again on its next
# start. The data folder (avatars, settings) is kept.
set -euo pipefail

if [ "${OS:-}" = "Windows_NT" ]; then
  # TODO: Windows, once WindowsBridge in src/mod/hooks/os-bridge.ts says where the app lives.
  echo "uninstall-app: not implemented on Windows yet" >&2
  exit 1
fi

# The places MacOsBridge.installedApp installs to, plus any staging folder an
# interrupted install left next to them.
/usr/bin/pkill -x DeskBuddy && echo "Quit DeskBuddy" || true
for dir in /Applications "$HOME/Applications"; do
  for app in "$dir/DeskBuddy.app" "$dir"/.DeskBuddy.app-*; do
    [ -e "$app" ] || continue
    rm -rf "$app"
    echo "Removed $app"
  done
done
