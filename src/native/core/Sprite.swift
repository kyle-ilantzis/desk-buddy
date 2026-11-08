// Sprite sheets and avatars.json. The sheet's rules are in
// ../../mod/tool-avatar-maker/AVATAR-SHEETS.md.
import Foundation

/// A picture as pixels: RGBA, 8 bits each, premultiplied, rows from the top.
public struct Bitmap {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    /// Whatever the OS layer wants to draw with, such as the decoded image it read this from.
    public let native: AnyObject?

    public init(width: Int, height: Int, pixels: [UInt8], native: AnyObject? = nil) {
        precondition(pixels.count == width * height * 4, "a bitmap needs 4 bytes a pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.native = native
    }

    /// Where the visible pixels inside `cell` are, counted from the cell's top left; nil if it has none.
    public func visibleBounds(in cell: PixelRect) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var found: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        let x0 = max(0, cell.x), y0 = max(0, cell.y)
        let x1 = min(width, cell.x + cell.width), y1 = min(height, cell.y + cell.height)
        guard x0 < x1, y0 < y1 else { return nil }
        for y in y0..<y1 {
            for x in x0..<x1 where pixels[(y * width + x) * 4 + 3] > 8 {
                let cx = x - cell.x, cy = y - cell.y
                let f = found ?? (cx, cx, cy, cy)
                found = (min(f.minX, cx), max(f.maxX, cx), min(f.minY, cy), max(f.maxY, cy))
            }
        }
        return found
    }
}

/// A rectangle of pixels in a sheet, from its top left.
public struct PixelRect: Equatable {
    public let x: Int, y: Int, width: Int, height: Int
}

struct AnimationConfig: Decodable {
    let row: Int
    let start: Int?
    let frames: Int?
    let fps: Double?
}

struct AvatarConfig: Decodable {
    let name: String? // shown on a resting buddy's tag; the avatar's id if left out
    let sheet: String
    let frameWidth: Int
    let frameHeight: Int
    let scale: Double?
    let fps: Double?
    let facesLeft: Bool?
    let animations: [String: AnimationConfig]?
}

struct AvatarsConfig: Decodable {
    let `default`: String?
    let avatars: [String: AvatarConfig]
}

/// A sheet's path from its config: absolute, from the home folder, or from `base`.
func resolve(_ sheet: String, base: URL) -> URL {
    if sheet.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(sheet.dropFirst(2)))
    }
    #if os(Windows)
    let absolute = sheet.count > 2 && Array(sheet)[1] == ":" || sheet.hasPrefix("\\\\")
    #else
    let absolute = sheet.hasPrefix("/")
    #endif
    return absolute ? URL(fileURLWithPath: sheet) : base.appendingPathComponent(sheet)
}

/// One configured sheet, cut into rows of frames counted from the top left.
public final class Sprite {
    public struct Animation { public let row: Int; public let start: Int; public let frames: Int; public let fps: Double }

    public let label: String // for the name tag
    public let image: Bitmap
    public let frameW: Int, frameH: Int
    public let size: Size
    public let body: Size // the character alone in its first idle frame, centred: frames also hold room for props
    public let facesLeft: Bool
    public let animations: [String: Animation]

