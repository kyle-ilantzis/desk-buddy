// The overlay: one small window per buddy, walking the screen. Clicks pass through
// all of it but the buddy's body, which can be picked up. Sessions report to it over a Unix socket, and it keeps
// their reports in memory. It draws the sprite sheet bundled with the app, or one from avatars.json in its data folder.
// The sheet's rules are in ../mod/AVATAR-SHEETS.md.
// Merely open sessions get no buddy: one is out per session at work, and one
// always stays, resting, to take the next session that starts working.
import AppKit
import Network

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent("Library/Application Support/DeskBuddy")
let oldBuddyDir = home.appendingPathComponent(".claude/desk-buddy") // where data lived before
let avatarsFile = buddyDir.appendingPathComponent("avatars.json")
let socketFile = buddyDir.appendingPathComponent("buddy.sock")
let protocolVersion = 1
let maxRequest = 64 * 1024
let staleAfter: TimeInterval = 45      // no heartbeat: the session has gone
let idleGrace: TimeInterval = 60       // a session keeps its buddy this long after its last turn
let awakeFor: ClosedRange<TimeInterval> = 90...180 // an idle buddy wanders this long
let napFor: ClosedRange<TimeInterval> = 60...180   // then naps this long
let wakingFor: TimeInterval = 2                    // and stands a moment before it walks off
let restingName = "buddy"
let winW: CGFloat = 190, winH: CGFloat = 112
let spriteFit: CGFloat = 64  // a sheet with no "scale" is drawn about this tall
let spriteMax: CGFloat = 256 // and no sheet is drawn larger than this
let tagGap: CGFloat = 28     // from the top of the body to the name tag: a full hop fits under it
let animationNames = ["idle", "walk", "thinking", "reading", "editing", "running", "browsing",
                      "delegating", "waiting", "done", "error", "asleep", "held"]

struct Report: Decodable {
    let id: String
    let seq: Int // reports can arrive out of order: a session's highest so far wins
    let project: String
    let mood: String
    let tool: String?
    let avatar: String?
    let updatedAt: Double
    let idleSince: Double? // when its last turn ended; nil if none ran or one is running

    var working: Bool { !["starting", "idle", "done", "error", "ended"].contains(mood) }
    var holdsBuddy: Bool {
        working || idleSince.map { Date().timeIntervalSince1970 - $0 / 1000 < idleGrace } ?? false
    }
}

struct Style { let speed: CGFloat; let caption: String; let pause: ClosedRange<Double> }

func style(_ mood: String, _ tool: String?) -> Style {
    switch mood {
    case "thinking":   return Style(speed: 55,  caption: "thinking…", pause: 0.4...1.6)
    case "reading":    return Style(speed: 90,  caption: "reading", pause: 0.3...1.0)
    case "editing":    return Style(speed: 150, caption: "writing", pause: 0.2...0.7)
    case "running":    return Style(speed: 300, caption: "running", pause: 0.0...0.2)
    case "browsing":   return Style(speed: 120, caption: "on the web", pause: 0.3...0.9)
    case "delegating": return Style(speed: 170, caption: "sent a helper", pause: 0.2...0.8)
    case "waiting":    return Style(speed: 0,   caption: "needs you!", pause: 1...1)
    case "done":       return Style(speed: 0,   caption: "done!", pause: 1...1)
    case "error":      return Style(speed: 0,   caption: "uh oh", pause: 1...1)
    default:           return Style(speed: 28,  caption: "", pause: 3...9)
    }
}

struct AnimationConfig: Decodable {
    let row: Int
    let start: Int?
    let frames: Int?
    let fps: Double?
}

struct AvatarConfig: Decodable {
    let sheet: String
    let frameWidth: Int
    let frameHeight: Int
    let scale: CGFloat?
    let fps: Double?
    let facesLeft: Bool?
    let animations: [String: AnimationConfig]?
}

struct AvatarsConfig: Decodable {
    let `default`: String?
    let avatars: [String: AvatarConfig]
}

