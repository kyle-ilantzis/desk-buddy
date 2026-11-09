# Desk Buddy

A little avatar for each Claude Code session that walks around your Mac's screen and acts out what the session is doing. It is two parts: a Claude Code mod in `src/mod/`, and a native macOS overlay app in `src/native/`.

See [ROADMAP.md](ROADMAP.md) for where it is going.

## Install

In Claude Code:

```
/plugin marketplace add https://github.com/kyle-ilantzis/desk-buddy.git#dist
/plugin install desk-buddy@desk-buddy
```

To work on it, install from a clone instead with `make install-dev`.

The first session installs the app from the mod into `/Applications`, or `~/Applications` when that can't be written to, and opens it. It isn't notarized, so if macOS blocks the first open, use System Settings > Privacy & Security > Open Anyway.

In a session, `/desk-buddy` lists the commands.

## Development

Needs the Xcode command line tools.

- `make dist` builds `src/` into `dist/`. Claude Code loads the mod from `dist/desk-buddy/`, so run `/reload-plugins` in a session after a rebuild.
- Edits Claude makes under `src/` rebuild `dist/` by themselves, through a hook in `.claude/settings.json`. Run `make dist` after editing by hand.
- `make test` runs the mod's tests.
- `src/native/macos/build.sh --install` builds the app and installs it into Applications.

## Distribution

`make dist` puts together `dist/`, a marketplace holding one plugin:

```
dist/.claude-plugin/marketplace.json
dist/desk-buddy/                        src/mod, plus app/DeskBuddy-macos.zip
```

The version comes from `src/mod/VERSION`, stamped into the app and `plugin.json` at build time. The native app is rebuilt only when `src/native/` or `src/mod/VERSION` changed. `make publish` builds `dist/` and pushes it to the `dist` branch, which is the marketplace people add. It needs a clean working tree, and warns if `src/mod/VERSION` wasn't bumped, since installed plugins only update when the version changes.
