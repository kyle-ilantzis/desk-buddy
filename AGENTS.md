# AGENTS.md

Instructions for coding agents working on Desk Buddy. For people, see [README.md](README.md).

Desk Buddy puts a small avatar on screen for each Claude Code session, and the avatar acts out what that session is doing. It has two parts: a Claude Code mod in TypeScript (`src/mod`), and a native overlay app in Swift (`src/native`), which has a shared core and one layer per OS.

**Read [ARCHITECTURE.md](ARCHITECTURE.md) first.** It describes the parts and how they connect. When you make a big change to the architecture, update it, and keep it high level. Plans for upcoming work are in [ROADMAP.md](ROADMAP.md) and `roadmaps/`.

## Build and test

Run these from the repo root:

```bash
make dist                # build src/ into dist/ (rebuilds the native app only if src/native or VERSION changed)
make test                # the mod's tests
npx --no-install tsc -p src/mod --noEmit   # type-check the mod
swift test --package-path src/native --scratch-path build/swiftpm   # the core's tests
src/native/macos/build.sh --install        # build the macOS app and install it
```

- A `PostToolUse` hook in `.claude/settings.json` rebuilds `dist/` after each edit under `src/`, so you don't need to run `make dist` yourself after an edit. Claude Code loads the mod from `dist/`, so a session needs `/reload-plugins` to pick up a change.
- Never edit `dist/` or `build/`. Both are generated.
- Before you finish, run `make test` after mod changes, and `swift test` after native changes.

## Where things go

- **The mod's behaviour** goes in `src/mod/hooks/register.ts`. Its tests are in `register.test.ts`.
- **Anything OS-specific in the mod** (commands, paths, the socket path) goes behind `OSBridge` in `src/mod/hooks/os-bridge.ts`, not in branches inside `register.ts`.
- **Shared native logic** goes in `src/native/core`. It imports only Foundation, never AppKit or WinSDK.
- **OS layers** (`src/native/macos` and `src/native/windows`) only fill in the core's protocols and paint what the core gives them. Keep behaviour out of them.
- **The version** is set only in `src/mod/VERSION`. The build stamps it into the app and into `plugin.json`.

## Gotchas

- The mod's engine reads a module's calls from its source, so `$` must not be passed into bridge methods. A bridge returns a `Command` or a path, and `register.ts` makes the call on `$`.
- The core counts y up from the bottom left of the main screen, as macOS does. The Windows layer flips y at its edge.
- The Windows layer is written but has never been built. Don't assume it compiles. Native changes need to build on macOS and must not break the Windows layer against the core's protocols.
- Each avatar sheet needs all 13 states listed in [AVATAR-SHEETS.md](src/mod/tool-avatar-maker/AVATAR-SHEETS.md).

## Style

- Match the code around your change: small functions, short comments that explain why, and constants named at the top of the file.
- Write docs in plain, short sentences, the way the existing READMEs and roadmaps do. When a roadmap item is done, tick it in `ROADMAP.md` or the matching `roadmaps/` file.
- Commit messages are short, lowercase summaries, such as `add bundled sam` or `make native split`.

## Security

- The app listens only on a per-user Unix socket (macOS) or named pipe (Windows). Don't open a network port.
- The avatar-maker agent's permissions are narrow on purpose: only `swift`, `swiftc`, `sips` and the app's own avatar tools, and writes only inside its job folder. Keep them that way.
