import CoreGraphics
import Foundation
import PDFKit
import Vision

enum VisionSupport {
    static func languages(_ codes: [String]) -> [Locale.Language] {
        codes.map { Locale.Language(identifier: $0) }
    }

    /// Converts a Vision normalized rect inside the rendered region to display and page rects.
    static func rects(_ n: NormalizedRect, imageRect: CGRect, scale: Double, geometry: PageGeometry) -> (display: CGRect, page: PageRect) {
        let r = n.cgRect
        let pixel = CGRect(x: imageRect.minX + r.minX * imageRect.width, y: imageRect.minY + r.minY * imageRect.height,
                           width: r.width * imageRect.width, height: r.height * imageRect.height)
        let display = CGRect(x: pixel.minX / scale, y: pixel.minY / scale, width: pixel.width / scale, height: pixel.height / scale)
        return (display, geometry.toPage(display))
    }
}

// MARK: - Vision OCR + layout

public struct VisionOCREngine: ExtractionEngine {
    public init() {}
    public var kind: EngineKind { .visionOCR }

    public func descriptor(options: ExtractionOptions) -> EngineDescriptor {
        EngineDescriptor(kind: .visionOCR, name: "Vision RecognizeTextRequest + DocLens layout",
                         version: "RecognizeTextRequest \(RecognizeTextRequest.supportedRevisions.last.map { "\($0)" } ?? "?"); layout \(LayoutAnalyzer.version); macOS \(EngineSupport.osVersion)",
                         configuration: options.configuration)
    }

    /// Recognized words in display space.
    public static func tokens(page: PDFPage, region: PageRect, options: ExtractionOptions) async throws -> (tokens: [LayoutToken], geometry: PageGeometry) {
        let scale = options.ocrScale
        let (image, imageRect, geometry) = try PDFSupport.render(page: page, region: region, scale: scale)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if options.recognitionLanguages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = VisionSupport.languages(options.recognitionLanguages)
        }
        try Task.checkCancellation()
        let observations = try await request.perform(on: image)
        var tokens: [LayoutToken] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let string = candidate.string
            var idx = string.startIndex
            while idx < string.endIndex {
                guard let start = string[idx...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                let range = start..<end
                if let box = candidate.boundingBox(for: range) {
                    let (display, _) = VisionSupport.rects(box.boundingBox, imageRect: imageRect, scale: scale, geometry: geometry)
                    tokens.append(LayoutToken(text: String(string[range]), rect: display, score: Double(candidate.confidence)))
                }
                idx = end
            }
        }
        return (tokens, geometry)
    }

    public func extract(_ input: SegmentInput, progress: ProgressHandler) async throws -> ExtractedTable {
        let (_, page) = try EngineSupport.page(input)
        progress(0.1, "Rendering page \(input.segment.pageIndex + 1)")
        let (tokens, geometry) = try await Self.tokens(page: page, region: input.segment.region, options: input.options)
        guard !tokens.isEmpty else { throw ExtractionError.noText }
        try Task.checkCancellation()
        progress(0.7, "Detecting ruling lines")
        let rules = input.options.detectRules ? EngineSupport.rules(page: page, region: input.segment.region, geometry: geometry) : .none
        progress(0.85, "Inferring rows and columns")
        let grid = LayoutAnalyzer.analyze(tokens: tokens, region: geometry.toDisplay(input.segment.region), rules: rules,
                                          options: LayoutOptions(mergeContinuationLines: input.options.mergeContinuationLines))
        guard grid.rowCount > 0 else { throw ExtractionError.noText }
        return EngineSupport.table(from: grid, geometry: geometry, input: input, method: .ocrWords,
                                   engine: descriptor(options: input.options))
    }
}

// MARK: - Vision document structure

public struct VisionDocumentEngine: ExtractionEngine {
    public init() {}
    public var kind: EngineKind { .visionDocument }

    public func descriptor(options: ExtractionOptions) -> EngineDescriptor {
        var config = options.configuration
        config.removeValue(forKey: "detectRules")
        config.removeValue(forKey: "mergeContinuationLines")
        return EngineDescriptor(kind: .visionDocument, name: "Vision RecognizeDocumentsRequest",
                                version: "RecognizeDocumentsRequest \(RecognizeDocumentsRequest.supportedRevisions.last.map { "\($0)" } ?? "?"); macOS \(EngineSupport.osVersion)",
                                configuration: config)
    }

