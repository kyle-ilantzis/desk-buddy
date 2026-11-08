// One buddy: where it is, where it's going, what it's up to, and being carried.
import Foundation

func randomSpot(_ screens: [Screen], near start: Point?, size: Size = Size(width: winW, height: winH)) -> Point {
    let areas = screens.map(\.visible)
    // Mostly stay on the same display; now and then wander to another.
    let current = start.flatMap { p in areas.first { $0.contains(p) } }
    let area = (current != nil && Double.random(in: 0...1) < 0.85) ? current! : (areas.randomElement() ?? .zero)
    return Point(x: Double.random(in: area.minX...max(area.minX, area.maxX - size.width)),
                   y: Double.random(in: area.minY...max(area.minY, area.maxY - size.height)))
}

public final class Buddy: OverlayWindowDelegate {
    var session: String?          // who it works for; nil while resting
    var pick: String?             // its session's avatar; nil wears the default
    private(set) var look = Look()
    let window: OverlayWindow
    let desktop: Desktop
    var position: Point
    var size = Size(width: winW, height: winH)
    var target: Point
    var restUntil: Date = .distantPast
    var mood = "starting"
    var moodSince = Date()
    var napping = false
    var routineTurns: Date?       // when an idle buddy next falls asleep or wakes; nil unless idle
    var lastHeard = Date()
    var redrawTick = 0
    var shownSpriteTick: Int?
    var clickThrough = true       // step() turns this off only over the body
    var isHeld = false
    var grabOffset = Point.zero // the cursor, from the window's corner
    var lift: Double = 0         // 0 on the ground, 1 floating

    init(_ window: OverlayWindow, _ desktop: Desktop) {
        self.window = window
        self.desktop = desktop
        position = randomSpot(desktop.screens(), near: nil)
        target = position
        window.delegate = self
        window.setClickThrough(true)
        window.place(frame)
        window.show(look)
    }

    var frame: Rect { Rect(origin: position, size: size) }

    func apply(_ report: Report) {
        lastHeard = Date(timeIntervalSince1970: report.updatedAt / 1000)
        look.name = report.project
        pick = report.avatar
        setMood(report.mood)
    }

    func rest() {
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

    // A resting buddy goes by its avatar's name; one at work keeps its project's.
    func dress(_ sprite: Sprite?) {
        if session == nil { look.name = sprite?.label ?? defaultAvatar }
        guard sprite !== look.sprite else { return }
        look.sprite = sprite
        size = sprite?.windowSize ?? Size(width: winW, height: winH)
        window.place(frame)
        window.show(look)
    }

    public func grab() {
        let mouse = desktop.mouseLocation
        grabOffset = Point(x: mouse.x - position.x, y: mouse.y - position.y)
        isHeld = true
    }

    public func drag() {
        guard isHeld else { return }
        let mouse = desktop.mouseLocation
        position = Point(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        window.place(frame)
    }

    public func drop() {
        guard isHeld else { return }
        isHeld = false
        // Land on the screen under the cursor, body and name tag both in view.
        let mouse = desktop.mouseLocation
        if let area = desktop.screens().first(where: { $0.frame.contains(mouse) })?.visible {
            var keep = look.bodyRect(width: size.width)
            keep.size.height = size.height - keep.minY
            keep = keep.offsetBy(dx: position.x, dy: position.y)
            position.x += max(0, area.minX - keep.minX) - max(0, keep.maxX - area.maxX)
            position.y += max(0, area.minY - keep.minY) - max(0, keep.maxY - area.maxY)
            window.place(frame)
        }
        target = position
        restUntil = Date().addingTimeInterval(2)
    }

    func step(_ dt: Double) {
        // A mouse-up can go missing, to a screen lock or Mission Control.
        if isHeld && !desktop.primaryButtonDown { drop() }

        // Clicks pass through everywhere but the body.
        let mouse = desktop.mouseLocation
        let hovered = look.bodyRect(width: size.width).contains(Point(x: mouse.x - position.x, y: mouse.y - position.y))
        let through = !hovered && !isHeld
        if clickThrough != through {
            clickThrough = through
            window.setClickThrough(through)
        }

        // "done" and "error" play for a few seconds and then settle into idle.
        var shown = mood
        let held = Date().timeIntervalSince(moodSince)
        if (mood == "done" || mood == "error") && held > 6 { shown = "idle" }
        let s = style(shown, nil)
        look.mood = shown
        look.caption = s.caption
        look.clock += dt
        followRoutine(idle: shown == "idle" && !isHeld)
        look.asleep = napping
        look.held = isHeld

        var moving = false
        // It waits under the cursor, or a running buddy could never be caught.
        if s.speed > 0 && !look.asleep && !isHeld && !hovered && Date() >= restUntil {
            let dx = target.x - position.x, dy = target.y - position.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < 3 {
                restUntil = Date().addingTimeInterval(Double.random(in: s.pause))
                target = randomSpot(desktop.screens(), near: position, size: size)
            } else {
                let stride = min(distance, s.speed * dt)
                position.x += dx / distance * stride
                position.y += dy / distance * stride
                if abs(dx) > 1 { look.facing = dx > 0 ? 1 : -1 }
                look.phase += stride / 7
                moving = true
            }
        }
        look.moving = moving
        switch shown {
        case "waiting": look.hop = abs(sin(look.clock * 6)) * 16
        case "done":    look.hop = abs(sin(look.clock * 7)) * 24
        default:        look.hop = moving ? abs(sin(look.phase)) * 3 : 0
        }
        // Rises when picked up, bobs while carried, and settles when dropped.
        lift += ((isHeld ? 1 : 0) - lift) * min(1, dt * 10)
        if !isHeld && lift < 0.02 { lift = 0 }
        if lift > 0 { look.hop = lift * (12 + sin(look.clock * 3) * 6) }
        if moving { window.place(frame) }
        // Standing still needs few redraws: only the sheet's frames and the "z" change.
        redrawTick += 1
        let lively = moving || lift > 0 || shown == "waiting" || shown == "done"
        let tick = look.spriteTick
        if lively || tick != shownSpriteTick || redrawTick % 6 == 0 { window.show(look) }
        shownSpriteTick = tick
    }

    func leave() { window.close() }
}
