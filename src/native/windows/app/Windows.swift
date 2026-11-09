// The rest of the Windows layer: paths, image loading, the screens and mouse, the
// notification area icon, and the named pipe sessions report to.
#if os(Windows)
import CGdiPlus
import DeskBuddyCore
import Foundation
import WinSDK

/// %LOCALAPPDATA%, from SHGetKnownFolderPath.
func localAppData() -> URL {
    var folder = GUID(Data1: 0xF1B3_2785, Data2: 0x6FBA, Data3: 0x4FCF, Data4: (0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91)) // FOLDERID_LocalAppData
    var found: PWSTR?
    if SHGetKnownFolderPath(&folder, 0, nil, &found) == S_OK, let found {
        defer { CoTaskMemFree(found) }
        return URL(fileURLWithPath: string(fromWide: UnsafePointer(found)), isDirectory: true)
    }
    let fallback = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSHomeDirectory() + "\\AppData\\Local"
    return URL(fileURLWithPath: fallback, isDirectory: true)
}

/// DeskBuddy.exe, wherever it was started from.
let exePath: String = {
    var buffer = [WCHAR](repeating: 0, count: 32_768)
    let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
}()

/// A file URL as Windows spells it, with a drive letter and backslashes.
func nativePath(_ url: URL) -> String {
    url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
}

let userName = ProcessInfo.processInfo.environment["USERNAME"] ?? "user"
let paths = Paths(dataDir: localAppData().appendingPathComponent("DeskBuddy", isDirectory: true),
                  legacyDir: nil,
                  resources: URL(fileURLWithPath: exePath).deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true),
                  // One pipe per user. The mod connects with \\.\pipe\DeskBuddy-%USERNAME%.
                  endpoint: "\\\\.\\pipe\\DeskBuddy-\(userName)")

/// PNGs through GDI+. The core gets the pixels; the GDI+ bitmap stays for drawing.
struct WinImages: ImageLoader {
    func load(_ url: URL) -> Bitmap? {
        var image: OpaquePointer?
        guard withWide(nativePath(url)) { GdipCreateBitmapFromFile($0, &image) } == 0, let image else { return nil }
        let kept = GdiImage(image)
        var w: UINT = 0, h: UINT = 0
        GdipGetImageWidth(image, &w)
        GdipGetImageHeight(image, &h)
        guard w > 0, h > 0 else { return nil }
        var area = CGdipRect(X: 0, Y: 0, Width: INT(w), Height: INT(h))
        var data = CGdipBitmapData()
        guard GdipBitmapLockBits(image, &area, UINT(CGdipImageLockModeRead), INT(CGdipPixelFormat32bppPARGB), &data) == 0,
              let scan0 = data.Scan0 else { return nil }
        defer { GdipBitmapUnlockBits(image, &data) }
        var pixels = [UInt8](repeating: 0, count: Int(w) * Int(h) * 4)
        for y in 0..<Int(h) {
            let row = scan0.advanced(by: y * Int(data.Stride)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<Int(w) {
                let i = (y * Int(w) + x) * 4
                pixels[i] = row[x * 4 + 2]     // BGRA to RGBA
                pixels[i + 1] = row[x * 4 + 1]
                pixels[i + 2] = row[x * 4]
                pixels[i + 3] = row[x * 4 + 3]
            }
        }
        return Bitmap(width: Int(w), height: Int(h), pixels: pixels, native: kept)
    }
}

final class Screens {
    var found: [Screen] = []
}

let monitorProc: MONITORENUMPROC = { monitor, _, _, context in
    guard let monitor, let raw = UnsafeMutableRawPointer(bitPattern: Int(context)) else { return true }
    var info = MONITORINFO()
    info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    if GetMonitorInfoW(monitor, &info) {
        Unmanaged<Screens>.fromOpaque(raw).takeUnretainedValue().found.append(Screen(frame: rect(info.rcMonitor), visible: rect(info.rcWork)))
    }
    return true
}

struct WinDesktop: Desktop {
    func screens() -> [Screen] {
        let screens = Screens()
        let context = Unmanaged.passUnretained(screens).toOpaque()
        EnumDisplayMonitors(nil, nil, monitorProc, LPARAM(Int(bitPattern: context)))
        return screens.found
    }

