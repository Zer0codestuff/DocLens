import Foundation

// MARK: - Enumerations

public enum ColumnType: String, Codable, CaseIterable, Sendable, Identifiable {
    case text
    case identifier
    case integer
    case decimal
    case percent
    case currency
    case date

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: "Text"
        case .identifier: "Identifier"
        case .integer: "Integer"
        case .decimal: "Decimal"
        case .percent: "Percent"
        case .currency: "Currency"
        case .date: "Date"
        }
    }

    public var shortLabel: String {
        switch self {
        case .text: "Aa"
        case .identifier: "ID"
        case .integer: "123"
        case .decimal: "1.5"
        case .percent: "%"
        case .currency: "¤"
        case .date: "Date"
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .integer, .decimal, .percent, .currency: true
        default: false
        }
    }

    /// Missing-value markers apply to typed columns only. In text and identifier columns a
    /// dash is literal text.
    public var usesMissingMarkers: Bool { isNumeric || self == .date }
}

/// Explicit numeric locale policy. `auto` infers per column and flags ambiguous values.
public enum NumberFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case pointDecimal
    case commaDecimal
    case spaceCommaDecimal
    case apostrophePointDecimal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Detect per column"
        case .pointDecimal: "1,234.56"
        case .commaDecimal: "1.234,56"
        case .spaceCommaDecimal: "1 234,56"
        case .apostrophePointDecimal: "1'234.56"
        }
    }

    public var decimalSeparator: Character? {
        switch self {
        case .auto: nil
        case .pointDecimal, .apostrophePointDecimal: "."
        case .commaDecimal, .spaceCommaDecimal: ","
        }
    }

    public var groupingSeparators: Set<Character> {
        switch self {
        case .auto: []
        case .pointDecimal: [",", " ", "\u{00A0}", "\u{202F}"]
        case .commaDecimal: [".", " ", "\u{00A0}", "\u{202F}"]
        case .spaceCommaDecimal: [" ", "\u{00A0}", "\u{202F}", "."]
        case .apostrophePointDecimal: ["'", "’", " ", "\u{00A0}"]
        }
    }
}

public enum DateOrder: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, dmy, mdy, ymd
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Detect (flag ambiguous)"
        case .dmy: "Day / Month / Year"
        case .mdy: "Month / Day / Year"
        case .ymd: "Year / Month / Day"
        }
    }
}

public enum ReviewState: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case needsReview
    case reviewed

    public var label: String {
        switch self {
        case .unreviewed: "Unreviewed"
        case .needsReview: "Needs review"
        case .reviewed: "Reviewed"
        }
    }
}

public enum RowRole: String, Codable, CaseIterable, Sendable {
    case header
    case data
    case total
    case excluded

    public var label: String {
        switch self {
        case .header: "Header"
        case .data: "Data"
        case .total: "Total"
        case .excluded: "Excluded"
        }
    }
}

public enum EngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case textLayer
    case visionOCR
    case visionDocument
    case docling

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Automatic"
        case .textLayer: "PDF Text Layer"
        case .visionOCR: "Vision OCR + Layout"
        case .visionDocument: "Vision Document Structure"
        case .docling: "Docling (external)"
        }
    }

    public var summary: String {
        switch self {
        case .auto: "Uses the text layer when the region has readable text, otherwise Vision."
        case .textLayer: "Exact glyphs and positions from a digital PDF. Fast and precise."
        case .visionOCR: "Recognizes words in a rendered image, then infers rows and columns."
        case .visionDocument: "Apple's document recognition infers the table structure."
        case .docling: "Runs a separate Python worker with Docling. Requires a configured interpreter."
        }
    }
}

public enum MappingMethod: String, Codable, Sendable {
    case textLayerGlyphs
    case ocrWords
    case visionDocumentCell
    case doclingCell
    case userEntered

    public var label: String {
        switch self {
        case .textLayerGlyphs: "PDF glyph positions"
        case .ocrWords: "OCR word boxes"
        case .visionDocumentCell: "Vision table cell"
        case .doclingCell: "Docling cell box"
        case .userEntered: "Entered by user"
        }
    }
}

// MARK: - Provenance

public struct SourceReference: Codable, Hashable, Sendable {
    public static let coordinateSpace = "pdf-page-points;origin=media-box-lower-left;unrotated"

    public var documentID: UUID
    public var pageIndex: Int
    public var regions: [PageRect]
    public var coordinateSpace: String
    public var method: MappingMethod

    public init(documentID: UUID, pageIndex: Int, regions: [PageRect], method: MappingMethod) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.regions = regions
        self.coordinateSpace = Self.coordinateSpace
        self.method = method
    }

    public var bounds: PageRect? {
        guard var r = regions.first else { return nil }
        for other in regions.dropFirst() { r = r.union(other) }
        return r
    }
}

