// ARCHIVE: the overlay as it was when the avatar was drawn in code, plus the
// `--export-buddy <dir>` mode that made assets/buddy.png and assets/buddy.json.
// Not part of the build. To change the art at its source, edit this, then:
//   swiftc -O -framework AppKit -o /tmp/drawn archive/DeskBuddy-drawn.swift && /tmp/drawn --export-buddy assets
//
// The overlay: one small window per buddy, walking the screen. Clicks pass through
// all of it but the buddy's body, which can be picked up. It reads ~/.claude/desk-buddy/sessions/*.json, which the mod writes,
// and draws from the sprite sheets in ~/.claude/desk-buddy/avatars.json, if any.
// Merely open sessions get no buddy: one is out per session at work, and one
// always stays, resting, to take the next session that starts working.
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent(".claude/desk-buddy")
let sessionsDir = buddyDir.appendingPathComponent("sessions")
let avatarsFile = buddyDir.appendingPathComponent("avatars.json")
let staleAfter: TimeInterval = 45      // no heartbeat: the session has gone
let quitAfterEmpty: TimeInterval = 120 // nobody left: the app leaves too
let idleGrace: TimeInterval = 60       // a session keeps its buddy this long after its last turn
let homeSeed = "desk-buddy"            // the first buddy's colour, the same every launch
let restingName = "buddy"
let winW: CGFloat = 190, winH: CGFloat = 112
let spriteFit: CGFloat = 64  // a sheet with no "scale" is drawn about this tall
let spriteMax: CGFloat = 256 // and no sheet is drawn larger than this

struct Report: Decodable {
    let id: String
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

// A buddy keeps one colour for life, whichever sessions it works for.
func color(for id: String) -> NSColor {
    var hash: UInt32 = 2166136261
    for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
    return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.62, brightness: 0.92, alpha: 1)
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

// One configured sheet, cut into rows of frames counted from the top left.
final class Sprite {
    struct Animation { let row: Int; let start: Int; let frames: Int; let fps: Double }

    let image: CGImage
    let frameW: Int, frameH: Int
    let size: NSSize
    let facesLeft: Bool
    let animations: [String: Animation]