    var mouseLocation: Point {
        var p = POINT()
        GetCursorPos(&p)
        return Point(x: Double(p.x), y: mainScreenHeight - Double(p.y))
    }

    var primaryButtonDown: Bool {
        let key = GetSystemMetrics(smSwapButton) != 0 ? vkRButton : vkLButton
        return GetAsyncKeyState(key) < 0 // the high bit: down now
    }
}

/// A hidden window for everything that isn't a buddy: the timer, the tray icon's
/// messages, and requests the pipe threads hand to the main thread.
let messageClass = "DeskBuddyMessages"
let trayMessage = wmApp + 1
let requestMessage = wmApp + 2
let thenMessage = wmApp + 3
let quitCommand: WORD = 1
let buddyCommands = 100 // then three ids a buddy row: Add, Remove, Default
var onMessage: (UINT, WPARAM, LPARAM) -> LRESULT? = { _, _, _ in nil }

let messageProc: WNDPROC = { hwnd, message, wParam, lParam in
    onMessage(message, wParam, lParam) ?? DefWindowProcW(hwnd, message, wParam, lParam)
}

func makeMessageWindow() -> HWND? {
    withWide(messageClass) { name in
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = messageProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.lpszClassName = name
        RegisterClassExW(&wc)
        // A top-level window that is never shown, rather than HWND_MESSAGE: the tray needs
        // it to come to the foreground so its menu closes when clicked away from.
        return CreateWindowExW(wsExToolWindow, name, nil, wsPopup, 0, 0, 0, 0, nil, nil, GetModuleHandleW(nil), nil)
    }
}

final class NotificationIcon: Tray {
    let hwnd: HWND?
    var data = NOTIFYICONDATAW()
    weak var delegate: TrayDelegate?
    var shown: TrayMenu?

    init(_ hwnd: HWND?) {
        self.hwnd = hwnd
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        data.uFlags = nifMessage | nifIcon | nifTip
        data.uCallbackMessage = trayMessage
        data.hIcon = LoadIconW(GetModuleHandleW(nil), intResource(1)) ?? LoadIconW(nil, intResource(32512)) // the app's, or IDI_APPLICATION
        setTip("DeskBuddy")
        Shell_NotifyIconW(nimAdd, &data)
    }

    func setTip(_ tip: String) {
        let chars = Array(tip.utf16.prefix(127)) + [0]
        withUnsafeMutableBytes(of: &data.szTip) { raw in
            let slots = raw.bindMemory(to: WCHAR.self)
            for (i, c) in chars.enumerated() where i < slots.count { slots[i] = c }
        }
    }

    /// Keeps the core's menu for the next right click, and the count for the tip.
    func show(_ menu: TrayMenu) {
        shown = menu
        let n = menu.buddiesOut
        setTip(n == 1 ? "DeskBuddy: 1 buddy" : "DeskBuddy: \(n) buddies")
        Shell_NotifyIconW(nimModify, &data)
    }

