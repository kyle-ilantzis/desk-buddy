// A buddy's window on Windows: a layered popup above everything, kept off the taskbar
// and never activated. It paints the core's Scene into a premultiplied BGRA DIB and hands
// that to UpdateLayeredWindow, so every pixel carries its own alpha. Clicks pass through
// (WS_EX_TRANSPARENT) unless the core says the mouse is over the body.
#if os(Windows)
import CGdiPlus
import DeskBuddyCore
import Foundation
import WinSDK

let overlayClass = "DeskBuddyOverlay"

/// The window procedure every overlay shares; its Overlay is in GWLP_USERDATA.
let overlayProc: WNDPROC = { hwnd, message, wParam, lParam in
    if let hwnd, let raw = UnsafeMutableRawPointer(bitPattern: Int(GetWindowLongPtrW(hwnd, gwlpUserData))) {
        let overlay = Unmanaged<Overlay>.fromOpaque(raw).takeUnretainedValue()
        switch message {
        case wmMouseActivate:
            return maNoActivate
        case wmLButtonDown:
            SetCapture(hwnd)
            overlay.delegate?.grab()
            return 0
        case wmMouseMove:
            if wParam & mkLButton != 0 && GetCapture() == hwnd { overlay.delegate?.drag() }
            return 0
        case wmLButtonUp:
            ReleaseCapture() // sends WM_CAPTURECHANGED, which drops
            return 0
        case wmCaptureChanged:
            overlay.delegate?.drop()
            return 0
        default:
            break
        }
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

func registerOverlayClass() {
    withWide(overlayClass) { name in
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = overlayProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hCursor = LoadCursorW(nil, intResource(32512)) // IDC_ARROW
        wc.lpszClassName = name
        RegisterClassExW(&wc)
    }
}

final class Overlay: OverlayWindow {
    weak var delegate: OverlayWindowDelegate?
    private var hwnd: HWND?
    private var frame = Rect(x: 0, y: 0, width: winW, height: winH)
    private var look = Look()
    // The DIB the scene is painted into, remade when the size changes.
    private var memDC: HDC?
    private var dib: HBITMAP?
    private var bits: UnsafeMutableRawPointer?
    private var dibSize = (w: 0, h: 0)

    init() {
        hwnd = withWide(overlayClass) { name in
            CreateWindowExW(wsExLayered | wsExTopmost | wsExToolWindow | wsExNoActivate | wsExTransparent,
                            name, nil, wsPopup, 0, 0, Int32(winW), Int32(winH), nil, nil, GetModuleHandleW(nil), nil)
        }
        guard let hwnd else { logLine("could not make a window: error \(GetLastError())"); return }
        SetWindowLongPtrW(hwnd, gwlpUserData, LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())))
        memDC = CreateCompatibleDC(nil)
        ShowWindow(hwnd, swShowNoActivate)
    }

    deinit { close() }

    func place(_ frame: Rect) {
        let resized = frame.size != self.frame.size
        self.frame = frame
        guard let hwnd else { return }
        if resized {
            render()
        } else {
            let p = topLeft(frame)
            SetWindowPos(hwnd, nil, p.x, p.y, 0, 0, swpNoSize | swpNoZOrder | swpNoActivate)
        }
    }

    func setClickThrough(_ through: Bool) {
        guard let hwnd else { return }
        let style = DWORD(truncatingIfNeeded: GetWindowLongPtrW(hwnd, gwlExStyle))
        let next = through ? style | wsExTransparent : style & ~wsExTransparent
        if next != style { SetWindowLongPtrW(hwnd, gwlExStyle, LONG_PTR(next)) }
    }

    func show(_ look: Look) {
        self.look = look
        render()
    }

    func close() {
        if let hwnd {
            SetWindowLongPtrW(hwnd, gwlpUserData, 0)
            DestroyWindow(hwnd)
        }
        hwnd = nil
        if let dib { DeleteObject(HGDIOBJ(dib)) }
        dib = nil
        if let memDC { DeleteDC(memDC) }
        memDC = nil
    }

    private func makeDIB(_ w: Int, _ h: Int) -> Bool {
        if dibSize == (w, h), dib != nil { return true }
        if let dib { DeleteObject(HGDIOBJ(dib)) }
        dib = nil
        bits = nil
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(w)
        info.bmiHeader.biHeight = -LONG(h) // rows from the top
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var pixels: UnsafeMutableRawPointer?
        guard let made = CreateDIBSection(memDC, &info, dibRGBColors, &pixels, nil, 0), let pixels else { return false }
        SelectObject(memDC, HGDIOBJ(made))
        dib = made
        bits = pixels
        dibSize = (w, h)
        return true
    }

    private func render() {
        guard let hwnd, let memDC else { return }
        let w = Int(frame.width.rounded()), h = Int(frame.height.rounded())
        guard w > 0, h > 0, makeDIB(w, h), let bits else { return }
        memset(bits, 0, w * h * 4)
        // GDI+ paints straight into the DIB's memory: premultiplied BGRA is its PARGB.
        var canvas: OpaquePointer?
        GdipCreateBitmapFromScan0(INT(w), INT(h), INT(w * 4), INT(CGdipPixelFormat32bppPARGB), bits.assumingMemoryBound(to: BYTE.self), &canvas)
        guard let canvas else { return }
        var graphics: OpaquePointer?
        GdipGetImageGraphicsContext(canvas, &graphics)
        if let graphics {
            paint(Scene(look, size: frame.size, measure: fonts.measure), on: graphics)
            GdipDeleteGraphics(graphics)
        }
        GdipDisposeImage(canvas)

        var destination = topLeft(frame)
        var size = SIZE(cx: LONG(w), cy: LONG(h))
        var source = POINT(x: 0, y: 0)
        var blend = BLENDFUNCTION(BlendOp: acSrcOver, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: acSrcAlpha)
        let screen = GetDC(nil)
        UpdateLayeredWindow(hwnd, screen, &destination, &size, memDC, &source, 0, &blend, ulwAlpha)
        ReleaseDC(nil, screen)
    }
}
#endif
