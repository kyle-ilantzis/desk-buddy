// A buddy's window on macOS: a borderless panel above everything, on every space, that
// paints the core's Scene. Clicks pass through it unless the core says the mouse is over the body.
import AppKit
import DeskBuddyCore

func font(_ size: CGFloat, _ weight: Scene.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight == .bold ? .bold : .semibold)
}

func measure(_ text: String, _ size: Double, _ weight: Scene.Weight) -> Size {
    let measured = (text as NSString).size(withAttributes: [.font: font(size, weight)])
    return Size(width: measured.width, height: measured.height)
}

/// Paints a scene into the current graphics context, with its origin at the context's.
func paint(_ scene: Scene) {
    NSColor.black.withAlphaComponent(Scene.shadowAlpha).setFill()
    NSBezierPath(ovalIn: CGRect(scene.shadow)).fill()

    if let s = scene.sprite, let ctx = NSGraphicsContext.current?.cgContext,
       let sheet = s.sprite.image.native.map({ $0 as! CGImage }),
       let frame = sheet.cropping(to: CGRect(x: s.source.x, y: s.source.y, width: s.source.width, height: s.source.height)) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: s.dest.midX, y: s.dest.minY)
        if s.mirrored { ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(frame, in: CGRect(x: -s.dest.width / 2, y: 0, width: s.dest.width, height: s.dest.height))
        ctx.restoreGState()
    }

    if let z = scene.snore { draw(z) }

    let tint: NSColor = switch scene.tint {
    case .alert: .systemRed
    case .warning: .systemOrange
    case .plain: .black
    }
    tint.withAlphaComponent(Scene.tagAlpha).setFill()
    NSBezierPath(roundedRect: CGRect(scene.tag), xRadius: Scene.tagRadius, yRadius: Scene.tagRadius).fill()
    draw(scene.label)
}

func draw(_ text: Scene.Text) {
    (text.string as NSString).draw(at: CGPoint(text.origin), withAttributes: [
        .font: font(text.size, text.weight), .foregroundColor: NSColor.white.withAlphaComponent(text.alpha),
    ])
}

final class BuddyView: NSView {
    var look = Look()
    weak var delegate: OverlayWindowDelegate?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { delegate?.grab() }
    override func mouseDragged(with event: NSEvent) { delegate?.drag() }
    override func mouseUp(with event: NSEvent) { delegate?.drop() }

    override func draw(_ dirty: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        paint(Scene(look, size: Size(width: bounds.width, height: bounds.height), measure: measure))
    }
}

final class Overlay: OverlayWindow {
    let window: NSPanel
    let view = BuddyView()

    var delegate: OverlayWindowDelegate? {
        get { view.delegate }
        set { view.delegate = newValue }
    }

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        window.orderFrontRegardless()
    }

    func place(_ frame: Rect) {
        let frame = CGRect(frame)
        if window.frame.size == frame.size {
            window.setFrameOrigin(frame.origin)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    func setClickThrough(_ through: Bool) { window.ignoresMouseEvents = through }

    func show(_ look: Look) {
        view.look = look
        view.needsDisplay = true
    }

    func close() { window.orderOut(nil); window.close() }
}

/// Every animation drawn as the overlay shows it, in one picture for checking the art.
func writeSheetPreview(_ sprite: Sprite?, to path: String) throws {
    let (cell, cols, looks) = previewLooks(sprite)
    let rows = (looks.count + cols - 1) / cols
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols * Int(cell.width), pixelsHigh: rows * Int(cell.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.55, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    for (i, look) in looks.enumerated() {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(i % cols) * cell.width, y: CGFloat(rows - 1 - i / cols) * cell.height)
        NSColor.clear.set()
        NSRect(origin: .zero, size: CGSize(cell)).fill()
        paint(Scene(look, size: cell, measure: measure))
        ctx.restoreGState()
    }
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
