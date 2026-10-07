import CoreGraphics
import Foundation
import PDFKit

public struct ExtractionOptions: Codable, Hashable, Sendable {
    public var recognitionLanguages: [String]
    public var usesLanguageCorrection: Bool
    /// Pixels per point used for OCR rasters. 4.17 is 300 dpi.
    public var ocrScale: Double
    public var detectRules: Bool
    public var mergeContinuationLines: Bool
    public var doclingPython: String?
    public var doclingWorker: String?

    public init(recognitionLanguages: [String] = [], usesLanguageCorrection: Bool = false, ocrScale: Double = 4.17,
                detectRules: Bool = true, mergeContinuationLines: Bool = true, doclingPython: String? = nil,
                doclingWorker: String? = nil) {
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.ocrScale = ocrScale
        self.detectRules = detectRules
        self.mergeContinuationLines = mergeContinuationLines
        self.doclingPython = doclingPython
        self.doclingWorker = doclingWorker
    }

    var configuration: [String: String] {
        var c: [String: String] = [
            "detectRules": String(detectRules),
            "mergeContinuationLines": String(mergeContinuationLines),
        ]
        c["ocrScale"] = String(format: "%.2f", ocrScale)
        c["languages"] = recognitionLanguages.isEmpty ? "automatic" : recognitionLanguages.joined(separator: ",")
        c["languageCorrection"] = String(usesLanguageCorrection)
        return c
    }
}

public typealias ProgressHandler = @Sendable (_ fraction: Double, _ message: String) -> Void

public struct SegmentInput: Sendable {
    public var documentURL: URL
    public var documentID: UUID
    public var segment: TableSegment
    public var options: ExtractionOptions
}

public protocol ExtractionEngine: Sendable {
    var kind: EngineKind { get }
    func descriptor(options: ExtractionOptions) -> EngineDescriptor
    func extract(_ input: SegmentInput, progress: ProgressHandler) async throws -> ExtractedTable
}

public enum ExtractionError: Error, LocalizedError, Equatable {
    case noText
    case noTableFound
    case engineUnavailable(String)
    case workerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noText:
            "No readable text was found in the selected region. If the page is scanned, choose Vision OCR or Vision Document Structure."
        case .noTableFound:
            "The engine did not recognize a table in the selected region. Try a tighter selection or another engine."
        case .engineUnavailable(let reason):
            reason
        case .workerFailed(let reason):
            "The extraction worker failed: \(reason)"
        case .cancelled:
            "Extraction was cancelled."
        }
    }
}

enum EngineSupport {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func page(_ input: SegmentInput) throws -> (PDFDocument, PDFPage) {
        let doc = try PDFSupport.open(input.documentURL)
        guard let page = doc.page(at: input.segment.pageIndex) else {
            throw PDFSupportError.pageOutOfRange(input.segment.pageIndex, doc.pageCount)
        }
        return (doc, page)
    }

    /// Renders the region in grayscale and detects ruling lines in display space.
    static func rules(page: PDFPage, region: PageRect, geometry: PageGeometry) -> RuleLines {
        let scale = 2.0
        let display = geometry.toDisplay(region)
        let pixelRect = CGRect(x: (display.minX * scale).rounded(.down), y: (display.minY * scale).rounded(.down),
                               width: (display.width * scale).rounded(.up), height: (display.height * scale).rounded(.up))
        let w = Int(pixelRect.width), h = Int(pixelRect.height)
        guard w > 4, h > 4, w * h < 40_000_000 else { return .none }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: -pixelRect.minX, y: -pixelRect.minY)
            ctx.concatenate(geometry.pageToDisplay(scale: scale))
            ctx.clip(to: geometry.cropBox.cgRect)
            if let ref = page.pageRef { ctx.drawPDFPage(ref) }
            return true
        }
        guard ok else { return .none }
        return RuleLineDetector.detect(pixels: pixels, width: w, height: h,
                                       origin: CGPoint(x: pixelRect.minX / scale, y: pixelRect.minY / scale), scale: scale)
    }

    /// Converts a layout grid into engine-independent cells with page-space regions.
    static func table(from grid: LayoutGrid, geometry: PageGeometry, input: SegmentInput, method: MappingMethod,
                      engine: EngineDescriptor) -> ExtractedTable {
        let cells = grid.cells.map { c in
            ExtractedCell(row: c.row, column: c.column, rowSpan: 1, colSpan: c.colSpan, text: c.text,
                          pageIndex: input.segment.pageIndex,
                          regions: c.rects.map { geometry.toPage($0) }, method: method, score: c.score, flags: c.flags)
        }
        return ExtractedTable(rowCount: grid.rowCount, columnCount: grid.columnCount, cells: cells,
                              rowSegments: Array(repeating: 0, count: grid.rowCount), headerRowCount: grid.headerRowCount,
                              engine: engine, notes: grid.notes)
    }
}