// Where a picture's visible pixels are, counted from its top left; nil if it has none.
func visibleBounds(_ image: CGImage) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    let w = image.width, h = image.height
    var alpha = [UInt8](repeating: 0, count: w * h)
    let drawn = alpha.withUnsafeMutableBytes { bytes -> Bool in
        guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    var found: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
    for y in 0..<h {
        for x in 0..<w where alpha[y * w + x] > 8 {
            let f = found ?? (x, x, y, y)
            found = (min(f.minX, x), max(f.maxX, x), min(f.minY, y), max(f.maxY, y))
        }
    }
    return found
}

// One configured sheet, cut into rows of frames counted from the top left.
final class Sprite {
    struct Animation { let row: Int; let start: Int; let frames: Int; let fps: Double }

    let image: CGImage
    let frameW: Int, frameH: Int
    let size: NSSize
    let body: NSSize // the character alone in its first idle frame, centred: frames also hold room for props
    let facesLeft: Bool
    let animations: [String: Animation]

    init?(_ name: String, _ config: AvatarConfig, base: URL = buddyDir) {
        let path = (config.sheet as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data)?.cgImage else {
            NSLog("desk-buddy: avatar %@: cannot read %@", name, url.path)
            return nil
        }
        let columns = config.frameWidth > 0 ? image.width / config.frameWidth : 0
        let rows = config.frameHeight > 0 ? image.height / config.frameHeight : 0
        guard columns > 0, rows > 0 else {
            NSLog("desk-buddy: avatar %@: a %dx%d frame does not fit its sheet", name, config.frameWidth, config.frameHeight)
            return nil
        }
        self.image = image
        frameW = config.frameWidth
        frameH = config.frameHeight
        facesLeft = config.facesLeft ?? false

        let h = CGFloat(frameH), w = CGFloat(frameW)
        let fitted = h < spriteFit ? max(1, floor(spriteFit / h)) : spriteFit / h
        let scale = min(config.scale ?? fitted, spriteMax / max(w, h))
        size = NSSize(width: w * scale, height: h * scale)

        let fps = config.fps ?? 8
        var cut: [String: Animation] = [:]
        for (mood, a) in config.animations ?? [:] {
            let start = a.start ?? 0
            guard (0..<rows).contains(a.row), (0..<columns).contains(start) else {
                NSLog("desk-buddy: avatar %@: animation %@ is outside the sheet", name, mood)
                continue
            }
            let frames = max(1, min(a.frames ?? columns - start, columns - start))
            cut[mood] = Animation(row: a.row, start: start, frames: frames, fps: max(a.fps ?? fps, 0.1))
        }
        if cut["idle"] == nil { cut["idle"] = Animation(row: 0, start: 0, frames: columns, fps: fps) }
        animations = cut

        let first = cut["idle"]!
        let idle = image.cropping(to: CGRect(x: first.start * frameW, y: first.row * frameH, width: frameW, height: frameH))
        if let seen = idle.flatMap(visibleBounds) {
            let reach = max(CGFloat(frameW) / 2 - CGFloat(seen.minX), CGFloat(seen.maxX + 1) - CGFloat(frameW) / 2)
            body = NSSize(width: reach * 2 * scale, height: CGFloat(frameH - seen.minY) * scale)
        } else {
            body = size
        }
    }

    // Room for the sprite, its hop, and the name tag above the body.
    var windowSize: NSSize {
        NSSize(width: max(winW, size.width + 60), height: max(winH, body.height + tagGap + 32, size.height + 40))
    }

    // What to play: the mood's own row, then the nearest stand-in.
    func animation(mood: String, moving: Bool, asleep: Bool, held: Bool) -> Animation {
        let wanted = held ? ["held"] : asleep ? ["asleep"] : moving ? [mood == "idle" ? "walk" : mood, "walk"] : [mood]
        return wanted.lazy.compactMap { self.animations[$0] }.first ?? animations["idle"]!
    }

