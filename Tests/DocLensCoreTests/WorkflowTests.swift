import Foundation
import Testing
@testable import DocLensCore

/// End-to-end checks of the library workflow on generated corpus documents: import,
/// extraction, review edits, re-extraction carry-over, checks, and exports.
@Suite(.serialized) struct WorkflowTests {
    let directory: URL
    let store: LibraryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("doclens-tests-\(UUID().uuidString)")
        store = try LibraryStore(directory: directory.appendingPathComponent("Library"))
    }

    func makeDocument(_ name: String) throws -> (DocumentRecord, TruthTable) {
        let spec = try #require(CorpusGenerator.specs.first { $0.name == name })
        let url = directory.appendingPathComponent("\(name).pdf")
        let truth = try CorpusGenerator.render(spec, to: url)
        try CorpusGenerator.setRotation(spec.rotation, url: url)
        let (doc, isNew) = try store.importDocument(from: url)
        #expect(isNew)
        return (doc, try #require(truth.tables.first))
    }

    func extract(_ table: TableRecord, document: DocumentRecord, engine: EngineKind = .textLayer) async throws
        -> (snapshot: TableSnapshot, summary: CarryOverSummary) {
        let extracted = try await ExtractionService.extract(documentURL: store.sourceURL(for: document), documentID: document.id,
                                                            segments: table.segments, engine: engine,
                                                            options: ExtractionOptions(), progress: { _, _ in })
        return try store.commitExtraction(tableID: table.id, extracted: extracted, startedAt: Date(), cacheKey: nil)
    }

    func grid(_ s: TableSnapshot) -> [[String]] {
        (0..<s.rowCount).map { r in (0..<s.columnCount).map { c in s.cell(row: r, column: c)?.text ?? "" } }
    }

    @Test func importIsImmutableAndDeduplicated() throws {
        let (doc, _) = try makeDocument("01-grid-point-decimal")
        let stored = store.sourceURL(for: doc)
        let attributes = try FileManager.default.attributesOfItem(atPath: stored.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o444)
        #expect(try Hashing.sha256(fileAt: stored) == doc.sha256)
        let again = try store.importDocument(from: directory.appendingPathComponent("01-grid-point-decimal.pdf"))
        #expect(!again.isNew)
        #expect(again.document.id == doc.id)
    }

    @Test func extractionMatchesTruthAndPassesChecks() async throws {
        let (doc, truth) = try makeDocument("02-borderless-comma-decimal")
        let table = try store.createTable(document: doc, segments: truth.segments)
        let (snapshot, _) = try await extract(table, document: doc)
        #expect(grid(snapshot) == truth.cells)
        #expect(snapshot.table.columns.map(\.type) == truth.columnTypes)
        let evaluation = store.evaluate(snapshot)
        #expect(evaluation.unresolved(in: snapshot).isEmpty)
        // Leading zeros survive as identifiers.
        let code = try #require(snapshot.cell(row: 1, column: 0))
        #expect(evaluation.normalized[code.id]?.canonical == "001272")
        // Comma decimals resolve from evidence.
        let area = try #require(snapshot.cell(row: 6, column: 3))
        #expect(evaluation.normalized[area.id]?.canonical == "1287.36")
        // Every non-empty data cell maps back to a page region.
        for cell in snapshot.cells where !cell.text.isEmpty {
            #expect(cell.hasSourceRegion, "\(cell.address) has no source region")
        }
    }

    @Test func resolvingNumberFormatClearsAmbiguityAndRefinesTypes() async throws {
        let (doc, truth) = try makeDocument("10-spanning-header")
        let table = try store.createTable(document: doc, segments: truth.segments)
        var (snapshot, _) = try await extract(table, document: doc)
        let ambiguous = store.evaluate(snapshot).unresolved(in: snapshot).filter { $0.ruleID == CheckRule.ambiguousFormat.id }
        #expect(!ambiguous.isEmpty)

        var settings = snapshot.table.settings
        settings.numberFormat = .pointDecimal
        try TableEditor(store: store).updateSettings(settings, in: &snapshot)
        #expect(store.evaluate(snapshot).unresolved(in: snapshot).filter { $0.ruleID == CheckRule.ambiguousFormat.id }.isEmpty)
        #expect(snapshot.table.columns.dropFirst().allSatisfy { $0.type == .integer })
        #expect(try store.table(id: table.id).columns.dropFirst().allSatisfy { $0.type == .integer })
    }

    @Test func correctionsSurviveReextraction() async throws {
        let (doc, truth) = try makeDocument("01-grid-point-decimal")
        let table = try store.createTable(document: doc, segments: truth.segments)
        var (snapshot, _) = try await extract(table, document: doc)
        let editor = TableEditor(store: store)
        let target = try #require(snapshot.cell(row: 2, column: 1))
        try editor.setText("11,763,651", cellID: target.id, in: &snapshot)
        let reviewed = try #require(snapshot.cell(row: 3, column: 1))
        try editor.setReview(.reviewed, cellIDs: [reviewed.id], in: &snapshot)
        #expect(snapshot.cell(id: target.id)?.extractedText == "11,763,650")

        let (second, summary) = try await extract(table, document: doc)
        #expect(second.run.id != snapshot.run.id)
        #expect(summary.carriedCorrections == 1)
        #expect(summary.reviewsKept == 1)
        #expect(second.cell(row: 2, column: 1)?.text == "11,763,651")
        #expect(second.cell(row: 2, column: 1)?.extractedText == "11,763,650")
        #expect(second.cell(row: 3, column: 1)?.review == .reviewed)
        // The previous version is kept intact.
        let oldCells = try store.cells(runID: snapshot.run.id)
        #expect(oldCells.first { $0.id == target.id }?.correctedText == "11,763,651")
        #expect(try store.runs(tableID: table.id).count == 2)
    }

    @Test func passingChecksDoNotMarkCellsReviewed() async throws {
        let (doc, truth) = try makeDocument("01-grid-point-decimal")
        let table = try store.createTable(document: doc, segments: truth.segments)
        let (snapshot, _) = try await extract(table, document: doc)
        _ = store.evaluate(snapshot)
        #expect(snapshot.cells.allSatisfy { $0.review == .unreviewed })
    }

    @Test func totalsAreChecked() async throws {
        let (doc, truth) = try makeDocument("03-booktabs-missing-values")
        let table = try store.createTable(document: doc, segments: truth.segments)
        var (snapshot, _) = try await extract(table, document: doc)
        let totalRow = try #require(snapshot.run.rows.last)
        #expect(totalRow.role == .total)
        var evaluation = store.evaluate(snapshot)
        #expect(!evaluation.results.contains { $0.ruleID == CheckRule.totals.id && $0.status == .failed })
        let cases = try #require(snapshot.cell(row: 2, column: 1))
        try TableEditor(store: store).setText("1,205", cellID: cases.id, in: &snapshot)
        evaluation = store.evaluate(snapshot)
        #expect(evaluation.results.contains { $0.ruleID == CheckRule.totals.id && $0.status == .failed })
    }

    @Test func exportsAgreeAcrossFormats() async throws {
        let (doc, truth) = try makeDocument("08-financial-statement")
        let table = try store.createTable(document: doc, segments: truth.segments)
        let (snapshot, _) = try await extract(table, document: doc)
        let evaluation = store.evaluate(snapshot)
        let out = directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let csvURL = out.appendingPathComponent("t.csv")
        let written = try ExportService.export(snapshot: snapshot, evaluation: evaluation, format: .csv,
                                               options: ExportOptions(), to: csvURL)
        #expect(written.count == 2)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csv.split(separator: "\r\n").map(String.init)
        #expect(lines.first == "Line item,2025,2024,Change")
        #expect(lines.contains("Cost of sales,-612300.25,-590100.00,3.8"))

        let jsonURL = out.appendingPathComponent("t.json")
        try ExportService.export(snapshot: snapshot, evaluation: evaluation, format: .json, options: ExportOptions(), to: jsonURL)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        #expect(json["schema"] as? String == JSONExporter.schema)
        let source = try #require(json["document"] as? [String: Any])
        #expect(source["sha256"] as? String == doc.sha256)

        let xlsxURL = out.appendingPathComponent("t.xlsx")
        try ExportService.export(snapshot: snapshot, evaluation: evaluation, format: .xlsx, options: ExportOptions(), to: xlsxURL)
        let listing = try run("/usr/bin/unzip", ["-l", xlsxURL.path])
        #expect(listing.contains("xl/worksheets/sheet1.xml"))
        let test = try run("/usr/bin/unzip", ["-t", xlsxURL.path])
        #expect(test.contains("No errors detected"))
    }

    @Test func recipeLocatesTableOnSimilarDocument() async throws {
        let (doc, truth) = try makeDocument("01-grid-point-decimal")
        let table = try store.createTable(document: doc, segments: truth.segments)
        var (snapshot, _) = try await extract(table, document: doc)
        var column = snapshot.table.columns[3]
        column.name = "Density per km²"
        column.typeConfirmed = true
        try TableEditor(store: store).updateColumn(column, in: &snapshot)
        let recipe = try store.saveRecipe(RecipeBuilder.make(name: "Population", from: snapshot, engine: .textLayer))
        let location = try RecipeApplier.locate(recipe: recipe, documentURL: store.sourceURL(for: doc))
        #expect(location.segment.pageIndex == truth.segments[0].pageIndex)
        #expect(location.segment.region.intersectionOverUnion(truth.segments[0].region) > 0.6)
        let applied = RecipeApplier.applyColumns(recipe: recipe, to: snapshot.table.columns)
        #expect(applied.matched == snapshot.columnCount)
        #expect(applied.columns[3].name == "Density per km²")
    }

    @Test func recipeFromNarrowerTableFitsTheWiderTable() async throws {
        let (source, sourceTruth) = try makeDocument("10-spanning-header")
        let table = try store.createTable(document: source, segments: sourceTruth.segments)
        let (snapshot, _) = try await extract(table, document: source)
        let recipe = try store.saveRecipe(RecipeBuilder.make(name: "Cases", from: snapshot, engine: .textLayer))

        let (target, truth) = try makeDocument("01-grid-point-decimal")
        let url = store.sourceURL(for: target)
        let expected = truth.segments[0].region
        let saved = try RecipeApplier.locate(recipe: recipe, documentURL: url)
        #expect(saved.segment.region.maxX < expected.maxX - 20)

        let fitted = try await RecipeApplier.locate(recipe: recipe, documentURL: url, options: ExtractionOptions())
        #expect(fitted.method.hasSuffix("fitted to the detected table"))
        #expect(fitted.segment.region.intersectionOverUnion(expected) > 0.8)
        let applied = try store.createTable(document: target, segments: [fitted.segment])
        let (result, _) = try await extract(applied, document: target)
        #expect(grid(result) == truth.cells)
    }

    func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
