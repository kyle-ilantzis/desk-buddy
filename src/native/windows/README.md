# Windows

The Win32 layer, `DeskBuddyWin`, on the shared core in `../core`. See [roadmaps/05-os-core-split.md](../../../roadmaps/05-os-core-split.md).

**Status: written, not yet built or run on Windows.** It was written on macOS against the core's protocols, and the first build on Windows, by hand or in CI, will turn up what needs fixing.

| File | What |
|---|---|
| `app/main.swift` | Startup, single instance (a named mutex), the timer and the message loop |
| `app/Overlay.swift` | A buddy's window: layered, topmost, tool window, never activated; painted with `UpdateLayeredWindow`, click-through with `WS_EX_TRANSPARENT` |
| `app/Paint.swift` | Paints the core's `Scene` with GDI+, and writes `--sheet` previews |
| `app/Windows.swift` | Paths, PNG loading, screens and mouse, the notification area icon, and the named pipe |
| `app/Win32.swift` | Wide strings, constants, and the y flip |
| `gdiplus/` | The GDI+ flat API declared in C, since `gdiplus.h` is C++ only |

- Data lives in `%LOCALAPPDATA%\DeskBuddy`.
- Sessions report over the named pipe `\\.\pipe\DeskBuddy-%USERNAME%`, with the same HTTP as the macOS socket. That is what the mod's `WindowsBridge.socketPath` should return.

## Build

On Windows, with the Swift toolchain from swift.org, the Visual Studio Build Tools and the Windows SDK:

```powershell
src\native\windows\build.ps1
```

It writes `build\windows\DeskBuddy.zip`: `DeskBuddy\DeskBuddy.exe`, the Swift runtime DLLs beside it, and `Resources\` with the bundled avatars and `VERSION`. `scripts/dist.sh` copies that zip to `dist/desk-buddy/app/DeskBuddy-windows.zip` when it is there.
