import Foundation

public struct ExportOptions: Codable, Hashable, Sendable {
    public enum Delimiter: String, Codable, CaseIterable, Sendable, Identifiable {
        case comma, semicolon, tab
        public var id: String { rawValue }
        public var character: String { self == .comma ? "," : self == .semicolon ? ";" : "\t" }
        public var label: String { self == .comma ? "Comma" : self == .semicolon ? "Semicolon" : "Tab" }
    }

    public enum NumericPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Machine-readable decimal with a point and no grouping: 1234.5
        case canonical
        /// The text as it appears after corrections, unchanged.
        case original
        public var id: String { rawValue }
        public var label: String { self == .canonical ? "Normalized (1234.5)" : "As written in the source" }
    }

    public enum MissingPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
        case empty, marker, na
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .empty: "Empty"
            case .marker: "Original marker"
            case .na: "NA"
            }
        }
    }

    public var delimiter: Delimiter
    public var numericPolicy: NumericPolicy
    public var missingPolicy: MissingPolicy
    public var includeTotals: Bool
    public var includeBOM: Bool
    public var protectFormulas: Bool
    public var writeSidecar: Bool
    public var includeReviewColumn: Bool

    public init(delimiter: Delimiter = .comma, numericPolicy: NumericPolicy = .canonical, missingPolicy: MissingPolicy = .empty,
                includeTotals: Bool = true, includeBOM: Bool = false, protectFormulas: Bool = true, writeSidecar: Bool = true,
                includeReviewColumn: Bool = false) {
        self.delimiter = delimiter
        self.numericPolicy = numericPolicy
        self.missingPolicy = missingPolicy
        self.includeTotals = includeTotals
        self.includeBOM = includeBOM
        self.protectFormulas = protectFormulas
        self.writeSidecar = writeSidecar
        self.includeReviewColumn = includeReviewColumn
    }
}

public struct ReviewDisclosure: Codable, Hashable, Sendable {
    public var cells: Int
    public var reviewed: Int
    public var needsReview: Int
    public var unreviewed: Int
    public var unresolvedIssues: Int
    public var correctedCells: Int
    public var cellsWithoutSource: Int

    public var isComplete: Bool { reviewed == cells && unresolvedIssues == 0 }

