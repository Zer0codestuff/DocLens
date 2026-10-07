import Foundation
import PDFKit

public enum ExtractionService {
    public static func engine(for kind: EngineKind) -> any ExtractionEngine {
        switch kind {
        case .textLayer, .auto: TextLayerEngine()
        case .visionOCR: VisionOCREngine()
        case .visionDocument: VisionDocumentEngine()
        case .docling: DoclingEngine()
        }
    }

    /// Chooses an engine for a segment. The text layer is used when the region contains enough
    /// characters; scanned regions go to Vision document recognition.
    public static func resolve(_ kind: EngineKind, documentURL: URL, segment: TableSegment) -> EngineKind {
        guard kind == .auto else { return kind }
        guard let doc = PDFDocument(url: documentURL), let page = doc.page(at: segment.pageIndex) else { return .visionDocument }
        return PDFSupport.textCharacterCount(page: page, region: segment.region) >= 8 ? .textLayer : .visionDocument
    }

    public static func cacheKey(documentSHA256: String, engine: EngineDescriptor, segments: [TableSegment]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let e = (try? encoder.encode(engine)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let s = (try? encoder.encode(segments)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Hashing.sha256("\(documentSHA256)|\(e)|\(s)")
    }

    /// Extracts every segment and joins them into one table. Repeated header rows at the top of
    /// later segments are flagged rather than removed.
    public static func extract(documentURL: URL, documentID: UUID, segments: [TableSegment], engine kind: EngineKind,
                               options: ExtractionOptions, progress: ProgressHandler) async throws -> ExtractedTable {
        var parts: [ExtractedTable] = []
        var used: [EngineKind] = []
        for (i, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let base = Double(i) / Double(segments.count)
            let span = 1 / Double(segments.count)
            let resolved = resolve(kind, documentURL: documentURL, segment: segment)
            let input = SegmentInput(documentURL: documentURL, documentID: documentID, segment: segment, options: options)
            let report: ProgressHandler = { f, m in
                progress(base + f * span, segments.count > 1 ? "Segment \(i + 1) of \(segments.count): \(m)" : m)
            }
            do {
                parts.append(try await engine(for: resolved).extract(input, progress: report))
                used.append(resolved)
            } catch ExtractionError.noTableFound where kind == .auto {
                parts.append(try await VisionOCREngine().extract(input, progress: report))
                used.append(.visionOCR)
            } catch is CancellationError {
                throw ExtractionError.cancelled
            }
        }
        progress(1, "Finishing")
        return join(parts, engines: used, requested: kind)
    }

    static func join(_ parts: [ExtractedTable], engines: [EngineKind], requested: EngineKind) -> ExtractedTable {
        guard var result = parts.first else {
            return ExtractedTable(rowCount: 0, columnCount: 0, cells: [], rowSegments: [], headerRowCount: 0,
                                  engine: EngineDescriptor(kind: requested, name: "none", version: ""))
        }
        if parts.count == 1 {
            if requested == .auto {
                result.engine.configuration["requested"] = "auto"
            }
            return result
        }
        let headerCount = result.headerRowCount
        let headerTexts = (0..<headerCount).map { r in
            (0..<result.columnCount).map { c in RecipeMatching.normalize(result.cell(row: r, column: c)?.text ?? "") }
        }
        var notes = result.notes
        var cells = result.cells
        var rowSegments = result.rowSegments
        var offset = result.rowCount
        let columnCount = parts.map(\.columnCount).max() ?? 0
        for (k, part) in parts.enumerated().dropFirst() {
            if part.columnCount != result.columnCount {
                notes.append("Segment \(k + 1) has \(part.columnCount) columns; segment 1 has \(result.columnCount). Check the column mapping.")
            }
            var repeated = Set<Int>()
            if headerCount > 0 {
                for r in 0..<min(headerCount, part.rowCount) {
                    let texts = (0..<part.columnCount).map { c in RecipeMatching.normalize(part.cell(row: r, column: c)?.text ?? "") }
                    let joinedA = headerTexts[r].joined(separator: " "), joinedB = texts.joined(separator: " ")
                    if !joinedB.trimmingCharacters(in: .whitespaces).isEmpty, RecipeMatching.similarity(joinedA, joinedB) >= 0.85 {
                        repeated.insert(r)
                    }
                }
                if !repeated.isEmpty { notes.append("Segment \(k + 1) repeats the header; those rows are excluded.") }
            }
            for var cell in part.cells {
                if repeated.contains(cell.row) { cell.flags.append(CellFlag.repeatedHeader) }
                cell.row += offset
                cells.append(cell)
            }
            rowSegments += Array(repeating: k, count: part.rowCount)
            offset += part.rowCount
        }
        var engine = result.engine
        if Set(engines).count > 1 {
            engine.configuration["segmentEngines"] = engines.map(\.rawValue).joined(separator: ",")
        }
        if requested == .auto { engine.configuration["requested"] = "auto" }
        return ExtractedTable(rowCount: offset, columnCount: columnCount, cells: cells, rowSegments: rowSegments,
                              headerRowCount: headerCount, engine: engine, notes: notes)
    }
}

public struct CarryOverSummary: Sendable, Hashable {
    public var carriedCorrections = 0
    public var conflicts = 0
    public var unplacedCorrections = 0
    public var reviewsKept = 0
    public var previousRunID: UUID?

    public init() {}

    public var hasUserWork: Bool { carriedCorrections + conflicts + unplacedCorrections + reviewsKept > 0 }

    public var message: String {
        var parts: [String] = []
        if carriedCorrections > 0 { parts.append("\(carriedCorrections) correction\(carriedCorrections == 1 ? "" : "s") carried over") }
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s") marked for review") }
        if reviewsKept > 0 { parts.append("\(reviewsKept) review\(reviewsKept == 1 ? "" : "s") kept where the source text is unchanged") }
        if unplacedCorrections > 0 { parts.append("\(unplacedCorrections) correction\(unplacedCorrections == 1 ? "" : "s") had no matching cell and remain in the previous version") }
        return parts.isEmpty ? "No user corrections were affected." : parts.joined(separator: "; ") + "."
    }
}