public struct DocumentRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var title: String
    public var sha256: String
    public var pageCount: Int
    public var pages: [PageGeometry]
    public var storedName: String
    public var fileSize: Int64
    public var importedAt: Date
    public var hasTextLayer: Bool

    public init(id: UUID = UUID(), filename: String, title: String, sha256: String, pageCount: Int,
                pages: [PageGeometry], storedName: String, fileSize: Int64, importedAt: Date = Date(),
                hasTextLayer: Bool) {
        self.id = id
        self.filename = filename
        self.title = title
        self.sha256 = sha256
        self.pageCount = pageCount
        self.pages = pages
        self.storedName = storedName
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.hasTextLayer = hasTextLayer
    }
}

public struct TableSegment: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var region: PageRect

    public init(pageIndex: Int, region: PageRect) {
        self.pageIndex = pageIndex
        self.region = region
    }
}

public struct TableSettings: Codable, Hashable, Sendable {
    public var numberFormat: NumberFormat
    public var dateOrder: DateOrder
    public var missingTokens: [String]
    /// Absolute tolerance for total checks, as a decimal string. `nil` uses one unit of the
    /// smallest decimal place present in the compared values.
    public var totalTolerance: String?
    public var mergeContinuationLines: Bool
    public var stripFootnoteMarkers: Bool

    public static let defaultMissingTokens = ["-", "\u{2013}", "\u{2014}", "..", "...", "…", "n/a", "N/A", "n.a.", "NA", "x", ":", "*"]

    public init(numberFormat: NumberFormat = .auto, dateOrder: DateOrder = .auto,
                missingTokens: [String] = TableSettings.defaultMissingTokens, totalTolerance: String? = nil,
                mergeContinuationLines: Bool = true, stripFootnoteMarkers: Bool = true) {
        self.numberFormat = numberFormat
        self.dateOrder = dateOrder
        self.missingTokens = missingTokens
        self.totalTolerance = totalTolerance
        self.mergeContinuationLines = mergeContinuationLines
        self.stripFootnoteMarkers = stripFootnoteMarkers
    }
}

public struct ColumnSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var index: Int
    public var name: String
    public var type: ColumnType
    public var unit: String
    /// Multiplier applied to parsed numbers, as a decimal string ("1", "1000").
    public var scale: String
    public var numberFormat: NumberFormat?
    /// Header text found in the source, kept separately from the user-facing name.
    public var sourceHeader: String
    public var typeConfirmed: Bool

    public init(id: UUID = UUID(), index: Int, name: String, type: ColumnType = .text, unit: String = "",
                scale: String = "1", numberFormat: NumberFormat? = nil, sourceHeader: String = "",
                typeConfirmed: Bool = false) {
        self.id = id
        self.index = index
        self.name = name
        self.type = type
        self.unit = unit
        self.scale = scale
        self.numberFormat = numberFormat
        self.sourceHeader = sourceHeader
        self.typeConfirmed = typeConfirmed
    }

    public var letter: String { ColumnSpec.letter(for: index) }

    public static func letter(for index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }
}

public struct RowSpec: Codable, Hashable, Sendable {
    public var index: Int
    public var role: RowRole
    public var segmentIndex: Int
    public var note: String?

    public init(index: Int, role: RowRole, segmentIndex: Int = 0, note: String? = nil) {
        self.index = index
        self.role = role
        self.segmentIndex = segmentIndex
        self.note = note
    }
}

public struct CellRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var runID: UUID
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var colSpan: Int
    /// Text exactly as returned by the engine. Never modified after extraction.
    public var extractedText: String
    /// Value entered by the user. `nil` when the cell has not been corrected.
    public var correctedText: String?
    public var sources: [SourceReference]
    /// Raw engine score when the engine reports one. Not a calibrated probability.
    public var engineScore: Double?
    public var review: ReviewState
    public var flags: [String]
    public var updatedAt: Date

    public init(id: UUID = UUID(), runID: UUID, row: Int, column: Int, rowSpan: Int = 1, colSpan: Int = 1,
                extractedText: String, correctedText: String? = nil, sources: [SourceReference] = [],
                engineScore: Double? = nil, review: ReviewState = .unreviewed, flags: [String] = [],
                updatedAt: Date = Date()) {
        self.id = id
        self.runID = runID
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.colSpan = colSpan
        self.extractedText = extractedText
        self.correctedText = correctedText
        self.sources = sources
        self.engineScore = engineScore
        self.review = review
        self.flags = flags
        self.updatedAt = updatedAt
    }

    public var text: String { correctedText ?? extractedText }
    public var isCorrected: Bool { correctedText != nil && correctedText != extractedText }
    public var hasSourceRegion: Bool { sources.contains { !$0.regions.isEmpty } }

    public var address: String { "\(ColumnSpec.letter(for: column))\(row + 1)" }
}