    func frame(_ a: Animation, tick: Int) -> CGImage? {
        let column = a.start + tick % a.frames
        return image.cropping(to: CGRect(x: column * frameW, y: a.row * frameH, width: frameW, height: frameH))
    }
}

// The sheet inside the app, for every buddy with no sheet of its own.
func bundledSprite() -> Sprite? {
    guard let resources = Bundle.main.resourceURL,
          let data = try? Data(contentsOf: resources.appendingPathComponent("buddy.json")),
          let config = try? JSONDecoder().decode(AvatarConfig.self, from: data) else {
        NSLog("desk-buddy: the app has no buddy.json")
        return nil
    }
    return Sprite("builtin", config, base: resources)
}

// avatars.json, read again when it changes. Without it, and for a pick that names
// nothing in it, a buddy wears the bundled sheet.
final class AvatarLibrary {
    private let bundled = bundledSprite()
    private var stamp: Date?
    private var sprites: [String: Sprite] = [:]
    private var fallback: String?

    func refresh() {
        let changed = (try? avatarsFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if changed == stamp { return }
        stamp = changed
        sprites = [:]
        fallback = nil
        guard let data = try? Data(contentsOf: avatarsFile) else { return }
        do {
            let config = try JSONDecoder().decode(AvatarsConfig.self, from: data)
            fallback = config.default
            for (name, avatar) in config.avatars { sprites[name] = Sprite(name, avatar) }
        } catch {
            NSLog("desk-buddy: avatars.json: %@", String(describing: error))
        }
    }

    func sprite(_ pick: String?) -> Sprite? { (pick ?? fallback).flatMap { sprites[$0] } ?? bundled }
    func has(_ name: String) -> Bool { sprites[name] != nil }
}

final class BuddyView: NSView {
    var mood = "idle"
    var name = ""
    var caption = ""
    var facing: CGFloat = 1
    var phase: CGFloat = 0   // walk cycle, for the bounce
    var hop: CGFloat = 0
    var moving = false
    var asleep = false
    var held = false         // being carried by the mouse
    var clock: CGFloat = 0
    var sprite: Sprite?
    weak var buddy: Buddy?
    let groundY: CGFloat = 8

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { buddy?.grab() }
    override func mouseDragged(with event: NSEvent) { buddy?.drag() }
    override func mouseUp(with event: NSEvent) { buddy?.drop() }

    var body: NSSize { sprite?.body ?? NSSize(width: 56, height: 52) }

    // The part that can be grabbed, up to the top of its hop.
    var bodyRect: NSRect {
        let size = body
        return NSRect(x: bounds.midX - size.width / 2, y: groundY, width: size.width, height: size.height + hop)
    }

    // The sheet's frame counter; nil for the built-in avatar.
    var spriteTick: Int? {
        sprite.map { Int(Double(clock) * $0.animation(mood: mood, moving: moving, asleep: asleep, held: held).fps) }
    }

    func drawSprite(_ sprite: Sprite, at y: CGFloat) {
        let a = sprite.animation(mood: mood, moving: moving, asleep: asleep, held: held)
        guard let frame = sprite.frame(a, tick: spriteTick ?? 0), let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: bounds.midX, y: y)
        if (facing < 0) != sprite.facesLeft { ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(frame, in: CGRect(x: -sprite.size.width / 2, y: 0, width: sprite.size.width, height: sprite.size.height))
        ctx.restoreGState()
    }

