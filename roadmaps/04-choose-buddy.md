# 4. Choose your buddy

How to tackle [section 4 of the roadmap](../ROADMAP.md#4-choose-your-buddy): the person chooses their buddies in the menu bar or tray menu. The app opens with only the default buddy. Buddies added from the menu come out straight away and wait for work.

## Decisions

- **No picker window.** Everything happens in the menu bar or tray menu, so there is no new UI to build, only a menu.
- **The app opens with only the default buddy.** There is always one default, and it is always on screen.
- **Add brings a buddy out straight away.** It rests until work from a session comes in, and it stays out until it is removed or the app quits.
- **Added buddies last for one launch.** Only the default is saved.
- **The same buddy can be added more than once,** for more than one copy.
- **Remove sends home the oldest added copy,** even at work. Its session falls to a free buddy, or a new one. The default itself can't be removed, only added copies of it.
- **When more sessions are working than there are buddies,** a temporary copy of the default comes out, and goes home when its work is done.
- **Changes take effect straight away.** No relaunch, and no session needed.
- **`/desk-buddy avatar <name>` sets the default,** as the menu's Default does. A session's own pick is retired, and reports no longer carry one.

## What the code did before

- **`Stage.cast()` already shares buddies out.** Work goes to a spare buddy before a new one is made, and the last buddy out never goes home. That is close to what this section needs.
- **Every buddy wears the same avatar.** It is the session's pick, or the default from `avatars.json`, through `AvatarLibrary.sprite()`. Nothing picks a different buddy for each new window.
- **The menu has one item,** "Send buddies home". The `Tray` protocol only has `show(buddies:)`.
- **Picking needs a session,** through `/desk-buddy avatar <name>`.

## The menu

```
Buddies
---
<buddy-name>
   -> Add
   -> Remove
   -> Default
```

- `Buddies` is a heading, followed by a separator.
- `<buddy-name>` is one row for every bundled buddy and every buddy made with `/desk-buddy create`, shown by display name.
- `->` is a submenu on each row.
- Each row has a checkmark when the buddy is out, shows `×2` when two copies are out, and marks the default with `(default)`.
- "Send buddies home" stays at the bottom of the menu.

### What each item does

- **Add** brings out another copy of the buddy straight away, resting until work comes in.
- **Remove** sends home the oldest added copy. It is disabled when no copy has been added, so the default itself always stays.
- **Default** makes the buddy the default and saves it. An added copy of it takes over as the default if there is one; otherwise a new one comes out. The old default goes home once it has nothing to do.

## Who comes out

- [x] The default buddy is always on screen, resting or at work.
- [x] New work goes to a free buddy first: one that is resting, or whose session has stopped. Buddies that stay out go before temporary ones.
- [x] When no buddy is free, a temporary copy of the default comes out and takes the work.
- [x] Temporary buddies go home when they have nothing to do. Added ones stay until removed.
- [x] Each buddy wears its own avatar, instead of every buddy wearing the session's pick.

## Build it

- [x] The core builds the menu: the buddies, how many of each are out, and which is the default. It also handles Add, Remove and Default. `Tray` grows from `show(buddies:)` to showing that menu (`show(_: TrayMenu)`, with picks coming back through `TrayDelegate`).
- [ ] macOS paints the menu with `NSMenu`, and Windows with `TrackPopupMenu`. Neither holds any behaviour of its own. Both are written; the Windows one hasn't been built yet.
- [x] Save the default in the app's data folder, so it survives a relaunch. It is `default` in `avatars.json`. Added buddies aren't saved.
- [x] List buddies made with `/desk-buddy create` in the menu beside the bundled ones.
- [ ] Draw more buddies for the starter set and add them to the bundled list. Each needs all 13 states from [AVATAR-SHEETS.md](../src/mod/tool-avatar-maker/AVATAR-SHEETS.md).

## Open questions

None left. The answers are under Decisions.