/// Converts engine output into a persisted extraction version.
public enum TableBuilder {
    static let totalPattern = try! NSRegularExpression(
        pattern: #"^\s*(grand\s+total|total[ei]?s?|tot\.|sum|summe|gesamt|insgesamt|somme|complessivo|totale\s+generale)\b"#,
        options: [.caseInsensitive])

    public static func isTotalLabel(_ text: String) -> Bool {
        totalPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public struct Output: Sendable {
        public var run: ExtractionRun
        public var cells: [CellRecord]
        public var columns: [ColumnSpec]
    }

    public static func build(table: TableRecord, document: DocumentRecord, extracted: ExtractedTable,
                             startedAt: Date, cacheKey: String?) -> Output {
        let runID = UUID()
        var cells: [CellRecord] = []
        var covered = Set<[Int]>()
        for c in extracted.cells where c.row < extracted.rowCount && c.column < extracted.columnCount {
            let key = [c.row, c.column]
            guard !covered.contains(key) else { continue }
            for r in c.row..<(c.row + max(1, c.rowSpan)) { for k in c.column..<(c.column + max(1, c.colSpan)) { covered.insert([r, k]) } }
            let source = SourceReference(documentID: document.id, pageIndex: c.pageIndex, regions: c.regions, method: c.method)
            cells.append(CellRecord(runID: runID, row: c.row, column: c.column, rowSpan: max(1, c.rowSpan),
                                    colSpan: max(1, c.colSpan), extractedText: c.text,
                                    sources: c.regions.isEmpty ? [] : [source], engineScore: c.score, flags: c.flags))
        }
        // Fill uncovered positions with explicit empty cells so every position is addressable.
        for r in 0..<extracted.rowCount {
            for c in 0..<extracted.columnCount where !covered.contains([r, c]) {
                cells.append(CellRecord(runID: runID, row: r, column: c, extractedText: ""))
            }
        }
        cells.sort { ($0.row, $0.column) < ($1.row, $1.column) }

        let byPosition = Dictionary(cells.map { ([$0.row, $0.column], $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [RowSpec] = []
        for r in 0..<extracted.rowCount {
            let segment = r < extracted.rowSegments.count ? extracted.rowSegments[r] : 0
            let rowCells = cells.filter { $0.row == r }
            var role: RowRole = r < extracted.headerRowCount ? .header : .data
            var note: String?
            if rowCells.contains(where: { $0.flags.contains(CellFlag.repeatedHeader) }) {
                role = .excluded
                note = "Repeated header"
            } else if role == .data, let first = byPosition[[r, 0]], isTotalLabel(first.text) {
                role = .total
                note = "Detected total label"
            }
            rows.append(RowSpec(index: r, role: role, segmentIndex: segment, note: note))
        }

        let settings = table.settings
        var columns: [ColumnSpec] = []
        let headerRows = rows.filter { $0.role == .header }.map(\.index)
        let dataRows = Set(rows.filter { $0.role == .data }.map(\.index))
        let hint = TypeInference.decimalHint(cells.filter { dataRows.contains($0.row) }.map(\.text), settings: settings)
        for c in 0..<extracted.columnCount {
            var parts: [String] = []
            for r in headerRows {
                if let cell = cells.first(where: { $0.row == r && $0.column <= c && c < $0.column + $0.colSpan }) {
                    let t = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty && parts.last != t { parts.append(t) }
                }
            }
            let header = parts.joined(separator: " ")
            let values = cells.filter { $0.column == c && dataRows.contains($0.row) }.map(\.text)
            let inferred = TypeInference.infer(header: header, values: values, settings: settings, decimalHint: hint)
            if c < table.columns.count, table.columns.count == extracted.columnCount {
                var existing = table.columns[c]
                existing.sourceHeader = header
                if !existing.typeConfirmed { existing.type = inferred }
                columns.append(existing)
            } else {
                columns.append(ColumnSpec(index: c, name: header.isEmpty ? "Column \(ColumnSpec.letter(for: c))" : header,
                                          type: inferred, sourceHeader: header))
            }
        }

        let run = ExtractionRun(id: runID, tableID: table.id, engine: extracted.engine, startedAt: startedAt,
                                finishedAt: Date(), status: .completed, segments: table.segments,
                                documentSHA256: document.sha256, rows: rows, columnCount: extracted.columnCount,
                                notes: extracted.notes, cacheKey: cacheKey)
        return Output(run: run, cells: cells, columns: columns)
    }

    /// Carries corrections and reviews from the previous version into new cells at the same
    /// position. Changed source text turns a kept correction into a conflict that needs review.
    public static func carryOver(from previous: TableSnapshot, into output: inout Output) -> (CarryOverSummary, [Correction]) {
        var summary = CarryOverSummary()
        summary.previousRunID = previous.run.id
        var corrections: [Correction] = []
        var index: [[Int]: Int] = [:]
        for (i, c) in output.cells.enumerated() { index[[c.row, c.column]] = i }
        for old in previous.cells {
            guard let i = index[[old.row, old.column]] else {
                if old.isCorrected { summary.unplacedCorrections += 1 }
                continue
            }
            var new = output.cells[i]
            let sameSource = RecipeMatching.normalize(old.extractedText) == RecipeMatching.normalize(new.extractedText)
            if old.isCorrected {
                new.correctedText = old.correctedText
                if sameSource {
                    new.review = old.review
                    new.flags.append(CellFlag.carriedOver)
                    summary.carriedCorrections += 1
                    corrections.append(Correction(tableID: previous.table.id, runID: output.run.id, cellID: new.id, kind: .carriedOver,
                                                  before: new.extractedText, after: old.correctedText,
                                                  detail: "Carried over from version \(previous.run.id.uuidString.prefix(8))"))
                } else {
                    new.review = .needsReview
                    new.flags.append(CellFlag.reextractionConflict)
                    summary.conflicts += 1
                    corrections.append(Correction(tableID: previous.table.id, runID: output.run.id, cellID: new.id, kind: .conflict,
                                                  before: old.extractedText, after: new.extractedText,
                                                  detail: "Kept correction “\(old.correctedText ?? "")”; source now reads “\(new.extractedText)”"))
                }
            } else if old.review == .reviewed && sameSource {
                new.review = .reviewed
                summary.reviewsKept += 1
            }
            output.cells[i] = new
        }
        if previous.run.rows.count == output.run.rows.count {
            for (i, row) in previous.run.rows.enumerated() where row.role != output.run.rows[i].role {
                output.run.rows[i].role = row.role
                output.run.rows[i].note = row.note
            }
        }
        return (summary, corrections)
    }
}
