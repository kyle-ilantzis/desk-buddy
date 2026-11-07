# Roadmap

Desk buddy today is a macOS overlay that exists to serve Claude Code sessions: the mod builds it, launches it, and it quits once the sessions are gone. These features turn it into an app of its own, with Claude Code as one thing it can react to.

## 1. Standalone app

Desk buddy runs without any Claude Code session. Open it and the buddy is on screen. The plan is in [roadmaps/01-standalone.md](roadmaps/01-standalone.md).

- [x] Opening the app shows a buddy straight away, with no session needed. It wanders and naps on its own.
- [x] The app stays open until the person quits it. Remove the quit that fires two minutes after the last session closes (`quitAfterEmpty`).
- [ ] Ship a prebuilt app that can be installed and opened like any other, so it no longer needs the Xcode command line tools or a first-run `swiftc` build. `macos/build.sh` makes the app, but it stays unticked until the release is signed and notarized.
- [x] Sessions join a running app: the mod finds it, or opens it if it is installed, and buddies pick up work as they do now.
- [x] Work out what `/desk-buddy stop` means when the person opened the app themselves. Today it kills the process.
- [x] Keep the app's data somewhere that makes sense without Claude Code installed. It now lives in `~/Library/Application Support/DeskBuddy/`.

## 2. Choose your buddy

Offer a set of buddies to pick from, inside the app.

- [ ] Draw a starter set of buddies and bundle them with the app. Only one ships today. Each needs all 13 states from [AVATAR-SHEETS.md](mod/AVATAR-SHEETS.md).
- [ ] Add a buddy picker to the app, with a preview of each one. Picking today needs `/desk-buddy avatar <name>`, so it needs a session.
- [ ] Save the choice as the default, so it survives a relaunch.
- [ ] List avatars made with `/desk-buddy create` in the picker beside the bundled ones.
- [ ] Have `/desk-buddy avatar` list the bundled buddies too, and keep a session's own pick working.

## 3. Windows support

Desk buddy runs on macOS and Windows, which means redesigning the native part so that the OS-specific code is small and sits behind one interface.

**Split the overlay in two**

- [ ] Shared core: session reading, who works for whom (`cast`), movement, moods, animation timing, and `avatars.json` and sprite sheet handling. Everything is in `macos/DeskBuddy.swift` today, tied to AppKit.
- [ ] Platform layer, one per OS, covering:
  - transparent, always-on-top, borderless windows
  - clicks that pass through everything but the buddy's body
  - pick up and drop with the mouse
  - the usable area of each screen, above the taskbar or Dock
  - the tray or menu bar item, and its menu
  - image loading, app data paths, logging and single-instance handling

**Bring it to Windows**

- [ ] Build the Windows platform layer, and a Windows installer.
- [ ] Build and test on both OSes in CI.
- [ ] Move the macOS app onto the new core, with no change in behaviour.

**Make the mod cross-platform**

- [ ] Replace the `open`, `/bin/rm`, `/bin/mkdir`, `/bin/cp`, `/bin/mv` and `/usr/bin/pkill` calls in `mod/hooks/register.ts`.
- [ ] Stop relying on `HOME` and on `/` as the path separator.
- [ ] Make `/desk-buddy create` work on Windows. The avatar maker generates sheets with `swift` and `sips`, which are macOS tools, and its permissions name them too.

## Suggested order

1. **Standalone**, since it is small and stands alone.
2. **The core and platform split**, before any new UI, so that the picker is not written in AppKit and then rewritten.
3. **The buddy picker**, on the new structure.
4. **The Windows platform layer**, then the mod changes and the installer.

## Open questions

- **What is the new native stack?** A shared core with a thin native layer per OS, or a cross-platform framework such as Tauri or Electron? Test the hard part first: per-pixel click-through on an always-on-top transparent window, on both OSes.
- **How is the app distributed?** Signing and notarizing on macOS, and code signing on Windows, decide whether people see security warnings when they first open it.
- **Should it start at login?** That fits an app that is always out, but it would be a new setting.
- **How many buddies are in the starter set,** and who draws them? The avatar maker could produce a first pass.
