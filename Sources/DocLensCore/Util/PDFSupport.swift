import CryptoKit
import Foundation
import PDFKit

public enum Hashing {
    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String { sha256(Data(string.utf8)) }
}

public enum PDFSupportError: Error, LocalizedError {
    case cannotOpen(String)
    case encrypted(String)
    case pageOutOfRange(Int, Int)
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): "“\(name)” could not be opened as a PDF."
        case .encrypted(let name): "“\(name)” is password protected. Unlock it in Preview and import the unlocked copy."
        case .pageOutOfRange(let p, let n): "Page \(p + 1) does not exist. The document has \(n) pages."
        case .renderFailed: "The page could not be rendered."
        }
    }
}

public enum PDFSupport {
    public static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFSupportError.cannotOpen(url.lastPathComponent) }
        if doc.isLocked { throw PDFSupportError.encrypted(url.lastPathComponent) }
        return doc
    }

    public static func geometry(of page: PDFPage) -> PageGeometry {
        PageGeometry(mediaBox: PageRect(page.bounds(for: .mediaBox)),
                     cropBox: PageRect(page.bounds(for: .cropBox)),
                     rotation: page.rotation)
    }

    public static func geometries(of doc: PDFDocument) -> [PageGeometry] {
        (0..<doc.pageCount).compactMap { doc.page(at: $0).map(geometry(of:)) }
    }

    /// Number of non-whitespace characters in the text layer within `region`, or the whole page.
    public static func textCharacterCount(page: PDFPage, region: PageRect? = nil) -> Int {
        guard let region else {
            return (page.string ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
        guard let sel = page.selection(for: region.cgRect), let s = sel.string else { return 0 }
        return s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    public static func hasTextLayer(_ doc: PDFDocument, samplePages: Int = 5) -> Bool {
        for i in 0..<min(doc.pageCount, samplePages) {
            if let p = doc.page(at: i), textCharacterCount(page: p) > 20 { return true }
        }
        return false
    }

    /// Renders `region` of a page (page space) at `scale` pixels per point, in display
    /// orientation. Returns the image and the pixel rect of the region inside the full-page
    /// raster space, so callers can map normalized image coordinates back to page space.
    public static func render(page: PDFPage, region: PageRect?, scale: Double,
                              grayscale: Bool = false) throws -> (image: CGImage, imageRect: CGRect, geometry: PageGeometry) {
        let geometry = geometry(of: page)
        let fullDisplay = CGRect(origin: .zero, size: geometry.displaySize)
        let displayRegion = (region.map { geometry.toDisplay($0) } ?? fullDisplay).intersection(fullDisplay)
        guard !displayRegion.isNull, displayRegion.width > 1, displayRegion.height > 1 else { throw PDFSupportError.renderFailed }
        let pixelRect = CGRect(x: (displayRegion.minX * scale).rounded(.down),
                               y: (displayRegion.minY * scale).rounded(.down),
                               width: (displayRegion.width * scale).rounded(.up),
                               height: (displayRegion.height * scale).rounded(.up))
        let width = Int(pixelRect.width), height = Int(pixelRect.height)
        guard width > 0, height > 0, width * height < 120_000_000 else { throw PDFSupportError.renderFailed }

        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw PDFSupportError.renderFailed
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: -pixelRect.minX, y: -pixelRect.minY)
        ctx.concatenate(geometry.pageToDisplay(scale: scale))
        ctx.clip(to: geometry.cropBox.cgRect)
        ctx.interpolationQuality = .high
        if let pageRef = page.pageRef {
            ctx.drawPDFPage(pageRef)
        } else {
            page.draw(with: .mediaBox, to: ctx)
        }
        guard let image = ctx.makeImage() else { throw PDFSupportError.renderFailed }
        return (image, pixelRect, geometry)
    }
}
