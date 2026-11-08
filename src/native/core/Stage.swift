// All the buddies, and the sessions they work for. Sessions report over HTTP and the
// stage keeps their reports in memory. Merely open sessions get no buddy: one is out per
// session at work, and one always stays, resting, to take the next session that starts working.
//
// The OS layer calls `start()` once, `tick(dt)` about 20 times a second, and `answer`
// for each request, all on its main thread.
import Foundation

public final class Stage {
    var buddies: [Buddy] = [] // oldest first
    var reports: [String: Report] = [:] // an ended session stays until it is stale, so a late report can't revive it
    let platform: Platform
    let avatars: AvatarLibrary
    var lastHousekeeping = Date()

    public init(_ platform: Platform) {
        self.platform = platform
        avatars = AvatarLibrary(platform.paths, platform.images)
    }

    public func start() { housekeeping() }

    /// One frame: every buddy moves on by `dt` seconds, and once a second the stage tidies up.
    public func tick(_ dt: Double) {
        buddies.forEach { $0.step(min(dt, 0.1)) }
        if Date().timeIntervalSince(lastHousekeeping) >= 1 { housekeeping() }
    }

    public func answer(_ route: String, _ body: Data) -> Reply {
        switch route {
        case "POST /report":
            guard let report = try? JSONDecoder().decode(Report.self, from: body) else { return Reply(status: 400) }
            receive(report)
            return Reply()
        case "GET /status":
            var status: [String: Any] = ["version": "dev", "binary": "", "resources": ""]
            platform.info().forEach { status[$0.key] = $0.value }
            status["protocol"] = protocolVersion
            status["sessions"] = reports.values.filter { $0.mood != "ended" }.count
            status["dataFolder"] = platform.paths.dataDir.path
            status["bundled"] = bundledAvatars
            return Reply(body: status)
        case "POST /quit":
            return Reply(then: platform.quit)
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
    func housekeeping() {
        lastHousekeeping = Date()
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
        platform.tray.show(buddies: buddies.count)
    }

    func newBuddy() -> Buddy { Buddy(platform.makeWindow(), platform.desktop) }

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
                let buddy = newBuddy()
                buddy.session = report.id
                buddies.append(buddy)
            }
        }
        if buddies.isEmpty { buddies.append(newBuddy()) }

        // Those with nobody to work for go home, but never the last one out.
        let resting = buddies.filter { $0.session == nil }
        for buddy in resting.dropFirst(resting.count == buddies.count ? 1 : 0) where !buddy.isHeld {
            buddy.leave()
            buddies.removeAll { $0 === buddy }
        }
    }
}
