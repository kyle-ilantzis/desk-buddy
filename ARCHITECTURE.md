# Architecture

> **Keeping this file current**
>
> - After a big change in architecture, update this file.
> - Stay high level. Name the parts and how they connect; leave details to the code, the READMEs and the roadmaps.

Desk Buddy puts a small avatar on screen for each Claude Code session, and the avatar acts out what that session is doing. It has two parts:

- **The mod** (`src/mod`), a Claude Code plugin written in TypeScript. It watches a session's events and reports them.
- **The native app** (`src/native`), an overlay written in Swift. It draws the buddies and moves them around.

## Project structure

```
src/
  mod/                  Claude Code plugin (TypeScript)
    hooks/register.ts     session events -> reports, /desk-buddy command, app install
    hooks/os-bridge.ts    the OS-specific commands and paths the mod uses
    tool-avatar-maker/    prompt and spec for the agent behind /desk-buddy create
    VERSION               single version for the mod and the app
  native/               one Swift package (Package.swift)
    core/                 DeskBuddyCore: shared logic, Foundation only
    macos/                DeskBuddyMac: AppKit layer
    windows/              DeskBuddyWin: Win32 layer (written, not yet built on Windows)
    tests/                core tests against a stand-in OS
scripts/                dist.sh (build dist/), claude.sh, uninstall-app.sh
roadmaps/               plans for each roadmap section
notes/                  design notes
build/                  intermediate build output (ignored)
dist/                   the marketplace Claude Code loads the mod from (ignored)
```

## System overview

```
 Claude Code session ──┐
 Claude Code session ──┼─ mod (hooks) ── HTTP over local socket ──▶ native app
 Claude Code session ──┘                 /report  /status  /quit     ├─ core (Stage, Buddy, Sprite, Scene)
                                                                     └─ OS layer (windows, tray, input, drawing)
```

1. On session, turn and tool events, the mod works out a **mood** (thinking, reading, editing, running, waiting, and so on) and sends the session's whole state to the app with `POST /report`, plus a heartbeat.
2. The app's **Stage** keeps the latest report from each session, decides which buddy works for which session (`cast`), and drops sessions that stop reporting.
3. Each **Buddy** walks, naps and reacts according to its mood. The core describes how it should look as a **Scene**, and the OS layer paints that scene.

The app also runs with no session at all. Its buddy then wanders and naps by itself.

## Core components

### Mod (`src/mod`)

- Hooks into the Claude Code session lifecycle (`session.start`, `turn.*`, `tool.call`, `session.end`) and turns each event into a report.
- Finds the running app, or installs it from the zip it carries and opens it. When the zip it carries is newer than the installed app, it replaces the installed one.
- Provides the `/desk-buddy` command: start and stop the app, pick an avatar, and `create`, which runs the avatar-maker agent to draw a new sprite sheet.
- Everything that depends on the OS goes through an `OSBridge`, so adding an OS means adding a bridge, not branches in `register.ts`.

### Native core (`src/native/core`)

- Imports only Foundation. It holds all the shared logic: reports and casting, movement and moods, sprite sheets and `avatars.json`, scene layout, and HTTP parsing.
- Defines the protocols each OS fills in: `OverlayWindow`, `Tray`, `ImageLoader`, `Desktop` and `Paths`.
- See [src/native/core/README.md](src/native/core/README.md).

### OS layers

- **macOS** (`src/native/macos`): AppKit windows, the menu bar item and a Unix socket.
- **Windows** (`src/native/windows`): layered Win32 windows painted with GDI+, a tray icon and a named pipe. See [src/native/windows/README.md](src/native/windows/README.md).
- Each layer runs the timer, calls `Stage.tick(dt)`, and paints what the core gives it. Neither layer holds any behaviour of its own.

## Data

All data is stored in local files. There is no database.

- **App data folder:** `~/Library/Application Support/DeskBuddy/` on macOS and `%LOCALAPPDATA%\DeskBuddy` on Windows. It holds `avatars.json`, the default pick, and avatars made with `/desk-buddy create`.
- **Bundled avatars:** `kyle`, `melody` and `sam`. Each is a PNG sprite sheet with a JSON file that describes its 13 animation states. They are in `src/native/core/assets` and get copied into each app's resources. The sheet format is described in [AVATAR-SHEETS.md](src/mod/tool-avatar-maker/AVATAR-SHEETS.md).

## Build and distribution

- `make dist` runs `scripts/dist.sh`, which builds `src/` into `dist/`. The result is a plugin marketplace that holds the mod and, inside it, the zipped app for each OS that has one built.
- The native app is rebuilt only when `src/native` or `VERSION` changes. Each OS builds on that OS: `build.sh` on macOS, `build.ps1` on Windows.
- CI (`.github/workflows/native.yml`) builds and tests on both OSes. It hasn't run yet.
- Local setup is in [README.md](README.md).

## Security

- The app listens only on a per-user local socket or pipe, never on a network port.
- The avatar-maker agent runs under narrow permissions. The mod allows only `swift`, `swiftc`, `sips` and the app's own avatar tools, and allows writes only inside the job folder.
- The macOS app isn't signed or notarized yet.

## Testing

- `make test` runs the mod's tests (`register.test.ts`).
- `swift test --package-path src/native --scratch-path build/swiftpm` runs the core's tests.

## Future

See [ROADMAP.md](ROADMAP.md). The main architectural work still open:

- Building and running the Windows layer for the first time.
- Making the mod cross-platform, which removes its dependence on `HOME`, `/` as a path separator and macOS-only commands.
- A buddy picker and a size setting, built on top of the core and platform split.

## Glossary

- **Buddy:** an avatar on screen, standing in for one session.
- **Mood:** what a session is doing right now, which sets a buddy's animation, speed and caption.
- **Cast:** the mapping from sessions to buddies.
- **Stage:** the core's model of every session and buddy.
- **Scene:** what one buddy should look like this frame, painted by the OS layer.
- **Bridge:** the mod's OS-specific commands and paths.