    init?(_ name: String, _ config: AvatarConfig, base: URL, images: ImageLoader) {
        let url = resolve(config.sheet, base: base)
        guard let image = images.load(url) else {
            logLine("avatar \(name): cannot read \(url.path)")
            return nil
        }
        let columns = config.frameWidth > 0 ? image.width / config.frameWidth : 0
        let rows = config.frameHeight > 0 ? image.height / config.frameHeight : 0
        guard columns > 0, rows > 0 else {
            logLine("avatar \(name): a \(config.frameWidth)x\(config.frameHeight) frame does not fit its sheet")
            return nil
        }
        label = config.name ?? name
        self.image = image
        frameW = config.frameWidth
        frameH = config.frameHeight
        facesLeft = config.facesLeft ?? false

        let h = Double(frameH), w = Double(frameW)
        let fitted = h < spriteFit ? max(1, floor(spriteFit / h)) : spriteFit / h
        let scale = min(config.scale ?? fitted, spriteMax / max(w, h))
        size = Size(width: w * scale, height: h * scale)

        let fps = config.fps ?? 8
        var cut: [String: Animation] = [:]
        for (mood, a) in config.animations ?? [:] {
            let start = a.start ?? 0
            guard (0..<rows).contains(a.row), (0..<columns).contains(start) else {
                logLine("avatar \(name): animation \(mood) is outside the sheet")
                continue
            }
            let frames = max(1, min(a.frames ?? columns - start, columns - start))
            cut[mood] = Animation(row: a.row, start: start, frames: frames, fps: max(a.fps ?? fps, 0.1))
        }
        if cut["idle"] == nil { cut["idle"] = Animation(row: 0, start: 0, frames: columns, fps: fps) }
        animations = cut

        let first = cut["idle"]!
        let idle = PixelRect(x: first.start * frameW, y: first.row * frameH, width: frameW, height: frameH)
        if let seen = image.visibleBounds(in: idle) {
            let reach = max(Double(frameW) / 2 - Double(seen.minX), Double(seen.maxX + 1) - Double(frameW) / 2)
            body = Size(width: reach * 2 * scale, height: Double(frameH - seen.minY) * scale)
        } else {
            body = size
        }
    }

    /// Room for the sprite, its hop, and the name tag above the body.
    public var windowSize: Size {
        Size(width: max(winW, size.width + 60), height: max(winH, body.height + tagGap + 32, size.height + 40))
    }

    /// What to play: the mood's own row, then the nearest stand-in.
    public func animation(mood: String, moving: Bool, asleep: Bool, held: Bool) -> Animation {
        let wanted = held ? ["held"] : asleep ? ["asleep"] : moving ? [mood == "idle" ? "walk" : mood, "walk"] : [mood]
        return wanted.lazy.compactMap { self.animations[$0] }.first ?? animations["idle"]!
    }

    /// Where frame `tick` of an animation is in the sheet.
    public func frame(_ a: Animation, tick: Int) -> PixelRect {
        let column = a.start + tick % a.frames
        return PixelRect(x: column * frameW, y: a.row * frameH, width: frameW, height: frameH)
    }
}

/// The sheets the app ships with, by name.
func bundledSprites(_ paths: Paths, _ images: ImageLoader) -> [String: Sprite] {
    guard let resources = paths.resources else { return [:] }
    var found: [String: Sprite] = [:]
    for name in bundledAvatars {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("\(name).json")),
              let config = try? JSONDecoder().decode(AvatarConfig.self, from: data) else {
            logLine("the app has no \(name).json")
            continue
        }
        found[name] = Sprite(name, config, base: resources, images: images)
    }
    found[retiredAvatar] = found[defaultAvatar]
    return found
}

/// avatars.json, read again when it changes. A name is looked up there, then among
/// the bundled sheets, so an entry named like a bundled avatar wins. Anything else wears kyle.
public final class AvatarLibrary {
    private let paths: Paths
    private let images: ImageLoader
    private let bundled: [String: Sprite]
    private var stamp: Date?
    private var sprites: [String: Sprite] = [:]
    private var fallback: String?

    public init(_ paths: Paths, _ images: ImageLoader) {
        self.paths = paths
        self.images = images
        bundled = bundledSprites(paths, images)
    }

    public func refresh() {
        let file = paths.avatarsFile
        let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if changed == stamp { return }
        stamp = changed
        sprites = [:]
        fallback = nil
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            let config = try JSONDecoder().decode(AvatarsConfig.self, from: data)
            fallback = config.default
            for (name, avatar) in config.avatars { sprites[name] = Sprite(name, avatar, base: paths.dataDir, images: images) }
        } catch {
            logLine("avatars.json: \(error)")
        }
    }

    public func sprite(_ pick: String?) -> Sprite? {
        (pick ?? fallback).flatMap { sprites[$0] ?? bundled[$0] } ?? bundled[defaultAvatar]
    }
    public func has(_ name: String) -> Bool { sprites[name] != nil || bundled[name] != nil }
}
