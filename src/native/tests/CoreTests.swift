// The shared core with a stand-in OS: no windows, no screen, no image decoder.
import Foundation
import XCTest
@testable import DeskBuddyCore

final class FakeWindow: OverlayWindow {
    weak var delegate: OverlayWindowDelegate?
    var frame = Rect.zero
    var through = false
    var shown: Look?
    var closed = false
    func place(_ frame: Rect) { self.frame = frame }
    func setClickThrough(_ through: Bool) { self.through = through }
    func show(_ look: Look) { shown = look }
    func close() { closed = true }
}

final class FakeDesktop: Desktop {
    var mouseLocation = Point(x: -1000, y: -1000)
    var primaryButtonDown = false
    func screens() -> [Screen] {
        let all = Rect(x: 0, y: 0, width: 1440, height: 900)
        return [Screen(frame: all, visible: Rect(x: 0, y: 0, width: 1440, height: 875))]
    }
}

final class FakeTray: Tray {
    weak var delegate: TrayDelegate?
    var menu: TrayMenu?
    var shows = 0
    var count: Int { menu?.buddiesOut ?? -1 }
    func show(_ menu: TrayMenu) { self.menu = menu; shows += 1 }
    func row(_ id: String) -> MenuRow? { menu?.rows.first { $0.id == id } }
}

/// Answers every image with an opaque block of `size`, or reads a PNG's size from its header.
struct FakeImages: ImageLoader {
    var size: (Int, Int)?
    var paint: ((Int, Int) -> UInt8)? // alpha at x, y
    func load(_ url: URL) -> Bitmap? {
        var w = 0, h = 0
        if let size { (w, h) = size } else {
            guard let data = try? Data(contentsOf: url), data.count > 24 else { return nil }
            let be = { (at: Int) in data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
            (w, h) = (be(16), be(20))
        }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        if let paint { for y in 0..<h { for x in 0..<w { pixels[(y * w + x) * 4 + 3] = paint(x, y) } } }
        return Bitmap(width: w, height: h, pixels: pixels)
    }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let assets = here.deletingLastPathComponent().appendingPathComponent("core/assets")

func tempPaths() -> Paths {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desk-buddy-tests-\(UUID().uuidString)")
    return Paths(dataDir: dir, legacyDir: nil, resources: assets, endpoint: "unused")
}

func report(_ id: String, _ mood: String, seq: Int = 1, idleSince: Double? = nil) -> Data {
    var json: [String: Any] = ["id": id, "seq": seq, "project": "p-\(id)", "mood": mood,
                               "updatedAt": Date().timeIntervalSince1970 * 1000]
    if let idleSince { json["idleSince"] = idleSince }
    return try! JSONSerialization.data(withJSONObject: json)
}

final class HTTPTests: XCTestCase {
    func route(_ r: String, _ body: Data) -> Reply { Reply(body: ["route": r, "body": String(decoding: body, as: UTF8.self)]) }

    func testWaitsForTheWholeRequest() {
        XCTAssertNil(HTTP.reply(to: Data("GET /status HTTP/1.1\r\nHost: x\r\n".utf8), route: route))
        XCTAssertNil(HTTP.reply(to: Data("POST /report HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc".utf8), route: route))
    }

    func testRoutesMethodAndPathWithoutQuery() {
        let reply = HTTP.reply(to: Data("POST /report?x=1 HTTP/1.1\r\ncontent-length: 3\r\n\r\nabcdef".utf8), route: route)
        XCTAssertEqual(reply?.body["route"] as? String, "POST /report")
        XCTAssertEqual(reply?.body["body"] as? String, "abc")
    }

    func testRejectsBadAndHugeRequests() {
        XCTAssertEqual(HTTP.reply(to: Data("NONSENSE\r\n\r\n".utf8), route: route)?.status, 400)
        XCTAssertEqual(HTTP.reply(to: Data(count: maxRequest + 1), route: route)?.status, 413)
    }

    func testEncodesErrorsAsNotOK() {
        let text = String(decoding: HTTP.encode(Reply(status: 404)), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Error\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":false}"))
    }
}

final class StageTests: XCTestCase {
    var windows: [FakeWindow] = []
    let tray = FakeTray()
    var quit = false