    override func draw(_ dirty: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        let cx = bounds.midX

        // Shadow stays on the ground as the buddy hops.
        NSColor.black.withAlphaComponent(0.22).setFill()
        let shadow = body.width - 4
        NSBezierPath(ovalIn: NSRect(x: cx - shadow / 2 + hop / 3, y: groundY - 5, width: shadow - hop / 1.5, height: 8)).fill()

        if let sprite { drawSprite(sprite, at: groundY + hop) }

        if asleep {
            let drift = (clock * 0.6).truncatingRemainder(dividingBy: 1)
            drawText("z", at: NSPoint(x: cx + body.width / 2 + 2, y: groundY + hop + body.height + drift * 12), size: 12 + drift * 5, weight: .bold, color: .white.withAlphaComponent(1 - drift))
        }

        // The name tag and what it is up to.
        let label = caption.isEmpty ? name : "\(name) · \(caption)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        var text = label
        while (text as NSString).size(withAttributes: attrs).width > winW - 20 && text.count > 4 { text = String(text.dropLast(2)) + "…" }
        let size = (text as NSString).size(withAttributes: attrs)
        let tag = NSRect(x: cx - size.width / 2 - 7, y: groundY + body.height + tagGap, width: size.width + 14, height: 20)
        let fill = (mood == "waiting" ? NSColor.systemRed : mood == "error" ? NSColor.systemOrange : NSColor.black).withAlphaComponent(0.72)
        fill.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: NSPoint(x: tag.minX + 7, y: tag.minY + 3), withAttributes: attrs)
    }

    func drawText(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}

func desktopArea() -> [NSRect] { NSScreen.screens.map { $0.visibleFrame } }

func randomSpot(near start: NSPoint?, size: NSSize = NSSize(width: winW, height: winH)) -> NSPoint {
    let screens = desktopArea()
    // Mostly stay on the same display; now and then wander to another.
    let current = start.flatMap { p in screens.first { $0.contains(p) } }
    let area = (current != nil && Double.random(in: 0...1) < 0.85) ? current! : (screens.randomElement() ?? .zero)
    return NSPoint(x: CGFloat.random(in: area.minX...max(area.minX, area.maxX - size.width)),
                   y: CGFloat.random(in: area.minY...max(area.minY, area.maxY - size.height)))
}

final class Buddy {
    var session: String?          // who it works for; nil while resting
    var pick: String?             // its session's avatar; nil wears the default
    let view = BuddyView()
    let window: NSPanel
    var position: NSPoint
    var target: NSPoint
    var restUntil: Date = .distantPast
    var mood = "starting"
    var moodSince = Date()
    var napping = false
    var routineTurns: Date?       // when an idle buddy next falls asleep or wakes; nil unless idle
    var lastHeard = Date()
    var redrawTick = 0
    var shownSpriteTick: Int?
    var isHeld = false
    var grabOffset = NSPoint.zero // the cursor, from the window's corner
    var lift: CGFloat = 0         // 0 on the ground, 1 floating

    init() {
        position = randomSpot(near: nil)
        target = position
        window = NSPanel(contentRect: NSRect(origin: position, size: NSSize(width: winW, height: winH)),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true // step() turns this off only over the body
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view.name = restingName
        view.buddy = self
        window.contentView = view
        window.orderFrontRegardless()
    }

    func apply(_ report: Report) {
        lastHeard = Date(timeIntervalSince1970: report.updatedAt / 1000)
        view.name = report.project
        pick = report.avatar
        setMood(report.mood)
    }

    func rest() {
        view.name = restingName
        pick = nil
        setMood("idle")
    }

    func setMood(_ next: String) {
        guard next != mood else { return }
        mood = next
        moodSince = Date()
        restUntil = .distantPast
    }

    // An idle buddy's own routine, session or no session: it wanders, naps, wakes
    // and wanders again. Anything else, being carried too, starts it over awake.
    func followRoutine(idle: Bool) {
        guard idle else {
            napping = false
            routineTurns = nil
            return
        }
        let now = Date()
        guard let turns = routineTurns else {
            routineTurns = now.addingTimeInterval(Double.random(in: awakeFor))
            return
        }
        guard now >= turns else { return }
        napping.toggle()
        routineTurns = now.addingTimeInterval(Double.random(in: napping ? napFor : awakeFor))
        if !napping { restUntil = now.addingTimeInterval(wakingFor) }
    }

    func dress(_ sprite: Sprite?) {
        guard sprite !== view.sprite else { return }
        view.sprite = sprite
        window.setFrame(NSRect(origin: position, size: sprite?.windowSize ?? NSSize(width: winW, height: winH)), display: true)
        view.needsDisplay = true
    }

    func grab() {
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: mouse.x - position.x, y: mouse.y - position.y)
        isHeld = true
    }

