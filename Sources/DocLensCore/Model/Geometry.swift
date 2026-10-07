import CoreGraphics
import Foundation

/// A rectangle in PDF page space: points, origin at the lower-left corner of the media box,
/// before the page's `/Rotate` value is applied. This is the coordinate space PDFKit uses
/// for `PDFPage` geometry and the only space persisted for source regions.
public struct PageRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        let r = rect.standardized
        self.init(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }

    public func union(_ other: PageRect) -> PageRect {
        PageRect(cgRect.union(other.cgRect))
    }

    public func intersectionArea(_ other: PageRect) -> Double {
        let i = cgRect.intersection(other.cgRect)
        return i.isNull ? 0 : Double(i.width * i.height)
    }

    public func intersectionOverUnion(_ other: PageRect) -> Double {
        let inter = intersectionArea(other)
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }

    public func insetBy(_ d: Double) -> PageRect {
        PageRect(cgRect.insetBy(dx: d, dy: d))
    }

    /// Short human-readable form, rounded to a tenth of a point.
    public var formatted: String {
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        return "x \(f(x)), y \(f(y)), w \(f(width)), h \(f(height))"
    }
}

/// Page metadata needed to convert between page space, display space, and raster pixels.
public struct PageGeometry: Codable, Hashable, Sendable {
    public var mediaBox: PageRect
    public var cropBox: PageRect
    /// Clockwise rotation in degrees, normalized to 0, 90, 180, or 270.
    public var rotation: Int

    public init(mediaBox: PageRect, cropBox: PageRect, rotation: Int) {
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        let r = ((rotation % 360) + 360) % 360
        self.rotation = (r / 90) * 90
    }

    /// Size of the page as displayed (crop box after rotation), in points.
    public var displaySize: CGSize {
        rotation == 90 || rotation == 270
            ? CGSize(width: cropBox.height, height: cropBox.width)
            : CGSize(width: cropBox.width, height: cropBox.height)
    }

    /// Transform from page space to display space scaled by `scale`.
    /// Display space has its origin at the lower-left of the rotated crop box.
    /// With `scale` equal to pixels per point this maps page space to raster pixels
    /// (lower-left origin), matching Core Graphics and Vision conventions.
    public func pageToDisplay(scale: Double = 1) -> CGAffineTransform {
        let s = CGFloat(scale)
        let minX = CGFloat(cropBox.x), minY = CGFloat(cropBox.y)
        let w = CGFloat(cropBox.width), h = CGFloat(cropBox.height)
        switch rotation {
        case 90:
            return CGAffineTransform(a: 0, b: -s, c: s, d: 0, tx: -s * minY, ty: s * (w + minX))
        case 180:
            return CGAffineTransform(a: -s, b: 0, c: 0, d: -s, tx: s * (w + minX), ty: s * (h + minY))
        case 270:
            return CGAffineTransform(a: 0, b: s, c: -s, d: 0, tx: s * (h + minY), ty: -s * minX)
        default:
            return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -s * minX, ty: -s * minY)
        }
    }

    public func displayToPage(scale: Double = 1) -> CGAffineTransform {
        pageToDisplay(scale: scale).inverted()
    }

    public func toDisplay(_ rect: PageRect, scale: Double = 1) -> CGRect {
        rect.cgRect.applying(pageToDisplay(scale: scale)).standardized
    }

    public func toPage(_ displayRect: CGRect, scale: Double = 1) -> PageRect {
        PageRect(displayRect.applying(displayToPage(scale: scale)).standardized)
    }

    /// Converts a Vision normalized rectangle (lower-left origin, relative to `imageRect`
    /// inside a raster rendered at `scale` pixels per point) to page space.
    public func pageRect(fromNormalized n: CGRect, imageRect: CGRect, scale: Double) -> PageRect {
        let pixel = CGRect(
            x: imageRect.minX + n.minX * imageRect.width,
            y: imageRect.minY + n.minY * imageRect.height,
            width: n.width * imageRect.width,
            height: n.height * imageRect.height
        )
        return toPage(pixel, scale: scale)
    }
}

public extension CGRect {
    var pageRect: PageRect { PageRect(self) }
}
