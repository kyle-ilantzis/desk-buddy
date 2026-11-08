// What each OS fills in for the core. The core imports only Foundation, so anything
// that touches windows, the mouse, the screens, the tray or image files comes through here.
//
// Coordinates are the macOS convention everywhere in the core: points, y up, with the
// origin at the bottom left of the main screen. A layer whose OS counts y down from the
// top flips at its edge.
import Foundation

/// Where the app keeps its data and finds what it ships with.
public struct Paths {
    public let dataDir: URL          // avatars.json and sprites/ live here
    public let legacyDir: URL?       // where data lived before, moved over on launch; nil if there was no before
    public let resources: URL?       // the bundled avatars: <name>.png and <name>.json
    public let endpoint: String      // the socket or pipe sessions report to
    public var avatarsFile: URL { dataDir.appendingPathComponent("avatars.json") }

    public init(dataDir: URL, legacyDir: URL?, resources: URL?, endpoint: String) {
        self.dataDir = dataDir
        self.legacyDir = legacyDir
        self.resources = resources
        self.endpoint = endpoint
    }
}

/// Reads a picture file into pixels the core can look at.
public protocol ImageLoader {
    func load(_ url: URL) -> Bitmap?
}

/// One display: all of it, and the part not under the Dock, menu bar or taskbar.
public struct Screen {
    public let frame: Rect
    public let visible: Rect
    public init(frame: Rect, visible: Rect) { self.frame = frame; self.visible = visible }
}

/// The screens and the mouse.
public protocol Desktop {
    func screens() -> [Screen]
    var mouseLocation: Point { get }
    var primaryButtonDown: Bool { get }
}

/// What a window tells its buddy about the mouse.
public protocol OverlayWindowDelegate: AnyObject {
    func grab()
    func drag()
    func drop()
}

/// One buddy's window: transparent, borderless, above everything, on every space.
public protocol OverlayWindow: AnyObject {
    /// Held weakly.
    var delegate: OverlayWindowDelegate? { get set }
    /// Moves and sizes the window. The frame is in screen coordinates.
    func place(_ frame: Rect)
    /// Whether clicks go through to whatever is underneath.
    func setClickThrough(_ through: Bool)
    /// Draws this look, now or on the next pass. A layer lays it out with `Scene`.
    func show(_ look: Look)
    func close()
}

/// The menu bar or notification area item.
public protocol Tray: AnyObject {
    func show(buddies: Int)
}

/// Everything an OS layer hands the core's `Stage`.
public struct Platform {
    public let paths: Paths
    public let images: ImageLoader
    public let desktop: Desktop
    public let tray: Tray
    public let makeWindow: () -> OverlayWindow
    public let quit: () -> Void
    /// `GET /status` extras: version, binary, resources.
    public let info: () -> [String: Any]

    public init(paths: Paths, images: ImageLoader, desktop: Desktop, tray: Tray,
                makeWindow: @escaping () -> OverlayWindow, quit: @escaping () -> Void, info: @escaping () -> [String: Any]) {
        self.paths = paths
        self.images = images
        self.desktop = desktop
        self.tray = tray
        self.makeWindow = makeWindow
        self.quit = quit
        self.info = info
    }
}

/// Where the core's messages go. A layer can point it at its own log.
public var logLine: (String) -> Void = { FileHandle.standardError.write(Data(("desk-buddy: " + $0 + "\n").utf8)) }