    init?(_ name: String, _ config: AvatarConfig) {
        let path = (config.sheet as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : buddyDir.appendingPathComponent(path)
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

// avatars.json, read again when it changes. Without it there are no sprites and
// every buddy draws itself; a pick that names nothing here does the same.
final class AvatarLibrary {
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

    func sprite(_ pick: String?) -> Sprite? { (pick ?? fallback).flatMap { sprites[$0] } }
}

final class BuddyView: NSView {
    var tint = NSColor.orange
    var mood = "idle"
    var name = ""
    var caption = ""
    var facing: CGFloat = 1
    var phase: CGFloat = 0   // walk cycle
    var hop: CGFloat = 0
    var moving = false
    var asleep = false
    var held = false         // being carried by the mouse
    var clock: CGFloat = 0
    var sprite: Sprite?
    weak var buddy: Buddy?
    var groundY: CGFloat = 8
    var exporting = false    // art alone: no shadow, tag or "z", all of which the overlay adds

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { buddy?.grab() }
    override func mouseDragged(with event: NSEvent) { buddy?.drag() }
    override func mouseUp(with event: NSEvent) { buddy?.drop() }

    // The part that can be grabbed, up to the top of its hop.
    var bodyRect: NSRect {
        let size = sprite?.size ?? NSSize(width: 56, height: 52)
        return NSRect(x: bounds.midX - size.width / 2, y: groundY, width: size.width, height: size.height + hop)
    }

    // The sheet's frame counter; nil for the built-in avatar.
    var spriteTick: Int? {
        sprite.map { Int(Double(clock) * $0.animation(mood: mood, moving: moving, asleep: asleep, held: held).fps) }
    }

    func drawSprite(_ sprite: Sprite, at y: CGFloat) -> Bool {
        let a = sprite.animation(mood: mood, moving: moving, asleep: asleep, held: held)
        guard let frame = sprite.frame(a, tick: spriteTick ?? 0), let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: bounds.midX, y: y)
        if (facing < 0) != sprite.facesLeft { ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(frame, in: CGRect(x: -sprite.size.width / 2, y: 0, width: sprite.size.width, height: sprite.size.height))
        ctx.restoreGState()
        return true
    }

    override func draw(_ dirty: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        let cx = bounds.midX
        let px: CGFloat = 4 // one "pixel" of the avatar
        let bodyY = groundY + 2 * px + hop

        func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
            c.setFill()
            NSRect(x: cx + x * px, y: bodyY + y * px, width: w * px, height: h * px).fill()
        }

        // Shadow stays on the ground as the buddy hops.
        if !exporting {
            NSColor.black.withAlphaComponent(0.22).setFill()
            let shadow = sprite.map { $0.size.width * 0.6 } ?? 52
            NSBezierPath(ovalIn: NSRect(x: cx - shadow / 2 + hop / 3, y: groundY - 5, width: shadow - hop / 1.5, height: 8)).fill()
        }

        let dark = tint.blended(withFraction: 0.32, of: .black) ?? tint
        let light = tint.blended(withFraction: 0.3, of: .white) ?? tint

        let drewSprite = sprite.map { drawSprite($0, at: groundY + hop) } ?? false
        if !drewSprite {
            // Feet: alternate while walking, dangle while carried.
            let swing = moving ? sin(phase) : 0
            let dangle = held ? sin(clock * 5) * 0.7 : 0
            let hang: CGFloat = held ? 1 : 0
            block(-5 + dangle, -2 - hang + max(0, swing) * 1.3, 3, 2, dark)
            block(2 - dangle, -2 - hang + max(0, -swing) * 1.3, 3, 2, dark)

            // A round-cornered body with two ears.
            block(-6, 0, 12, 9, tint)
            block(-7, 1, 14, 7, tint)
            block(-6, 9, 3, 2, tint)
            block(3, 9, 3, 2, tint)
            block(-5, 8, 10, 1, light)

            // Face looks the way it walks.
            let look = facing * 1
            if held {
                // Wide eyes and an open mouth: it did not expect to fly.
                block(-5 + look, 4, 3, 4, .black)
                block(2 + look, 4, 3, 4, .black)
                block(-5 + look, 7, 1, 1, .white)
                block(2 + look, 7, 1, 1, .white)
                block(-1 + look, 2, 2, 2, .black)
            } else if asleep {
                block(-4 + look, 5, 3, 1, .black)
                block(1 + look, 5, 3, 1, .black)
            } else if mood == "error" {
                for (x, y) in [(-4.0, 6.0), (-2.0, 6.0), (-3.0, 5.0), (-4.0, 4.0), (-2.0, 4.0)] { block(x + look, y, 1, 1, .black) }
                for (x, y) in [(2.0, 6.0), (4.0, 6.0), (3.0, 5.0), (2.0, 4.0), (4.0, 4.0)] { block(x + look, y, 1, 1, .black) }
            } else {
                let blink = sin(clock * 0.9) > 0.985
                let h: CGFloat = blink ? 1 : 3
                let y: CGFloat = blink ? 5 : 4
                block(-4 + look, y, 2, h, .black)
                block(2 + look, y, 2, h, .black)
                if !blink {
                    block(-4 + look, 6, 1, 1, .white)
                    block(2 + look, 6, 1, 1, .white)
                }
            }
            if mood == "done" && !held { block(-2 + look, 2, 4, 1, .black); block(-3 + look, 3, 1, 1, .black); block(2 + look, 3, 1, 1, .black) }
        }

        // Props for what it is doing, held on the side it faces. A sheet with its
        // own row for the mood acts it out alone.
        let sized = drewSprite ? sprite?.size : nil
        let reach = sized.map { $0.width / 2 / px } ?? 7
        let side = facing > 0 ? reach : -reach - 4
        let acted = drewSprite && sprite?.animations[mood] != nil
        switch acted || held ? "" : mood {
        case "reading":
            block(side, 2, 4, 4, .white); block(side, 2, 4, 1, dark); block(side + 2, 2, 0.5, 4, .gray)
        case "editing":
            let tap = sin(clock * 14) * 0.8
            block(side + 1, 3 + tap, 1, 5, .systemYellow); block(side + 1, 2 + tap, 1, 1, .black)
        case "running":
            for i in 0..<3 {
                let trail = CGFloat(i) * 3 + reach + 3
                block(-facing * trail, 2 + CGFloat(i) * 2, 2, 0.6, NSColor.white.withAlphaComponent(0.8))
            }
        case "browsing":
            block(side, 3, 4, 4, .systemBlue); block(side + 1, 3, 1, 4, .systemGreen); block(side, 5, 4, 1, .systemGreen)
        case "delegating":
            let mini = dark.withAlphaComponent(0.9)
            let behind = -facing * (reach + 5)
            block(behind - 2, -1, 4, 4, mini); block(behind - 1, 1, 1, 1, .black); block(behind + 1 - 1, 1, 1, 1, .black)
        case "waiting":
            let wave = sin(clock * 10) * 1.5
            if !drewSprite { block(7, 6 + wave, 2, 5, tint) }
        case "done":
            for i in 0..<5 {
                let a = CGFloat(i) * 1.26 + clock * 2
                block(cos(a) * 12, 6 + sin(a) * 9, 1, 1, .yellow)
            }
        default: break
        }
        if exporting { return }
        if asleep {
            let drift = (clock * 0.6).truncatingRemainder(dividingBy: 1)
            drawText("z", at: NSPoint(x: cx + reach * px + 2, y: bodyY + (sized?.height ?? 52) - 8 + drift * 12), size: 12 + drift * 5, weight: .bold, color: .white.withAlphaComponent(1 - drift))
        }

        // The name tag and what it is up to.
        let label = caption.isEmpty ? name : "\(name) · \(caption)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        var text = label
        while (text as NSString).size(withAttributes: attrs).width > winW - 20 && text.count > 4 { text = String(text.dropLast(2)) + "…" }
        let size = (text as NSString).size(withAttributes: attrs)
        let tag = NSRect(x: cx - size.width / 2 - 7, y: bounds.maxY - 24, width: size.width + 14, height: 20)
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
    var pick: String?             // the avatar last asked for, kept from session to session
    let view = BuddyView()
    let window: NSPanel
    var position: NSPoint
    var target: NSPoint
    var restUntil: Date = .distantPast
    var mood = "starting"
    var moodSince = Date()
    var lastHeard = Date()
    var redrawTick = 0
    var shownSpriteTick: Int?
    var isHeld = false
    var grabOffset = NSPoint.zero // the cursor, from the window's corner
    var lift: CGFloat = 0         // 0 on the ground, 1 floating

    init(seed: String) {
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
        view.tint = color(for: seed)
        view.name = restingName
        view.buddy = self
        window.contentView = view
        window.orderFrontRegardless()
    }

    func apply(_ report: Report) {
        lastHeard = Date(timeIntervalSince1970: report.updatedAt / 1000)
        view.name = report.project
        pick = report.avatar ?? pick
        setMood(report.mood)
    }

    func rest() {
        view.name = restingName
        setMood("idle")
    }

    func setMood(_ next: String) {
        guard next != mood else { return }
        mood = next
        moodSince = Date()
        restUntil = .distantPast
    }

    func dress(_ sprite: Sprite?) {
        guard sprite !== view.sprite else { return }
        view.sprite = sprite
        // Room for the sprite, its hop and props, and the name tag above.
        let need = sprite?.size ?? .zero
        let size = NSSize(width: max(winW, need.width + 60), height: max(winH, need.height + 60))
        window.setFrame(NSRect(origin: position, size: size), display: true)
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
        view.asleep = !isHeld && shown == "idle" && held > 90
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
        // Standing still needs few redraws: only blinks and props change.
        redrawTick += 1
        let lively = moving || lift > 0 || shown == "waiting" || shown == "done"
        let tick = view.spriteTick
        if lively || tick != shownSpriteTick || redrawTick % 6 == 0 { view.needsDisplay = true }
        shownSpriteTick = tick
    }

    func leave() { window.orderOut(nil); window.close() }
}

final class Stage: NSObject, NSApplicationDelegate {
    var buddies: [Buddy] = [] // oldest first
    var emptySince = Date()
    var statusItem: NSStatusItem!
    var last = Date()
    let avatars = AvatarLibrary()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Send buddies home", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        poll()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        let frames = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(frames, forMode: .common)
    }

    func frame() {
        let now = Date()
        let dt = CGFloat(min(now.timeIntervalSince(last), 0.1))
        last = now
        buddies.forEach { $0.step(dt) }
    }

    func poll() {
        avatars.refresh()
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var reports: [String: Report] = [:]
        var unread = Set<String>()
        for file in files where file.pathExtension == "json" {
            // A half-written file reads as nothing this second, and as itself the next.
            guard let data = try? Data(contentsOf: file),
                  let report = try? JSONDecoder().decode(Report.self, from: data) else {
                unread.insert(file.deletingPathExtension().lastPathComponent)
                continue
            }
            let age = Date().timeIntervalSince1970 - report.updatedAt / 1000
            if report.mood == "ended" || age > staleAfter {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            reports[report.id] = report
        }
        cast(reports, unread)
        for buddy in buddies {
            if let session = buddy.session {
                if let report = reports[session] { buddy.apply(report) }
            } else {
                buddy.rest()
            }
            buddy.dress(avatars.sprite(buddy.pick))
        }
        statusItem.button?.title = buddies.isEmpty ? "🐾" : "🐾 \(buddies.count)"
        if !reports.isEmpty || !unread.isEmpty { emptySince = Date() }
        if Date().timeIntervalSince(emptySince) > quitAfterEmpty { NSApp.terminate(nil) }
    }

    // Who works for whom. A session at work without a buddy takes a spare one
    // before a new one is made, so working one session after another keeps the
    // same buddy; only sessions working at once bring out more.
    func cast(_ reports: [String: Report], _ unread: Set<String>) {
        for buddy in buddies {
            guard let session = buddy.session, !unread.contains(session) else { continue }
            if reports[session]?.holdsBuddy != true { buddy.session = nil }
        }

        // Spare: resting, or with a session that has stopped; the longest stopped goes first.
        let stopped = { (buddy: Buddy) in buddy.session.flatMap { reports[$0]?.idleSince } ?? 0 }
        let taken = Set(buddies.compactMap(\.session))
        for report in reports.values where report.working && !taken.contains(report.id) {
            let spares = buddies.filter { buddy in
                buddy.session.map { !unread.contains($0) && reports[$0]?.working == false } ?? true
            }
            if let buddy = spares.min(by: { stopped($0) < stopped($1) }) {
                buddy.session = report.id
            } else {
                let buddy = Buddy(seed: buddies.isEmpty ? homeSeed : report.id)
                buddy.session = report.id
                buddies.append(buddy)
            }
        }
        if buddies.isEmpty { buddies.append(Buddy(seed: homeSeed)) }

        // Those with nobody to work for go home, but never the last one out.
        let resting = buddies.filter { $0.session == nil }
        for buddy in resting.dropFirst(resting.count == buddies.count ? 1 : 0) where !buddy.isHeld {
            buddy.leave()
            buddies.removeAll { $0 === buddy }
        }
    }
}

// `DeskBuddy --sheet out.png [avatar]` draws every mood into one picture, for checking the art.
if (3...4).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--sheet" {
    let library = AvatarLibrary()
    library.refresh()
    let sprite = library.sprite(CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "builtin")
    let cellW = max(winW, (sprite?.size.width ?? 0) + 60), cellH = max(winH, (sprite?.size.height ?? 0) + 60)
    let moods = ["idle", "thinking", "reading", "editing", "running", "browsing", "delegating", "waiting", "done", "error", "asleep", "held"]
    let cols = 4, rows = (moods.count + cols - 1) / cols
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols * Int(cellW), pixelsHigh: rows * Int(cellH), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.55, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    for (i, m) in moods.enumerated() {
        let v = BuddyView(frame: NSRect(x: 0, y: 0, width: cellW, height: cellH))
        v.sprite = sprite
        v.tint = color(for: m)
        v.name = "my-project"
        v.asleep = m == "asleep"
        v.held = m == "held"
        v.hop = v.held ? 14 : 0
        v.mood = v.asleep || v.held ? "idle" : m
        v.caption = style(v.mood, nil).caption
        v.moving = ["thinking", "running", "editing"].contains(m)
        v.phase = 1.4
        v.clock = 0.7
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(i % cols) * cellW, y: CGFloat(rows - 1 - i / cols) * cellH)
        v.draw(v.bounds)
        ctx.restoreGState()
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

// `--export-buddy <dir>`: every animation as a sheet, one pixel per 4pt block.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-buddy" {
    struct Row { let name: String; let frames: Int; let fps: Double; var mood = "idle"; var moving = false; var period: CGFloat = 0 }
    let tau = CGFloat.pi * 2
    // Walking rows run at the speed style() gives the mood, up to the overlay's 20 Hz.
    let rows = [
        Row(name: "idle", frames: 16, fps: 4),
        Row(name: "walk", frames: 6, fps: 4, moving: true),
        Row(name: "thinking", frames: 6, fps: 8, mood: "thinking", moving: true),
        Row(name: "reading", frames: 6, fps: 12, mood: "reading", moving: true),
        Row(name: "editing", frames: 6, fps: 16, mood: "editing", moving: true, period: tau / 14),
        Row(name: "running", frames: 6, fps: 20, mood: "running", moving: true),
        Row(name: "browsing", frames: 6, fps: 16, mood: "browsing", moving: true),
        Row(name: "delegating", frames: 6, fps: 20, mood: "delegating", moving: true),
        Row(name: "waiting", frames: 6, fps: 10, mood: "waiting", period: tau / 10),
        Row(name: "done", frames: 6, fps: 10, mood: "done", period: tau / 10),
        Row(name: "error", frames: 1, fps: 1, mood: "error"),
        Row(name: "asleep", frames: 1, fps: 1),
        Row(name: "held", frames: 6, fps: 5, period: tau / 5),
    ]
    let frameW = 40, frameH = 24, block: CGFloat = 4, columns = 16
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: columns * frameW, pixelsHigh: rows.count * frameH, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(false)
    var animations: [String: Any] = [:]
    for (r, row) in rows.enumerated() {
        animations[row.name] = ["row": r, "frames": row.frames, "fps": row.fps]
        for i in 0..<row.frames {
            let v = BuddyView(frame: NSRect(x: 0, y: 0, width: CGFloat(frameW) * block, height: CGFloat(frameH) * block))
            v.exporting = true
            v.tint = color(for: homeSeed)
            v.mood = row.mood
            v.moving = row.moving
            v.asleep = row.name == "asleep"
            v.held = row.name == "held"
            v.groundY = v.held ? block : 0 // its feet hang a block low
            v.phase = tau * CGFloat(i) / CGFloat(row.frames)
            v.clock = row.period * CGFloat(i) / CGFloat(row.frames)
            if row.name == "idle" && i == row.frames - 1 { v.clock = .pi / 2 / 0.9 } // the one blink
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i * frameW), y: CGFloat((rows.count - 1 - r) * frameH))
            ctx.scaleBy(x: 1 / block, y: 1 / block)
            ctx.clip(to: v.bounds)
            v.draw(v.bounds)
            ctx.restoreGState()
        }
    }
    let dir = URL(fileURLWithPath: CommandLine.arguments[2])
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("buddy.png"))
    let config: [String: Any] = ["sheet": "buddy.png", "frameWidth": frameW, "frameHeight": frameH, "scale": block, "animations": animations]
    try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("buddy.json"))
    exit(0)
}

let app = NSApplication.shared
let stage = Stage()
app.delegate = stage
app.setActivationPolicy(.accessory)
app.run()
