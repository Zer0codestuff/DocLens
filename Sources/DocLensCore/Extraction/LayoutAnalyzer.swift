import CoreGraphics
import Foundation

/// A word with its position in display space (points, lower-left origin, page rotation applied).
public struct LayoutToken: Sendable, Hashable {
    public var text: String
    public var rect: CGRect
    public var score: Double?

    public init(text: String, rect: CGRect, score: Double? = nil) {
        self.text = text
        self.rect = rect
        self.score = score
    }
}

public struct RuleLines: Sendable, Hashable {
    /// Y positions of horizontal rules in display space.
    public var horizontal: [Double]
    /// X positions of vertical rules in display space.
    public var vertical: [Double]

    public init(horizontal: [Double] = [], vertical: [Double] = []) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let none = RuleLines()
}

public struct LayoutCell: Sendable, Hashable {
    public var row: Int
    public var column: Int
    public var colSpan: Int
    public var text: String
    /// Token rectangles grouped per line, in display space.
    public var rects: [CGRect]
    public var score: Double?
    public var flags: [String]
}

public struct LayoutGrid: Sendable, Hashable {
    public var rowCount: Int
    public var columnCount: Int
    public var cells: [LayoutCell]
    public var headerRowCount: Int
    public var columnBounds: [ClosedRange<Double>]
    public var rowBounds: [ClosedRange<Double>]
    public var notes: [String]
}

public struct LayoutOptions: Sendable, Hashable {
    public var mergeContinuationLines: Bool
    public init(mergeContinuationLines: Bool = true) {
        self.mergeContinuationLines = mergeContinuationLines
    }
}

/// Deterministic table structure inference from positioned words. Columns come from ruling lines
/// when the table has a grid, otherwise from vertical whitespace shared by the body lines.
public enum LayoutAnalyzer {
    public static let version = "1.0"

    struct Line {
        var tokens: [LayoutToken]
        var minY: Double
        var maxY: Double
        var midY: Double { (minY + maxY) / 2 }
        var height: Double { maxY - minY }
    }

    public static func groupLines(_ tokens: [LayoutToken]) -> [[LayoutToken]] {
        buildLines(tokens).map(\.tokens)
    }

