// Painting the core's Scene with GDI+, into a buddy's window or into a preview PNG.
// A Scene counts y up from the bottom of its window; GDI+ counts it down from the top.
#if os(Windows)
import CGdiPlus
import DeskBuddyCore
import Foundation
import WinSDK

/// A GDI+ image the core's Bitmap came from, kept for drawing and freed with it.
final class GdiImage {
    let image: OpaquePointer
    init(_ image: OpaquePointer) { self.image = image }
    deinit { GdipDisposeImage(image) }
}

func argb(_ alpha: Double, _ r: UInt32, _ g: UInt32, _ b: UInt32) -> DWORD {
    DWORD(max(0, min(255, (alpha * 255).rounded()))) << 24 | r << 16 | g << 8 | b
}

/// Fonts by size and weight. Segoe UI is the system font; its Semibold face stands in
/// for the semibold weight GDI+ has no style for.
final class Fonts {
    private var cache: [String: OpaquePointer] = [:]
    let typographic: OpaquePointer? = {
        var format: OpaquePointer?
        GdipStringFormatGetGenericTypographic(&format)
        return format
    }()
    /// A tiny canvas, only for measuring.
    private let scratch: (bitmap: OpaquePointer?, graphics: OpaquePointer?) = {
        var bitmap: OpaquePointer?, graphics: OpaquePointer?
        GdipCreateBitmapFromScan0(1, 1, 4, INT(CGdipPixelFormat32bppPARGB), nil, &bitmap)
        if let bitmap { GdipGetImageGraphicsContext(bitmap, &graphics) }
        if let graphics { GdipSetTextRenderingHint(graphics, INT(CGdipTextRenderingHintAntiAliasGridFit)) }
        return (bitmap, graphics)
    }()

    func font(_ size: Double, _ weight: Scene.Weight) -> OpaquePointer? {
        let key = "\((size * 4).rounded() / 4)-\(weight)"
        if let font = cache[key] { return font }
        let family = weight == .bold ? "Segoe UI" : "Segoe UI Semibold"
        var familyRef: OpaquePointer?
        withWide(family) { _ = GdipCreateFontFamilyFromName($0, nil, &familyRef) }
        guard let familyRef else { return nil }
        defer { GdipDeleteFontFamily(familyRef) }
        var font: OpaquePointer?
        GdipCreateFont(familyRef, Float(size), INT(weight == .bold ? CGdipFontStyleBold : CGdipFontStyleRegular), INT(CGdipUnitPixel), &font)
        cache[key] = font
        return font
    }

    func measure(_ text: String, _ size: Double, _ weight: Scene.Weight) -> Size {
        guard let graphics = scratch.graphics, let font = font(size, weight) else { return Size(width: Double(text.count) * size * 0.55, height: size * 1.3) }
        let chars = Array(text.utf16)
        var layout = CGdipRectF(X: 0, Y: 0, Width: 10_000, Height: 1_000)
        var box = CGdipRectF(X: 0, Y: 0, Width: 0, Height: 0)
        GdipMeasureString(graphics, chars, INT(chars.count), font, &layout, typographic, &box, nil, nil)
        return Size(width: Double(box.Width), height: Double(box.Height))
    }
}

let fonts = Fonts()

