# 2. Bundled avatars

How to tackle [section 2 of the roadmap](../ROADMAP.md#2-bundled-avatars): the app ships with two avatars, `kyle` and `melody`, and the settings work from a list of them rather than one built-in sheet.

## Bundle the avatars

- [x] Rename the bundled avatar from `buddy` to `kyle`. That covers `macos/assets/`, `macos/build.sh`, `bundledSprite()`, the example sheet the avatar maker is given, and the docs.
- [x] Bundle `melody`. Copy its sheet and config from the app's data folder into `macos/assets/`, with `sheet` changed to `melody.png`. It already has all 13 states.

## Work from a list

- [x] Replace the single bundled sprite with a list of well-known avatars. `AvatarLibrary` looks a name up in `avatars.json`, then in the list, and falls back to `kyle`.
- [x] Have `/desk-buddy avatar` list and pick the bundled avatars beside the configured ones, and keep a session's own pick working.
- [x] Save a pick when there is no `avatars.json`. `rememberDefault` skips that case today, because every buddy is then built in, so a pick of `melody` would be lost.
- [x] Retire `builtin` in favour of `kyle`. A saved `builtin` default or session pick keeps working and wears `kyle`.
- [x] Reserve the bundled names, so `/desk-buddy create` and `--install-avatar` refuse them. An existing `avatars.json` entry with one of those names still wins, so a `melody` that is already installed keeps working.

## Name an avatar

- [x] Let `/desk-buddy create` take a display name, such as `"Mr Rex"`. Today it only takes a lowercase id. Keep an id (`mr-rex`) for picks and file names, save the display name as `name` in `avatars.json`, and show it in `/desk-buddy avatar`.
- [x] Show the avatar's display name on a resting buddy's name tag, in place of `restingName`. An avatar with no `name`, such as one already installed, shows its id. A buddy at work keeps its project's name.