    static func buildLines(_ tokens: [LayoutToken]) -> [Line] {
        let sorted = tokens.sorted { $0.rect.midY > $1.rect.midY }
        var lines: [Line] = []
        for t in sorted {
            let tMin = Double(t.rect.minY), tMax = Double(t.rect.maxY)
            var best: (Int, Double)?
            for (i, line) in lines.enumerated().reversed() {
                if line.minY > tMax + 50 { break }
                let overlap = min(line.maxY, tMax) - max(line.minY, tMin)
                let ratio = overlap / max(0.1, min(line.height, tMax - tMin))
                if ratio >= 0.5, ratio > (best?.1 ?? 0) { best = (i, ratio) }
            }
            if let (i, _) = best {
                lines[i].tokens.append(t)
                lines[i].minY = min(lines[i].minY, tMin)
                lines[i].maxY = max(lines[i].maxY, tMax)
            } else {
                lines.append(Line(tokens: [t], minY: tMin, maxY: tMax))
            }
        }
        for i in lines.indices { lines[i].tokens.sort { $0.rect.minX < $1.rect.minX } }
        return lines.sorted { $0.midY > $1.midY }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func looksNumeric(_ text: String) -> Bool {
        let t = ValueNormalizer.splitFootnote(text).value
        return !NumberParsing.interpretations(t).isEmpty
    }

    public static func analyze(tokens: [LayoutToken], region: CGRect, rules: RuleLines = .none,
                               options: LayoutOptions = LayoutOptions()) -> LayoutGrid {
        var notes: [String] = []
        let inside = tokens.filter { region.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        let lines = buildLines(inside)
        guard !lines.isEmpty else {
            return LayoutGrid(rowCount: 0, columnCount: 0, cells: [], headerRowCount: 0, columnBounds: [],
                              rowBounds: [], notes: ["No text was found in the selected region."])
        }
        let medianHeight = max(1, median(lines.flatMap { $0.tokens.map { Double($0.rect.height) } }))

        // Columns.
        let minX = Double(region.minX), maxX = Double(region.maxX)
        let internalVertical = rules.vertical.filter { $0 > minX + 3 && $0 < maxX - 3 }.sorted()
        var separators: [Double]
        if internalVertical.count >= 2 {
            separators = dedupe(internalVertical, tolerance: 3)
            notes.append("Columns follow \(separators.count) vertical ruling lines.")
        } else {
            separators = whitespaceSeparators(lines: lines, minX: minX, maxX: maxX, medianHeight: medianHeight)
            if !internalVertical.isEmpty {
                separators = dedupe((separators + internalVertical).sorted(), tolerance: medianHeight)
            }
            notes.append("Columns inferred from aligned whitespace.")
        }
        var bounds: [ClosedRange<Double>] = []
        var edges = [minX] + separators + [maxX]
        edges = edges.sorted()
        for i in 0..<(edges.count - 1) where edges[i + 1] > edges[i] {
            bounds.append(edges[i]...edges[i + 1])
        }

        // Assign tokens to columns.
        struct Placed { var token: LayoutToken; var column: Int; var span: Int; var crossed: Bool }
        func place(_ t: LayoutToken) -> Placed {
            let a = Double(t.rect.minX), b = Double(t.rect.maxX), w = max(0.1, b - a)
            var overlaps: [(Int, Double)] = []
            for (i, r) in bounds.enumerated() {
                let o = min(b, r.upperBound) - max(a, r.lowerBound)
                if o > 0 { overlaps.append((i, o)) }
            }
            guard let primary = overlaps.max(by: { $0.1 < $1.1 }) else {
                let mid = (a + b) / 2
                let nearest = bounds.enumerated().min { abs(($0.1.lowerBound + $0.1.upperBound) / 2 - mid) < abs(($1.1.lowerBound + $1.1.upperBound) / 2 - mid) }
                return Placed(token: t, column: nearest?.0 ?? 0, span: 1, crossed: true)
            }
            let significant = overlaps.filter { $0.1 >= 0.2 * w && $0.1 > medianHeight * 0.4 }
            if significant.count >= 2 {
                let first = significant.map(\.0).min()!, last = significant.map(\.0).max()!
                return Placed(token: t, column: first, span: last - first + 1, crossed: true)
            }
            return Placed(token: t, column: primary.0, span: 1, crossed: false)
        }

        // Rows.
        let internalHorizontal = rules.horizontal.filter { $0 > Double(region.minY) + 2 && $0 < Double(region.maxY) - 2 }.sorted(by: >)
        var rowLines: [[Line]] = []
        var mergedRowFlags: [Bool] = []
        let useHorizontalRules = internalHorizontal.count >= 2 && Double(internalHorizontal.count) >= Double(lines.count) * 0.45
        if useHorizontalRules {
            let ys = [Double(region.maxY)] + dedupe(internalHorizontal.sorted(), tolerance: 2).sorted(by: >) + [Double(region.minY)]
            for i in 0..<(ys.count - 1) {
                let band = lines.filter { $0.midY <= ys[i] && $0.midY > ys[i + 1] }
                if !band.isEmpty {
                    rowLines.append(band)
                    mergedRowFlags.append(band.count > 1)
                }
            }
            notes.append("Rows follow horizontal ruling lines.")
        } else {
            let pitch = median(zip(lines, lines.dropFirst()).map { $0.minY - $1.maxY })
            for line in lines {
                if options.mergeContinuationLines, let previous = rowLines.last?.last,
                   isContinuation(line, previous: previous, rowLines: rowLines.last!, bounds: bounds, place: { place($0).column },
                                  medianHeight: medianHeight, pitch: pitch) {
                    rowLines[rowLines.count - 1].append(line)
                    mergedRowFlags[mergedRowFlags.count - 1] = true
                } else {
                    rowLines.append([line])
                    mergedRowFlags.append(false)
                }
            }
        }

        // Build the grid.
        var grid: [[[Placed]]] = Array(repeating: Array(repeating: [], count: bounds.count), count: rowLines.count)
        var spanCells: [Int: [Int: Int]] = [:]
        for (r, band) in rowLines.enumerated() {
            for line in band {
                for t in line.tokens {
                    let p = place(t)
                    grid[r][p.column].append(p)
                    if p.span > 1 { spanCells[r, default: [:]][p.column] = max(spanCells[r]?[p.column] ?? 1, p.span) }
                }
            }
        }

        // Drop columns with no text at all.
        let usedColumns = (0..<bounds.count).filter { c in grid.contains { !$0[c].isEmpty } }
        if usedColumns.count < bounds.count {
            let remap = Dictionary(uniqueKeysWithValues: usedColumns.enumerated().map { ($1, $0) })
            bounds = usedColumns.map { bounds[$0] }
            grid = grid.map { row in usedColumns.map { row[$0] } }
            var newSpans: [Int: [Int: Int]] = [:]
            for (r, m) in spanCells {
                for (c, s) in m {
                    if let nc = remap[c] {
                        let last = (c..<(c + s)).compactMap { remap[$0] }.max() ?? nc
                        newSpans[r, default: [:]][nc] = last - nc + 1
                    }
                }
            }
            spanCells = newSpans
        }

        let headerRows = detectHeaderRows(grid: grid.map { row in row.map { $0.map(\.token.text).joined(separator: " ") } },
                                          rules: useHorizontalRules ? [] : internalHorizontal, rowLines: rowLines,
                                          spanRows: Set(spanCells.filter { $0.value.values.contains { $0 > 1 } }.keys))

        // A header aligned differently from its values can form a column of its own. Merge a
        // header-only column into an adjacent data-only column.
        if headerRows > 0 && internalVertical.count < 2 {
            var c = 0
            while c < bounds.count {
                let headerOnly = (0..<grid.count).allSatisfy { r in r < headerRows ? true : grid[r][c].isEmpty }
                    && (0..<headerRows).contains { !grid[$0][c].isEmpty }
                func dataOnly(_ k: Int) -> Bool {
                    k >= 0 && k < bounds.count && (0..<headerRows).allSatisfy { grid[$0][k].isEmpty }
                        && (headerRows..<grid.count).contains { !grid[$0][k].isEmpty }
                }
                if headerOnly, let target = [c + 1, c - 1].first(where: dataOnly) {
                    let lo = min(c, target), hi = max(c, target)
                    bounds[lo] = min(bounds[lo].lowerBound, bounds[hi].lowerBound)...max(bounds[lo].upperBound, bounds[hi].upperBound)
                    bounds.remove(at: hi)
                    for r in grid.indices {
                        grid[r][lo] += grid[r][hi]
                        grid[r].remove(at: hi)
                    }
                    var newSpans: [Int: [Int: Int]] = [:]
                    for (r, m) in spanCells {
                        for (k, s) in m { newSpans[r, default: [:]][k > hi ? k - 1 : k] = k < hi && k + s > hi ? s - 1 : s }
                    }
                    spanCells = newSpans
                    notes.append("Merged a header-only column with the values below it.")
                    c = lo + 1
                } else {
                    c += 1
                }
            }
        }

        var cells: [LayoutCell] = []
        for r in 0..<grid.count {
            var c = 0
            while c < bounds.count {
                let isHeader = r < headerRows
                var span = spanCells[r]?[c] ?? 1
                if !isHeader && span > 1 {
                    // In data rows a crossing token stays in its anchor column and is flagged.
                    span = 1
                }
                span = min(span, bounds.count - c)
                var placed: [Placed] = []
                for k in c..<(c + span) { placed += grid[r][k] }
                let crossed = placed.contains { $0.crossed }
                let ordered = placed.sorted {
                    abs($0.token.rect.midY - $1.token.rect.midY) > medianHeight * 0.5
                        ? $0.token.rect.midY > $1.token.rect.midY
                        : $0.token.rect.minX < $1.token.rect.minX
                }
                let text = joinTokens(ordered.map(\.token), medianHeight: medianHeight)
                let rects = lineRects(ordered.map(\.token), medianHeight: medianHeight)
                let scores = ordered.compactMap(\.token.score)
                var flags: [String] = []
                if mergedRowFlags[r] && !useHorizontalRules && Set(ordered.map { Int($0.token.rect.midY / max(1, medianHeight * 0.5)) }).count > 1 {
                    flags.append(CellFlag.continuationMerged)
                }
                if span > 1 { flags.append(CellFlag.spansColumns) }
                if crossed && span == 1 && !isHeader { flags.append(CellFlag.outsideColumns) }
                cells.append(LayoutCell(row: r, column: c, colSpan: span, text: text, rects: rects,
                                        score: scores.min(), flags: flags))
                c += span
            }
        }

        let rowBounds = rowLines.map { band in (band.map(\.minY).min() ?? 0)...(band.map(\.maxY).max() ?? 0) }
        return LayoutGrid(rowCount: rowLines.count, columnCount: bounds.count, cells: cells, headerRowCount: headerRows,
                          columnBounds: bounds, rowBounds: rowBounds, notes: notes)
    }

    static func dedupe(_ xs: [Double], tolerance: Double) -> [Double] {
        var out: [Double] = []
        for x in xs.sorted() {
            if let last = out.last, x - last < tolerance { out[out.count - 1] = (last + x) / 2 } else { out.append(x) }
        }
        return out
    }

    /// Finds x positions crossed by no body-line token, with a minimum gap width.
    static func whitespaceSeparators(lines: [Line], minX: Double, maxX: Double, medianHeight: Double) -> [Double] {
        let width = maxX - minX
        guard width > 1 else { return [] }
        var body = lines.filter { $0.tokens.count >= 2 }
        if body.count < 2 { body = lines }
        let wideLimit = width * 0.5
        let step = 0.5
        let n = Int(width / step) + 1
        var coverage = [Int](repeating: 0, count: n)
        var bodyTokens: [LayoutToken] = []
        for line in body {
            var marked = [Bool](repeating: false, count: n)
            for t in line.tokens where Double(t.rect.width) < wideLimit {
                bodyTokens.append(t)
                let a = max(0, Int((Double(t.rect.minX) - minX) / step))
                let b = min(n - 1, Int((Double(t.rect.maxX) - minX) / step))
                if a <= b { for i in a...b { marked[i] = true } }
            }
            for i in 0..<n where marked[i] { coverage[i] += 1 }
        }
        let tolerance = body.count >= 12 ? Int(Double(body.count) * 0.06) : 0
        let minGap = max(3.0, 0.6 * medianHeight)

        // Runs of low coverage.
        var runs: [(Double, Double)] = []
        var i = 0
        while i < n {
            if coverage[i] <= tolerance {
                let start = i
                while i < n && coverage[i] <= tolerance { i += 1 }
                runs.append((minX + Double(start) * step, minX + Double(i - 1) * step))
            } else {
                i += 1
            }
        }
        var separators: [Double] = []
        let firstText = bodyTokens.map { Double($0.rect.minX) }.min() ?? minX
        let lastText = bodyTokens.map { Double($0.rect.maxX) }.max() ?? maxX
        for (a, b) in runs {
            // Ignore margins before the first and after the last text.
            guard a > firstText, b < lastText else { continue }
            // Tokens fully inside a tolerated run form their own column.
            let islands = bodyTokens.filter { Double($0.rect.minX) >= a + minGap / 2 && Double($0.rect.maxX) <= b - minGap / 2 }
                .map { (Double($0.rect.minX), Double($0.rect.maxX)) }.sorted { $0.0 < $1.0 }
            var merged: [(Double, Double)] = []
            for iv in islands {
                if let last = merged.last, iv.0 <= last.1 + minGap { merged[merged.count - 1].1 = max(last.1, iv.1) } else { merged.append(iv) }
            }
            var cursor = a
            for iv in merged + [(b, b)] {
                let gapEnd = iv.0
                if gapEnd - cursor >= minGap { separators.append((cursor + gapEnd) / 2) }
                cursor = iv.1
            }
        }
        return separators
    }

    static func isContinuation(_ line: Line, previous: Line, rowLines: [Line], bounds: [ClosedRange<Double>],
                               place: (LayoutToken) -> Int, medianHeight: Double, pitch: Double) -> Bool {
        guard bounds.count >= 2 else { return false }
        let columns = Set(line.tokens.map(place))
        guard !columns.contains(0) else { return false }
        guard !line.tokens.contains(where: { looksNumeric($0.text) }) else { return false }
        let gap = previous.minY - line.maxY
        guard gap <= max(medianHeight * 0.6, pitch * 0.9) else { return false }
        if pitch > 0, gap > pitch * 0.9 + 0.5 { return false }
        let previousColumns = Set(rowLines.flatMap { $0.tokens.map(place) })
        guard previousColumns.contains(0) || rowLines.count > 1 else { return false }
        return columns.isSubset(of: previousColumns)
    }

    static func isYear(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count == 4 && t.allSatisfy(\.isASCIIDigit) && (1900...2100).contains(Int(t) ?? 0)
    }

    /// Counts leading header rows by comparing each top row with the dominant cell types of the
    /// table body. Rows containing spanning cells are headers.
    static func detectHeaderRows(grid: [[String]], rules: [Double], rowLines: [[Line]], spanRows: Set<Int> = []) -> Int {
        guard grid.count > 1, let width = grid.map(\.count).max(), width > 0 else { return 0 }
        func cell(_ r: Int, _ c: Int) -> String { c < grid[r].count ? grid[r][c].trimmingCharacters(in: .whitespaces) : "" }
        let missing = Set(TableSettings.defaultMissingTokens)
        let bodyStart = min(grid.count - 1, max(1, grid.count / 3))
        var numericColumns: [Int] = []
        var yearColumns = Set<Int>()
        for c in 0..<width {
            let values = (bodyStart..<grid.count).map { cell($0, c) }.filter { !$0.isEmpty && !missing.contains($0) }
            guard !values.isEmpty else { continue }
            let numeric = values.filter(looksNumeric).count
            if Double(numeric) / Double(values.count) >= 0.7 { numericColumns.append(c) }
            if Double(values.filter(isYear).count) / Double(values.count) >= 0.7 { yearColumns.insert(c) }
        }
        guard !numericColumns.isEmpty else { return 1 }

        func isHeader(_ r: Int) -> Bool {
            if spanRows.contains(r) { return true }
            var judged = 0, headerLike = 0
            for c in numericColumns {
                let t = cell(r, c)
                if t.isEmpty || missing.contains(t) { continue }
                judged += 1
                if !looksNumeric(t) || (isYear(t) && !yearColumns.contains(c)) { headerLike += 1 }
            }
            if judged == 0 {
                // Only text in non-numeric columns: a header when the body is mostly filled.
                return (0..<width).contains { !cell(r, $0).isEmpty }
            }
            return Double(headerLike) / Double(judged) >= 0.5
        }
        var count = 0
        for r in 0..<min(4, grid.count - 1) {
            if !isHeader(r) { break }
            count += 1
        }
        // A header rule below the first lines confirms or limits the header block.
        if rules.count >= 1, let ruleY = rules.sorted(by: >).first(where: { y in rowLines.first.map { $0.map(\.minY).min()! > y } ?? false }) {
            let above = rowLines.prefix { band in band.map(\.minY).min()! > ruleY }.count
            if above > 0 && above <= 3 && rowLines.count > above { return above }
        }
        return min(count, 3)
    }

    static func joinTokens(_ tokens: [LayoutToken], medianHeight: Double) -> String {
        var out = ""
        var previous: LayoutToken?
        for t in tokens {
            if let p = previous {
                let sameLine = abs(p.rect.midY - t.rect.midY) < medianHeight * 0.5
                if sameLine && Double(t.rect.minX - p.rect.maxX) < medianHeight * 0.05 && p.text.last == "-" {
                    // Keep hyphenated tokens joined only when they touch.
                } else {
                    out += " "
                }
            }
            out += t.text
            previous = t
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Unions token rectangles per line so a cell keeps one region per text line.
    static func lineRects(_ tokens: [LayoutToken], medianHeight: Double) -> [CGRect] {
        var rects: [CGRect] = []
        for t in tokens {
            if let i = rects.firstIndex(where: { abs($0.midY - t.rect.midY) < medianHeight * 0.5 && t.rect.minX - $0.maxX < medianHeight * 1.5 }) {
                rects[i] = rects[i].union(t.rect)
            } else {
                rects.append(t.rect)
            }
        }
        return rects
    }
}

/// Detects table ruling lines in a grayscale raster of a region.
public enum RuleLineDetector {
    /// `pixels` is a top-down 8-bit grayscale buffer. `origin` is the display-space point of the
    /// lower-left corner of the raster and `scale` is pixels per point.
    public static func detect(pixels: [UInt8], width: Int, height: Int, origin: CGPoint, scale: Double,
                              threshold: UInt8 = 150, minimumFraction: Double = 0.35) -> RuleLines {
        guard width > 4, height > 4 else { return .none }
        let maxGapPixels = max(1, Int(scale * 1.0))
        let maxThickness = max(3, Int(scale * 3.0))

        func longestRun(_ count: Int, _ dark: (Int) -> Bool) -> Int {
            var best = 0, current = 0, gap = 0
            for i in 0..<count {
                if dark(i) {
                    current += 1 + gap
                    gap = 0
                    best = max(best, current)
                } else if current > 0 {
                    gap += 1
                    if gap > maxGapPixels { current = 0; gap = 0 }
                }
            }
            return best
        }

        var rowHits: [Bool] = []
        for y in 0..<height {
            let base = y * width
            rowHits.append(Double(longestRun(width) { pixels[base + $0] < threshold }) >= Double(width) * minimumFraction)
        }
        var columnHits: [Bool] = []
        for x in 0..<width {
            columnHits.append(Double(longestRun(height) { pixels[$0 * width + x] < threshold }) >= Double(height) * minimumFraction)
        }

        func centers(_ hits: [Bool]) -> [Double] {
            var out: [Double] = []
            var i = 0
            while i < hits.count {
                if hits[i] {
                    let start = i
                    while i < hits.count && hits[i] { i += 1 }
                    if i - start <= maxThickness { out.append(Double(start + i - 1) / 2) }
                } else {
                    i += 1
                }
            }
            return out
        }

        let horizontal = centers(rowHits).map { Double(origin.y) + (Double(height) - 0.5 - $0) / scale }
        let vertical = centers(columnHits).map { Double(origin.x) + ($0 + 0.5) / scale }
        return RuleLines(horizontal: horizontal, vertical: vertical)
    }
}