    func makeStage(_ paths: Paths = tempPaths(), avatars: String? = nil) -> Stage {
        if let avatars {
            try! FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
            try! Data(avatars.utf8).write(to: paths.avatarsFile)
        }
        return Stage(Platform(paths: paths, images: FakeImages(), desktop: FakeDesktop(), tray: tray,
                       makeWindow: { let w = FakeWindow(); self.windows.append(w); return w },
                       quit: { self.quit = true }, info: { ["version": "test"] }))
    }

    var open: Int { windows.filter { !$0.closed }.count }
    func wearing(_ stage: Stage) -> [String] { stage.buddies.map(\.avatar).sorted() }
    func work(_ stage: Stage, _ ids: String...) { ids.forEach { _ = stage.answer("POST /report", report($0, "thinking")) } }

    func testOneBuddyRestsWithNoSessions() {
        let stage = makeStage()
        stage.start()
        XCTAssertEqual(open, 1)
        XCTAssertEqual(tray.count, 1)
        XCTAssertEqual(stage.buddies.first?.look.name, "kyle", "a resting buddy wears its avatar's name")
    }

    func testEachWorkingSessionGetsABuddyAndStoppedOnesGoHome() {
        let stage = makeStage()
        stage.start()
        _ = stage.answer("POST /report", report("a", "thinking"))
        XCTAssertEqual(open, 1, "the resting buddy takes the first session")
        _ = stage.answer("POST /report", report("b", "editing"))
        XCTAssertEqual(open, 2)
        _ = stage.answer("POST /report", report("a", "ended", seq: 2))
        XCTAssertEqual(open, 2, "the default stays out, resting")
        XCTAssertEqual(stage.buddies.first { $0.role == .temporary }?.session, "b")
        XCTAssertNil(stage.buddies.first { $0.role == .main }?.session)
        _ = stage.answer("POST /report", report("b", "ended", seq: 2))
        XCTAssertEqual(open, 1)
    }

    func testAnOldReportCannotUndoANewerOne() {
        let stage = makeStage()
        stage.start()
        _ = stage.answer("POST /report", report("a", "ended", seq: 5))
        _ = stage.answer("POST /report", report("a", "thinking", seq: 4))
        XCTAssertNil(stage.buddies.first?.session)
    }

    func testStatusAndQuit() {
        let stage = makeStage()
        stage.start()
        _ = stage.answer("POST /report", report("a", "thinking"))
        let status = stage.answer("GET /status", Data()).body
        XCTAssertEqual(status["sessions"] as? Int, 1)
        XCTAssertEqual(status["version"] as? String, "test")
        XCTAssertEqual(status["protocol"] as? Int, protocolVersion)
        stage.answer("POST /quit", Data()).then?()
        XCTAssertTrue(quit)
        XCTAssertEqual(stage.answer("GET /nope", Data()).status, 404)
        XCTAssertEqual(stage.answer("POST /report", Data("{}".utf8)).status, 400)
    }

