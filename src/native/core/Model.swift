// The settings, what a session reports, and how each mood moves.
import Foundation

public let protocolVersion = 1
public let maxRequest = 64 * 1024
let staleAfter: TimeInterval = 45      // no heartbeat: the session has gone
let idleGrace: TimeInterval = 60       // a session keeps its buddy this long after its last turn
let awakeFor: ClosedRange<TimeInterval> = 90...180 // an idle buddy wanders this long
let napFor: ClosedRange<TimeInterval> = 60...180   // then naps this long
let wakingFor: TimeInterval = 2                    // and stands a moment before it walks off
public let defaultAvatar = "kyle"                     // worn when nothing else is picked
public let bundledAvatars = [defaultAvatar, "melody"] // each is <name>.png and <name>.json in the app's resources
let retiredAvatar = "builtin"                         // kyle's old name, which a saved pick can still say
public let winW: Double = 190, winH: Double = 112
let spriteFit: Double = 64  // a sheet with no "scale" is drawn about this tall
let spriteMax: Double = 256 // and no sheet is drawn larger than this
let tagGap: Double = 28     // from the top of the body to the name tag: a full hop fits under it
public let animationNames = ["idle", "walk", "thinking", "reading", "editing", "running", "browsing",
                             "delegating", "waiting", "done", "error", "asleep", "held"]

public struct Report: Decodable {
    public let id: String
    public let seq: Int // reports can arrive out of order: a session's highest so far wins
    public let project: String
    public let mood: String
    public let tool: String?
    public let avatar: String?
    public let updatedAt: Double
    public let idleSince: Double? // when its last turn ended; nil if none ran or one is running

    public var working: Bool { !["starting", "idle", "done", "error", "ended"].contains(mood) }
    public var holdsBuddy: Bool {
        working || idleSince.map { Date().timeIntervalSince1970 - $0 / 1000 < idleGrace } ?? false
    }
}

public struct Style { public let speed: Double; public let caption: String; public let pause: ClosedRange<Double> }

public func style(_ mood: String, _ tool: String?) -> Style {
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
