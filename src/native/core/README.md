# Core

What every OS shares, as the Swift module `DeskBuddyCore`. It imports only Foundation, never AppKit or WinSDK. See [roadmaps/05-os-core-split.md](../../../roadmaps/05-os-core-split.md).

| File | What |
|---|---|
| `Platform.swift` | The protocols each OS fills in: `OverlayWindow`, `Tray`, `ImageLoader`, `Desktop`, and the `Paths` and `Platform` it hands the core |
| `Stage.swift` | The sessions' reports, who works for whom (`cast`), and the `/report`, `/status` and `/quit` routes |
| `Buddy.swift` | One buddy: walking, moods, naps, and being picked up and dropped |
| `Sprite.swift` | Sprite sheets, `avatars.json`, and the bundled avatars |
| `Scene.swift` | What a buddy looks like (`Look`) and where each piece goes in its window (`Scene`), which each OS paints |
| `HTTP.swift` | Request parsing and replies; each OS owns the transport |
| `Tools.swift` | `--sheet`, `--check-avatar` and `--install-avatar`, and the data folder's upkeep |
| `Geometry.swift` | `Point`, `Size` and `Rect`, y up |

The core counts y up from the bottom left of the main screen, as macOS does.

`assets/` holds the bundled avatars, which each platform's build copies into its app.

Test it with `swift test --package-path src/native --scratch-path build/swiftpm`, from the repo root.