    func testOnlyTheDefaultIsOutAtLaunch() {
        let stage = makeStage(avatars: #"{"avatars":{},"buddies":["kyle","melody"]}"#)
        stage.start()
        XCTAssertEqual(wearing(stage), ["kyle"], "an old saved list brings nobody else out")
        XCTAssertEqual(tray.menu?.rows.map(\.id), bundledAvatars)
        XCTAssertEqual(tray.row("kyle")?.title, "kyle (default)")
        XCTAssertEqual(tray.row("kyle")?.checked, true)
        XCTAssertEqual(tray.row("kyle")?.canRemove, false, "the default itself always stays")
        XCTAssertEqual(tray.row("melody")?.checked, false)
    }

    func testAddBringsOutCopiesAtOnceAndRemoveTakesTheOldest() {
        let stage = makeStage()
        stage.start()
        tray.delegate?.choose(.add("melody"))
        let first = stage.buddies.last!
        tray.delegate?.choose(.add("melody"))
        XCTAssertEqual(wearing(stage), ["kyle", "melody", "melody"], "added buddies come out straight away")
        XCTAssertTrue(stage.buddies.allSatisfy { $0.session == nil }, "and rest until work comes in")
        XCTAssertEqual(tray.row("melody")?.title, "melody ×2")
        XCTAssertEqual(tray.row("melody")?.checked, true)
        stage.housekeeping()
        XCTAssertEqual(wearing(stage), ["kyle", "melody", "melody"], "they don't go home when idle")
        tray.delegate?.choose(.remove("melody"))
        XCTAssertFalse(stage.buddies.contains { $0 === first }, "the oldest copy goes")
        XCTAssertEqual(wearing(stage), ["kyle", "melody"])
    }

    func testRemoveOnTheDefaultTakesOnlyAddedCopies() {
        let stage = makeStage()
        stage.start()
        tray.delegate?.choose(.add("kyle"))
        XCTAssertEqual(tray.row("kyle")?.title, "kyle ×2 (default)")
        XCTAssertEqual(tray.row("kyle")?.canRemove, true)
        let main = stage.buddies.first!
        tray.delegate?.choose(.remove("kyle"))
        tray.delegate?.choose(.remove("kyle"))
        XCTAssertEqual(stage.buddies.map { $0 === main }, [true], "the default itself stays")
        XCTAssertEqual(tray.row("kyle")?.canRemove, false)
    }

    func testARemovedWorkingBuddyGoesHomeAndItsWorkMoves() {
        let stage = makeStage()
        stage.start()
        tray.delegate?.choose(.add("melody"))
        work(stage, "a", "b")
        let melody = stage.buddies.first { $0.avatar == "melody" }!
        let session = melody.session!
        tray.delegate?.choose(.remove("melody"))
        XCTAssertFalse(stage.buddies.contains { $0 === melody })
        XCTAssertEqual(stage.buddies.filter { $0.session == session }.map(\.avatar), ["kyle"],
                       "its session goes to a temporary copy of the default")
    }

    func testExtraWorkBringsOutTemporaryCopiesOfTheDefault() {
        let stage = makeStage()
        stage.start()
        tray.delegate?.choose(.add("sam"))
        work(stage, "a", "b", "c")
        XCTAssertEqual(wearing(stage), ["kyle", "kyle", "sam"])
        XCTAssertEqual(tray.row("kyle")?.title, "kyle (default)", "temporary copies aren't counted in the menu")
        for id in ["a", "b", "c"] { _ = stage.answer("POST /report", report(id, "ended", seq: 2)) }
        XCTAssertEqual(wearing(stage), ["kyle", "sam"], "the temporary copy goes home; the rest stay")
    }

    func testANewDefaultTakesOverAndIsSaved() {
        let paths = tempPaths()
        let stage = makeStage(paths, avatars: #"{"avatars":{},"other":1}"#)
        stage.start()
        tray.delegate?.choose(.makeDefault("onyx"))
        XCTAssertEqual(wearing(stage), ["onyx"], "the resting old default goes home")
        XCTAssertEqual(tray.row("onyx")?.isDefault, true)

        tray.delegate?.choose(.add("melody"))
        let copy = stage.buddies.last!
        let opened = windows.count
        tray.delegate?.choose(.makeDefault("melody"))
        XCTAssertEqual(windows.count, opened, "an added copy of the new default takes over")
        XCTAssertEqual(copy.role, .main)
        XCTAssertEqual(wearing(stage), ["melody"])

        let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: paths.avatarsFile)) as! [String: Any]
        XCTAssertEqual(saved["default"] as? String, "melody")
        XCTAssertEqual(saved["other"] as? Int, 1, "other keys survive")
        tray.delegate?.choose(.add("sam"))
        let again = makeStage(paths)
        again.start()
        XCTAssertEqual(wearing(again), ["melody"], "added buddies last for one launch")
    }

    func testAnOldDefaultAtWorkFinishesFirst() {
        let stage = makeStage()
        stage.start()
        work(stage, "a")
        tray.delegate?.choose(.makeDefault("sam"))
        XCTAssertEqual(wearing(stage), ["kyle", "sam"])
        XCTAssertEqual(stage.buddies.first { $0.avatar == "kyle" }?.session, "a")
        _ = stage.answer("POST /report", report("a", "ended", seq: 2))
        XCTAssertEqual(wearing(stage), ["sam"])
    }

    func testTheMenuIsSentOnlyWhenItChanges() {
        let stage = makeStage()
        stage.start()
        let shows = tray.shows
        stage.housekeeping()
        stage.housekeeping()
        XCTAssertEqual(tray.shows, shows)
    }

