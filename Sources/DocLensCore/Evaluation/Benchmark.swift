import Foundation

/// Scores an extraction against ground truth. Grids are compared by position after aligning
/// rows on their text, so one missing row does not shift every following comparison.
public struct BenchmarkScore: Codable, Sendable {
    public var document: String
    public var engine: String
    public var truthRows: Int
    public var truthColumns: Int
    public var extractedRows: Int
    public var extractedColumns: Int
    public var missingRows: Int
    public var extraRows: Int
    public var cellsCompared: Int
    public var cellsExact: Int
    public var numericCells: Int
    public var numericExact: Int
    public var textRecall: Double
    public var sourceCoverage: Double
    public var sourceCorrect: Double
    public var leadingZeroCells: Int
    public var leadingZeroPreserved: Int
    public var headerRowsExpected: Int
    public var headerRowsDetected: Int
    public var latencySeconds: Double
    public var peakMemoryMB: Double?
    public var error: String?

    public static func failure(truth: TruthTable, document: String, engine: String, latency: Double, error: String) -> BenchmarkScore {
        BenchmarkScore(document: document, engine: engine, truthRows: truth.cells.count, truthColumns: truth.cells.first?.count ?? 0,
                       extractedRows: 0, extractedColumns: 0, missingRows: truth.cells.count, extraRows: 0, cellsCompared: 0,
                       cellsExact: 0, numericCells: 0, numericExact: 0, textRecall: 0, sourceCoverage: 0, sourceCorrect: 0,
                       leadingZeroCells: 0, leadingZeroPreserved: 0, headerRowsExpected: truth.headerRows, headerRowsDetected: 0,
                       latencySeconds: latency, peakMemoryMB: nil, error: error)
    }

    public var cellAccuracy: Double { cellsCompared == 0 ? 0 : Double(cellsExact) / Double(cellsCompared) }
    public var numericAccuracy: Double { numericCells == 0 ? 1 : Double(numericExact) / Double(numericCells) }
}

public enum BenchmarkScorer {
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func score(truth: TruthTable, extracted: ExtractedTable, document: String, engine: String,
                             latency: Double, memoryMB: Double?) -> BenchmarkScore {
        let truthGrid = truth.cells
        let grid = extracted.textGrid.enumerated().filter { r, _ in
            // Rows flagged as repeated headers are excluded, as the application does.
            !extracted.cells.contains { $0.row == r && $0.flags.contains(CellFlag.repeatedHeader) }
        }.map { $0.element }
        let extractedRowMap = extracted.textGrid.indices.filter { r in
            !extracted.cells.contains { $0.row == r && $0.flags.contains(CellFlag.repeatedHeader) }
        }

        // Align rows: dynamic programming over row similarity.
        func rowSim(_ a: [String], _ b: [String]) -> Double {
            let n = max(a.count, b.count)
            guard n > 0 else { return 0 }
            var same = 0
            for i in 0..<min(a.count, b.count) where clean(a[i]) == clean(b[i]) && !clean(a[i]).isEmpty { same += 1 }
            let nonEmpty = a.filter { !clean($0).isEmpty }.count
            return nonEmpty == 0 ? 0 : Double(same) / Double(max(1, nonEmpty))
        }
        let n = truthGrid.count, m = grid.count
        var dp = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                let s = rowSim(truthGrid[i], grid[j])
                dp[i][j] = max(dp[i + 1][j], dp[i][j + 1], s > 0.2 ? dp[i + 1][j + 1] + s : 0)
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            let s = rowSim(truthGrid[i], grid[j])
            if s > 0.2 && dp[i][j] == dp[i + 1][j + 1] + s { pairs.append((i, j)); i += 1; j += 1 } else if dp[i][j] == dp[i + 1][j] { i += 1 } else { j += 1 }
        }

        var compared = 0, exact = 0, numeric = 0, numericExact = 0, lz = 0, lzKept = 0
        var sourceTotal = 0, sourceOK = 0
        let decimal = truth.numberFormat.decimalSeparator ?? "."
        let grouping = truth.numberFormat.groupingSeparators
        for (ti, ej) in pairs {
            for c in 0..<truthGrid[ti].count {
                let t = clean(truthGrid[ti][c])
                let e = c < grid[ej].count ? clean(grid[ej][c]) : ""
                if t.isEmpty && e.isEmpty { continue }
                compared += 1
                if t == e { exact += 1 }
                let type = c < truth.columnTypes.count ? truth.columnTypes[c] : .text
                if ti >= truth.headerRows && type.isNumeric {
                    let tv = ValueNormalizer.splitFootnote(t).value
                    if case .success(let tp) = NumberParsing.parse(tv, decimal: decimal, grouping: grouping) {
                        numeric += 1
                        let ev = ValueNormalizer.splitFootnote(e).value
                        if case .success(let ep) = NumberParsing.parse(ev, decimal: decimal, grouping: grouping), ep.canonical == tp.canonical {
                            numericExact += 1
                        }
                    }
                }
                if ti >= truth.headerRows && t.count > 1 && t.hasPrefix("0") && t.allSatisfy(\.isASCIIDigit) {
                    lz += 1
                    if e == t { lzKept += 1 }
                }
                // Source mapping: the region's center must fall inside the truth cell box.
                if !t.isEmpty, let truthRect = truth.cellRects[ti][c] {
                    let er = extractedRowMap[ej]
                    if let cell = extracted.cells.first(where: { $0.row == er && $0.column == c }), !cell.text.isEmpty {
                        sourceTotal += 1
                        let pageOK = cell.pageIndex == truth.cellPages[ti][c]
                        if pageOK, let r = cell.regions.first {
                            var union = r
                            for other in cell.regions.dropFirst() { union = union.union(other) }
                            if truthRect.insetBy(-2).contains(x: union.midX, y: union.midY) { sourceOK += 1 }
                        }
                    }
                }
            }
        }

        // Text recall ignores structure: share of truth cell texts found anywhere.
        var pool: [String: Int] = [:]
        for row in grid { for t in row { pool[clean(t), default: 0] += 1 } }
        var found = 0, total = 0
        for row in truthGrid { for t in row where !clean(t).isEmpty {
            total += 1
            if let k = pool[clean(t)], k > 0 { found += 1; pool[clean(t)] = k - 1 }
        } }
        let withRegion = extracted.cells.filter { !$0.text.isEmpty && !$0.regions.isEmpty }.count
        let nonEmpty = extracted.cells.filter { !$0.text.isEmpty }.count

        return BenchmarkScore(
            document: document, engine: engine, truthRows: n, truthColumns: truthGrid.first?.count ?? 0,
            extractedRows: m, extractedColumns: extracted.columnCount, missingRows: n - pairs.count, extraRows: m - pairs.count,
            cellsCompared: compared, cellsExact: exact, numericCells: numeric, numericExact: numericExact,
            textRecall: total == 0 ? 0 : Double(found) / Double(total),
            sourceCoverage: nonEmpty == 0 ? 0 : Double(withRegion) / Double(nonEmpty),
            sourceCorrect: sourceTotal == 0 ? 0 : Double(sourceOK) / Double(sourceTotal),
            leadingZeroCells: lz, leadingZeroPreserved: lzKept, headerRowsExpected: truth.headerRows,
            headerRowsDetected: extracted.headerRowCount, latencySeconds: latency, peakMemoryMB: memoryMB, error: nil)
    }
}