// MARK: - PDF text layer

public struct TextLayerEngine: ExtractionEngine {
    public init() {}
    public var kind: EngineKind { .textLayer }

    public func descriptor(options: ExtractionOptions) -> EngineDescriptor {
        var config = options.configuration
        config.removeValue(forKey: "ocrScale")
        config.removeValue(forKey: "languages")
        config.removeValue(forKey: "languageCorrection")
        return EngineDescriptor(kind: .textLayer, name: "PDF text layer + DocLens layout",
                                version: "layout \(LayoutAnalyzer.version); PDFKit macOS \(EngineSupport.osVersion)",
                                configuration: config)
    }

    static let ligatures: [Character: String] = ["ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"]

    /// Words in the region, in display space.
    public static func tokens(page: PDFPage, region: PageRect, geometry: PageGeometry) -> [LayoutToken] {
        let text = (page.string ?? "") as NSString
        let count = text.length
        guard count > 0 else { return [] }
        let toDisplay = geometry.pageToDisplay()
        let paddedRegion = region.cgRect.insetBy(dx: -0.5, dy: -0.5)

        struct Glyph { var char: String; var rect: CGRect; var spaceAfter: Bool }
        var glyphs: [Glyph] = []
        var i = 0
        while i < count {
            let range = text.rangeOfComposedCharacterSequence(at: i)
            i = range.location + range.length
            let raw = text.substring(with: range)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !glyphs.isEmpty { glyphs[glyphs.count - 1].spaceAfter = true }
                continue
            }
            // `characterBounds(at:)` drifts by one index after line breaks on some PDFs;
            // a one-character selection reports the glyph and its box consistently.
            guard let sel = page.selection(for: range), sel.string != nil else { continue }
            let bounds = sel.bounds(for: page)
            guard bounds.width > 0 || bounds.height > 0 else { continue }
            guard paddedRegion.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { continue }
            let mapped = raw.count == 1 ? (ligatures[raw.first!] ?? raw) : raw
            let rect = bounds.applying(toDisplay).standardized
            // Characters of one ligature glyph share a box; keep them as one glyph in order.
            if let last = glyphs.last, abs(last.rect.minX - rect.minX) < 0.01, abs(last.rect.width - rect.width) < 0.01,
               abs(last.rect.minY - rect.minY) < 0.01 {
                glyphs[glyphs.count - 1].char += mapped
                continue
            }
            glyphs.append(Glyph(char: mapped, rect: rect, spaceAfter: false))
        }
        guard !glyphs.isEmpty else { return [] }

        // Lines by vertical overlap, words by horizontal gaps.
        // The score slot carries the glyph index through line grouping; it is cleared below.
        let asTokens = glyphs.enumerated().map { LayoutToken(text: $1.char, rect: $1.rect, score: Double($0)) }
        var words: [LayoutToken] = []
        for line in LayoutAnalyzer.groupLines(asTokens) {
            let height = LayoutAnalyzer.median(line.map { Double($0.rect.height) })
            var current: LayoutToken?
            var previousHadSpace = false
            for g in line {
                if var w = current {
                    let gap = Double(g.rect.minX - w.rect.maxX)
                    let breakHere = gap > 0.18 * height || (previousHadSpace && gap > -0.05 * height)
                    if breakHere {
                        words.append(w)
                        current = g
                    } else {
                        w.text += g.text
                        w.rect = w.rect.union(g.rect)
                        current = w
                    }
                } else {
                    current = g
                }
                previousHadSpace = g.score.map { glyphs[Int($0)].spaceAfter } ?? false
            }
            if let w = current { words.append(w) }
        }
        return words.map { LayoutToken(text: $0.text, rect: $0.rect, score: nil) }
    }

    public func extract(_ input: SegmentInput, progress: ProgressHandler) async throws -> ExtractedTable {
        let (_, page) = try EngineSupport.page(input)
        let geometry = PDFSupport.geometry(of: page)
        progress(0.1, "Reading the text layer")
        let tokens = Self.tokens(page: page, region: input.segment.region, geometry: geometry)
        guard !tokens.isEmpty else { throw ExtractionError.noText }
        try Task.checkCancellation()
        progress(0.5, "Detecting ruling lines")
        let rules = input.options.detectRules ? EngineSupport.rules(page: page, region: input.segment.region, geometry: geometry) : .none
        try Task.checkCancellation()
        progress(0.7, "Inferring rows and columns")
        let grid = LayoutAnalyzer.analyze(tokens: tokens, region: geometry.toDisplay(input.segment.region), rules: rules,
                                          options: LayoutOptions(mergeContinuationLines: input.options.mergeContinuationLines))
        guard grid.rowCount > 0 else { throw ExtractionError.noText }
        return EngineSupport.table(from: grid, geometry: geometry, input: input, method: .textLayerGlyphs,
                                   engine: descriptor(options: input.options))
    }
}