    public var summary: String {
        if isComplete { return "All \(cells) cells reviewed by the user; no unresolved issues." }
        var parts: [String] = []
        if unreviewed + needsReview > 0 { parts.append("\(unreviewed + needsReview) of \(cells) cells not reviewed") }
        if unresolvedIssues > 0 { parts.append("\(unresolvedIssues) unresolved issue\(unresolvedIssues == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + "."
    }

    public init(snapshot: TableSnapshot, evaluation: TableEvaluation) {
        let rows = Set(snapshot.dataRowIndexes)
        let relevant = snapshot.cells.filter { rows.contains($0.row) }
        cells = relevant.count
        reviewed = relevant.filter { $0.review == .reviewed }.count
        needsReview = relevant.filter { $0.review == .needsReview }.count
        unreviewed = relevant.filter { $0.review == .unreviewed }.count
        unresolvedIssues = evaluation.unresolved(in: snapshot).count
        correctedCells = relevant.filter(\.isCorrected).count
        cellsWithoutSource = relevant.filter { !$0.text.isEmpty && !$0.hasSourceRegion }.count
    }
}

/// Values shared by every export format, so CSV, XLSX, and JSON agree.
public struct ExportDataset: Sendable {
    public struct Value: Sendable {
        public var cell: CellRecord?
        public var text: String
        /// Set when the value is written as a number in spreadsheets.
        public var number: String?
        public var kind: ValueKind
    }

    public var columns: [ColumnSpec]
    public var rowIndexes: [Int]
    public var rows: [[Value]]
    public var disclosure: ReviewDisclosure

    public init(snapshot: TableSnapshot, evaluation: TableEvaluation, options: ExportOptions) {
        columns = snapshot.table.columns
        rowIndexes = snapshot.run.rows.filter { $0.role == .data || ($0.role == .total && options.includeTotals) }.map(\.index)
        disclosure = ReviewDisclosure(snapshot: snapshot, evaluation: evaluation)
        rows = rowIndexes.map { r in
            snapshot.table.columns.map { column in
                guard let cell = snapshot.cell(row: r, column: column.index) else {
                    if let covering = snapshot.coveringCell(row: r, column: column.index) {
                        return Value(cell: covering, text: "", number: nil, kind: .empty)
                    }
                    return Value(cell: nil, text: "", number: nil, kind: .empty)
                }
                let v = evaluation.normalized[cell.id] ?? .empty
                return Self.value(cell: cell, normalized: v, column: column, options: options)
            }
        }
    }

    static func value(cell: CellRecord, normalized v: NormalizedValue, column: ColumnSpec, options: ExportOptions) -> Value {
        switch v.kind {
        case .empty:
            return Value(cell: cell, text: "", number: nil, kind: .empty)
        case .missing:
            let text: String
            switch options.missingPolicy {
            case .empty: text = ""
            case .marker: text = v.missingToken ?? cell.text
            case .na: text = "NA"
            }
            return Value(cell: cell, text: text, number: nil, kind: .missing)
        case .ambiguous, .invalid:
            return Value(cell: cell, text: cell.text.trimmingCharacters(in: .whitespacesAndNewlines), number: nil, kind: v.kind)
        case .value:
            if column.type.isNumeric, let canonical = v.canonical {
                let text = options.numericPolicy == .canonical ? canonical : cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return Value(cell: cell, text: text, number: canonical, kind: .value)
            }
            if column.type == .date, options.numericPolicy == .original {
                return Value(cell: cell, text: cell.text.trimmingCharacters(in: .whitespacesAndNewlines), number: nil, kind: .value)
            }
            return Value(cell: cell, text: v.canonical ?? cell.text, number: nil, kind: .value)
        }
    }
}

public enum ExportError: Error, LocalizedError {
    case emptyTable
    public var errorDescription: String? { "The table has no data rows to export." }
}

public enum CSVExporter {
    static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Neutralizes text that spreadsheet applications would evaluate as a formula.
    public static func protect(_ text: String) -> String {
        guard let first = text.first, formulaPrefixes.contains(first) else { return text }
        if first == "-" || first == "+" {
            // A lone sign or a plain signed number is not evaluated as a formula.
            if text.count == 1 || !NumberParsing.interpretations(text).isEmpty { return text }
        }
        return "'" + text
    }

    public static func quote(_ field: String, delimiter: String) -> String {
        if field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func render(_ dataset: ExportDataset, options: ExportOptions) -> String {
        let d = options.delimiter.character
        var lines: [String] = []
        var header = dataset.columns.map { quote(options.protectFormulas ? protect($0.name) : $0.name, delimiter: d) }
        if options.includeReviewColumn { header.append("doclens_row_review") }
        lines.append(header.joined(separator: d))
        for row in dataset.rows {
            var fields = row.map { v -> String in
                var text = v.text
                if options.protectFormulas && v.number == nil { text = protect(text) }
                return quote(text, delimiter: d)
            }
            if options.includeReviewColumn {
                let cells = row.compactMap(\.cell)
                fields.append(cells.allSatisfy { $0.review == .reviewed } ? "reviewed" : "not reviewed")
            }
            lines.append(fields.joined(separator: d))
        }
        return (options.includeBOM ? "\u{FEFF}" : "") + lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - JSON

public enum JSONExporter {
    public static let schema = "https://doclens.app/schema/table-export/1"
    public static let schemaVersion = 1

    struct Root: Encodable {
        var schema: String
        var schemaVersion: Int
        var exportedAt: Date
        var application: [String: String]
        var document: DocumentOut
        var table: TableOut
        var extraction: ExtractionRun
        var rows: [RowSpec]
        var cells: [CellOut]
        var checks: ChecksOut
        var corrections: [Correction]
        var review: ReviewDisclosure
        var exportOptions: ExportOptions?
        var exportedValues: [[String]]?
    }

    struct DocumentOut: Encodable {
        var id: UUID
        var filename: String
        var title: String
        var sha256: String
        var pageCount: Int
        var pages: [PageGeometry]
    }

    struct ColumnOut: Encodable {
        var index: Int
        var name: String
        var type: ColumnType
        var typeConfirmed: Bool
        var unit: String
        var scale: String
        var sourceHeader: String
        var decimalSeparator: String?
        var formatResolution: String
        var dateOrder: String?
    }

    struct TableOut: Encodable {
        var id: UUID
        var name: String
        var segments: [TableSegment]
        var settings: TableSettings
        var columns: [ColumnOut]
        var recipeID: UUID?
        var recipeVersion: Int?
    }

    struct CellOut: Encodable {
        var id: UUID
        var address: String
        var row: Int
        var column: Int
        var rowSpan: Int
        var colSpan: Int
        var extractedText: String
        var correctedText: String?
        var value: NormalizedValue
        var sources: [SourceReference]
        var sourceEvidence: String
        var engineScore: Double?
        var engineScoreNote: String?
        var review: ReviewState
        var flags: [String]
        var checks: [String]
    }

    struct ChecksOut: Encodable {
        var rules: [RuleOut]
        var results: [CheckResult]
    }

    struct RuleOut: Encodable {
        var id: String
        var version: Int
        var title: String
        var tests: String
        var status: CheckStatus
        var tested: Int
        var failed: Int
    }

    public static func render(snapshot: TableSnapshot, evaluation: TableEvaluation, options: ExportOptions? = nil,
                              dataset: ExportDataset? = nil, appVersion: String = "1.0") throws -> Data {
        let contexts = evaluation.contexts
        let columns = snapshot.table.columns.map { c -> ColumnOut in
            let ctx = c.index < contexts.count ? contexts[c.index] : nil
            return ColumnOut(index: c.index, name: c.name, type: c.type, typeConfirmed: c.typeConfirmed, unit: c.unit,
                             scale: c.scale, sourceHeader: c.sourceHeader, decimalSeparator: ctx?.decimal.map(String.init),
                             formatResolution: ctx?.resolution.rawValue ?? "notApplicable",
                             dateOrder: c.type == .date ? ctx?.dateOrder.rawValue : nil)
        }
        let cells = snapshot.cells.map { c in
            CellOut(id: c.id, address: c.address, row: c.row, column: c.column, rowSpan: c.rowSpan, colSpan: c.colSpan,
                    extractedText: c.extractedText, correctedText: c.isCorrected ? c.correctedText : nil,
                    value: evaluation.normalized[c.id] ?? .empty, sources: c.sources,
                    sourceEvidence: c.hasSourceRegion ? "region" : (c.text.isEmpty ? "not applicable (empty)" : "unavailable"),
                    engineScore: c.engineScore,
                    engineScoreNote: c.engineScore == nil ? nil : "Raw engine score, not a calibrated probability.",
                    review: c.review, flags: c.flags, checks: (evaluation.resultsByCell[c.id] ?? []).map(\.id))
        }
        let rules = evaluation.summaries.compactMap { s -> RuleOut? in
            guard let rule = CheckRule.rule(id: s.ruleID) else { return nil }
            return RuleOut(id: rule.id, version: rule.version, title: rule.title, tests: rule.tests, status: s.status,
                           tested: s.tested, failed: s.failed)
        }
        let root = Root(schema: schema, schemaVersion: schemaVersion, exportedAt: Date(),
                        application: ["name": "DocLens", "version": appVersion],
                        document: DocumentOut(id: snapshot.document.id, filename: snapshot.document.filename,
                                              title: snapshot.document.title, sha256: snapshot.document.sha256,
                                              pageCount: snapshot.document.pageCount, pages: snapshot.document.pages),
                        table: TableOut(id: snapshot.table.id, name: snapshot.table.name, segments: snapshot.table.segments,
                                        settings: snapshot.table.settings, columns: columns, recipeID: snapshot.table.recipeID,
                                        recipeVersion: snapshot.table.recipeVersion),
                        extraction: snapshot.run, rows: snapshot.run.rows, cells: cells,
                        checks: ChecksOut(rules: rules, results: evaluation.results),
                        corrections: snapshot.corrections, review: ReviewDisclosure(snapshot: snapshot, evaluation: evaluation),
                        exportOptions: options,
                        exportedValues: dataset.map { d in [d.columns.map(\.name)] + d.rows.map { $0.map(\.text) } })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(root)
    }
}

// MARK: - XLSX

public enum XLSXExporter {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 forbids most control characters.
                if scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    enum Cell {
        case text(String, style: Int)
        case number(String, style: Int)
        case empty(style: Int)
    }

    static func columnName(_ i: Int) -> String { ColumnSpec.letter(for: i) }

    static func sheetXML(_ rows: [[Cell]], widths: [Double], freezeHeader: Bool = true) -> String {
        var x = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        x += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        if freezeHeader {
            x += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        }
        if !widths.isEmpty {
            x += "<cols>"
            for (i, w) in widths.enumerated() { x += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(String(format: "%.1f", w))" customWidth="1"/>"# }
            x += "</cols>"
        }
        x += "<sheetData>"
        for (r, row) in rows.enumerated() {
            x += #"<row r="\#(r + 1)">"#
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                switch cell {
                case .text(let s, let style):
                    // Inline strings are never evaluated as formulas.
                    x += #"<c r="\#(ref)" t="inlineStr" s="\#(style)"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                case .number(let n, let style):
                    x += #"<c r="\#(ref)" s="\#(style)"><v>\#(n)</v></c>"#
                case .empty(let style):
                    if style != 0 { x += #"<c r="\#(ref)" s="\#(style)"/>"# }
                }
            }
            x += "</row>"
        }
        x += "</sheetData>"
        if let first = rows.first, !first.isEmpty, rows.count > 1 {
            x += #"<autoFilter ref="A1:\#(columnName(first.count - 1))\#(rows.count)"/>"#
        }
        x += "</worksheet>"
        return x
    }

    /// Styles: 0 default, 1 bold header, 2 not reviewed, 3 unresolved issue, 4 reviewed, 5 wrapped text.
    static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
    <fills count="5"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF6D5"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFE0DC"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF0F0F0"/><bgColor indexed="64"/></patternFill></fill></fills>
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="6">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="4" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>
    </cellXfs>
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """

    public static func render(snapshot: TableSnapshot, evaluation: TableEvaluation, dataset: ExportDataset,
                              options: ExportOptions, highlightReview: Bool = true) -> Data {
        let unresolved = Set(evaluation.unresolved(in: snapshot).flatMap(\.cellIDs))

        // Data
        var data: [[Cell]] = [dataset.columns.map { .text($0.name, style: 1) }]
        var dataAddress: [UUID: String] = [:]
        for (i, row) in dataset.rows.enumerated() {
            data.append(row.enumerated().map { c, v in
                if let cell = v.cell, cell.column == c { dataAddress[cell.id] = "\(columnName(c))\(i + 2)" }
                var style = 0
                if highlightReview, let cell = v.cell {
                    if unresolved.contains(cell.id) { style = 3 } else if cell.review != .reviewed { style = 2 }
                }
                if let n = v.number, options.numericPolicy == .canonical { return .number(n, style: style) }
                return v.text.isEmpty ? .empty(style: style) : .text(v.text, style: style)
            })
        }
        let widths = dataset.columns.enumerated().map { c, col in
            min(60, max(8, Double(([col.name.count] + dataset.rows.map { $0[c].text.count }).max() ?? 8) * 1.1 + 2))
        }

        // Sources
        var sources: [[Cell]] = [["Data cell", "Table cell", "Column", "Value", "Extracted text", "Document", "SHA-256", "Page",
                                  "Regions (x, y, width, height in PDF points)", "Coordinate space", "Mapping method",
                                  "Engine score (raw)", "Review"].map { .text($0, style: 1) }]
        let includedRows = Set(dataset.rowIndexes)
        for cell in snapshot.cells where includedRows.contains(cell.row) && cell.column < snapshot.table.columns.count {
            let source = cell.sources.first
            let regions = cell.sources.flatMap(\.regions)
                .map { String(format: "%.2f, %.2f, %.2f, %.2f", $0.x, $0.y, $0.width, $0.height) }.joined(separator: "; ")
            sources.append([
                .text(dataAddress[cell.id] ?? "", style: 0), .text(cell.address, style: 0),
                .text(snapshot.table.columns[cell.column].name, style: 0), .text(cell.text, style: 0),
                .text(cell.extractedText, style: 0), .text(snapshot.document.filename, style: 0),
                .text(snapshot.document.sha256, style: 0),
                source.map { .number(String($0.pageIndex + 1), style: 0) } ?? .empty(style: 0),
                .text(regions.isEmpty ? (cell.text.isEmpty ? "" : "No source region available") : regions, style: 0),
                .text(source?.coordinateSpace ?? "", style: 0), .text(source?.method.label ?? "", style: 0),
                cell.engineScore.map { .number(String(format: "%.4f", $0), style: 0) } ?? .empty(style: 0),
                .text(cell.review.label, style: 0),
            ])
        }

        // Corrections
        var corrections: [[Cell]] = [["Time", "Cell", "Change", "Before", "After", "Detail", "Extraction version"].map { .text($0, style: 1) }]
        let iso = ISO8601DateFormatter()
        for c in snapshot.corrections {
            let address = c.cellID.flatMap { snapshot.cell(id: $0)?.address } ?? ""
            corrections.append([.text(iso.string(from: c.createdAt), style: 0), .text(address, style: 0), .text(c.kind.rawValue, style: 0),
                                .text(c.before ?? "", style: 0), .text(c.after ?? "", style: 0), .text(c.detail, style: 0),
                                .text(String(c.runID.uuidString.prefix(8)), style: 0)])
        }

        // Checks
        var checks: [[Cell]] = [["Rule", "Version", "Status", "Severity", "Resolved by review", "Cells", "Message", "What was tested", "Tolerance"].map { .text($0, style: 1) }]
        for r in evaluation.results {
            let addresses = r.cellIDs.compactMap { snapshot.cell(id: $0)?.address }.joined(separator: ", ")
            checks.append([.text(r.ruleID, style: 0), .number(String(r.ruleVersion), style: 0), .text(r.status.rawValue, style: 0),
                           .text(r.severity.rawValue, style: 0),
                           .text(r.status == .failed ? (evaluation.isResolved(r, in: snapshot) ? "yes" : "no") : "", style: 0),
                           .text(addresses, style: 0), .text(r.message, style: 0), .text(r.tested, style: 0), .text(r.tolerance ?? "", style: 0)])
        }

        // About
        let d = dataset.disclosure
        let about: [[Cell]] = [
            [.text("Property", style: 1), .text("Value", style: 1)],
            [.text("Review status", style: 0), .text(d.isComplete ? "Fully reviewed" : "NOT FULLY REVIEWED: " + d.summary, style: d.isComplete ? 0 : 3)],
            [.text("Cells", style: 0), .number(String(d.cells), style: 0)],
            [.text("Reviewed by user", style: 0), .number(String(d.reviewed), style: 0)],
            [.text("Needs review", style: 0), .number(String(d.needsReview), style: 0)],
            [.text("Unreviewed", style: 0), .number(String(d.unreviewed), style: 0)],
            [.text("Unresolved issues", style: 0), .number(String(d.unresolvedIssues), style: 0)],
            [.text("Corrected cells", style: 0), .number(String(d.correctedCells), style: 0)],
            [.text("Document", style: 0), .text(snapshot.document.filename, style: 0)],
            [.text("Document SHA-256", style: 0), .text(snapshot.document.sha256, style: 0)],
            [.text("Pages", style: 0), .text(snapshot.table.pageIndexes.map { String($0 + 1) }.joined(separator: ", "), style: 0)],
            [.text("Table", style: 0), .text(snapshot.table.name, style: 0)],
            [.text("Engine", style: 0), .text(snapshot.run.engine.name, style: 0)],
            [.text("Engine version", style: 0), .text(snapshot.run.engine.version, style: 0)],
            [.text("Extracted at", style: 0), .text(iso.string(from: snapshot.run.startedAt), style: 0)],
            [.text("Exported at", style: 0), .text(iso.string(from: Date()), style: 0)],
            [.text("Numbers", style: 0), .text(options.numericPolicy.label, style: 0)],
            [.text("Missing values", style: 0), .text(options.missingPolicy.label, style: 0)],
            [.text("Highlighting", style: 0), .text("Yellow: not reviewed by the user. Red: unresolved issue.", style: 0)],
        ]

        let sheets: [(String, String)] = [
            ("Data", sheetXML(data, widths: widths)),
            ("Sources", sheetXML(sources, widths: [10, 10, 18, 18, 18, 24, 20, 6, 40, 30, 20, 12, 12])),
            ("Corrections", sheetXML(corrections, widths: [22, 8, 12, 20, 20, 50, 12])),
            ("Checks", sheetXML(checks, widths: [24, 8, 12, 10, 10, 20, 60, 60, 10])),
            ("About", sheetXML(about, widths: [22, 80])),
        ]

        var zip = ZipWriter()
        var contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
        for i in sheets.indices {
            contentTypes += #"<Override PartName="/xl/worksheets/sheet\#(i + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }
        contentTypes += "</Types>"
        zip.add(path: "[Content_Types].xml", text: contentTypes)
        zip.add(path: "_rels/.rels", text: #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>"#)
        zip.add(path: "docProps/core.xml", text: #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\#(escape(snapshot.table.name))</dc:title><dc:creator>DocLens</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\#(iso.string(from: Date()))</dcterms:created></cp:coreProperties>"#)
        var workbook = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
        var rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for (i, sheet) in sheets.enumerated() {
            workbook += #"<sheet name="\#(sheet.0)" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
            rels += #"<Relationship Id="rId\#(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(i + 1).xml"/>"#
            zip.add(path: "xl/worksheets/sheet\(i + 1).xml", text: sheet.1)
        }
        workbook += "</sheets>"
        if dataset.rows.count > 0 {
            workbook += #"<definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">Data!$A$1:$\#(columnName(max(0, dataset.columns.count - 1)))$\#(dataset.rows.count + 1)</definedName></definedNames>"#
        }
        workbook += "</workbook>"
        rels += #"<Relationship Id="rId\#(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
        zip.add(path: "xl/workbook.xml", text: workbook)
        zip.add(path: "xl/_rels/workbook.xml.rels", text: rels)
        zip.add(path: "xl/styles.xml", text: stylesXML)
        return zip.finish()
    }
}

/// Writes exports to disk, including the optional JSON provenance sidecar.
public enum ExportService {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case csv, xlsx, json
        public var id: String { rawValue }
        public var label: String { self == .csv ? "CSV" : self == .xlsx ? "Excel (XLSX)" : "JSON with provenance" }
        public var fileExtension: String { rawValue }
    }

    public static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("provenance.json")
    }

    @discardableResult
    public static func export(snapshot: TableSnapshot, evaluation: TableEvaluation, format: Format, options: ExportOptions,
                              to url: URL, appVersion: String = "1.0") throws -> [URL] {
        let dataset = ExportDataset(snapshot: snapshot, evaluation: evaluation, options: options)
        var written: [URL] = []
        switch format {
        case .csv:
            try Data(CSVExporter.render(dataset, options: options).utf8).write(to: url, options: .atomic)
        case .xlsx:
            try XLSXExporter.render(snapshot: snapshot, evaluation: evaluation, dataset: dataset, options: options)
                .write(to: url, options: .atomic)
        case .json:
            try JSONExporter.render(snapshot: snapshot, evaluation: evaluation, options: options, dataset: dataset,
                                    appVersion: appVersion).write(to: url, options: .atomic)
        }
        written.append(url)
        if format != .json && options.writeSidecar {
            let sidecar = sidecarURL(for: url)
            try JSONExporter.render(snapshot: snapshot, evaluation: evaluation, options: options, dataset: dataset,
                                    appVersion: appVersion).write(to: sidecar, options: .atomic)
            written.append(sidecar)
        }
        return written
    }
}
