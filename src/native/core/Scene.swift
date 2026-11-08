// What a buddy looks like right now, and where each piece of it goes in its window.
// Both are the same on every OS; a layer only paints a Scene.
import Foundation

/// A buddy's state as drawn.
public struct Look {
    public var mood = "idle"
    public var name = ""
    public var caption = ""
    public var facing: Double = 1
    public var phase: Double = 0   // walk cycle, for the bounce
    public var hop: Double = 0
    public var moving = false
    public var asleep = false
    public var held = false         // being carried by the mouse
    public var clock: Double = 0
    public var sprite: Sprite?

    public init() {}

    public static let groundY: Double = 8

    public var body: Size { sprite?.body ?? Size(width: 56, height: 52) }

    /// The part that can be grabbed, up to the top of its hop, in a window `width` wide.
    public func bodyRect(width: Double) -> Rect {
        let size = body
        return Rect(x: width / 2 - size.width / 2, y: Look.groundY, width: size.width, height: size.height + hop)
    }

    public var animation: Sprite.Animation? {
        sprite?.animation(mood: mood, moving: moving, asleep: asleep, held: held)
    }

    /// The sheet's frame counter; nil with no sheet.
    public var spriteTick: Int? { animation.map { Int(Double(clock) * $0.fps) } }
}

/// A Look laid out in a window, with y up from its bottom left.
public struct Scene {
    public enum Weight { case semibold, bold }
    public enum Tint { case plain, alert, warning } // black, red, orange

    public struct Text {
        public let string: String
        public let origin: Point // bottom left of the text's box
        public let size: Double
        public let weight: Weight
        public let alpha: Double  // white, this opaque
    }

    public struct SpriteDraw {
        public let sprite: Sprite
        public let source: PixelRect // in the sheet
        public let dest: Rect      // in the window
        public let mirrored: Bool    // flipped left to right about dest's middle
    }

    public let size: Size
    public let shadow: Rect      // an oval, black at 22%
    public let sprite: SpriteDraw?
    public let snore: Text?        // the "z" over a napping buddy
    public let tag: Rect         // rounded, radius 9, at 72%
    public let tint: Tint
    public let label: Text

    public static let tagRadius: Double = 9
    public static let shadowAlpha: Double = 0.22
    public static let tagAlpha: Double = 0.72

    /// `measure` gives a string's width and height in the system font at a size and weight.
    public init(_ look: Look, size: Size, measure: (String, Double, Weight) -> Size) {
        self.size = size
        let cx = size.width / 2
        let body = look.body
        let groundY = Look.groundY

        // Shadow stays on the ground as the buddy hops.
        let shadowW = body.width - 4
        shadow = Rect(x: cx - shadowW / 2 + look.hop / 3, y: groundY - 5, width: shadowW - look.hop / 1.5, height: 8)

        if let s = look.sprite, let a = look.animation {
            sprite = SpriteDraw(sprite: s, source: s.frame(a, tick: look.spriteTick ?? 0),
                                dest: Rect(x: cx - s.size.width / 2, y: groundY + look.hop, width: s.size.width, height: s.size.height),
                                mirrored: (look.facing < 0) != s.facesLeft)
        } else {
            sprite = nil
        }

        if look.asleep {
            let drift = (look.clock * 0.6).truncatingRemainder(dividingBy: 1)
            snore = Text(string: "z", origin: Point(x: cx + body.width / 2 + 2, y: groundY + look.hop + body.height + drift * 12),
                         size: 12 + drift * 5, weight: .bold, alpha: 1 - drift)
        } else {
            snore = nil
        }

        // The name tag and what it is up to.
        let full = look.caption.isEmpty ? look.name : "\(look.name) · \(look.caption)"
        var text = full
        while measure(text, 11, .semibold).width > winW - 20 && text.count > 4 { text = String(text.dropLast(2)) + "…" }
        let measured = measure(text, 11, .semibold)
        tag = Rect(x: cx - measured.width / 2 - 7, y: groundY + body.height + tagGap, width: measured.width + 14, height: 20)
        tint = look.mood == "waiting" ? .alert : look.mood == "error" ? .warning : .plain
        label = Text(string: text, origin: Point(x: tag.minX + 7, y: tag.minY + 3), size: 11, weight: .semibold, alpha: 1)
    }
}

/// Every animation as the overlay draws it, for checking the art: one Look a cell,
/// four cells a row, in a window of the sprite's size.
public func previewLooks(_ sprite: Sprite?) -> (cell: Size, columns: Int, looks: [Look]) {
    let cell = sprite?.windowSize ?? Size(width: winW, height: winH)
    let looks = animationNames.map { m -> Look in
        var v = Look()
        v.sprite = sprite
        v.name = m
        v.asleep = m == "asleep"
        v.held = m == "held"
        v.hop = v.held ? 14 : 0
        v.mood = v.asleep || v.held || m == "walk" ? "idle" : m
        v.caption = style(v.mood, nil).caption
        v.moving = ["walk", "thinking", "running", "editing"].contains(m)
        v.clock = 0.7
        return v
    }
    return (cell, 4, looks)
}