    func drag() {
        let mouse = NSEvent.mouseLocation
        position = NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        window.setFrameOrigin(position)
    }

    func drop() {
        guard isHeld else { return }
        isHeld = false
        // Land on the screen under the cursor, body and name tag both in view.
        let mouse = NSEvent.mouseLocation
        if let area = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame {
            var keep = view.bodyRect
            keep.size.height = view.bounds.height - keep.minY
            keep = keep.offsetBy(dx: position.x, dy: position.y)
            position.x += max(0, area.minX - keep.minX) - max(0, keep.maxX - area.maxX)
            position.y += max(0, area.minY - keep.minY) - max(0, keep.maxY - area.maxY)
            window.setFrameOrigin(position)
        }
        target = position
        restUntil = Date().addingTimeInterval(2)
    }

    func step(_ dt: CGFloat) {
        // A mouse-up can go missing, to a screen lock or Mission Control.
        if isHeld && NSEvent.pressedMouseButtons & 1 == 0 { drop() }

        // Clicks pass through everywhere but the body.
        let mouse = NSEvent.mouseLocation
        let hovered = view.bodyRect.contains(NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY))
        let clickThrough = !hovered && !isHeld
        if window.ignoresMouseEvents != clickThrough { window.ignoresMouseEvents = clickThrough }

        // "done" and "error" play for a few seconds and then settle into idle.
        var shown = mood
        let held = Date().timeIntervalSince(moodSince)
        if (mood == "done" || mood == "error") && held > 6 { shown = "idle" }
        let s = style(shown, nil)
        view.mood = shown
        view.caption = s.caption
        view.clock += dt
        followRoutine(idle: shown == "idle" && !isHeld)
        view.asleep = napping
        view.held = isHeld

        var moving = false
        // It waits under the cursor, or a running buddy could never be caught.
        if s.speed > 0 && !view.asleep && !isHeld && !hovered && Date() >= restUntil {
            let dx = target.x - position.x, dy = target.y - position.y
            let distance = hypot(dx, dy)
            if distance < 3 {
                restUntil = Date().addingTimeInterval(Double.random(in: s.pause))
                target = randomSpot(near: position, size: window.frame.size)
            } else {
                let stride = min(distance, s.speed * dt)
                position.x += dx / distance * stride
                position.y += dy / distance * stride
                if abs(dx) > 1 { view.facing = dx > 0 ? 1 : -1 }
                view.phase += stride / 7
                moving = true
            }
        }
        view.moving = moving
        switch shown {
        case "waiting": view.hop = abs(sin(view.clock * 6)) * 16
        case "done":    view.hop = abs(sin(view.clock * 7)) * 24
        default:        view.hop = moving ? abs(sin(view.phase)) * 3 : 0
        }
        // Rises when picked up, bobs while carried, and settles when dropped.
        lift += ((isHeld ? 1 : 0) - lift) * min(1, dt * 10)
        if !isHeld && lift < 0.02 { lift = 0 }
        if lift > 0 { view.hop = lift * (12 + sin(view.clock * 3) * 6) }
        if moving { window.setFrameOrigin(position) }
        // Standing still needs few redraws: only the sheet's frames and the "z" change.
        redrawTick += 1
        let lively = moving || lift > 0 || shown == "waiting" || shown == "done"
        let tick = view.spriteTick
        if lively || tick != shownSpriteTick || redrawTick % 6 == 0 { view.needsDisplay = true }
        shownSpriteTick = tick
    }

    func leave() { window.orderOut(nil); window.close() }
}

struct Reply {
    var status = 200
    var body: [String: Any] = ["ok": true]
    var then: (() -> Void)? = nil // runs once the reply has gone
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