public enum RunStatus: String, Codable, Sendable {
    case running, completed, failed, cancelled
}

public struct ExtractionRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var tableID: UUID
    public var engine: EngineDescriptor
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var errorMessage: String?
    public var segments: [TableSegment]
    public var documentSHA256: String
    public var rows: [RowSpec]
    public var columnCount: Int
    public var notes: [String]
    public var cacheKey: String?

    public init(id: UUID = UUID(), tableID: UUID, engine: EngineDescriptor, startedAt: Date = Date(),
                finishedAt: Date? = nil, status: RunStatus = .running, errorMessage: String? = nil,
                segments: [TableSegment], documentSHA256: String, rows: [RowSpec] = [], columnCount: Int = 0,
                notes: [String] = [], cacheKey: String? = nil) {
        self.id = id
        self.tableID = tableID
        self.engine = engine
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.errorMessage = errorMessage
        self.segments = segments
        self.documentSHA256 = documentSHA256
        self.rows = rows
        self.columnCount = columnCount
        self.notes = notes
        self.cacheKey = cacheKey
    }
}

public struct EngineDescriptor: Codable, Hashable, Sendable {
    public var kind: EngineKind
    public var name: String
    public var version: String
    public var configuration: [String: String]

    public init(kind: EngineKind, name: String, version: String, configuration: [String: String] = [:]) {
        self.kind = kind
        self.name = name
        self.version = version
        self.configuration = configuration
    }
}

public struct TableRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var currentRunID: UUID?
    public var settings: TableSettings
    public var segments: [TableSegment]
    public var columns: [ColumnSpec]
    public var recipeID: UUID?
    public var recipeVersion: Int?

    public init(id: UUID = UUID(), documentID: UUID, name: String, createdAt: Date = Date(),
                updatedAt: Date = Date(), currentRunID: UUID? = nil, settings: TableSettings = TableSettings(),
                segments: [TableSegment], columns: [ColumnSpec] = [], recipeID: UUID? = nil,
                recipeVersion: Int? = nil) {
        self.id = id
        self.documentID = documentID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.currentRunID = currentRunID
        self.settings = settings
        self.segments = segments
        self.columns = columns
        self.recipeID = recipeID
        self.recipeVersion = recipeVersion
    }

    public var pageIndexes: [Int] { Array(Set(segments.map(\.pageIndex))).sorted() }
}

public enum CorrectionKind: String, Codable, Sendable {
    case edit
    case undo
    case redo
    case review
    case columnType
    case columnRename
    case columnSettings
    case rowRole
    case carriedOver
    case conflict
    case tableSettings
}

public struct Correction: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var tableID: UUID
    public var runID: UUID
    public var cellID: UUID?
    public var kind: CorrectionKind
    public var before: String?
    public var after: String?
    public var detail: String
    public var createdAt: Date

    public init(id: UUID = UUID(), tableID: UUID, runID: UUID, cellID: UUID?, kind: CorrectionKind,
                before: String?, after: String?, detail: String = "", createdAt: Date = Date()) {
        self.id = id
        self.tableID = tableID
        self.runID = runID
        self.cellID = cellID
        self.kind = kind
        self.before = before
        self.after = after
        self.detail = detail
        self.createdAt = createdAt
    }
}

public enum CheckStatus: String, Codable, Sendable {
    case passed, failed, notApplicable
}

public enum CheckSeverity: String, Codable, Sendable, Comparable {
    case info, warning, error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: CheckSeverity, rhs: CheckSeverity) -> Bool { lhs.rank < rhs.rank }
}

public struct CheckResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ruleID: String
    public var ruleVersion: Int
    public var status: CheckStatus
    public var severity: CheckSeverity
    public var cellIDs: [UUID]
    public var row: Int?
    public var column: Int?
    public var message: String
    public var tested: String
    public var tolerance: String?

    public init(ruleID: String, ruleVersion: Int, status: CheckStatus, severity: CheckSeverity,
                cellIDs: [UUID] = [], row: Int? = nil, column: Int? = nil, message: String, tested: String,
                tolerance: String? = nil) {
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.status = status
        self.severity = severity
        self.cellIDs = cellIDs
        self.row = row
        self.column = column
        self.message = message
        self.tested = tested
        self.tolerance = tolerance
        self.id = "\(ruleID)#\(row ?? -1):\(column ?? -1):\(cellIDs.first?.uuidString ?? "")"
    }
}