    /// The menu, on a right click. Choosing from it sends WM_COMMAND to `hwnd` with
    /// `quitCommand`, or a buddy's command id, which `choice(for:)` reads back.
    func menu() {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) } // takes its submenus with it
        withWide("Buddies") { _ = AppendMenuW(menu, mfString | mfGrayed, 0, $0) }
        AppendMenuW(menu, mfSeparator, 0, nil)
        for (i, row) in (shown?.rows ?? []).enumerated() {
            guard let actions = CreatePopupMenu() else { continue }
            let items = [("Add", row.canAdd), ("Remove", row.canRemove), ("Default", row.canMakeDefault)]
            for (j, (title, enabled)) in items.enumerated() {
                withWide(title) { _ = AppendMenuW(actions, mfString | (enabled ? 0 : mfGrayed), UINT_PTR(buddyCommands + i * 3 + j), $0) }
            }
            let flags = mfString | mfPopup | (row.checked ? mfChecked : 0)
            withWide(row.title) { _ = AppendMenuW(menu, flags, UINT_PTR(UInt(bitPattern: Int(bitPattern: actions))), $0) }
        }
        AppendMenuW(menu, mfSeparator, 0, nil)
        withWide("Send buddies home") { _ = AppendMenuW(menu, mfString, UINT_PTR(quitCommand), $0) }
        var p = POINT()
        GetCursorPos(&p)
        SetForegroundWindow(hwnd)
        TrackPopupMenu(menu, tpmRightButton, p.x, p.y, 0, hwnd, nil)
    }

    /// What a WM_COMMAND id from the menu picks.
    func choice(for command: Int) -> TrayChoice? {
        if command == Int(quitCommand) { return .sendHome }
        let i = command - buddyCommands
        guard i >= 0, let rows = shown?.rows, rows.indices.contains(i / 3) else { return nil }
        let id = rows[i / 3].id
        return [TrayChoice.add(id), .remove(id), .makeDefault(id)][i % 3]
    }

    func remove() { Shell_NotifyIconW(nimDelete, &data) }
}

/// One request a pipe thread is waiting on, answered on the main thread.
final class Request {
    let route: String
    let body: Data
    var reply = Reply(status: 503)
    init(_ route: String, _ body: Data) { self.route = route; self.body = body }
}

/// HTTP over a named pipe. Each connection carries one request, read and written on a
/// thread of its own; the request is answered on the main thread, by SendMessage to
/// `window`, which waits for the answer. Remote clients are refused, and the pipe's
/// default security lets only this user, SYSTEM and administrators write to it.
final class PipeServer {
    let name: String
    let window: HWND?

    init(name: String, window: HWND?) {
        self.name = name
        self.window = window
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let pipe = withWide(name) {
                    CreateNamedPipeW($0, pipeAccessDuplex,
                                     DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT) | pipeRejectRemoteClients,
                                     pipeUnlimitedInstances, DWORD(maxRequest), DWORD(maxRequest), 0, nil)
                }
                guard let pipe, pipe != invalidHandle else {
                    logLine("could not open the pipe \(name): error \(GetLastError())")
                    return
                }
                if !ConnectNamedPipe(pipe, nil) && GetLastError() != errorPipeConnected {
                    CloseHandle(pipe)
                    continue
                }
                Thread.detachNewThread { [self] in serve(pipe) }
            }
        }
    }

    private func serve(_ pipe: HANDLE) {
        defer {
            FlushFileBuffers(pipe)
            DisconnectNamedPipe(pipe)
            CloseHandle(pipe)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var read: DWORD = 0
            guard ReadFile(pipe, &chunk, DWORD(chunk.count), &read, nil), read > 0 else { return }
            buffer.append(contentsOf: chunk[0..<Int(read)])
            guard let reply = HTTP.reply(to: buffer, route: answerOnMain) else { continue }
            let bytes = [UInt8](HTTP.encode(reply))
            var written: DWORD = 0
            _ = WriteFile(pipe, bytes, DWORD(bytes.count), &written, nil)
            if let then = reply.then {
                let box = Unmanaged.passRetained(Request("", Data()))
                box.takeUnretainedValue().reply.then = then
                PostMessageW(window, thenMessage, 0, LPARAM(Int(bitPattern: box.toOpaque())))
            }
            return
        }
    }

    private func answerOnMain(_ route: String, _ body: Data) -> Reply {
        let request = Request(route, body)
        let raw = Unmanaged.passUnretained(request).toOpaque()
        SendMessageW(window, requestMessage, 0, LPARAM(Int(bitPattern: raw)))
        return request.reply
    }
}
#endif
