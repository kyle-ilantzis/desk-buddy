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
    var count = -1
    func show(buddies: Int) { count = buddies }
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

    func makeStage() -> Stage {
        Stage(Platform(paths: tempPaths(), images: FakeImages(), desktop: FakeDesktop(), tray: tray,
                       makeWindow: { let w = FakeWindow(); self.windows.append(w); return w },
                       quit: { self.quit = true }, info: { ["version": "test"] }))
    }

    var open: Int { windows.filter { !$0.closed }.count }

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
        XCTAssertEqual(open, 1)
        XCTAssertEqual(stage.buddies.first?.session, "b")
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
