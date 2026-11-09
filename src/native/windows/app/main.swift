// The overlay on Windows. What buddies do, and for whom, is in the shared core (../../core);
// this layer runs the timer, gives the core its windows, and draws what the core says to draw.
#if os(Windows)
import CGdiPlus
import DeskBuddyCore
import Foundation
import WinSDK

var gdiplusToken: ULONG_PTR = 0
var startup = CGdipStartupInput(GdiplusVersion: 1, DebugEventCallback: nil, SuppressBackgroundThread: false, SuppressExternalCodecs: false)
guard GdiplusStartup(&gdiplusToken, &startup, nil) == 0 else { fatalError("GDI+ did not start") }

prepareDataFolder(paths)
runTool(CommandLine.arguments, paths, WinImages(), writePreview: writeSheetPreview)

// One copy per user: a second one leaves quietly.
let mutex = withWide("Local\\DeskBuddy-\(userName)") { CreateMutexW(nil, true, $0) }
if GetLastError() == errorAlreadyExists { exit(0) }

let version = (try? String(contentsOf: paths.resources!.appendingPathComponent("VERSION"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"

registerOverlayClass()
let messages = makeMessageWindow()
let tray = NotificationIcon(messages)
let stage = Stage(Platform(
    paths: paths, images: WinImages(), desktop: WinDesktop(), tray: tray,
    makeWindow: { Overlay() },
    quit: { PostQuitMessage(0) },
    info: { ["version": version, "binary": exePath, "resources": paths.resources?.path ?? ""] }))
let server = PipeServer(name: paths.endpoint, window: messages)

var last = Date()
onMessage = { message, wParam, lParam in
    switch message {
    case wmTimer:
        let now = Date()
        stage.tick(now.timeIntervalSince(last))
        last = now
        return 0
    case requestMessage:
        guard let raw = UnsafeMutableRawPointer(bitPattern: Int(lParam)) else { return 0 }
        let request = Unmanaged<Request>.fromOpaque(raw).takeUnretainedValue()
        request.reply = stage.answer(request.route, request.body)
        return 0
    case thenMessage:
        guard let raw = UnsafeMutableRawPointer(bitPattern: Int(lParam)) else { return 0 }
        Unmanaged<Request>.fromOpaque(raw).takeRetainedValue().reply.then?()
        return 0
    case trayMessage:
        let event = UINT(truncatingIfNeeded: lParam)
        if event == wmRButtonUp || event == wmContextMenu { tray.menu() }
        return 0
    case wmCommand:
        // The menu's picks go to the core, "Send buddies home" too.
        guard let choice = tray.choice(for: Int(WORD(truncatingIfNeeded: wParam))) else { return nil } // LOWORD
        tray.delegate?.choose(choice)
        return 0
    default:
        return nil
    }
}

server.start()
stage.start()
SetTimer(messages, 1, 50, nil)

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}

tray.remove()
GdiplusShutdown(gdiplusToken)
if let mutex { CloseHandle(mutex) }
#else
print("DeskBuddyWin builds on Windows only")
#endif