    func start() {
        let path = socketFile.path
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
        unlink(socketFile.path)
    }

    func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequest) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = received + (data ?? Data())
            if let reply = self.reply(to: buffer) {
                self.send(reply, on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    // The reply once the whole request is in; nil until then.
    func reply(to buffer: Data) -> Reply? {
        if buffer.count > maxRequest { return Reply(status: 413) }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let length = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        let start = lines[0].split(separator: " ")
        guard start.count == 3 else { return Reply(status: 400) }
        let path = start[1].split(separator: "?", omittingEmptySubsequences: false)[0]
        return route("\(start[0]) \(path)", Data(buffer[end.upperBound...].prefix(length)))
    }

    func send(_ reply: Reply, on connection: NWConnection) {
        var body = reply.body
        if reply.status != 200 { body = ["ok": false] }
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in
            connection.cancel()
            reply.then?()
        })
    }
}

final class Stage: NSObject, NSApplicationDelegate {
    var buddies: [Buddy] = [] // oldest first
    var reports: [String: Report] = [:] // an ended session stays until it is stale, so a late report can't revive it
    let server = Server()
    var statusItem: NSStatusItem!
    var last = Date()
    let avatars = AvatarLibrary()

    func applicationDidFinishLaunching(_ note: Notification) {
        server.route = { [weak self] route, body in self?.answer(route, body) ?? Reply(status: 503) }
        server.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Send buddies home", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        tick()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        let frames = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(frames, forMode: .common)
    }

    func frame() {
        let now = Date()
        let dt = CGFloat(min(now.timeIntervalSince(last), 0.1))
        last = now
        buddies.forEach { $0.step(dt) }
    }

    func applicationWillTerminate(_ note: Notification) { server.stop() }

    func answer(_ route: String, _ body: Data) -> Reply {
        switch route {
        case "POST /report":
            guard let report = try? JSONDecoder().decode(Report.self, from: body) else { return Reply(status: 400) }
            receive(report)
            return Reply()
        case "GET /status":
            return Reply(body: ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev",
                                "protocol": protocolVersion,
                                "sessions": reports.values.filter { $0.mood != "ended" }.count,
                                "dataFolder": buddyDir.path,
                                "binary": Bundle.main.executablePath ?? "",
                                "resources": Bundle.main.resourcePath ?? ""])
        case "POST /quit":
            return Reply(then: { NSApp.terminate(nil) })
        default:
            return Reply(status: 404)
        }
    }

    func receive(_ report: Report) {
        if let known = reports[report.id], report.seq <= known.seq { return }
        reports[report.id] = report
        refresh()
    }

    // What only time changes: silent sessions going stale, and idle ones losing their buddy.
    func tick() {
        avatars.refresh()
        let now = Date().timeIntervalSince1970
        reports = reports.filter { now - $0.value.updatedAt / 1000 <= staleAfter }
        refresh()
    }

    func refresh() {
        let live = reports.filter { $0.value.mood != "ended" }
        cast(live)
        for buddy in buddies {
            if let session = buddy.session {
                if let report = live[session] { buddy.apply(report) }
            } else {
                buddy.rest()
            }
            buddy.dress(avatars.sprite(buddy.pick))
        }
        statusItem.button?.title = buddies.isEmpty ? "🐾" : "🐾 \(buddies.count)"
    }

    // Who works for whom. A session at work without a buddy takes a spare one
    // before a new one is made, so working one session after another keeps the
    // same buddy; only sessions working at once bring out more.
    func cast(_ reports: [String: Report]) {
        for buddy in buddies {
            guard let session = buddy.session else { continue }
            if reports[session]?.holdsBuddy != true { buddy.session = nil }
        }

        // Spare: resting, or with a session that has stopped; the longest stopped goes first.
        let stopped = { (buddy: Buddy) in buddy.session.flatMap { reports[$0]?.idleSince } ?? 0 }
        let taken = Set(buddies.compactMap(\.session))
        for report in reports.values where report.working && !taken.contains(report.id) {
            let spares = buddies.filter { buddy in
                buddy.session.map { reports[$0]?.working == false } ?? true
            }
            if let buddy = spares.min(by: { stopped($0) < stopped($1) }) {
                buddy.session = report.id
            } else {
                let buddy = Buddy()
                buddy.session = report.id
                buddies.append(buddy)
            }
        }
        if buddies.isEmpty { buddies.append(Buddy()) }

        // Those with nobody to work for go home, but never the last one out.
        let resting = buddies.filter { $0.session == nil }
        for buddy in resting.dropFirst(resting.count == buddies.count ? 1 : 0) where !buddy.isHeld {
            buddy.leave()
            buddies.removeAll { $0 === buddy }
        }
    }
}

