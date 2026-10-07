import CoreGraphics
import Foundation
import PDFKit

public enum RecipeBuilder {
    /// Captures the schema, settings, and location hints of a reviewed table.
    public static func make(name: String, from snapshot: TableSnapshot, engine: EngineKind) -> Recipe {
        let columns = snapshot.table.columns.map { c in
            RecipeColumn(name: c.name, type: c.type, unit: c.unit, scale: c.scale, numberFormat: c.numberFormat,
                         aliases: Array(Set([c.sourceHeader, c.name].filter { !$0.isEmpty })).sorted())
        }
        let segment = snapshot.table.segments.first ?? TableSegment(pageIndex: 0, region: PageRect(x: 0, y: 0, width: 0, height: 0))
        let geometry = segment.pageIndex < snapshot.document.pages.count ? snapshot.document.pages[segment.pageIndex] : nil

        // The longest header cell on the first segment is the most distinctive anchor.
        let headerCells = snapshot.headerRowIndexes.prefix(1).flatMap { r in
            snapshot.cells.filter { $0.row == r && !$0.extractedText.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let anchorCell = headerCells.filter { $0.extractedText.count >= 3 && $0.hasSourceRegion }
            .max { $0.extractedText.count < $1.extractedText.count }
        var anchorOffset: PageRect?
        if let anchorCell, let bounds = anchorCell.sources.first?.bounds, let geometry {
            let a = geometry.toDisplay(bounds)
            let r = geometry.toDisplay(segment.region)
            anchorOffset = PageRect(x: r.minX - a.minX, y: r.minY - a.minY, width: r.width, height: r.height)
        }
        var hint = PageRect(x: 0, y: 0, width: 1, height: 1)
        if let geometry {
            let d = geometry.toDisplay(segment.region)
            let size = geometry.displaySize
            hint = PageRect(x: d.minX / size.width, y: d.minY / size.height, width: d.width / size.width, height: d.height / size.height)
        }
        return Recipe(name: name, engine: engine, settings: snapshot.table.settings, columns: columns,
                      headerRowCount: snapshot.headerRowIndexes.count, anchorText: anchorCell?.extractedText ?? "",
                      anchorOffset: anchorOffset, regionHint: hint, pageHint: segment.pageIndex)
    }
}

public struct RecipeLocation: Sendable, Hashable {
    public var segment: TableSegment
    public var method: String
}

public enum RecipeApplier {
    /// Finds the recipe's table in a document: by anchor text when available, otherwise by the
    /// saved relative position. The region is extended down over aligned text lines so tables
    /// that gained rows are not cut off.
    public static func locate(recipe: Recipe, documentURL: URL) throws -> RecipeLocation {
        let doc = try PDFSupport.open(documentURL)
        guard doc.pageCount > 0 else { throw PDFSupportError.pageOutOfRange(0, 0) }

        if !recipe.anchorText.isEmpty, let offset = recipe.anchorOffset {
            let matches = doc.findString(recipe.anchorText, withOptions: [.caseInsensitive])
            let ranked = matches.compactMap { sel -> (PDFPage, CGRect)? in
                guard let page = sel.pages.first else { return nil }
                return (page, sel.bounds(for: page))
            }.sorted { a, b in
                abs(doc.index(for: a.0) - recipe.pageHint) < abs(doc.index(for: b.0) - recipe.pageHint)
            }
            if let (page, bounds) = ranked.first {
                let geometry = PDFSupport.geometry(of: page)
                let a = geometry.toDisplay(PageRect(bounds))
                var display = CGRect(x: a.minX + offset.x, y: a.minY + offset.y, width: offset.width, height: offset.height)
                display = display.intersection(CGRect(origin: .zero, size: geometry.displaySize))
                var region = geometry.toPage(display)
                region = extendDown(page: page, region: region, geometry: geometry)
                return RecipeLocation(segment: TableSegment(pageIndex: doc.index(for: page), region: region), method: "anchor “\(recipe.anchorText)”")
            }
        }
        let pageIndex = min(recipe.pageHint, doc.pageCount - 1)
        guard let page = doc.page(at: pageIndex) else { throw PDFSupportError.pageOutOfRange(pageIndex, doc.pageCount) }
        let geometry = PDFSupport.geometry(of: page)
        let size = geometry.displaySize
        let h = recipe.regionHint
        let display = CGRect(x: h.x * size.width, y: h.y * size.height, width: h.width * size.width, height: h.height * size.height)
        var region = geometry.toPage(display)
        region = extendDown(page: page, region: region, geometry: geometry)
        return RecipeLocation(segment: TableSegment(pageIndex: pageIndex, region: region), method: "saved position")
    }

    /// Locates the table, then snaps the region to the detected table it mostly overlaps. The
    /// saved region has the size of the table the recipe was made from, so on its own it crops
    /// wider tables and overreaches narrower ones.
    public static func locate(recipe: Recipe, documentURL: URL, options: ExtractionOptions) async throws -> RecipeLocation {
        let located = try locate(recipe: recipe, documentURL: documentURL)
        let pageIndex = located.segment.pageIndex
        guard let candidates = try? await VisionDocumentEngine.detectTables(documentURL: documentURL, pageIndex: pageIndex, options: options),
              let candidate = bestCandidate(for: located.segment.region, among: candidates.filter { $0.pageIndex == pageIndex }),
              let page = try PDFSupport.open(documentURL).page(at: pageIndex)
        else { return located }
        let region = extendDown(page: page, region: candidate.region, geometry: PDFSupport.geometry(of: page))
        return RecipeLocation(segment: TableSegment(pageIndex: pageIndex, region: region),
                              method: "\(located.method), fitted to the detected table")
    }

    /// The candidate with the largest overlap, provided the overlap covers at least half of the
    /// smaller of the two regions. Otherwise the located region is kept as saved.
    static func bestCandidate(for region: PageRect, among candidates: [TableCandidate]) -> TableCandidate? {
        candidates
            .map { ($0, $0.region.intersectionArea(region)) }
            .filter { candidate, overlap in overlap > 0 && overlap >= 0.5 * min(candidate.region.area, region.area) }
            .max { $0.1 < $1.1 }?.0
    }

    static func extendDown(page: PDFPage, region: PageRect, geometry: PageGeometry) -> PageRect {
        let display = geometry.toDisplay(region)
        let fullPage = CGRect(origin: .zero, size: geometry.displaySize)
        let below = CGRect(x: display.minX, y: 0, width: display.width, height: display.maxY).intersection(fullPage)
        let tokens = TextLayerEngine.tokens(page: page, region: geometry.toPage(below), geometry: geometry)
        guard !tokens.isEmpty else { return region }
        let lines = LayoutAnalyzer.buildLines(tokens)
        let insideLines = lines.filter { $0.midY >= Double(display.minY) }
        let pitches = zip(insideLines, insideLines.dropFirst()).map { $0.midY - $1.midY }
        let pitch = LayoutAnalyzer.median(pitches)
        guard pitch > 0 else { return region }
        var bottom = Double(display.minY)
        var lastMid = insideLines.last?.midY ?? Double(display.minY)
        for line in lines where line.midY < Double(display.minY) {
            guard lastMid - line.midY <= pitch * 1.6, line.tokens.count >= 2 else { break }
            bottom = line.minY - 1
            lastMid = line.midY
        }
        guard bottom < Double(display.minY) else { return region }
        let extended = CGRect(x: display.minX, y: bottom, width: display.width, height: Double(display.maxY) - bottom)
        return geometry.toPage(extended)
    }

    /// Applies recipe column definitions where headers match. Unmatched columns keep their
    /// extracted headers so the schema check can flag them for inspection.
    public static func applyColumns(recipe: Recipe, to columns: [ColumnSpec]) -> (columns: [ColumnSpec], matched: Int) {
        let mapping = RecipeMatching.mapColumns(headers: columns.map(\.sourceHeader), recipe: recipe)
        var out = columns
        var matched = 0
        for (i, m) in mapping.enumerated() {
            let positional = (columns.count == recipe.columns.count && columns[i].sourceHeader.isEmpty) ? i : nil
            guard let target = m ?? positional else { continue }
            let rc = recipe.columns[target]
            out[i].name = rc.name
            out[i].type = rc.type
            out[i].unit = rc.unit
            out[i].scale = rc.scale
            out[i].numberFormat = rc.numberFormat
            out[i].typeConfirmed = true
            matched += 1
        }
        return (out, matched)
    }
}
