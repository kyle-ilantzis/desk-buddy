# OS and core split

How to tackle the native stack for [section 5 of the roadmap](../ROADMAP.md#5-windows-support): the overlay splits into a shared core and a thin layer per OS, so that the Windows app shares everything but the OS-specific code with the macOS one.

## Decisions

- **Everything native stays in Swift.** Swift has official Windows support: the toolchain from swift.org, plus the Visual Studio Build Tools and the Windows SDK, gives `swift build` with Swift Package Manager as on macOS. The macOS app was already Swift (one file, `src/native/macos/DeskBuddy.swift`), so nothing was rewritten.
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

- [ ] **Prove the hard part first.** A Swift spike on Windows: one layered, always-on-top window showing a sprite, where clicks on transparent pixels reach the window below and clicks on the sprite pick it up. Not done as a separate spike: the Windows layer was written straight against the core, on macOS, so the first Windows build and run is the spike.
- [x] Add `src/native/Package.swift` with the three targets, and build the macOS app through it with no change in behaviour. `build.sh` runs `swift build` once per architecture and joins them with `lipo`; the `--sheet` previews of both bundled avatars match the old app's pixel for pixel.
- [x] Move the shared logic out of `DeskBuddy.swift` into `DeskBuddyCore`, behind the platform protocols. `swift test` runs the core's tests against a stand-in OS.
- [ ] Build the Windows layer against those protocols, and have its build write `build/windows/DeskBuddy.zip`, runtime DLLs included. Written (`src/native/windows/app`, `build.ps1`) but not yet compiled or run on Windows.
- [ ] Build and test both OSes in CI. `.github/workflows/native.yml` does both; it hasn't run yet.

## How it came out

- **Geometry.** Foundation on macOS has `CGRect` but none of its methods without CoreGraphics, so the core has its own `Point`, `Size` and `Rect` in `Double`, y up as on macOS. The Windows layer flips y at its edge against the main screen's height (`Win32.swift`).
- **Images.** The core never decodes a file. `ImageLoader` hands it a `Bitmap` of premultiplied RGBA, which it reads for the body's size and the avatar checks, and the decoded native image rides along in `Bitmap.native` for drawing: a `CGImage` on macOS, a GDI+ bitmap on Windows.
- **Drawing.** The core lays a buddy out as a `Scene` (shadow, sprite cell and mirroring, the "z", the name tag and its tint) from a `Look`, and each OS only paints it. Text measuring is passed in, since fonts are the OS's. `--sheet` and `--check-avatar` previews use the same path.
- **Transport.** The HTTP parsing and replies are in the core (`HTTP.swift`). macOS keeps its Unix socket; Windows listens on the named pipe `\\.\pipe\DeskBuddy-%USERNAME%`, which Node's `socketPath` reaches as it does a Unix socket. The pipe threads hand each request to the main thread with `SendMessageW`.
- **GDI+ from Swift.** Windows' `gdiplus.h` is C++ only, so the flat API calls are declared again in C in `src/native/windows/gdiplus` (the `CGdiPlus` target).
- **Timer.** Each layer calls `Stage.tick(dt)` 20 times a second; the stage does its once-a-second housekeeping itself.

Still open on Windows: DPI awareness (it runs unaware, so Windows scales it), an app icon (the tray uses the stock one), and an installer. The mod's `WindowsBridge` is section 5's next part.
