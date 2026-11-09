// All the buddies, and the sessions they work for. Sessions report over HTTP and the
// stage keeps their reports in memory. Merely open sessions get no buddy: one is out per
// session at work. The default buddy is always out, and so is every buddy added from the
// tray menu, resting until work comes in. Work none of them is free for brings out a
// temporary copy of the default, which goes home once it is done.
//
// The OS layer calls `start()` once, `tick(dt)` about 20 times a second, and `answer`
// for each request, all on its main thread.
import Foundation

public final class Stage: TrayDelegate {
    var buddies: [Buddy] = [] // oldest first
    var reports: [String: Report] = [:] // an ended session stays until it is stale, so a late report can't revive it
    let platform: Platform
    let avatars: AvatarLibrary
    var lastHousekeeping = Date()
    var shownMenu: TrayMenu?

    public init(_ platform: Platform) {
        self.platform = platform
        avatars = AvatarLibrary(platform.paths, platform.images)
        platform.tray.delegate = self
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
            buddy.dress(avatars.sprite(buddy.avatar))
        }
        let menu = trayMenu()
        if menu != shownMenu {
            shownMenu = menu
            platform.tray.show(menu)
        }
    }

    func newBuddy(_ avatar: String, _ role: Buddy.Role) -> Buddy {
        Buddy(platform.makeWindow(), platform.desktop, avatar: avatar, role: role)
    }

    func sendHome(_ buddy: Buddy) {
        buddy.leave()
        buddies.removeAll { $0 === buddy }
    }

    // Who works for whom. A session at work without a buddy takes a spare one
    // before a new one comes out, so working one session after another keeps the
    // same buddy; only sessions working at once bring out more. The default is always out.
    func cast(_ reports: [String: Report]) {
        for buddy in buddies {
            guard let session = buddy.session else { continue }
            if reports[session]?.holdsBuddy != true { buddy.session = nil }
        }

        // One main buddy, wearing the default. A new default takes over an added copy of
        // itself if there is one; the old main finishes its work and goes home.
        let wanted = avatars.defaultBuddy
        for buddy in buddies where buddy.role == .main && buddy.avatar != wanted { buddy.role = .temporary }
        if !buddies.contains(where: { $0.role == .main }) {
            if let copy = buddies.first(where: { $0.role == .added && $0.avatar == wanted }) {
                copy.role = .main
            } else {
                buddies.insert(newBuddy(wanted, .main), at: 0)
            }
        }

        // Spare: resting, or with a session that has stopped. Ones that stay out go before
        // temporary ones, then the longest stopped goes first.
        let rank = { (buddy: Buddy) -> (Int, Double) in
            (buddy.role == .temporary ? 1 : 0, buddy.session.flatMap { reports[$0]?.idleSince } ?? 0)
        }
        let taken = Set(buddies.compactMap(\.session))
        for report in reports.values.sorted(by: { $0.id < $1.id }) where report.working && !taken.contains(report.id) {
            let spares = buddies.filter { buddy in
                buddy.session.map { reports[$0]?.working == false } ?? true
            }
            if let buddy = spares.min(by: { rank($0) < rank($1) }) {
                buddy.session = report.id
            } else {
                let buddy = newBuddy(wanted, .temporary)
                buddy.session = report.id
                buddies.append(buddy)
            }
        }

        // Temporary ones with nobody to work for go home. The rest stay until removed.
        buddies.filter { $0.role == .temporary && $0.session == nil && !$0.isHeld }.forEach(sendHome)
    }

    // The tray menu: every avatar there is, how many of it are out, and which is the default.
    func trayMenu() -> TrayMenu {
        let main = avatars.defaultBuddy
        let rows = avatars.ids.map { id -> MenuRow in
            let kept = buddies.filter { $0.avatar == id && $0.role != .temporary }
            let isDefault = id == main
            var title = avatars.label(id)
            if kept.count > 1 { title += " ×\(kept.count)" }
            if isDefault { title += " (default)" }
            return MenuRow(id: id, title: title, checked: !kept.isEmpty, isDefault: isDefault, canAdd: true,
                           canRemove: kept.contains { $0.role == .added }, canMakeDefault: !isDefault)
        }
        return TrayMenu(buddiesOut: buddies.count, rows: rows)
    }

    // A pick from the tray menu, which applies at once. Added buddies last for this launch;
    // only the default is saved.
    public func choose(_ choice: TrayChoice) {
        switch choice {
        case .add(let id):
            guard avatars.has(id) else { return }
            buddies.append(newBuddy(id, .added)) // out now, resting until work comes in
        case .remove(let id):
            // The oldest added copy goes home, at work or not. Its session finds another buddy.
            guard let oldest = buddies.first(where: { $0.role == .added && $0.avatar == id }) else { return }
            sendHome(oldest)
        case .makeDefault(let id):
            guard avatars.has(id), id != avatars.defaultBuddy else { return }
            avatars.setDefault(id)
        case .sendHome:
            platform.quit()
            return
        }
        refresh()
    }
}
