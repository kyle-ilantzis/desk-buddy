# How the avatar changes between states

Handoff note for agents working on `src/native/macos/DeskBuddy.swift`. Line numbers are from commit `92660d0` and may drift, so search by function name if they don't match. The sprite sheet rules are in `src/mod/tool-avatar-maker/AVATAR-SHEETS.md`.

## Summary

There is no transition logic. Each frame, the overlay works out which animation row to show, so a state change is a hard cut to the new row with no crossfade.

## Pipeline

### 1. The mood arrives (as each report does)

`Stage.receive()` takes each `POST /report` from the mod, keeps it in memory unless its `seq` is older, and calls `refresh()` straight away. `Stage.tick()` calls `refresh()` once a second too, for the changes only time brings. `Buddy.apply()` (line 338) passes the report's mood to `setMood()` (line 351), which stores it, resets `moodSince` and clears any pause (`restUntil`). A buddy with no session calls `rest()` (line 345) and gets the mood `idle`.

### 2. The mood becomes a displayed state (20 times a second)

`Buddy.step()` (line 394) adjusts the mood before drawing:

- `done` and `error` show for 6 seconds, then display as `idle`. The stored `mood` doesn't change, only the local `shown`.
- `view.asleep` follows `Buddy.followRoutine()`. While `shown` is `idle` and the buddy isn't held, it wanders for `awakeFor` (90–180 seconds), naps for `napFor` (60–180 seconds), stands for `wakingFor` (2 seconds), then wanders again. Any other `shown`, or being carried, wakes it and starts the routine over.
- `view.held` is true while the mouse is carrying the buddy.
- `view.moving` is true only on frames where the buddy actually moved. It's false during pauses and while the cursor is over the body.

The local `held` in `step()` is the time since `moodSince`, not the carried flag. The carried flag is `isHeld`.

### 3. The state picks a sheet row

`Sprite.animation(mood:moving:asleep:held:)` (line 163) uses the first row that exists:

| Condition | Rows tried, in order |
|---|---|
| Held | `held`, then `idle` |
| Asleep | `asleep`, then `idle` |
| Moving | the mood's row (`walk` if the mood is `idle`), then `walk`, then `idle` |
| Standing still | the mood's row, then `idle` |

A mood with no row of its own, like `starting`, walks when moving and idles when still.

### 4. The row picks a frame

`Sprite.frame(_:tick:)` (line 168) uses column `start + tick % frames`, where `tick` is `Int(clock * fps)` (`BuddyView.spriteTick`, line 243). `view.clock` never resets, so a new animation usually starts partway through its cycle rather than on its first frame.

## Other things that change with state

### Speed, pauses and caption

These come from `style()` (line 41):

| Mood | Speed | Pause (s) | Caption |
|---|---|---|---|
| `thinking` | 55 | 0.4–1.6 | thinking… |
| `reading` | 90 | 0.3–1.0 | reading |
| `editing` | 150 | 0.2–0.7 | writing |
| `running` | 300 | 0.0–0.2 | running |
| `browsing` | 120 | 0.3–0.9 | on the web |
| `delegating` | 170 | 0.2–0.8 | sent a helper |
| `waiting` | 0 | n/a | needs you! |
| `done` | 0 | n/a | done! |
| `error` | 0 | n/a | uh oh |
| anything else | 28 | 3–9 | none |

### Hop

Set in `step()` (line 433):

- `waiting` bounces up to 16.
- `done` bounces up to 24.
- Walking bounces up to 3.
- Being carried overrides all of these with a float and bob (line 441).

### Name tag colour

Set in `BuddyView.draw()` (line 282): red for `waiting`, orange for `error`, otherwise black.

### Sleep "z"

Drawn in code on top of the sprite in `BuddyView.draw()` (line 270). It doesn't come from the sheet.

## Changing the sheet itself

`Buddy.dress()` (line 358) swaps the whole sprite when the session's avatar pick changes, for example when the buddy takes a new session. `poll()` calls it every second. `AvatarLibrary.sprite()` resolves the pick, or else the `default` in `avatars.json`, looking the name up in `avatars.json` and then among the bundled sheets, and falls back to `kyle`. A resting buddy clears its pick, so it goes back to the default avatar, and `dress()` puts that avatar's name on its tag.

## Adding a new state

- Add the name to `animationNames` (line 21). `checkAvatar()` then requires it in every generated avatar, and `writeSheetPreview()` draws it.
- Add a case to `style()`, or the mood gets the idle speed and no caption.
- If it shouldn't count as working, add it to the list in `Report.working` (line 33). That list decides who holds a buddy.
- If it needs a hop, a tag colour or a timed return to `idle`, update `step()` and `BuddyView.draw()`.
- A hopping state also needs adding to `lively` in `step()` (line 445), or it redraws too rarely to look smooth.
