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

## 2. Bundled avatars

The app ships with two avatars, `kyle` and `melody`, and the settings work from a list of them rather than one built-in sheet. The plan is in [roadmaps/02-bundled-avatars.md](roadmaps/02-bundled-avatars.md).

## 3. The mod installs the app

Going standalone gave the mod a manual step: it opens the app but doesn't include it, so people have to unzip it, drag it into Applications and get past Gatekeeper themselves. The mod should carry the build and install it, so that installing the mod is the only step.

**Carry the build in the mod**

- [ ] Have `macos/build.sh` put the zip inside `mod/`, at a fixed path such as `mod/app/DeskBuddy.zip`. `build/` is ignored by git, so the zip has to be committed or added by a release step for it to reach people.
- [ ] Keep the versions together. `macos/Info.plist` and `mod/.claude-plugin/plugin.json` both say `0.5.0` by hand today, so have the build fail or set one from the other.

**Install it**

- [ ] On `session.start` and `/desk-buddy start`, install the app from `$.plugin.root` if it is missing, then open it. These are the only two places that open the app today, and that has to stay true so that a quit isn't undone by a heartbeat.
- [ ] Unpack with `ditto` to a temporary folder beside the target, then move it into place. Sessions often start together, and neither should see a half-copied app.
- [ ] Open the app by path after an install. `open -b` relies on Launch Services, which may not know about a freshly copied app yet.
- [ ] Fall back to `~/Applications` when `/Applications` can't be written to, as on a standard account. The check for a missing app has to look in both.
- [ ] Say what happened: a short note when the app is installed, and a clear reason when it can't be. Replace "Is DeskBuddy in Applications?" in `/desk-buddy start`.

**Update it**

- [ ] When the mod carries a newer version than the installed app, replace it. `GET /status` already gives the running version, and a closed app's version is in its `Info.plist`.
- [ ] Quit a running app before replacing it, as `build.sh --install` does, then reopen it. Other sessions rebuild their buddies within one heartbeat.
- [ ] Never replace a newer app with an older one, so that a build made with `build.sh --install` survives.

**Finish up**

- [ ] Test the first open on a clean account. A file a browser downloads is quarantined, but one unpacked by the mod may not be, which would remove the Open Anyway step until the release is notarized. This is unproven, and it decides what the README has to say.
- [ ] Cover install, update, skip and failure in `mod/hooks/register.test.ts`.
- [ ] Remove the manual steps from "Install the app" in `mod/README.md`, keeping `build.sh --install` for development.

## 4. Choose your buddy

Offer a set of buddies to pick from, inside the app.

- [ ] Draw more buddies for the starter set and add them to the bundled list. Each needs all 13 states from [AVATAR-SHEETS.md](mod/AVATAR-SHEETS.md).
- [ ] Add a buddy picker to the app, with a preview of each one. Picking today needs `/desk-buddy avatar <name>`, so it needs a session.
- [ ] Save the choice as the default, so it survives a relaunch.
- [ ] List avatars made with `/desk-buddy create` in the picker beside the bundled ones.

## 5. Windows support

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

- [ ] Replace the `open`, `/bin/rm`, `/bin/mkdir`, `/bin/cp`, `/bin/mv` and `/usr/bin/pkill` calls in `mod/hooks/register.ts`, and the `ditto` call the app install adds.
- [ ] Carry and install the Windows build from the mod, as the macOS one is.
- [ ] Stop relying on `HOME` and on `/` as the path separator.
- [ ] Make `/desk-buddy create` work on Windows. The avatar maker generates sheets with `swift` and `sips`, which are macOS tools, and its permissions name them too.

## 6. Bigger buddies

Let the person make the buddy bigger. Its size is fixed today: a sheet is drawn about 64 points tall (`spriteFit`), or at its own `scale` in `avatars.json`, and never larger than 256 points (`spriteMax`).

- [ ] Add a size setting to the menu bar menu, such as small, medium, large and extra large, that multiplies the scale each sheet is drawn at.
- [ ] Keep pixel art sharp: draw with nearest-neighbour sampling, and prefer whole-number scales for sheets that are already pixel-fitted.
- [ ] Raise or remove `spriteMax` so that the largest size isn't capped, and grow everything sized from the body with it: the window (`windowSize`), the shadow, the hop, the nap "z" and the name tag's place above the body (`tagGap`).
- [ ] Keep a big buddy on screen: wandering, napping spots (`randomSpot`) and drops after a pick-up should fit the larger window inside the usable area.
- [ ] Apply a new size to buddies already out, without a relaunch, and save it as the default so it survives one.
- [ ] Decide whether size is one setting for every buddy or set per buddy, and whether `/desk-buddy` gets a command for it.

## Suggested order

1. **Standalone**, since it is small and stands alone.
2. **Bundled avatars**, since they need no new UI and give the picker something to list.
3. **The mod installs the app**, since until then everyone with the mod has a manual step.
4. **The core and platform split**, before any new UI, so that the picker is not written in AppKit and then rewritten.
5. **The buddy picker**, on the new structure.
6. **Bigger buddies**, as a setting beside the picker, so that it is also built on the new structure.
7. **The Windows platform layer**, then the mod changes and the installer.

## Open questions

- **What is the new native stack?** A shared core with a thin native layer per OS, or a cross-platform framework such as Tauri or Electron? Test the hard part first: per-pixel click-through on an always-on-top transparent window, on both OSes.
- **How is the app distributed?** The mod carries it for people with Claude Code. People without it still need a download, and signing and notarizing on macOS, and code signing on Windows, decide whether they see security warnings when they first open it.
- **Should the mod replace an app that is in use?** Updating as soon as a session starts is simple, but it interrupts the buddies of every other session for a moment. Waiting until the app is closed could leave an old app running for days.
- **Should it start at login?** That fits an app that is always out, but it would be a new setting.
- **How many buddies are in the starter set,** and who draws them? The avatar maker could produce a first pass.
