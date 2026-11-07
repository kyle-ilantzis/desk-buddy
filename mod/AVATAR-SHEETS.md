# Avatar sprite sheets

What a desk buddy sheet must hold. `../macos/assets/buddy.png` and `buddy.json` are the built-in avatar: a complete example of every state, at a smaller frame size than generated avatars use.

## The states

There are 13 animations, one row each, in this order. A generated avatar must have all of them. The frames and fps are the built-in avatar's, as a guide.

| Row | Name | Plays when | What it should show | Frames @ fps |
| --- | --- | --- | --- | --- |
| 0 | `idle` | Nothing is happening: a session started, was interrupted, or a `done` or `error` wore off. Also `starting`, which has no row. | Standing calmly. Long and slow, so a blink or breath stays rare. | 16 @ 4 |
| 1 | `walk` | An idle buddy strolling between spots. | A relaxed walk cycle, facing right. | 6 @ 4 |
| 2 | `thinking` | Claude is working out a reply, or uses a tool with no mood of its own. | Pondering, feet stepping slowly. | 6 @ 8 |
| 3 | `reading` | Read, Grep, Glob, LS. | Holding a book or papers, feet stepping. | 6 @ 12 |
| 4 | `editing` | Edit, Write, MultiEdit. | Writing with a pencil that taps, feet stepping. | 6 @ 16 |
| 5 | `running` | Bash and other commands. | A sprint, with speed lines behind it. | 6 @ 20 |
| 6 | `browsing` | WebFetch, WebSearch, browser tools. | Holding a globe or screen, feet stepping. | 6 @ 16 |
| 7 | `delegating` | Agent, Task. | A small helper trailing behind it. | 6 @ 20 |
| 8 | `waiting` | A question or a permission prompt: it needs the person. | Standing, waving an arm to get attention. | 6 @ 10 |
| 9 | `done` | A turn finished. Plays for 6 seconds. | Delighted, with sparkles around it. | 6 @ 10 |
| 10 | `error` | A turn ended in failure. Plays for 6 seconds. | Dazed: X eyes or similar. | 1 @ 1 |
| 11 | `asleep` | On and off while idle, first after 90 to 180 seconds. | Eyes closed, resting. | 1 @ 1 |
| 12 | `held` | Carried by the mouse. | Surprised, feet dangling. | 6 @ 5 |

## What the overlay does, so the art must not

- **Hops and floating.** It lifts the whole sprite for `waiting`, `done`, walking bounces and `held`. Draw these in place.
- **The shadow, the name tag and the drifting "z" of `asleep`.**
- **Facing left.** It mirrors the art. Draw everything facing right, and keep lettering out of it.

## How rows play

- Rows 2 to 7 play while the buddy moves and during its short pauses, so feet should step rather than stand. There is no separate still version.
- Every row loops, and the first frame follows the last: make that seamless.
- `waiting`, `done`, `error`, `asleep` and `held` never move across the screen.
- The overlay redraws at 20 Hz, so an fps above 20 shows no more.

## Sheet rules

- A PNG with a transparent background: frames must not fill their cells edge to edge.
- A grid counted from the top left: one row per animation, frames from column 0. The sheet is as wide as its longest row. Unused cells stay empty.
- The character stands on the bottom edge of its cell, centred left to right, in the same place in every frame of every row so it doesn't jitter. That includes `asleep` and `held`: the overlay lifts `held` itself. Props reach out to the sides of the cell.
- It is scaled without smoothing, so use hard pixels: no antialiasing, soft shadows or gradients.
- The overlay measures the character from the first `idle` frame, for its shadow, name tag and grab area. Keep props out of that frame.

Generated avatars should use 64x48 frames at `scale` 2 with the character about 26 pixels tall, which is the built-in avatar's size on screen (52 points). Nothing is drawn larger than 256 points.

## avatar.json

The same shape as an entry in `avatars.json`. `sheet` is filled in on install.

```json
{
  "frameWidth": 64,
  "frameHeight": 48,
  "scale": 2,
  "animations": {
    "idle": { "row": 0, "frames": 16, "fps": 4 },
    "walk": { "row": 1, "frames": 6, "fps": 4 }
  }
}
```

This shows two of the 13. List them all, each with its `row`, `frames` and `fps`. Set `"facesLeft": true` only if the art faces left.

## Checking and installing

With `DeskBuddy` being `/Applications/DeskBuddy.app/Contents/MacOS/DeskBuddy`, and a folder holding `sheet.png` and `avatar.json`:

- `DeskBuddy --check-avatar <folder> <preview.png>` lists what's wrong, such as a missing state or a blank frame, and draws every state as the overlay would.
- `DeskBuddy --install-avatar <name> <folder>` runs the same checks, copies the sheet to `~/Library/Application Support/DeskBuddy/sprites/<name>.png`, and adds it to `avatars.json`.
