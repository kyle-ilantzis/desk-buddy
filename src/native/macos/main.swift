// The overlay on macOS: one small window per buddy, walking the screen. Clicks pass through
// all of it but the buddy's body, which can be picked up. Sessions report to it over a Unix
// socket. What buddies do, and for whom, is in the shared core (../core); this layer
// runs the timer, gives the core its windows, and draws what the core says to draw.
import AppKit
import DeskBuddyCore

final class App: NSObject, NSApplicationDelegate {
    let server = Server(path: paths.endpoint)
    var stage: Stage!
    var last = Date()

    func applicationDidFinishLaunching(_ note: Notification) {
        let platform = Platform(
            paths: paths, images: MacImages(), desktop: MacDesktop(), tray: MenuBarItem(),
            makeWindow: { Overlay() },
            quit: { NSApp.terminate(nil) },
            info: {
                ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev",
                 "binary": Bundle.main.executablePath ?? "",
                 "resources": Bundle.main.resourcePath ?? ""]
            })
        let stage = Stage(platform)
        self.stage = stage
        server.route = { route, body in stage.answer(route, body) }
        server.start()
        stage.start()
        let frames = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(frames, forMode: .common)
    }

    func frame() {
        let now = Date()
        stage.tick(CGFloat(now.timeIntervalSince(last)))
        last = now
    }

    func applicationWillTerminate(_ note: Notification) { server.stop() }
}

DeskBuddyCore.logLine = { NSLog("desk-buddy: %@", $0) }
prepareDataFolder(paths)
runTool(CommandLine.arguments, paths, MacImages(), writePreview: writeSheetPreview)

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
