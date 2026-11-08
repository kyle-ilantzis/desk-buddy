# desk-buddy

A little avatar for each Claude Code session at work that walks around your Mac's screen and acts out what the session is doing: strolling while it thinks, carrying a book while it reads, sprinting while a command runs, hopping when it needs you, and napping when idle.

The mod sends the app one small report per session over a Unix socket, holding the project folder's name, tool names and the chosen avatar's name only. A native overlay app draws the avatars in windows that clicks pass through. It stays open until you quit it from the menu bar or run `/desk-buddy stop`.

Opening a session brings out no buddy. A session gets one when you send it a message, and keeps it until it has been idle for a minute. There is always at least one buddy out: the last one rests, tagged with its avatar's name, and the next session you message takes it. A buddy winding down its minute is handed over the same way, so working through sessions one at a time keeps one buddy. Sessions working at the same time each get their own.

To move a buddy, press on its body and hold: it stops when the cursor is over it, floats while you carry it, and lands where you let go. Only the body catches the mouse, so a click on the name tag or beside the buddy still reaches the app underneath.

- `/desk-buddy` lists the commands. The overlay comes out by itself when a session starts; `/desk-buddy start` brings them back and `/desk-buddy stop` sends them home.
- `/desk-buddy avatar` lists the avatars, the ones the app comes with (`kyle` and `melody`) beside any you have made; `/desk-buddy avatar <name>` picks one for this session and saves it as the `default` in `avatars.json`, making the file if need be, so sessions with no pick of their own wear it from then on, including after the overlay relaunches.
- `/desk-buddy create <name> <image> [image...]` makes a new avatar from one or more pictures. See [Making an avatar](#making-an-avatar).
- The 🐾 menu bar item shows how many are out and can quit the overlay.

## Install the app

The mod opens the app but doesn't include it yet. Unzip `DeskBuddy-macos.zip` (in the plugin's `app/` folder), drag `DeskBuddy.app` into Applications and open it. It isn't notarized, so macOS blocks the first open: go to System Settings > Privacy & Security and choose Open Anyway. To build it yourself, which needs the Xcode command line tools, run `../native/macos/build.sh --install`.

## Developing

This folder is source. What Claude Code loads is `dist/desk-buddy/` at the repo root, which `make dist` builds from it and from `../native/`. Set it up once from the repo root:

```bash
make install-dev
```

That builds `dist/`, adds it as a local marketplace and installs `desk-buddy` from it. Because the marketplace is a folder, Claude Code runs the plugin straight from `dist/desk-buddy/`, so after each rebuild `/reload-plugins` in a session loads the new build. Edits Claude makes under `src/` rebuild `dist/` by themselves, through a hook in `.claude/settings.json`; run `make dist` after editing by hand.

## Making an avatar

`/desk-buddy create "Mr Rex" ~/Pictures/rex.png ~/Pictures/rex-side.jpg` starts a background agent that redraws the pictures as a pixel-art character in all 13 states, following [AVATAR-SHEETS.md](AVATAR-SHEETS.md). Paths with spaces can be quoted, or dragged in.

The name is what a resting buddy's tag shows. It also gives the avatar an id, here `mr-rex`, for picks and file names. `kyle`, `melody` and `builtin` are kept for the app, so they can't be used.

You can keep working meanwhile, and a notification says when it's done. Then `/desk-buddy avatar mr-rex` wears it. The agent runs inside the session that started it, using that session's login, so it stops if you close that session; run the command again to start over.

It works in `~/Library/Application Support/DeskBuddy/jobs/mr-rex/`, keeping your pictures' copies, its generator and its previews there. The sheet lands in `~/Library/Application Support/DeskBuddy/sprites/mr-rex.png`, and an entry in `avatars.json`. The agent can read files, write only in its job folder, and run only `swift`, `swiftc`, `sips` and the two `DeskBuddy` commands. `swift` runs any code it is given, so this keeps mistakes contained rather than being a sandbox.

## Sprite sheet avatars

Avatars are configured in `~/Library/Application Support/DeskBuddy/avatars.json`. The app also carries two of its own, `kyle` and `melody`, as `../native/core/assets/<name>.png` and `<name>.json`. A name is looked up in `avatars.json` first, so an entry called `melody` wins over the bundled one. Without that file every buddy is `kyle`. `../native/macos/archive/DeskBuddy-drawn.swift` is the code that drew it, kept to regenerate it. `builtin`, its old name, still works in a saved pick.

```json
{
  "default": "fox",
  "avatars": {
    "fox": {
      "name": "Mr Fox",
      "sheet": "sprites/fox.png",
      "frameWidth": 32,
      "frameHeight": 32,
      "scale": 2,
      "fps": 8,
      "facesLeft": false,
      "animations": {
        "idle": { "row": 0, "frames": 4 },
        "walk": { "row": 1, "frames": 6, "fps": 12 },
        "asleep": { "row": 2, "start": 1, "frames": 2, "fps": 2 },
        "waiting": { "row": 3 },
        "held": { "row": 4, "frames": 2, "fps": 4 }
      }
    }
  }
}
```

Only `avatars`, `sheet`, `frameWidth` and `frameHeight` are required.

| Field | Meaning |
| --- | --- |
| `default` | The avatar for sessions that have not picked one. `/desk-buddy avatar <name>` sets it, and rewrites the file to do so. Left out, those sessions wear `kyle`. |
| `name` | The display name, shown on a resting buddy's tag and in `/desk-buddy avatar`. Left out, the avatar's id is shown. |
| `sheet` | A PNG (or other image macOS reads): an absolute path, a `~/` path, or a path relative to `~/Library/Application Support/DeskBuddy/`. |
| `frameWidth`, `frameHeight` | One frame's size in the sheet's pixels. Frames sit in a grid counted from the top left. |
| `scale` | Screen points per sheet pixel. Left out, the sprite is sized to about 64 points tall. Nothing is drawn over 256 points. |
| `fps` | Frames per second, 8 if left out. An animation's own `fps` wins. |
| `facesLeft` | Set `true` if the art faces left. It is mirrored when the buddy walks the other way. |
| `animations` | Mood name to `{ row, start, frames, fps }`, each counted from 0. `start` defaults to 0 and `frames` to the rest of the row. |

The animation names are `idle`, `walk`, `asleep`, `thinking`, `reading`, `editing`, `running`, `browsing`, `delegating`, `waiting`, `done`, `error` and `held`. `held` plays while the buddy is carried, and the overlay adds the float itself, so draw it in place. A moving buddy with no row for its mood plays `walk`, and anything else missing plays `idle`, which defaults to the whole of the top row. [AVATAR-SHEETS.md](AVATAR-SHEETS.md) says when each one plays and what it should show.

Frames stand on the bottom edge of their cell. The overlay reads `avatars.json` again within a second of it changing; after replacing only a PNG, save `avatars.json` too. An avatar whose sheet cannot be read, a pick the config no longer has, and a file that is not valid JSON all fall back to `kyle`, and the reason goes to the system log (`log show --process DeskBuddy --last 5m`).

To check a sheet, draw every mood into one picture with `/Applications/DeskBuddy.app/Contents/MacOS/DeskBuddy --sheet out.png fox`.