// Every animation drawn as the overlay shows it, in one picture for checking the art.
func writeSheetPreview(_ sprite: Sprite?, to path: String) throws {
    let window = sprite?.windowSize ?? NSSize(width: winW, height: winH)
    let cellW = window.width, cellH = window.height
    let cols = 4, rows = (animationNames.count + cols - 1) / cols
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols * Int(cellW), pixelsHigh: rows * Int(cellH), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.55, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    for (i, m) in animationNames.enumerated() {
        let v = BuddyView(frame: NSRect(x: 0, y: 0, width: cellW, height: cellH))
        v.sprite = sprite
        v.name = m
        v.asleep = m == "asleep"
        v.held = m == "held"
        v.hop = v.held ? 14 : 0
        v.mood = v.asleep || v.held || m == "walk" ? "idle" : m
        v.caption = style(v.mood, nil).caption
        v.moving = ["walk", "thinking", "running", "editing"].contains(m)
        v.clock = 0.7
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(i % cols) * cellW, y: CGFloat(rows - 1 - i / cols) * cellH)
        v.draw(v.bounds)
        ctx.restoreGState()
    }
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// A generated avatar in its folder: sheet.png and avatar.json. Answers the config
// and the sprite, or every reason it would not work in the overlay.
func checkAvatar(_ folder: URL) -> (entry: [String: Any], sprite: Sprite?, problems: [String]) {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("avatar.json")),
          var entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return ([:], nil, ["avatar.json is missing, or is not a JSON object"])
    }
    entry["sheet"] = "sheet.png"
    guard let fixed = try? JSONSerialization.data(withJSONObject: entry),
          let config = try? JSONDecoder().decode(AvatarConfig.self, from: fixed) else {
        return (entry, nil, ["avatar.json needs frameWidth and frameHeight, and each animation a row"])
    }
    guard let sprite = Sprite("candidate", config, base: folder) else {
        return (entry, nil, ["sheet.png cannot be read, or a \(config.frameWidth)x\(config.frameHeight) frame does not fit it"])
    }
    var problems: [String] = []
    let wanted = config.animations ?? [:]
    for name in animationNames {
        guard wanted[name] != nil else { problems.append("\(name): no animation"); continue }
        guard let a = sprite.animations[name] else { problems.append("\(name): outside the sheet"); continue }
        for i in 0..<a.frames {
            guard let frame = sprite.frame(a, tick: i), let seen = visibleBounds(frame) else {
                problems.append("\(name): frame \(i) is blank")
                continue
            }
            if seen.minX == 0 && seen.maxX == frame.width - 1 && seen.minY == 0 && seen.maxY == frame.height - 1 {
                problems.append("\(name): frame \(i) fills its cell: is the background still there?")
            }
        }
    }
    if let a = sprite.animations["idle"], let frame = sprite.frame(a, tick: 0), let seen = visibleBounds(frame), seen.maxY != frame.height - 1 {
        problems.append("idle: the character must stand on the bottom edge of its cell")
    }
    return (entry, sprite, problems)
}

