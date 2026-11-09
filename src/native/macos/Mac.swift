// The rest of the macOS layer: paths, image loading, the screens and mouse, the menu bar
// item, and the Unix socket sessions report to.
import AppKit
import DeskBuddyCore
import Network

let home = FileManager.default.homeDirectoryForCurrentUser
let paths = Paths(dataDir: home.appendingPathComponent("Library/Application Support/DeskBuddy"),
                  legacyDir: home.appendingPathComponent(".claude/desk-buddy"),
                  resources: Bundle.main.resourceURL,
                  endpoint: home.appendingPathComponent("Library/Application Support/DeskBuddy/buddy.sock").path)

/// PNGs through ImageIO. The core gets the pixels; the CGImage stays for drawing.
struct MacImages: ImageLoader {
    func load(_ url: URL) -> Bitmap? {
        guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Bitmap(width: w, height: h, pixels: pixels, native: image) : nil
    }
}

struct MacDesktop: Desktop {
    func screens() -> [Screen] { NSScreen.screens.map { Screen(frame: Rect($0.frame), visible: Rect($0.visibleFrame)) } }
    var mouseLocation: Point { Point(NSEvent.mouseLocation) }
    var primaryButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
}

// The menu bar item. It paints the core's menu and hands each pick back to it.
final class MenuBarItem: NSObject, Tray {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    weak var delegate: TrayDelegate?
    var choices: [TrayChoice] = [] // each menu item's tag is its place in here

    override init() {
        super.init()
        item.button?.title = "🐾" // the core sends the menu once the stage starts
    }

    func show(_ menu: TrayMenu) {
        item.button?.title = menu.buddiesOut == 0 ? "🐾" : "🐾 \(menu.buddiesOut)"
        choices = []
        let built = NSMenu()
        built.autoenablesItems = false
        let heading = NSMenuItem(title: "Buddies", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        built.addItem(heading)
        built.addItem(.separator())
        for row in menu.rows {
            let buddy = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            buddy.state = row.checked ? .on : .off
            let actions = NSMenu()
            actions.autoenablesItems = false
            actions.addItem(entry("Add", .add(row.id), enabled: row.canAdd))
            actions.addItem(entry("Remove", .remove(row.id), enabled: row.canRemove))
            actions.addItem(entry("Default", .makeDefault(row.id), enabled: row.canMakeDefault))
            buddy.submenu = actions
            built.addItem(buddy)
        }
        built.addItem(.separator())
        built.addItem(entry("Send buddies home", .sendHome, enabled: true, key: "q"))
        item.menu = built
    }

    func entry(_ title: String, _ choice: TrayChoice, enabled: Bool, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: key)
        entry.target = self
        entry.tag = choices.count
        entry.isEnabled = enabled
        choices.append(choice)
        return entry
    }

    @objc func picked(_ sender: NSMenuItem) {
        guard choices.indices.contains(sender.tag) else { return }
        delegate?.choose(choices[sender.tag])
    }
}

// Does anything answer on this socket? A file nothing answers on is left by a crash.
func socketAnswers(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

// HTTP over a Unix socket, on the main queue. File permissions keep it to this user,
// so it needs no token. Each connection carries one request.
final class Server {
    var route: (String, Data) -> Reply = { _, _ in Reply(status: 503) }
    var listener: NWListener?
    let path: String

    init(path: String) { self.path = path }

    func start() {
        // Too long and NWListener says it's ready, but makes no socket. The buddy still runs.
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            NSLog("DeskBuddy: socket path is too long, so sessions can't reach this app: %@", path)
            return
        }
        if socketAnswers(path) { exit(0) } // another copy is already running
        do {
            unlink(path)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("DeskBuddy: socket failed: %@", String(describing: error)) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.read(connection, Data())
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("DeskBuddy: could not open the socket: %@", String(describing: error))
        }
    }

    func stop() {
        guard listener != nil else { return }
        listener?.cancel()
        unlink(path)
    }

    func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequest) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = received + (data ?? Data())
            if let reply = HTTP.reply(to: buffer, route: self.route) {
                connection.send(content: HTTP.encode(reply), completion: .contentProcessed { _ in
                    connection.cancel()
                    reply.then?()
                })
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }
}

// Between the core's geometry and CoreGraphics'.
extension CGPoint { init(_ p: Point) { self.init(x: p.x, y: p.y) } }
extension CGSize { init(_ s: Size) { self.init(width: s.width, height: s.height) } }
extension CGRect { init(_ r: Rect) { self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height) } }
extension Point { init(_ p: CGPoint) { self.init(x: p.x, y: p.y) } }
extension Rect { init(_ r: CGRect) { self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height) } }