/// Paints `scene` on `graphics`, its window's top left at (x, y).
func paint(_ scene: Scene, on graphics: OpaquePointer, x: Double = 0, y: Double = 0) {
    let h = scene.size.height
    // A Scene rectangle, as GDI+ wants it: left, top, width, height.
    func flip(_ r: Rect) -> (Float, Float, Float, Float) {
        (Float(x + r.minX), Float(y + h - r.maxY), Float(r.width), Float(r.height))
    }
    func fill(_ color: DWORD, _ draw: (OpaquePointer) -> Void) {
        var brush: OpaquePointer?
        GdipCreateSolidFill(color, &brush)
        guard let brush else { return }
        draw(brush)
        GdipDeleteBrush(brush)
    }

    GdipSetSmoothingMode(graphics, INT(CGdipSmoothingModeAntiAlias))
    GdipSetTextRenderingHint(graphics, INT(CGdipTextRenderingHintAntiAliasGridFit))

    let shadow = flip(scene.shadow)
    fill(argb(Scene.shadowAlpha, 0, 0, 0)) { GdipFillEllipse(graphics, $0, shadow.0, shadow.1, shadow.2, shadow.3) }

    if let s = scene.sprite, let image = s.sprite.image.native as? GdiImage {
        let dest = flip(s.dest)
        GdipSetInterpolationMode(graphics, INT(CGdipInterpolationModeNearestNeighbor))
        GdipSetPixelOffsetMode(graphics, INT(CGdipPixelOffsetModeHalf))
        GdipTranslateWorldTransform(graphics, dest.0 + dest.2 / 2, dest.1, INT(CGdipMatrixOrderPrepend))
        if s.mirrored { GdipScaleWorldTransform(graphics, -1, 1, INT(CGdipMatrixOrderPrepend)) }
        GdipDrawImageRectRectI(graphics, image.image,
                               INT((-dest.2 / 2).rounded()), 0, INT(dest.2.rounded()), INT(dest.3.rounded()),
                               INT(s.source.x), INT(s.source.y), INT(s.source.width), INT(s.source.height),
                               INT(CGdipUnitPixel), nil, nil, nil)
        GdipResetWorldTransform(graphics)
    }

    func text(_ t: Scene.Text) {
        guard let font = fonts.font(t.size, t.weight) else { return }
        let measured = fonts.measure(t.string, t.size, t.weight)
        let chars = Array(t.string.utf16)
        var layout = CGdipRectF(X: Float(x + t.origin.x), Y: Float(y + h - t.origin.y - measured.height),
                                Width: Float(measured.width + 4), Height: Float(measured.height))
        fill(argb(t.alpha, 255, 255, 255)) { GdipDrawString(graphics, chars, INT(chars.count), font, &layout, fonts.typographic, $0) }
    }

    if let z = scene.snore { text(z) }

    let tint: DWORD = switch scene.tint {
    case .alert: argb(Scene.tagAlpha, 255, 59, 48)   // systemRed
    case .warning: argb(Scene.tagAlpha, 255, 149, 0) // systemOrange
    case .plain: argb(Scene.tagAlpha, 0, 0, 0)
    }
    let tag = flip(scene.tag)
    let d = Float(Scene.tagRadius * 2)
    var path: OpaquePointer?
    GdipCreatePath(INT(CGdipFillModeAlternate), &path)
    if let path {
        GdipAddPathArc(path, tag.0, tag.1, d, d, 180, 90)
        GdipAddPathArc(path, tag.0 + tag.2 - d, tag.1, d, d, 270, 90)
        GdipAddPathArc(path, tag.0 + tag.2 - d, tag.1 + tag.3 - d, d, d, 0, 90)
        GdipAddPathArc(path, tag.0, tag.1 + tag.3 - d, d, d, 90, 90)
        GdipClosePathFigure(path)
        fill(tint) { GdipFillPath(graphics, $0, path) }
        GdipDeletePath(path)
    }
    text(scene.label)
}

/// image/png, for GdipSaveImageToFile.
var pngEncoder = CLSID(Data1: 0x557C_F406, Data2: 0x1A04, Data3: 0x11D3, Data4: (0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E))

struct PreviewError: Error, CustomStringConvertible { let description: String }

/// Every animation drawn as the overlay shows it, in one picture for checking the art.
func writeSheetPreview(_ sprite: Sprite?, to path: String) throws {
    let (cell, cols, looks) = previewLooks(sprite)
    let rows = (looks.count + cols - 1) / cols
    let w = cols * Int(cell.width), h = rows * Int(cell.height)
    var bitmap: OpaquePointer?, graphics: OpaquePointer?
    GdipCreateBitmapFromScan0(INT(w), INT(h), 0, INT(CGdipPixelFormat32bppPARGB), nil, &bitmap)
    guard let bitmap else { throw PreviewError(description: "could not make a \(w)x\(h) picture") }
    defer { GdipDisposeImage(bitmap) }
    GdipGetImageGraphicsContext(bitmap, &graphics)
    guard let graphics else { throw PreviewError(description: "could not draw") }
    GdipGraphicsClear(graphics, argb(1, 140, 140, 140))
    for (i, look) in looks.enumerated() {
        let x = Double(i % cols) * cell.width, y = Double(i / cols) * cell.height
        // As on macOS, each cell starts clear, over the grey.
        GdipSetCompositingMode(graphics, INT(CGdipCompositingModeSourceCopy))
        var clear: OpaquePointer?
        GdipCreateSolidFill(0, &clear)
        if let clear { GdipFillRectangle(graphics, clear, Float(x), Float(y), Float(cell.width), Float(cell.height)); GdipDeleteBrush(clear) }
        GdipSetCompositingMode(graphics, INT(CGdipCompositingModeSourceOver))
        paint(Scene(look, size: cell, measure: fonts.measure), on: graphics, x: x, y: y)
    }
    GdipDeleteGraphics(graphics)
    let status = withWide(path) { GdipSaveImageToFile(bitmap, $0, &pngEncoder, nil) }
    if status != 0 { throw PreviewError(description: "could not write \(path) (GDI+ status \(status))") }
}
#endif
