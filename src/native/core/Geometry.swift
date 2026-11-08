// Points, sizes and rectangles, in the core's own types: Foundation's Rect has no
// geometry on macOS without CoreGraphics, and the core runs where CoreGraphics doesn't.
// y goes up, as on macOS.
import Foundation

public struct Point: Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
}

public struct Size: Equatable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Rect: Equatable {
    public var origin: Point
    public var size: Size
    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { min(origin.x, origin.x + size.width) }
    public var maxX: Double { max(origin.x, origin.x + size.width) }
    public var minY: Double { min(origin.y, origin.y + size.height) }
    public var maxY: Double { max(origin.y, origin.y + size.height) }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var width: Double { abs(size.width) }
    public var height: Double { abs(size.height) }

    /// As CoreGraphics counts it: the left and bottom edges are in, the right and top out.
    public func contains(_ p: Point) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }
    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
    }
}
