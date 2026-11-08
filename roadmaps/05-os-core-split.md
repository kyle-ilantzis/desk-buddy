# OS and core split

How to tackle the native stack for [section 5 of the roadmap](../ROADMAP.md#5-windows-support): the overlay splits into a shared core and a thin layer per OS, so that the Windows app shares everything but the OS-specific code with the macOS one.

## Decisions

- **Everything native stays in Swift.** Swift has official Windows support: the toolchain from swift.org, plus the Visual Studio Build Tools and the Windows SDK, gives `swift build` with Swift Package Manager as on macOS. The macOS app is already Swift (`src/native/macos/DeskBuddy.swift`), so nothing is rewritten.
- **The core is written once.** It imports only Foundation, never AppKit or WinSDK.
- **Each OS layer calls its own APIs directly.** AppKit on macOS, and Win32 through `import WinSDK` on Windows. There is no UI framework in between.
- **Each OS builds on that OS.** Building the Windows app from macOS isn't practical, so Windows builds run on a Windows machine or a Windows CI runner.

### Why not something else

| Option | Verdict |
|---|---|
| **Swift core with AppKit and Win32 layers** | **Use this.** The macOS code carries over, and the core is shared as it is. |
| Rust or C++ | Still needs hand-written click-through and per-pixel alpha on each OS, and rewrites the macOS side. |
| Tauri or Electron | Heavy for one sprite, and per-pixel click-through on a transparent window still takes native code on each OS. |

## Layout

One Swift package at `src/native/Package.swift`, with three targets:

```
src/native/Package.swift
src/native/core      DeskBuddyCore   imports only Foundation
src/native/macos     DeskBuddyMac    AppKit, macOS only
src/native/windows   DeskBuddyWin    WinSDK, Windows only
```

- **Core:** session reading, who works for whom (`cast`), movement, moods, animation timing, and `avatars.json` and sprite sheet handling. It defines protocols that each OS fills in, such as `OverlayWindow`, `Tray`, `ImageLoader` and `Paths`.
- **Each OS layer** runs the timer and calls `core.tick(dt)`, and draws what the core says to draw.
- `Package.swift` limits each executable target to its own platform, and code that has to tell them apart uses `#if os(Windows)` and `#if os(macOS)`.
- `src/native/macos/build.sh` moves from `swiftc` on one file to `swift build`, and still writes the same app bundle.

## The Windows layer

How each item of the platform layer maps to Win32:

| Need | Win32 approach |
|---|---|
| Transparent, always on top, borderless | `CreateWindowExW` with `WS_EX_LAYERED \| WS_EX_TOPMOST \| WS_EX_TOOLWINDOW` and a `WS_POPUP` style |
| Per-pixel alpha | Draw the sprite into a premultiplied BGRA DIB, then call `UpdateLayeredWindow` |
| Clicks pass through everything but the buddy | Comes almost for free: with `UpdateLayeredWindow`, pixels with alpha 0 don't take clicks. For more control, switch `WS_EX_TRANSPARENT` on and off from the cursor position. |
| Pick up and drop | `WM_LBUTTONDOWN`, then `SetCapture`, track `WM_MOUSEMOVE`, and `ReleaseCapture` on button up |
| Usable area of each screen | `EnumDisplayMonitors` and `GetMonitorInfoW`, using `rcWork` |
| Tray item and its menu | `Shell_NotifyIconW` and `TrackPopupMenu` |
| Image loading | The GDI+ flat API (`GdipCreateBitmapFromFile`), which is easier than WIC and COM from Swift |
| App data paths | `%LOCALAPPDATA%\DeskBuddy`, found with `SHGetKnownFolderPath` |
| Single instance | A named mutex from `CreateMutexW` |

## Downsides to plan for

- **Size.** The Swift runtime and Foundation DLLs ship with the Windows app, which adds roughly 30–50 MB to `build/windows/DeskBuddy.zip`. A Windows layer that avoids Foundation cuts some of that, but the core uses it for JSON.
- **Win32 from Swift is clunky at first.** Strings are UTF-16 (`withCString(encodedAs: UTF16.self)`), some macros aren't imported (`MAKEINTRESOURCE`, `LOWORD`), and callbacks must be `@convention(c)`. Write a small set of helpers once.
- **Tooling.** Debugging and editor support on Windows are behind Xcode. VS Code with the Swift extension works.
- **CI.** GitHub Actions has Windows runners, and an action such as `compnerd/gha-setup-swift` installs Swift.

## Plan

- [ ] **Prove the hard part first.** A Swift spike on Windows: one layered, always-on-top window showing a sprite, where clicks on transparent pixels reach the window below and clicks on the sprite pick it up.
- [ ] Add `src/native/Package.swift` with the three targets, and build the macOS app through it with no change in behaviour.
- [ ] Move the shared logic out of `DeskBuddy.swift` into `DeskBuddyCore`, behind the platform protocols.
- [ ] Build the Windows layer against those protocols, and have its build write `build/windows/DeskBuddy.zip`, runtime DLLs included.
- [ ] Build and test both OSes in CI.
