#!/bin/sh
# Runs the Claude Code CLI: `claude` on PATH, else $CLAUDE_BIN, else the newest copy the
# desktop app keeps. Prints nothing and exits 127 when none is found.
if command -v claude >/dev/null 2>&1; then exec claude "$@"; fi
if [ -n "${CLAUDE_BIN:-}" ]; then exec "$CLAUDE_BIN" "$@"; fi
bin="$(ls -d "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude 2>/dev/null | sort -V | tail -1)"
[ -n "$bin" ] || { echo "claude CLI not found: put it on PATH or set CLAUDE_BIN" >&2; exit 127; }
exec "$bin" "$@"
