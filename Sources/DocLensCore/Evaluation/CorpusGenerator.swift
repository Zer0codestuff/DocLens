import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

/// Ground truth for one annotated table in the evaluation corpus.
public struct TruthTable: Codable, Sendable {
    public var segments: [TableSegment]
    public var headerRows: Int
    /// Text per row and column, header rows first. Covered span positions are empty.
    public var cells: [[String]]
    /// Cell boxes in page space, matching `cells`. Nil where the cell is empty.
    public var cellRects: [[PageRect?]]
    public var cellPages: [[Int]]
    public var spans: [[Int]]
    public var numberFormat: NumberFormat
    public var columnTypes: [ColumnType]
}

public struct TruthDocument: Codable, Sendable {
    public var document: String
    public var description: String
    public var tags: [String]
    public var scanned: Bool
    public var tables: [TruthTable]
}

public enum CorpusGenerator {
    public enum Style: Sendable { case grid, booktabs, borderless, zebra }

    public struct Spec: Sendable {
        var name: String
        var description: String
        var tags: [String]
        var title: String?
        var header: [[String]]
        /// Column spans for header cells: (row, column, span).
        var headerSpans: [(Int, Int, Int)] = []
        var rows: [[String]]
        var widths: [Double]
        var rightAligned: Set<Int>
        var style: Style
        var fontSize: Double = 9
        var rowHeight: Double? = nil
        var numberFormat: NumberFormat
        var types: [ColumnType]
        var rotation: Int = 0
        var landscape: Bool = false
        var rowsPerPage: Int? = nil
        var repeatHeader: Bool = true
        var wrapColumn: Int? = nil
    }

    // MARK: Drawing helpers

