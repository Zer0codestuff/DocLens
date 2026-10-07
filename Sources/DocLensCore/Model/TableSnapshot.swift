import Foundation

/// The complete working state of one table at its current extraction version.
public struct TableSnapshot: Sendable, Hashable {
    public var document: DocumentRecord
    public var table: TableRecord
    public var run: ExtractionRun
    public var cells: [CellRecord] {
        didSet { rebuildIndex() }
    }
    public var corrections: [Correction]
    public private(set) var anchorIndex: [Int: Int] = [:]
    public private(set) var coverIndex: [Int: Int] = [:]

    public init(document: DocumentRecord, table: TableRecord, run: ExtractionRun, cells: [CellRecord],
                corrections: [Correction]) {
        self.document = document
        self.table = table
        self.run = run
        self.cells = cells
        self.corrections = corrections
        rebuildIndex()
    }

    public var rowCount: Int { run.rows.count }
    public var columnCount: Int { table.columns.count }

    private func key(_ row: Int, _ column: Int) -> Int { row &* 4096 &+ column }

    private mutating func rebuildIndex() {
        anchorIndex.removeAll(keepingCapacity: true)
        coverIndex.removeAll(keepingCapacity: true)
        for (i, c) in cells.enumerated() {
            anchorIndex[key(c.row, c.column)] = i
            for r in c.row..<(c.row + max(1, c.rowSpan)) {
                for col in c.column..<(c.column + max(1, c.colSpan)) {
                    coverIndex[key(r, col)] = i
                }
            }
        }
    }

    /// The cell anchored exactly at a position.
    public func cell(row: Int, column: Int) -> CellRecord? {
        anchorIndex[key(row, column)].map { cells[$0] }
    }

    /// The cell anchored at or spanning over a position.
    public func coveringCell(row: Int, column: Int) -> CellRecord? {
        coverIndex[key(row, column)].map { cells[$0] }
    }

    public func cellIndex(id: UUID) -> Int? { cells.firstIndex { $0.id == id } }

    public func cell(id: UUID) -> CellRecord? { cellIndex(id: id).map { cells[$0] } }

    public func role(of row: Int) -> RowRole { row < run.rows.count ? run.rows[row].role : .data }

    public var dataRowIndexes: [Int] { run.rows.filter { $0.role == .data || $0.role == .total }.map(\.index) }
    public var strictDataRowIndexes: [Int] { run.rows.filter { $0.role == .data }.map(\.index) }
    public var headerRowIndexes: [Int] { run.rows.filter { $0.role == .header }.map(\.index) }

    /// Effective text in each column for data rows, used for format inference.
    public func valuesByColumn() -> [[String]] {
        var result = Array(repeating: [String](), count: columnCount)
        for r in strictDataRowIndexes {
            for c in 0..<columnCount {
                if let cell = cell(row: r, column: c) { result[c].append(cell.text) }
            }
        }
        return result
    }

    public func headerText(column: Int) -> String {
        headerRowIndexes.compactMap { r -> String? in
            guard let cell = coveringCell(row: r, column: column) else { return nil }
            let t = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        .reduce(into: [String]()) { acc, t in if acc.last != t { acc.append(t) } }
        .joined(separator: " ")
    }

    public func corrections(for cellID: UUID) -> [Correction] {
        corrections.filter { $0.cellID == cellID }.sorted { $0.createdAt < $1.createdAt }
    }

    public var reviewProgress: (reviewed: Int, total: Int) {
        let ids = Set(dataRowIndexes)
        let relevant = cells.filter { ids.contains($0.row) }
        return (relevant.filter { $0.review == .reviewed }.count, relevant.count)
    }
}
