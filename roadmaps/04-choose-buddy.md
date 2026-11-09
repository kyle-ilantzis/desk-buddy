# 4. Choose your buddy

How to tackle [section 4 of the roadmap](../ROADMAP.md#4-choose-your-buddy): the person keeps an allow list of buddies in the menu bar or tray menu. One buddy is the default and is always out. More buddies from the list come out as more work comes in.

## Decisions

- **No picker window.** Everything happens in the menu bar or tray menu, so there is no new UI to build, only a menu.
- **The allow list is the set of buddies that may come out.** Bundled buddies and ones made with `/desk-buddy create` can both be on it.
- **There is always one default.** It is always on the list and always on screen. There is never more than one default.
- **Changes take effect straight away.** No relaunch, and no session needed.

## What the code does today

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
- Each row shows whether the buddy is on the list, and which one is the default, for example with a checkmark.
- "Send buddies home" stays at the bottom of the menu.

### What each item does

- **Add** puts the buddy on the allow list. It doesn't come out straight away. It is free to take the next work that needs another buddy.
- **Remove** takes the buddy off the list. It is disabled on the default, so the default always stays.
- **Default** makes the buddy the default, and adds it to the list if it isn't on it. The old default stays on the list as an ordinary buddy.

## Who comes out

- [ ] The default buddy is always on screen, resting or at work.
- [ ] New work goes to a free buddy first: one that is resting, or whose session has stopped. This is what `cast()` does today.
- [ ] When no buddy is free, a buddy from the allow list that isn't on screen yet comes out and takes the work.
- [ ] Buddies other than the default go home when they have nothing to do, as they do today.
- [ ] Each buddy wears its own avatar, instead of every buddy wearing the session's pick.

## Build it

- [ ] The core builds the menu: the buddies, which are on the list, and which is the default. It also handles Add, Remove and Default. `Tray` grows from `show(buddies:)` to showing that menu.
- [ ] macOS paints the menu with `NSMenu`, and Windows with `TrackPopupMenu`. Neither holds any behaviour of its own.
- [ ] Save the allow list and the default in the app's data folder, so they survive a relaunch. The default could stay as `default` in `avatars.json`.
- [ ] List buddies made with `/desk-buddy create` in the menu beside the bundled ones.
- [ ] Draw more buddies for the starter set and add them to the bundled list. Each needs all 13 states from [AVATAR-SHEETS.md](../src/mod/tool-avatar-maker/AVATAR-SHEETS.md).

## Open questions

- **What happens when every buddy on the list is out, and more work comes in?** The work could wait for a free buddy, or a busy buddy could take on a second session.
- **What happens when a buddy at work is removed?** It could go home straight away, or finish its work first.
- **What becomes of `/desk-buddy avatar <name>`?** It could set the default, or be retired now that the menu does the job. The same goes for a session's own pick.
- **Does a newly created buddy start on the list?**