    static func request(options: ExtractionOptions) -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = options.usesLanguageCorrection
        if options.recognitionLanguages.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            request.textRecognitionOptions.recognitionLanguages = VisionSupport.languages(options.recognitionLanguages)
        }
        request.barcodeDetectionOptions.enabled = false
        return request
    }

    public func extract(_ input: SegmentInput, progress: ProgressHandler) async throws -> ExtractedTable {
        let (_, page) = try EngineSupport.page(input)
        progress(0.1, "Rendering page \(input.segment.pageIndex + 1)")
        let scale = min(input.options.ocrScale, 3.0)
        let (image, imageRect, geometry) = try PDFSupport.render(page: page, region: input.segment.region, scale: scale)
        try Task.checkCancellation()
        progress(0.3, "Recognizing document structure")
        let observations = try await Self.request(options: input.options).perform(on: image)
        try Task.checkCancellation()
        let tables = observations.flatMap { $0.document.tables }
        guard let table = tables.max(by: { $0.boundingRegion.boundingBox.width * $0.boundingRegion.boundingBox.height
                                               < $1.boundingRegion.boundingBox.width * $1.boundingRegion.boundingBox.height }) else {
            throw ExtractionError.noTableFound
        }
        progress(0.85, "Mapping cells to the page")
        var cells: [ExtractedCell] = []
        var seen = Set<[Int]>()
        var maxRow = -1, maxCol = -1
        for row in table.rows {
            for cell in row {
                let key = [cell.rowRange.lowerBound, cell.columnRange.lowerBound]
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let text = cell.content.text.transcript.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = cell.content.text.lines
                var regions = lines.map {
                    VisionSupport.rects($0.boundingRegion.boundingBox, imageRect: imageRect, scale: scale, geometry: geometry).page
                }
                if regions.isEmpty && !text.isEmpty {
                    regions = [VisionSupport.rects(cell.content.boundingRegion.boundingBox, imageRect: imageRect, scale: scale, geometry: geometry).page]
                }
                let score = lines.map { Double($0.confidence) }.min()
                cells.append(ExtractedCell(row: cell.rowRange.lowerBound, column: cell.columnRange.lowerBound,
                                           rowSpan: cell.rowRange.count, colSpan: cell.columnRange.count, text: text,
                                           pageIndex: input.segment.pageIndex, regions: text.isEmpty ? [] : regions,
                                           method: .visionDocumentCell, score: score,
                                           flags: cell.columnRange.count > 1 ? [CellFlag.spansColumns] : []))
                maxRow = max(maxRow, cell.rowRange.upperBound)
                maxCol = max(maxCol, cell.columnRange.upperBound)
            }
        }
        guard maxRow >= 0, maxCol >= 0 else { throw ExtractionError.noTableFound }
        let rowCount = maxRow + 1, columnCount = maxCol + 1
        let header = Self.headerRows(cells: cells, rowCount: rowCount, columnCount: columnCount)
        return ExtractedTable(rowCount: rowCount, columnCount: columnCount, cells: cells,
                              rowSegments: Array(repeating: 0, count: rowCount), headerRowCount: header,
                              engine: descriptor(options: input.options),
                              notes: ["Vision recognized \(tables.count) table\(tables.count == 1 ? "" : "s"); the largest was used."])
    }

    static func headerRows(cells: [ExtractedCell], rowCount: Int, columnCount: Int) -> Int {
        var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for c in cells { grid[c.row][c.column] = c.text }
        return LayoutAnalyzer.detectHeaderRows(grid: grid, rules: [], rowLines: [],
                                               spanRows: Set(cells.filter { $0.colSpan > 1 }.map(\.row)))
    }

    /// Candidate tables on a full page.
    public static func detectTables(documentURL: URL, pageIndex: Int, options: ExtractionOptions = ExtractionOptions()) async throws -> [TableCandidate] {
        let doc = try PDFSupport.open(documentURL)
        guard let page = doc.page(at: pageIndex) else { throw PDFSupportError.pageOutOfRange(pageIndex, doc.pageCount) }
        let scale = 2.0
        let (image, imageRect, geometry) = try PDFSupport.render(page: page, region: nil, scale: scale)
        let observations = try await request(options: options).perform(on: image)
        return observations.flatMap { $0.document.tables }.map { t in
            var rect = VisionSupport.rects(t.boundingRegion.boundingBox, imageRect: imageRect, scale: scale, geometry: geometry).page
            rect = rect.insetBy(-4)
            let crop = geometry.cropBox
            rect = PageRect(rect.cgRect.intersection(crop.cgRect))
            return TableCandidate(pageIndex: pageIndex, region: rect, rowCount: t.rows.count,
                                  columnCount: t.columns.count, source: "Vision")
        }
        .sorted { $0.region.maxY > $1.region.maxY }
    }
}
