# Desk Buddy

A little avatar for each Claude Code session that walks around your Mac's screen and acts out what the session is doing. It is two parts: a Claude Code mod in `src/mod/`, and a native macOS overlay app in `src/native/`.

See [ROADMAP.md](ROADMAP.md) for where it is going.

## Install

There is no release repository yet, so install from a clone:

```bash
make install-dev
```

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

The version comes from `src/mod/VERSION`, stamped into the app and `plugin.json` at build time. The native app is rebuilt only when `src/native/` or `src/mod/VERSION` changed. The plan for publishing `dist/` is in [roadmaps/03-mod-install.md](roadmaps/03-mod-install.md).