func fail(_ lines: [String]) -> Never {
    lines.forEach { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    exit(1)
}

// Copies a checked avatar in and adds it to avatars.json, which goes last: the
// overlay notices the JSON changing, and by then the sheet is in place.
func installAvatar(_ name: String, from folder: URL) {
    guard name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil, name != "builtin" else {
        fail(["\"\(name)\" cannot be an avatar's name"])
    }
    let (candidate, _, problems) = checkAvatar(folder)
    if !problems.isEmpty { fail(problems) }

    var config: [String: Any] = [:]
    if let data = try? Data(contentsOf: avatarsFile) {
        guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail(["\(avatarsFile.path) is not valid JSON: fix it, then install again"])
        }
        config = read
    }
    var avatars = config["avatars"] as? [String: Any] ?? [:]
    if avatars[name] != nil { fail(["an avatar named \(name) is already configured"]) }

    do {
        let manager = FileManager.default
        let spritesDir = buddyDir.appendingPathComponent("sprites")
        try manager.createDirectory(at: spritesDir, withIntermediateDirectories: true)
        let sheet = spritesDir.appendingPathComponent("\(name).png")
        try? manager.removeItem(at: sheet)
        try manager.copyItem(at: folder.appendingPathComponent("sheet.png"), to: sheet)
        var entry = candidate
        entry["sheet"] = "sprites/\(name).png"
        avatars[name] = entry
        config["avatars"] = avatars
        let json = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: avatarsFile, options: .atomic)
    } catch {
        fail(["could not install: \(error.localizedDescription)"])
    }
    print("Installed \(name). Pick it with /desk-buddy avatar \(name).")
}

// Makes the data folder, private to this user, and brings over what lived in the old
// one. Anything already here stays. avatars.json goes last, once its sheets are in place.
func moveOldData() {
    let manager = FileManager.default
    do {
        try manager.createDirectory(at: buddyDir, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: buddyDir.path)
    } catch {
        NSLog("DeskBuddy: could not make the data folder: %@", String(describing: error))
        return
    }
    for name in ["sprites", "jobs", "avatars.json"] {
        let old = oldBuddyDir.appendingPathComponent(name), new = buddyDir.appendingPathComponent(name)
        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else { continue }
        do { try manager.moveItem(at: old, to: new) } catch {
            NSLog("DeskBuddy: could not move %@: %@", name, String(describing: error))
        }
    }
    try? manager.removeItem(at: oldBuddyDir.appendingPathComponent("sessions"))
}

moveOldData()
let arguments = CommandLine.arguments
// `DeskBuddy --sheet out.png [avatar]`: a configured avatar, or the bundled one, in every mood.
if (3...4).contains(arguments.count), arguments[1] == "--sheet" {
    let library = AvatarLibrary()
    library.refresh()
    if arguments.count == 4, arguments[3] != "builtin", !library.has(arguments[3]) { fail(["no avatar named \(arguments[3])"]) }
    do { try writeSheetPreview(library.sprite(arguments.count == 4 ? arguments[3] : "builtin"), to: arguments[2]) } catch { fail([String(describing: error)]) }
    exit(0)
}
// `DeskBuddy --check-avatar <folder> <preview.png>`: is this generated avatar ready, and how does it look?
if arguments.count == 4, arguments[1] == "--check-avatar" {
    let (_, sprite, problems) = checkAvatar(URL(fileURLWithPath: arguments[2]))
    if let sprite { do { try writeSheetPreview(sprite, to: arguments[3]) } catch { fail([String(describing: error)]) } }
    if !problems.isEmpty { fail(problems) }
    print("Ready to install. Preview: \(arguments[3])")
    exit(0)
}
// `DeskBuddy --install-avatar <name> <folder>`: add a generated avatar to avatars.json.
if arguments.count == 4, arguments[1] == "--install-avatar" {
    installAvatar(arguments[2], from: URL(fileURLWithPath: arguments[3]))
    exit(0)
}

let app = NSApplication.shared
let stage = Stage()
app.delegate = stage
app.setActivationPolicy(.accessory)
app.run()
