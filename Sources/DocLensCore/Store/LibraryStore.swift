import Foundation
import PDFKit

public enum LibraryError: Error, LocalizedError {
    case notFound(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) could not be found in the library."
        case .invalidData(let what): "Stored data for \(what) is unreadable."
        }
    }
}

/// The library: one SQLite database plus a directory of immutable source PDFs named by hash.
/// This type is the only writer to the database.
public final class LibraryStore {
    public let directory: URL
    public let sourcesDirectory: URL
    let db: SQLiteDatabase

    public static let schemaVersion = 1

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DocLens/Library", isDirectory: true)
    }

    public init(directory: URL = LibraryStore.defaultDirectory) throws {
        self.directory = directory
        self.sourcesDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appendingPathComponent("library.sqlite").path)
        try migrate()
    }

    // MARK: Schema

    private func migrate() throws {
        let version = db.userVersion
        if version < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS documents (
                    id TEXT PRIMARY KEY, filename TEXT NOT NULL, title TEXT NOT NULL, sha256 TEXT NOT NULL UNIQUE,
                    page_count INTEGER NOT NULL, pages TEXT NOT NULL, stored_name TEXT NOT NULL, file_size INTEGER NOT NULL,
                    imported_at REAL NOT NULL, has_text_layer INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS tables (
                    id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    name TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, current_run_id TEXT,
                    settings TEXT NOT NULL, segments TEXT NOT NULL, columns TEXT NOT NULL, recipe_id TEXT, recipe_version INTEGER);
                CREATE INDEX IF NOT EXISTS tables_document ON tables(document_id);
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY, table_id TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
                    engine TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL, status TEXT NOT NULL, error TEXT,
                    segments TEXT NOT NULL, document_sha256 TEXT NOT NULL, rows TEXT NOT NULL, column_count INTEGER NOT NULL,
                    notes TEXT NOT NULL, cache_key TEXT);
                CREATE INDEX IF NOT EXISTS runs_table ON runs(table_id);
                CREATE TABLE IF NOT EXISTS cells (
                    id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    row INTEGER NOT NULL, col INTEGER NOT NULL, row_span INTEGER NOT NULL, col_span INTEGER NOT NULL,
                    extracted_text TEXT NOT NULL, corrected_text TEXT, sources TEXT NOT NULL, engine_score REAL,
                    review TEXT NOT NULL, flags TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS cells_run ON cells(run_id, row, col);
                CREATE TABLE IF NOT EXISTS corrections (
                    id TEXT PRIMARY KEY, table_id TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
                    run_id TEXT NOT NULL, cell_id TEXT, kind TEXT NOT NULL, before_value TEXT, after_value TEXT,
                    detail TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS corrections_table ON corrections(table_id, created_at);
                CREATE TABLE IF NOT EXISTS checks (
                    table_id TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE, run_id TEXT NOT NULL,
                    computed_at REAL NOT NULL, results TEXT NOT NULL, summaries TEXT NOT NULL,
                    PRIMARY KEY (table_id, run_id));
                CREATE TABLE IF NOT EXISTS recipes (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL, updated_at REAL NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS recipe_versions (
                    recipe_id TEXT NOT NULL, version INTEGER NOT NULL, body TEXT NOT NULL, created_at REAL NOT NULL,
                    PRIMARY KEY (recipe_id, version));
                CREATE TABLE IF NOT EXISTS extraction_cache (
                    key TEXT PRIMARY KEY, created_at REAL NOT NULL, result TEXT NOT NULL);
                """)
                try db.setUserVersion(1)
            }
        }
    }

    // MARK: Encoding helpers

    static func json<T: Encodable>(_ value: T) throws -> SQLValue {
        .text(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?, _ what: String) throws -> T {
        guard let text, let data = text.data(using: .utf8) else { throw LibraryError.invalidData(what) }
        return try decoder.decode(type, from: data)
    }

    static func uuid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

    // MARK: Documents

    public func sourceURL(for document: DocumentRecord) -> URL {
        sourcesDirectory.appendingPathComponent(document.storedName)
    }

    /// Imports a PDF. The file is copied into the library, made read-only, and identified by
    /// its SHA-256 hash. Importing the same bytes twice returns the existing document.
    @discardableResult
    public func importDocument(from url: URL) throws -> (document: DocumentRecord, isNew: Bool) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let hash = try Hashing.sha256(fileAt: url)
        if let existing = try documents().first(where: { $0.sha256 == hash }) {
            return (existing, false)
        }
        let pdf = try PDFSupport.open(url)
        let storedName = "\(hash).pdf"
        let destination = sourcesDirectory.appendingPathComponent(storedName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            let temp = sourcesDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
            try fm.copyItem(at: url, to: temp)
            guard try Hashing.sha256(fileAt: temp) == hash else {
                try? fm.removeItem(at: temp)
                throw LibraryError.invalidData("the copied source file")
            }
            try fm.moveItem(at: temp, to: destination)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
        }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let doc = DocumentRecord(filename: url.lastPathComponent, title: title, sha256: hash,
                                 pageCount: pdf.pageCount, pages: PDFSupport.geometries(of: pdf),
                                 storedName: storedName, fileSize: size, hasTextLayer: PDFSupport.hasTextLayer(pdf))
        try db.run("""
            INSERT INTO documents (id, filename, title, sha256, page_count, pages, stored_name, file_size, imported_at, has_text_layer)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(doc.id.uuidString), .text(doc.filename), .text(doc.title), .text(doc.sha256),
                  .int(Int64(doc.pageCount)), try Self.json(doc.pages), .text(doc.storedName), .int(doc.fileSize),
                  .double(doc.importedAt.timeIntervalSince1970), .int(doc.hasTextLayer ? 1 : 0)])
        return (doc, true)
    }

    public func documents() throws -> [DocumentRecord] {
        try db.query("SELECT id, filename, title, sha256, page_count, pages, stored_name, file_size, imported_at, has_text_layer FROM documents ORDER BY imported_at DESC") { s in
            DocumentRecord(id: Self.uuid(s.string(0)) ?? UUID(), filename: s.string(1) ?? "", title: s.string(2) ?? "",
                           sha256: s.string(3) ?? "", pageCount: Int(s.int(4) ?? 0),
                           pages: try Self.decode([PageGeometry].self, s.string(5), "page metadata"),
                           storedName: s.string(6) ?? "", fileSize: s.int(7) ?? 0,
                           importedAt: Date(timeIntervalSince1970: s.double(8) ?? 0), hasTextLayer: (s.int(9) ?? 0) != 0)
        }
    }

    public func document(id: UUID) throws -> DocumentRecord {
        guard let d = try documents().first(where: { $0.id == id }) else { throw LibraryError.notFound("The document") }
        return d
    }

    public func renameDocument(id: UUID, title: String) throws {
        try db.run("UPDATE documents SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
    }

    /// Removes a document, its tables, and its stored source file.
    public func deleteDocument(id: UUID) throws {
        let doc = try document(id: id)
        try db.run("DELETE FROM documents WHERE id = ?", [.text(id.uuidString)])
        let url = sourceURL(for: doc)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Tables

    private func tableFrom(_ s: SQLiteStatement) throws -> TableRecord {
        TableRecord(id: Self.uuid(s.string(0)) ?? UUID(), documentID: Self.uuid(s.string(1)) ?? UUID(),
                    name: s.string(2) ?? "", createdAt: Date(timeIntervalSince1970: s.double(3) ?? 0),
                    updatedAt: Date(timeIntervalSince1970: s.double(4) ?? 0), currentRunID: Self.uuid(s.string(5)),
                    settings: try Self.decode(TableSettings.self, s.string(6), "table settings"),
                    segments: try Self.decode([TableSegment].self, s.string(7), "table segments"),
                    columns: try Self.decode([ColumnSpec].self, s.string(8), "columns"),
                    recipeID: Self.uuid(s.string(9)), recipeVersion: s.int(10).map(Int.init))
    }

    static let tableColumns = "id, document_id, name, created_at, updated_at, current_run_id, settings, segments, columns, recipe_id, recipe_version"

    public func tables(documentID: UUID? = nil) throws -> [TableRecord] {
        if let documentID {
            return try db.query("SELECT \(Self.tableColumns) FROM tables WHERE document_id = ? ORDER BY created_at",
                                [.text(documentID.uuidString)], tableFrom)
        }
        return try db.query("SELECT \(Self.tableColumns) FROM tables ORDER BY created_at", [], tableFrom)
    }

    public func table(id: UUID) throws -> TableRecord {
        guard let t = try db.query("SELECT \(Self.tableColumns) FROM tables WHERE id = ?", [.text(id.uuidString)], tableFrom).first else {
            throw LibraryError.notFound("The table")
        }
        return t
    }

    public func saveTable(_ table: TableRecord) throws {
        var t = table
        t.updatedAt = Date()
        try db.run("""
            INSERT INTO tables (\(Self.tableColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at,
              current_run_id=excluded.current_run_id, settings=excluded.settings, segments=excluded.segments,
              columns=excluded.columns, recipe_id=excluded.recipe_id, recipe_version=excluded.recipe_version
            """, [.text(t.id.uuidString), .text(t.documentID.uuidString), .text(t.name),
                  .double(t.createdAt.timeIntervalSince1970), .double(t.updatedAt.timeIntervalSince1970),
                  t.currentRunID.map { .text($0.uuidString) } ?? .null, try Self.json(t.settings),
                  try Self.json(t.segments), try Self.json(t.columns), t.recipeID.map { .text($0.uuidString) } ?? .null,
                  t.recipeVersion.map { .int(Int64($0)) } ?? .null])
    }

    public func deleteTable(id: UUID) throws {
        try db.run("DELETE FROM tables WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: Runs and cells

    private func runFrom(_ s: SQLiteStatement) throws -> ExtractionRun {
        ExtractionRun(id: Self.uuid(s.string(0)) ?? UUID(), tableID: Self.uuid(s.string(1)) ?? UUID(),
                      engine: try Self.decode(EngineDescriptor.self, s.string(2), "engine"),
                      startedAt: Date(timeIntervalSince1970: s.double(3) ?? 0),
                      finishedAt: s.double(4).map(Date.init(timeIntervalSince1970:)),
                      status: RunStatus(rawValue: s.string(5) ?? "") ?? .failed, errorMessage: s.string(6),
                      segments: try Self.decode([TableSegment].self, s.string(7), "run segments"),
                      documentSHA256: s.string(8) ?? "",
                      rows: try Self.decode([RowSpec].self, s.string(9), "rows"),
                      columnCount: Int(s.int(10) ?? 0),
                      notes: try Self.decode([String].self, s.string(11), "notes"), cacheKey: s.string(12))
    }

    static let runColumns = "id, table_id, engine, started_at, finished_at, status, error, segments, document_sha256, rows, column_count, notes, cache_key"

    public func runs(tableID: UUID) throws -> [ExtractionRun] {
        try db.query("SELECT \(Self.runColumns) FROM runs WHERE table_id = ? ORDER BY started_at DESC",
                     [.text(tableID.uuidString)], runFrom)
    }

    public func run(id: UUID) throws -> ExtractionRun {
        guard let r = try db.query("SELECT \(Self.runColumns) FROM runs WHERE id = ?", [.text(id.uuidString)], runFrom).first else {
            throw LibraryError.notFound("The extraction run")
        }
        return r
    }

    public func saveRun(_ run: ExtractionRun) throws {
        try db.run("""
            INSERT INTO runs (\(Self.runColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET finished_at=excluded.finished_at, status=excluded.status, error=excluded.error,
              rows=excluded.rows, column_count=excluded.column_count, notes=excluded.notes, cache_key=excluded.cache_key
            """, [.text(run.id.uuidString), .text(run.tableID.uuidString), try Self.json(run.engine),
                  .double(run.startedAt.timeIntervalSince1970), run.finishedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                  .text(run.status.rawValue), run.errorMessage.map(SQLValue.text) ?? .null, try Self.json(run.segments),
                  .text(run.documentSHA256), try Self.json(run.rows), .int(Int64(run.columnCount)), try Self.json(run.notes),
                  run.cacheKey.map(SQLValue.text) ?? .null])
    }

    private func cellFrom(_ s: SQLiteStatement) throws -> CellRecord {
        CellRecord(id: Self.uuid(s.string(0)) ?? UUID(), runID: Self.uuid(s.string(1)) ?? UUID(),
                   row: Int(s.int(2) ?? 0), column: Int(s.int(3) ?? 0), rowSpan: Int(s.int(4) ?? 1),
                   colSpan: Int(s.int(5) ?? 1), extractedText: s.string(6) ?? "", correctedText: s.string(7),
                   sources: try Self.decode([SourceReference].self, s.string(8), "sources"), engineScore: s.double(9),
                   review: ReviewState(rawValue: s.string(10) ?? "") ?? .unreviewed,
                   flags: try Self.decode([String].self, s.string(11), "flags"),
                   updatedAt: Date(timeIntervalSince1970: s.double(12) ?? 0))
    }

    public func cells(runID: UUID) throws -> [CellRecord] {
        try db.query("SELECT id, run_id, row, col, row_span, col_span, extracted_text, corrected_text, sources, engine_score, review, flags, updated_at FROM cells WHERE run_id = ? ORDER BY row, col",
                     [.text(runID.uuidString)], cellFrom)
    }

    public func saveCells(_ cells: [CellRecord]) throws {
        try db.transaction {
            for c in cells {
                try db.run("""
                    INSERT INTO cells (id, run_id, row, col, row_span, col_span, extracted_text, corrected_text, sources, engine_score, review, flags, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET corrected_text=excluded.corrected_text, review=excluded.review,
                      flags=excluded.flags, updated_at=excluded.updated_at
                    """, [.text(c.id.uuidString), .text(c.runID.uuidString), .int(Int64(c.row)), .int(Int64(c.column)),
                          .int(Int64(c.rowSpan)), .int(Int64(c.colSpan)), .text(c.extractedText),
                          c.correctedText.map(SQLValue.text) ?? .null, try Self.json(c.sources),
                          c.engineScore.map(SQLValue.double) ?? .null, .text(c.review.rawValue), try Self.json(c.flags),
                          .double(c.updatedAt.timeIntervalSince1970)])
            }
        }
    }

    // MARK: Corrections and checks

    public func addCorrections(_ corrections: [Correction]) throws {
        guard !corrections.isEmpty else { return }
        try db.transaction {
            for c in corrections {
                try db.run("INSERT INTO corrections (id, table_id, run_id, cell_id, kind, before_value, after_value, detail, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                           [.text(c.id.uuidString), .text(c.tableID.uuidString), .text(c.runID.uuidString),
                            c.cellID.map { .text($0.uuidString) } ?? .null, .text(c.kind.rawValue),
                            c.before.map(SQLValue.text) ?? .null, c.after.map(SQLValue.text) ?? .null,
                            .text(c.detail), .double(c.createdAt.timeIntervalSince1970)])
            }
        }
    }

    public func corrections(tableID: UUID) throws -> [Correction] {
        try db.query("SELECT id, table_id, run_id, cell_id, kind, before_value, after_value, detail, created_at FROM corrections WHERE table_id = ? ORDER BY created_at",
                     [.text(tableID.uuidString)]) { s in
            Correction(id: Self.uuid(s.string(0)) ?? UUID(), tableID: Self.uuid(s.string(1)) ?? UUID(),
                       runID: Self.uuid(s.string(2)) ?? UUID(), cellID: Self.uuid(s.string(3)),
                       kind: CorrectionKind(rawValue: s.string(4) ?? "") ?? .edit, before: s.string(5), after: s.string(6),
                       detail: s.string(7) ?? "", createdAt: Date(timeIntervalSince1970: s.double(8) ?? 0))
        }
    }

    public func saveChecks(tableID: UUID, runID: UUID, results: [CheckResult], summaries: [RuleSummary]) throws {
        try db.run("INSERT OR REPLACE INTO checks (table_id, run_id, computed_at, results, summaries) VALUES (?,?,?,?,?)",
                   [.text(tableID.uuidString), .text(runID.uuidString), .double(Date().timeIntervalSince1970),
                    try Self.json(results), try Self.json(summaries)])
    }

    public func checks(tableID: UUID, runID: UUID) throws -> (results: [CheckResult], summaries: [RuleSummary])? {
        try db.query("SELECT results, summaries FROM checks WHERE table_id = ? AND run_id = ?",
                     [.text(tableID.uuidString), .text(runID.uuidString)]) { s in
            (try Self.decode([CheckResult].self, s.string(0), "checks"), try Self.decode([RuleSummary].self, s.string(1), "check summaries"))
        }.first
    }

    // MARK: Snapshot

    public func snapshot(tableID: UUID) throws -> TableSnapshot? {
        let table = try table(id: tableID)
        guard let runID = table.currentRunID else { return nil }
        let doc = try document(id: table.documentID)
        let run = try run(id: runID)
        return TableSnapshot(document: doc, table: table, run: run, cells: try cells(runID: runID),
                             corrections: try corrections(tableID: tableID))
    }

    // MARK: Recipes

    public func recipes() throws -> [Recipe] {
        try db.query("SELECT body FROM recipes ORDER BY name COLLATE NOCASE") { s in
            try Self.decode(Recipe.self, s.string(0), "recipe")
        }
    }

    public func recipe(id: UUID) throws -> Recipe? {
        try db.query("SELECT body FROM recipes WHERE id = ?", [.text(id.uuidString)]) { s in
            try Self.decode(Recipe.self, s.string(0), "recipe")
        }.first
    }

    /// Saves a recipe. Saving a changed recipe increments its version and keeps the old version.
    @discardableResult
    public func saveRecipe(_ recipe: Recipe) throws -> Recipe {
        var r = recipe
        if let existing = try self.recipe(id: recipe.id) {
            var comparable = existing
            comparable.updatedAt = r.updatedAt
            comparable.version = r.version
            if comparable != r { r.version = existing.version + 1 }
        }
        r.updatedAt = Date()
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO recipes (id, name, version, updated_at, body) VALUES (?,?,?,?,?)",
                       [.text(r.id.uuidString), .text(r.name), .int(Int64(r.version)), .double(r.updatedAt.timeIntervalSince1970),
                        try Self.json(r)])
            try db.run("INSERT OR REPLACE INTO recipe_versions (recipe_id, version, body, created_at) VALUES (?,?,?,?)",
                       [.text(r.id.uuidString), .int(Int64(r.version)), try Self.json(r), .double(Date().timeIntervalSince1970)])
        }
        return r
    }

    public func deleteRecipe(id: UUID) throws {
        try db.run("DELETE FROM recipes WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: Cache

    public func cachedExtraction(key: String) throws -> ExtractedTable? {
        try db.query("SELECT result FROM extraction_cache WHERE key = ?", [.text(key)]) { s in
            try Self.decode(ExtractedTable.self, s.string(0), "cached extraction")
        }.first
    }

    public func cacheExtraction(_ table: ExtractedTable, key: String) throws {
        try db.run("INSERT OR REPLACE INTO extraction_cache (key, created_at, result) VALUES (?,?,?)",
                   [.text(key), .double(Date().timeIntervalSince1970), try Self.json(table)])
    }

    public func clearCache() throws { try db.run("DELETE FROM extraction_cache") }
}
