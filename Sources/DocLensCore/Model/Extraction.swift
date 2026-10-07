import Foundation

/// Engine-independent extraction output. Engines return this type; the application converts it
/// into persisted cells. Raw engine objects never leave the adapter.
public struct ExtractedTable: Codable, Hashable, Sendable {
    public var rowCount: Int
    public var columnCount: Int
    public var cells: [ExtractedCell]
    /// Segment index for each row.
    public var rowSegments: [Int]
    public var headerRowCount: Int
    public var engine: EngineDescriptor
    public var notes: [String]

    public init(rowCount: Int, columnCount: Int, cells: [ExtractedCell], rowSegments: [Int],
                headerRowCount: Int, engine: EngineDescriptor, notes: [String] = []) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
        self.rowSegments = rowSegments
        self.headerRowCount = headerRowCount
        self.engine = engine
        self.notes = notes
    }

    public func cell(row: Int, column: Int) -> ExtractedCell? {
        cells.first { $0.row == row && $0.column == column }
    }

    /// Plain text grid, with spanned positions filled by an empty string.
    public var textGrid: [[String]] {
        var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for c in cells where c.row < rowCount && c.column < columnCount {
            grid[c.row][c.column] = c.text
        }
        return grid
    }
}

public struct ExtractedCell: Codable, Hashable, Sendable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var colSpan: Int
    public var text: String
    public var pageIndex: Int
    public var regions: [PageRect]
    public var method: MappingMethod
    public var score: Double?
    public var flags: [String]

    public init(row: Int, column: Int, rowSpan: Int = 1, colSpan: Int = 1, text: String, pageIndex: Int,
                regions: [PageRect], method: MappingMethod, score: Double? = nil, flags: [String] = []) {
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.colSpan = colSpan
        self.text = text
        self.pageIndex = pageIndex
        self.regions = regions
        self.method = method
        self.score = score
        self.flags = flags
    }
}

public enum CellFlag {
    public static let continuationMerged = "continuation-merged"
    public static let spansColumns = "spans-columns"
    public static let outsideColumns = "outside-columns"
    public static let repeatedHeader = "repeated-header"
    public static let carriedOver = "carried-over"
    public static let reextractionConflict = "reextraction-conflict"
}

/// Candidate table found on a page, used for one-click extraction.
public struct TableCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var pageIndex: Int
    public var region: PageRect
    public var rowCount: Int
    public var columnCount: Int
    public var source: String

    public init(id: UUID = UUID(), pageIndex: Int, region: PageRect, rowCount: Int, columnCount: Int, source: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.region = region
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.source = source
    }
}

// MARK: - Recipes

/// A reusable, versioned description of how to extract and interpret a recurring table.
public struct Recipe: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var engine: EngineKind
    public var settings: TableSettings
    public var columns: [RecipeColumn]
    public var headerRowCount: Int
    /// Text found near the top of the table, used to locate it on new documents.
    public var anchorText: String
    /// Offset of the region relative to the anchor's bounds, in display points.
    public var anchorOffset: PageRect?
    /// Region relative to the page crop box, normalized to 0...1 in display orientation.
    public var regionHint: PageRect
    public var pageHint: Int
    public var notes: String

    public init(id: UUID = UUID(), name: String, version: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date(),
                engine: EngineKind, settings: TableSettings, columns: [RecipeColumn], headerRowCount: Int,
                anchorText: String, anchorOffset: PageRect?, regionHint: PageRect, pageHint: Int, notes: String = "") {
        self.id = id
        self.name = name
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.engine = engine
        self.settings = settings
        self.columns = columns
        self.headerRowCount = headerRowCount
        self.anchorText = anchorText
        self.anchorOffset = anchorOffset
        self.regionHint = regionHint
        self.pageHint = pageHint
        self.notes = notes
    }
}

public struct RecipeColumn: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var type: ColumnType
    public var unit: String
    public var scale: String
    public var numberFormat: NumberFormat?
    public var aliases: [String]
    public var required: Bool

    public init(id: UUID = UUID(), name: String, type: ColumnType, unit: String = "", scale: String = "1",
                numberFormat: NumberFormat? = nil, aliases: [String], required: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.unit = unit
        self.scale = scale
        self.numberFormat = numberFormat
        self.aliases = aliases
        self.required = required
    }
}
