# 3. Build, distribute and install the app

How to tackle [section 3 of the roadmap](../ROADMAP.md#3-build-distribute-and-install-the-app). Going standalone gave the mod a manual step. The mod opens the app but doesn't include it, so people have to unzip it, drag it into Applications and get past Gatekeeper themselves. The mod should carry the build and install it, so that installing the mod is the only step.

That needs one place where the shipped plugin is put together, and a way to run that same plugin while developing. So the work comes in order: layout, dev loading, carrying the build, installing it, updating it, then releasing.

## Layout

```
VERSION                  one version for the app and the mod
src/mod/                 the Claude Code mod, the same on macOS and Windows
src/native/core/         what every OS shares: the bundled avatars today, the shared logic after section 5
src/native/macos/        the AppKit app and build.sh
src/native/windows/      the Windows app, from section 5
scripts/dist.sh          src → build → dist
build/                   intermediate output, ignored by git: build/macos/DeskBuddy.app and DeskBuddy.zip
dist/                    what ships, ignored by git
  .claude-plugin/marketplace.json
  desk-buddy/            src/mod with its version set, plus app/DeskBuddy-macos.zip
```

- [x] Move `mod/` to `src/mod/`, `macos/` to `src/native/macos/`, and the bundled avatars to `src/native/core/assets/`.
- [x] `src/native/macos/build.sh` writes to `build/macos/`, with a fixed zip name, `DeskBuddy.zip`.
- [x] Keep the versions together. `VERSION` is the only place the version is set. The build stamps it into the app's `Info.plist` and the plugin's `plugin.json`, and the copies in `src/` say `0.0.0`.
- [x] `make dist` builds `dist/`. It rebuilds the native app only when something under `src/native` or `VERSION` is newer than the last zip, so a mod-only change takes under a second.
- [x] `dist/` is staged in `build/dist.tmp/`, checked with `claude plugin validate`, and swapped in with one rename, so a session that starts mid-build never reads half a plugin and a failed build leaves the old one.

## Dev loading

- [x] `make install-dev` adds `dist/` as a local marketplace and installs `desk-buddy@desk-buddy` from it. A marketplace that is a folder with a relative `source` is read in place, so Claude Code runs `dist/desk-buddy/` itself, and `/reload-plugins` picks up a rebuild with no reinstall.
- [x] A `PostToolUse` hook in `.claude/settings.json` runs `scripts/dist.sh --hook` after Claude edits a file, and rebuilds when the file is under `src/`. Edits made by hand need `make dist`.
- [x] Remove `CLAUDE_CODE_PLUGIN_DIRS` from `~/.claude/settings.json` on each development machine, so the mod isn't loaded twice. It pointed at the old `mod/` folder.
- [ ] Consider `make watch` for hand edits. There is no `fswatch` or `entr` here, so it would be a small `node` script using `fs.watch`.

## Carry the build

- [x] The zip lives in the plugin at `dist/desk-buddy/app/DeskBuddy-macos.zip`, so `$.plugin.root/app/DeskBuddy-macos.zip` is how the mod finds it. Nothing binary is committed to `src/`.
- [ ] Add `app/DeskBuddy-windows.zip` once section 5 has a Windows build at `build/windows/DeskBuddy.zip`.

## Install it

- [ ] Put each OS-specific step below behind `OSBridge` in `src/mod/hooks/os-bridge.ts`, implemented in `MacOsBridge`, with `WindowsBridge` throwing until section 5. Likely methods: `installedApp(env)` (the places to look for the app), `unpackApp(archive, into)` (`ditto` on macOS), `launchAppAt(path)`, and `appVersionOf(path)` (read from `Info.plist`). A bridge only returns commands and paths, and `register.ts` makes the calls on `$`, because the engine won't load a module that passes `$` to an object's method.
- [ ] On `session.start` and `/desk-buddy start`, install the app from `$.plugin.root/app/` if it is missing, then open it. These are the only two places that open the app today, and that has to stay true so that a quit isn't undone by a heartbeat.
- [ ] Unpack with `ditto` to a temporary folder beside the target, then move it into place. Sessions often start together, and neither should see a half-copied app.
- [ ] Open the app by path after an install. `open -b` relies on Launch Services, which may not know about a freshly copied app yet.
- [ ] Fall back to `~/Applications` when `/Applications` can't be written to, as on a standard account. The check for a missing app has to look in both.
- [ ] Say what happened: a short note when the app is installed, and a clear reason when it can't be. Replace "Is DeskBuddy in Applications?" in `/desk-buddy start`.

## Update it

- [ ] When the mod carries a newer version than the installed app, replace it. Both come from `VERSION`, so the plugin's version is the one to compare. `GET /status` gives the running app's version, and a closed app's version is in its `Info.plist`.
- [ ] Quit a running app before replacing it, as `build.sh --install` does, then reopen it. Other sessions rebuild their buddies within one heartbeat.
- [ ] Never replace a newer app with an older one, so that a build made with `build.sh --install` survives.

## Release

- [ ] Publish `dist/` to a GitHub repository of its own (or an orphan `dist` branch of this one), so that people install with `/plugin install desk-buddy --marketplace <owner>/<repo>`. The `marketplace.json` that `make dist` writes works there unchanged.
- [ ] Bump `VERSION` for every release. An installed plugin from GitHub only updates when its version changes.
- [ ] Build `dist/` in CI on a tag, on macOS, and later on Windows as well, and push it to the release repository.
- [ ] Sign and notarize the macOS app before it is called a release. Until then, the first open needs Open Anyway.

## Finish up

- [ ] Test the first open on a clean account. A file a browser downloads is quarantined, but one unpacked by the mod may not be, which would remove the Open Anyway step until the release is notarized. This is unproven, and it decides what the README has to say.
- [ ] Cover install, update, skip and failure in `src/mod/hooks/register.test.ts`.
- [ ] Remove the manual steps from "Install" in `README.md`, keeping `build.sh --install` for development, and add the `/plugin install` line once the release repository exists.