    func testABuddyTakesClicksOnlyOverItsBody() {
        let desktop = FakeDesktop()
        let window = FakeWindow()
        let buddy = Buddy(window, desktop)
        buddy.step(0.05)
        XCTAssertTrue(window.through)
        let body = buddy.look.bodyRect(width: buddy.size.width)
        desktop.mouseLocation = Point(x: buddy.position.x + body.midX, y: buddy.position.y + body.midY)
        buddy.step(0.05)
        XCTAssertFalse(window.through)
    }

    func testADroppedBuddyLandsInView() {
        let desktop = FakeDesktop()
        let window = FakeWindow()
        let buddy = Buddy(window, desktop)
        desktop.mouseLocation = Point(x: buddy.position.x + 10, y: buddy.position.y + 10)
        desktop.primaryButtonDown = true
        buddy.grab()
        desktop.mouseLocation = Point(x: 1430, y: 5) // drags it mostly off the bottom right
        buddy.drag()
        desktop.primaryButtonDown = false
        buddy.step(0.05) // the missing mouse-up is noticed
        XCTAssertFalse(buddy.isHeld)
        let body = buddy.look.bodyRect(width: buddy.size.width).offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        XCTAssertLessThanOrEqual(body.maxX, 1440)
        XCTAssertGreaterThanOrEqual(body.minY, 0, "the body, not the whole window, stays in view")
    }
}

final class SpriteTests: XCTestCase {
    func config(_ json: String) -> AvatarConfig { try! JSONDecoder().decode(AvatarConfig.self, from: Data(json.utf8)) }

    func testCutsTheSheetAndMeasuresTheBody() {
        // 4 columns of 16x16; the character fills x 4...11, y 6...15 of each cell.
        let images = FakeImages(size: (64, 32), paint: { x, y in (4...11).contains(x % 16) && y % 16 >= 6 ? 255 : 0 })
        let sprite = Sprite("t", config(#"{"sheet":"s.png","frameWidth":16,"frameHeight":16,"animations":{"walk":{"row":1,"frames":2,"fps":4}}}"#),
                            base: assets, images: images)!
        XCTAssertEqual(sprite.size, Size(width: 64, height: 64), "small sheets scale up by whole numbers to about 64")
        XCTAssertEqual(sprite.body, Size(width: 32, height: 40))
        XCTAssertEqual(sprite.animations["idle"]?.frames, 4, "idle defaults to the whole first row")
        let walk = sprite.animation(mood: "idle", moving: true, asleep: false, held: false)
        XCTAssertEqual(walk.row, 1)
        XCTAssertEqual(sprite.frame(walk, tick: 3), PixelRect(x: 16, y: 16, width: 16, height: 16))
        XCTAssertEqual(sprite.animation(mood: "error", moving: false, asleep: false, held: false).row, 0, "a missing mood plays idle")
    }

    func testTheSavedDefaultIsKnownOrKyle() {
        let known = { (id: String) in ["kyle", "fox"].contains(id) }
        XCTAssertEqual(chosenDefault(saved: "fox", known: known), "fox")
        XCTAssertEqual(chosenDefault(saved: "builtin", known: known), "kyle", "builtin is kyle")
        XCTAssertEqual(chosenDefault(saved: "ghost", known: known), "kyle")
        XCTAssertEqual(chosenDefault(saved: nil, known: known), "kyle")
    }

    func testRejectsAFrameBiggerThanTheSheet() {
        let images = FakeImages(size: (8, 8))
        XCTAssertNil(Sprite("t", config(#"{"sheet":"s.png","frameWidth":16,"frameHeight":16}"#), base: assets, images: images))
    }

    func testBundledAvatarsLoad() {
        let library = AvatarLibrary(tempPaths(), FakeImages())
        for name in bundledAvatars {
            XCTAssertTrue(library.has(name), name)
            let sprite = library.sprite(name)!
            for mood in animationNames where mood != "walk" {
                XCTAssertNotNil(sprite.animations[mood], "\(name) has \(mood)")
            }
        }
        XCTAssertTrue(library.sprite("nobody-by-this-name") === library.sprite(nil), "unknown picks wear the default")
    }

    func testSceneTrimsALongName() {
        var look = Look()
        look.name = String(repeating: "long-project-name-", count: 10)
        let scene = Scene(look, size: Size(width: winW, height: winH), measure: { s, _, _ in Size(width: Double(s.count) * 6, height: 13) })
        XCTAssertTrue(scene.label.string.hasSuffix("…"))
        XCTAssertLessThanOrEqual(Double(scene.label.string.count) * 6, winW - 20)
    }
}