    static func font(_ size: Double, bold: Bool = false) -> CTFont {
        CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    static func line(_ text: String, size: Double, bold: Bool) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    static func width(_ text: String, size: Double, bold: Bool) -> Double {
        Double(CTLineGetTypographicBounds(line(text, size: size, bold: bold), nil, nil, nil))
    }

    static func draw(_ text: String, ctx: CGContext, x: Double, baseline: Double, size: Double, bold: Bool) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line(text, size: size, bold: bold), ctx)
    }

    /// Splits text into lines that fit `width`.
    static func wrap(_ text: String, width: Double, size: Double) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if Self.width(candidate, size: size, bold: false) > width && !current.isEmpty {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: Generation

    /// Draws a table spec into a PDF and returns its ground truth.
    static func render(_ spec: Spec, to url: URL) throws -> TruthDocument {
        let pageSize = spec.landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        // Media box is portrait when rotated so that the displayed page matches `pageSize`.
        let media = spec.rotation == 90 || spec.rotation == 270
            ? CGRect(x: 0, y: 0, width: pageSize.height, height: pageSize.width)
            : CGRect(origin: .zero, size: pageSize)
        let geometry = PageGeometry(mediaBox: PageRect(media), cropBox: PageRect(media), rotation: spec.rotation)
        var mediaBox = media
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw PDFSupportError.renderFailed }

        let size = spec.fontSize
        let rowHeight = spec.rowHeight ?? size * 1.9
        let pad = 4.0
        let x0 = 54.0
        let tableWidth = spec.widths.reduce(0, +)
        let pages: [[[String]]] = {
            guard let n = spec.rowsPerPage else { return [spec.rows] }
            return stride(from: 0, to: spec.rows.count, by: n).map { Array(spec.rows[$0..<min($0 + n, spec.rows.count)]) }
        }()

        var truthCells: [[String]] = []
        var truthRects: [[PageRect?]] = []
        var truthPages: [[Int]] = []
        var spans: [[Int]] = []
        var segments: [TableSegment] = []

        for (p, pageRows) in pages.enumerated() {
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: media)] as CFDictionary)
            ctx.saveGState()
            ctx.concatenate(geometry.displayToPage())
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            var y = Double(pageSize.height) - 60
            if let title = spec.title, p == 0 {
                draw(title, ctx: ctx, x: x0, baseline: y, size: size + 3, bold: true)
                y -= (size + 3) * 2.2
            }
            let tableTop = y
            let headerRows = (p == 0 || spec.repeatHeader) ? spec.header : []
            var allRows: [(cells: [String], header: Bool, headerIndex: Int)] = headerRows.enumerated().map { ($1, true, $0) }
            allRows += pageRows.map { ($0, false, -1) }

            var rowTops: [Double] = []
            var cursor = tableTop
            for (ri, row) in allRows.enumerated() {
                var lineCount = 1
                if let wc = spec.wrapColumn, !row.header {
                    lineCount = max(1, wrap(row.cells[wc], width: spec.widths[wc] - 2 * pad, size: size).count)
                }
                let h = rowHeight + Double(lineCount - 1) * size * 1.15
                rowTops.append(cursor)
                if spec.style == .zebra && !row.header && ri % 2 == 0 {
                    ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
                    ctx.fill(CGRect(x: x0, y: cursor - h, width: tableWidth, height: h))
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                }
                var cx = x0
                var c = 0
                var rowCells: [String] = Array(repeating: "", count: spec.widths.count)
                var rowRects: [PageRect?] = Array(repeating: nil, count: spec.widths.count)
                var rowSpans: [Int] = Array(repeating: 1, count: spec.widths.count)
                while c < spec.widths.count {
                    var span = 1
                    if row.header, let s = spec.headerSpans.first(where: { $0.0 == row.headerIndex && $0.1 == c }) { span = s.2 }
                    let w = spec.widths[c..<(c + span)].reduce(0, +)
                    let text = c < row.cells.count ? row.cells[c] : ""
                    let bold = row.header
                    let baseline = cursor - rowHeight / 2 - size * 0.35
                    var lines = [text]
                    if let wc = spec.wrapColumn, wc == c, !row.header { lines = wrap(text, width: w - 2 * pad, size: size) }
                    for (li, l) in lines.enumerated() {
                        let tw = width(l, size: size, bold: bold)
                        let tx: Double
                        if row.header && span > 1 { tx = cx + (w - tw) / 2 } else if spec.rightAligned.contains(c) && !row.header { tx = cx + w - pad - tw } else { tx = cx + pad }
                        draw(l, ctx: ctx, x: tx, baseline: baseline - Double(li) * size * 1.15, size: size, bold: bold)
                    }
                    rowCells[c] = text
                    rowSpans[c] = span
                    if !text.isEmpty {
                        rowRects[c] = geometry.toPage(CGRect(x: cx, y: cursor - h, width: w, height: h))
                    }
                    cx += w
                    c += span
                }
                // Header rows on later pages are repeated headers; the truth keeps only the first.
                if !(row.header && p > 0) {
                    truthCells.append(rowCells)
                    truthRects.append(rowRects)
                    truthPages.append(Array(repeating: p, count: rowCells.count))
                    spans.append(rowSpans)
                }
                cursor -= h
            }
            let tableBottom = cursor

            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            switch spec.style {
            case .grid:
                ctx.setLineWidth(0.6)
                for t in rowTops + [tableBottom] {
                    ctx.move(to: CGPoint(x: x0, y: t)); ctx.addLine(to: CGPoint(x: x0 + tableWidth, y: t))
                }
                let bottoms = Array(rowTops.dropFirst()) + [tableBottom]
                for (ri, top) in rowTops.enumerated() {
                    var vx = x0
                    var spanInterior = Set<Int>()
                    if allRows[ri].header {
                        for s in spec.headerSpans where s.0 == allRows[ri].headerIndex {
                            for k in (s.1 + 1)..<(s.1 + s.2) { spanInterior.insert(k) }
                        }
                    }
                    for (bi, w) in ([0] + spec.widths).enumerated() {
                        vx += w
                        if spanInterior.contains(bi) { continue }
                        ctx.move(to: CGPoint(x: vx, y: top)); ctx.addLine(to: CGPoint(x: vx, y: bottoms[ri]))
                    }
                }
                ctx.strokePath()
            case .booktabs:
                ctx.setLineWidth(1.0)
                let headerBottom = headerRows.isEmpty ? tableTop : rowTops[headerRows.count]
                for t in [tableTop, headerBottom, tableBottom] {
                    ctx.move(to: CGPoint(x: x0, y: t)); ctx.addLine(to: CGPoint(x: x0 + tableWidth, y: t))
                }
                ctx.strokePath()
            case .borderless, .zebra:
                break
            }
            ctx.restoreGState()
            ctx.endPDFPage()

            let display = CGRect(x: x0 - 6, y: tableBottom - 6, width: tableWidth + 12, height: tableTop - tableBottom + 12)
            segments.append(TableSegment(pageIndex: p, region: geometry.toPage(display)))
        }
        ctx.closePDF()

        return TruthDocument(
            document: url.lastPathComponent, description: spec.description, tags: spec.tags, scanned: false,
            tables: [TruthTable(segments: segments, headerRows: spec.header.count, cells: truthCells, cellRects: truthRects,
                                cellPages: truthPages, spans: spans, numberFormat: spec.numberFormat, columnTypes: spec.types)])
    }

    /// Rasterizes every page and writes an image-only PDF, simulating a scan.
    static func scan(source: URL, to url: URL, dpi: Double, noise: Double, seed: UInt64) throws {
        let doc = try PDFSupport.open(source)
        var generator = SplitMix(seed: seed)
        guard let firstPage = doc.page(at: 0) else { return }
        var mediaBox = firstPage.bounds(for: .mediaBox)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw PDFSupportError.renderFailed }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let geometry = PDFSupport.geometry(of: page)
            let scale = dpi / 72
            let (image, _, _) = try PDFSupport.render(page: page, region: nil, scale: scale, grayscale: true)
            let w = image.width, h = image.height
            var pixels = [UInt8](repeating: 255, count: w * h)
            pixels.withUnsafeMutableBytes { buf in
                let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for k in 0..<pixels.count {
                let n = (generator.nextDouble() - 0.5) * 2 * noise * 255
                var v = Double(pixels[k]) * 0.92 + 255 * 0.06 + n
                if generator.nextDouble() < 0.0008 { v = 40 }
                pixels[k] = UInt8(max(0, min(255, v)))
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let noisy = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            var box = page.bounds(for: .mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: box)] as CFDictionary)
            ctx.saveGState()
            ctx.concatenate(geometry.displayToPage())
            let display = geometry.displaySize
            ctx.draw(noisy, in: CGRect(origin: .zero, size: display))
            ctx.restoreGState()
            ctx.endPDFPage()
            box = .zero
        }
        ctx.closePDF()
    }

    /// Applies `/Rotate` values, which Core Graphics PDF contexts cannot write directly.
    static func setRotation(_ rotation: Int, url: URL) throws {
        guard rotation != 0 else { return }
        let doc = try PDFSupport.open(url)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotation }
        guard doc.write(to: url) else { throw PDFSupportError.renderFailed }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    // MARK: Corpus

    public static var specs: [Spec] {
        let countries = [
            ["Austria", "9,104,772", "83,879", "108.5", "1.2"], ["Belgium", "11,763,650", "30,688", "383.3", "0.6"],
            ["Croatia", "3,850,894", "56,594", "68.0", "-0.3"], ["Denmark", "5,932,654", "42,933", "138.2", "0.8"],
            ["Finland", "5,563,970", "338,455", "16.4", "0.3"], ["France", "68,401,997", "632,734", "108.1", "0.3"],
            ["Germany", "84,358,845", "357,588", "235.9", "0.4"], ["Greece", "10,413,982", "131,957", "78.9", "-0.4"],
            ["Ireland", "5,271,395", "69,825", "75.5", "1.9"], ["Italy", "58,989,749", "302,068", "195.3", "-0.1"],
            ["Portugal", "10,467,366", "92,227", "113.5", "1.1"], ["Spain", "48,059,777", "505,983", "95.0", "1.0"],
        ]
        let comuni = [
            ["001272", "Torino", "848.885", "130,01", "6.529,4"], ["015146", "Milano", "1.354.196", "181,67", "7.454,3"],
            ["027042", "Venezia", "250.369", "415,90", "602,0"], ["037006", "Bologna", "387.971", "140,86", "2.754,3"],
            ["048017", "Firenze", "360.930", "102,32", "3.527,5"], ["058091", "Roma", "2.754.719", "1.287,36", "2.139,8"],
            ["063049", "Napoli", "913.462", "119,02", "7.674,9"], ["072006", "Bari", "316.015", "117,39", "2.692,0"],
            ["082053", "Palermo", "630.828", "160,59", "3.928,1"], ["092009", "Cagliari", "148.117", "85,01", "1.742,3"],
            ["010025", "Genova", "558.745", "240,29", "2.325,3"], ["083048", "Messina", "218.786", "213,75", "1.023,6"],
        ]
        let missing = [
            ["North", "1,204", "-", "12.5*", "0"], ["North-East", "877", "..", "9.8", "3"],
            ["Centre", "1,031", "512", "", "0"], ["South", "-", "640", "11.2", "7"],
            ["Islands", "455", "..", "8.4*", "-"], ["Abroad", "0", "0", "0.0", "0"],
            ["Unknown", "..", "-", "", ".."], ["Total", "3,567", "1,152", "41.9", "10"],
        ]
        let finance = [
            ["Revenue", "€ 1,250,400.00", "€ 1,118,750.50", "11.8%"], ["Cost of sales", "(612,300.25)", "(590,100.00)", "3.8%"],
            ["Gross profit", "638,099.75", "528,650.50", "20.7%"], ["Operating expenses", "(402,775.10)", "(388,240.80)", "3.7%"],
            ["Other income", "12,450.00", "(2,110.40)", "-689.9%"], ["Operating profit", "247,774.65", "138,299.30", "79.2%"],
        ]
        var dense: [[String]] = []
        let places = ["Ancona", "Bergamo", "Como", "Lecce", "Parma", "Pisa", "Siena", "Trento", "Udine", "Varese"]
        for i in 0..<36 {
            let day = (i * 7) % 28 + 1, month = (i % 12) + 1
            dense.append([String(format: "%03d", i + 1), String(format: "%02d/%02d/2026", day, month), places[i % places.count],
                          String(format: "%d", 100 + (i * 37) % 900), String(format: "%.2f", Double((i * 131) % 1000) / 7.0),
                          i % 5 == 0 ? "-" : String(format: "%.1f", Double((i * 17) % 100) / 3.0), i % 3 == 0 ? "A" : "B"])
        }
        var long: [[String]] = []
        for i in 0..<46 {
            long.append([String(format: "R%02d", i + 1), "Item \(i + 1)", String(1000 + i * 23), String(format: "%.2f", Double(i) * 1.25 + 3)])
        }
        let quarterly = [
            ["Lombardia", "1,204", "1,311", "1,280", "1,402"], ["Lazio", "988", "1,021", "1,005", "1,117"],
            ["Campania", "755", "790", "802", "811"], ["Veneto", "702", "699", "731", "760"],
            ["Piemonte", "611", "640", "652", "648"], ["Sicilia", "590", "602", "611", "633"],
        ]
        let wrapped = [
            ["A-100", "Hydraulic pump with reinforced housing and stainless steel shaft", "12", "1,240.00"],
            ["A-101", "Seal kit", "40", "18.50"],
            ["B-210", "Pressure sensor, 0 to 250 bar, with calibration certificate", "6", "389.90"],
            ["B-211", "Cable harness", "25", "22.00"],
            ["C-300", "Control unit firmware license for one installation site", "3", "1,500.00"],
            ["C-301", "Mounting bracket", "18", "9.75"],
        ]
        let french = [
            ["Ain", "01", "657 856", "5 762,4", "114,2"], ["Aisne", "02", "525 503", "7 361,7", "71,4"],
            ["Allier", "03", "334 872", "7 340,1", "45,6"], ["Ardèche", "07", "330 069", "5 528,6", "59,7"],
            ["Aube", "10", "310 242", "6 004,0", "51,7"], ["Cantal", "15", "143 692", "5 726,0", "25,1"],
            ["Corrèze", "19", "239 470", "5 856,8", "40,9"], ["Doubs", "25", "546 157", "5 233,7", "104,4"],
        ]

        return [
            Spec(name: "01-grid-point-decimal", description: "Digital PDF, full grid, point decimals with comma grouping.",
                 tags: ["digital", "grid", "point-decimal"], title: "Table 1. Population and area, 2024",
                 header: [["Country", "Population", "Area (km²)", "Density", "Growth (%)"]], rows: countries,
                 widths: [110, 90, 90, 70, 75], rightAligned: [1, 2, 3, 4], style: .grid, numberFormat: .pointDecimal,
                 types: [.text, .integer, .integer, .decimal, .decimal]),
            Spec(name: "02-borderless-comma-decimal", description: "Digital PDF, borderless, comma decimals, ISTAT codes with leading zeros.",
                 tags: ["digital", "borderless", "comma-decimal", "leading-zeros"], title: "Tavola 2 - Comuni capoluogo",
                 header: [["Codice ISTAT", "Comune", "Popolazione", "Superficie km²", "Densità"]], rows: comuni,
                 widths: [80, 100, 85, 90, 75], rightAligned: [2, 3, 4], style: .borderless, numberFormat: .commaDecimal,
                 types: [.identifier, .text, .integer, .decimal, .decimal]),
            Spec(name: "03-booktabs-missing-values", description: "Digital PDF, booktabs rules, dashes, '..', empty cells, zeros, footnote markers, total row.",
                 tags: ["digital", "booktabs", "missing-values", "footnotes", "totals"], title: "Table 3. Cases by area",
                 header: [["Area", "Cases", "Recovered", "Rate", "Deaths"]], rows: missing,
                 widths: [100, 70, 80, 60, 60], rightAligned: [1, 2, 3, 4], style: .booktabs, numberFormat: .pointDecimal,
                 types: [.text, .integer, .integer, .decimal, .integer]),
            Spec(name: "04-rotated-landscape", description: "Digital PDF, page with /Rotate 90 and upright landscape content.",
                 tags: ["digital", "rotated", "grid"], title: "Table 4. Rotated page",
                 header: [["Country", "Population", "Area (km²)", "Density", "Growth (%)"]], rows: Array(countries.prefix(8)),
                 widths: [130, 110, 110, 90, 90], rightAligned: [1, 2, 3, 4], style: .grid, numberFormat: .pointDecimal,
                 types: [.text, .integer, .integer, .decimal, .decimal], rotation: 90, landscape: true),
            Spec(name: "05-multipage-repeated-header", description: "Digital PDF, one table across two pages with the header repeated.",
                 tags: ["digital", "multipage", "repeated-header", "zebra"], title: "Table 5. Inventory",
                 header: [["Ref", "Item", "Quantity", "Unit price"]], rows: long,
                 widths: [60, 160, 80, 80], rightAligned: [2, 3], style: .zebra, numberFormat: .pointDecimal,
                 types: [.identifier, .text, .integer, .decimal], rowsPerPage: 28),
            Spec(name: "08-financial-statement", description: "Digital PDF, currency symbols, parentheses negatives, percentages.",
                 tags: ["digital", "borderless", "currency", "negative-parentheses", "percent"], title: "Income statement",
                 header: [["Line item", "2025", "2024", "Change"]], rows: finance,
                 widths: [140, 110, 110, 70], rightAligned: [1, 2, 3], style: .booktabs, numberFormat: .pointDecimal,
                 types: [.text, .currency, .currency, .percent]),
            Spec(name: "09-dense-dates", description: "Digital PDF, 36 rows at 7 pt, zebra stripes, day-first dates.",
                 tags: ["digital", "dense", "dates", "zebra", "leading-zeros"], title: "Register",
                 header: [["No.", "Date", "Place", "Count", "Amount", "Index", "Class"]], rows: dense,
                 widths: [40, 70, 80, 50, 60, 50, 45], rightAligned: [3, 4, 5], style: .zebra, fontSize: 7, numberFormat: .pointDecimal,
                 types: [.identifier, .date, .text, .integer, .decimal, .decimal, .text]),
            Spec(name: "10-spanning-header", description: "Digital PDF, two header rows with column groups spanning two columns.",
                 tags: ["digital", "grid", "spanning-header"], title: "Quarterly registrations",
                 header: [["Region", "2024", "", "2025", ""], ["", "H1", "H2", "H1", "H2"]], headerSpans: [(0, 1, 2), (0, 3, 2)],
                 rows: quarterly, widths: [110, 70, 70, 70, 70], rightAligned: [1, 2, 3, 4], style: .grid, numberFormat: .pointDecimal,
                 types: [.text, .integer, .integer, .integer, .integer]),
            Spec(name: "11-wrapped-cells", description: "Digital PDF, borderless table whose description column wraps onto two lines.",
                 tags: ["digital", "borderless", "wrapped-text"], title: "Order lines",
                 header: [["Code", "Description", "Qty", "Price"]], rows: wrapped,
                 widths: [60, 200, 50, 80], rightAligned: [2, 3], style: .borderless, rowHeight: 24, numberFormat: .pointDecimal,
                 types: [.identifier, .text, .integer, .decimal], wrapColumn: 1),
            Spec(name: "12-space-grouping-french", description: "Digital PDF, space digit grouping and comma decimals, department codes.",
                 tags: ["digital", "grid", "space-grouping", "comma-decimal", "leading-zeros"], title: "Départements",
                 header: [["Département", "Code", "Population", "Superficie", "Densité"]], rows: french,
                 widths: [100, 50, 85, 85, 70], rightAligned: [2, 3, 4], style: .grid, numberFormat: .spaceCommaDecimal,
                 types: [.text, .identifier, .integer, .decimal, .decimal]),
        ]
    }

    /// Generates the corpus and writes `<name>.pdf` and `<name>.truth.json` files.
    @discardableResult
    public static func generate(into directory: URL) throws -> [TruthDocument] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var out: [TruthDocument] = []
        func save(_ truth: TruthDocument, name: String) throws {
            try encoder.encode(truth).write(to: directory.appendingPathComponent("\(name).truth.json"))
            out.append(truth)
        }
        var generated: [String: TruthDocument] = [:]
        for spec in specs {
            let url = directory.appendingPathComponent("\(spec.name).pdf")
            let truth = try render(spec, to: url)
            try setRotation(spec.rotation, url: url)
            generated[spec.name] = truth
            try save(truth, name: spec.name)
        }
        let scans: [(String, String, Double, Double)] = [
            ("06-scanned-grid", "01-grid-point-decimal", 200, 0.06),
            ("07-scanned-borderless", "02-borderless-comma-decimal", 200, 0.08),
            ("13-scanned-low-resolution", "03-booktabs-missing-values", 120, 0.10),
        ]
        for (i, (name, sourceName, dpi, noise)) in scans.enumerated() {
            let source = directory.appendingPathComponent("\(sourceName).pdf")
            let url = directory.appendingPathComponent("\(name).pdf")
            try scan(source: source, to: url, dpi: dpi, noise: noise, seed: UInt64(42 + i))
            guard var truth = generated[sourceName] else { continue }
            truth.document = url.lastPathComponent
            truth.scanned = true
            truth.description = "Scanned copy (\(Int(dpi)) dpi, noise) of \(sourceName). No text layer."
            truth.tags = ["scanned"] + truth.tags.filter { $0 != "digital" }
            try save(truth, name: name)
        }
        return out.sorted { $0.document < $1.document }
    }
}
