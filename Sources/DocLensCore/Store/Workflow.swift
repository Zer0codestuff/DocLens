import Foundation

public extension LibraryStore {
    func nextTableName(documentID: UUID) -> String {
        let count = ((try? tables(documentID: documentID)) ?? []).count
        return "Table \(count + 1)"
    }

    func createTable(document: DocumentRecord, segments: [TableSegment], name: String? = nil,
                     settings: TableSettings = TableSettings(), recipe: Recipe? = nil) throws -> TableRecord {
        let table = TableRecord(documentID: document.id, name: name ?? nextTableName(documentID: document.id),
                                settings: recipe?.settings ?? settings, segments: segments,
                                recipeID: recipe?.id, recipeVersion: recipe?.version)
        try saveTable(table)
        return table
    }

    /// Stores an extraction as a new version of the table and makes it current. Corrections
    /// and reviews from the previous version carry over by position; nothing is overwritten.
    func commitExtraction(tableID: UUID, extracted: ExtractedTable, startedAt: Date, cacheKey: String?,
                          recipe: Recipe? = nil) throws -> (snapshot: TableSnapshot, summary: CarryOverSummary) {
        var table = try table(id: tableID)
        let document = try document(id: table.documentID)
        let previous = try snapshot(tableID: tableID)
        var output = TableBuilder.build(table: table, document: document, extracted: extracted, startedAt: startedAt,
                                        cacheKey: cacheKey)
        var summary = CarryOverSummary()
        var carried: [Correction] = []
        if let previous {
            (summary, carried) = TableBuilder.carryOver(from: previous, into: &output)
        }
        var columns = output.columns
        if let recipe {
            columns = RecipeApplier.applyColumns(recipe: recipe, to: columns).columns
        }
        table.columns = columns
        table.currentRunID = output.run.id
        try db.transaction {
            try saveRun(output.run)
            try saveCells(output.cells)
            try saveTable(table)
            try addCorrections(carried)
        }
        guard let snap = try snapshot(tableID: tableID) else { throw LibraryError.notFound("The new extraction") }
        return (snap, summary)
    }

    func recordFailedRun(tableID: UUID, engine: EngineDescriptor, startedAt: Date, error: Error, cancelled: Bool) throws {
        let table = try table(id: tableID)
        let document = try document(id: table.documentID)
        let run = ExtractionRun(tableID: tableID, engine: engine, startedAt: startedAt, finishedAt: Date(),
                                status: cancelled ? .cancelled : .failed, errorMessage: error.localizedDescription,
                                segments: table.segments, documentSHA256: document.sha256)
        try saveRun(run)
    }

    func setCurrentRun(tableID: UUID, runID: UUID) throws -> TableSnapshot? {
        var table = try table(id: tableID)
        let run = try run(id: runID)
        guard run.status == .completed else { return try snapshot(tableID: tableID) }
        table.currentRunID = runID
        if table.columns.count != run.columnCount {
            table.columns = (0..<run.columnCount).map { ColumnSpec(index: $0, name: "Column \(ColumnSpec.letter(for: $0))") }
        }
        try saveTable(table)
        return try snapshot(tableID: tableID)
    }

    /// Evaluates checks for a snapshot and stores the results with the current version.
    @discardableResult
    func evaluate(_ snapshot: TableSnapshot) -> TableEvaluation {
        let recipe = snapshot.table.recipeID.flatMap { try? self.recipe(id: $0) }
        let evaluation = CheckEngine.evaluate(snapshot, recipe: recipe)
        try? saveChecks(tableID: snapshot.table.id, runID: snapshot.run.id, results: evaluation.results,
                        summaries: evaluation.summaries)
        return evaluation
    }
}

/// Mutations of a table. Each writes through to the store and records a correction entry, so
/// history is append-only and the original extraction is never modified.
public struct TableEditor {
    public let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    private func log(_ snapshot: inout TableSnapshot, _ corrections: [Correction]) throws {
        try store.addCorrections(corrections)
        snapshot.corrections.append(contentsOf: corrections)
    }

    /// Sets the user value of a cell. Passing the extracted text clears the correction.
    public func setText(_ text: String, cellID: UUID, in snapshot: inout TableSnapshot, kind: CorrectionKind = .edit) throws {
        guard let i = snapshot.cellIndex(id: cellID) else { return }
        var cell = snapshot.cells[i]
        let before = cell.text
        guard before != text else { return }
        cell.correctedText = text == cell.extractedText ? nil : text
        if cell.review == .reviewed { cell.review = .needsReview }
        cell.updatedAt = Date()
        try store.saveCells([cell])
        snapshot.cells[i] = cell
        try log(&snapshot, [Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: cellID, kind: kind,
                                       before: before, after: text,
                                       detail: cell.correctedText == nil ? "Restored extracted value" : "")])
    }

    public func setReview(_ state: ReviewState, cellIDs: [UUID], in snapshot: inout TableSnapshot) throws {
        var changed: [CellRecord] = []
        var corrections: [Correction] = []
        for id in cellIDs {
            guard let i = snapshot.cellIndex(id: id), snapshot.cells[i].review != state else { continue }
            let before = snapshot.cells[i].review
            snapshot.cells[i].review = state
            snapshot.cells[i].updatedAt = Date()
            changed.append(snapshot.cells[i])
            corrections.append(Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: id, kind: .review,
                                          before: before.rawValue, after: state.rawValue))
        }
        guard !changed.isEmpty else { return }
        try store.saveCells(changed)
        try log(&snapshot, corrections)
    }

    public func updateColumn(_ column: ColumnSpec, in snapshot: inout TableSnapshot) throws {
        guard column.index < snapshot.table.columns.count else { return }
        let old = snapshot.table.columns[column.index]
        guard old != column else { return }
        var corrections: [Correction] = []
        if old.type != column.type {
            corrections.append(Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: nil, kind: .columnType,
                                          before: old.type.rawValue, after: column.type.rawValue,
                                          detail: "Column \(column.letter) type"))
        }
        if old.name != column.name {
            corrections.append(Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: nil, kind: .columnRename,
                                          before: old.name, after: column.name, detail: "Column \(column.letter) name"))
        }
        if old.unit != column.unit || old.scale != column.scale || old.numberFormat != column.numberFormat {
            corrections.append(Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: nil, kind: .columnSettings,
                                          before: "unit=\(old.unit) scale=\(old.scale) format=\(old.numberFormat?.rawValue ?? "table")",
                                          after: "unit=\(column.unit) scale=\(column.scale) format=\(column.numberFormat?.rawValue ?? "table")",
                                          detail: "Column \(column.letter) settings"))
        }
        snapshot.table.columns[column.index] = column
        try store.saveTable(snapshot.table)
        try log(&snapshot, corrections)
    }

    public func setRole(_ role: RowRole, rows: [Int], in snapshot: inout TableSnapshot) throws {
        var corrections: [Correction] = []
        for r in rows where r < snapshot.run.rows.count && snapshot.run.rows[r].role != role {
            corrections.append(Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: nil, kind: .rowRole,
                                          before: snapshot.run.rows[r].role.rawValue, after: role.rawValue, detail: "Row \(r + 1)"))
            snapshot.run.rows[r].role = role
            snapshot.run.rows[r].note = nil
        }
        guard !corrections.isEmpty else { return }
        try store.saveRun(snapshot.run)
        try log(&snapshot, corrections)
    }

    /// Rebuilds column names from the current header rows, keeping names the user changed.
    public func refreshHeaderNames(in snapshot: inout TableSnapshot) throws {
        for i in snapshot.table.columns.indices {
            let header = snapshot.headerText(column: i)
            var column = snapshot.table.columns[i]
            let wasDerived = column.name == column.sourceHeader || column.name == "Column \(column.letter)"
            column.sourceHeader = header
            if wasDerived { column.name = header.isEmpty ? "Column \(column.letter)" : header }
            snapshot.table.columns[i] = column
        }
        try store.saveTable(snapshot.table)
    }

    public func updateSettings(_ settings: TableSettings, in snapshot: inout TableSnapshot) throws {
        guard settings != snapshot.table.settings else { return }
        let formatChanged = settings.numberFormat != snapshot.table.settings.numberFormat
        snapshot.table.settings = settings
        if formatChanged { reinferSuggestedTypes(in: &snapshot) }
        try store.saveTable(snapshot.table)
        try log(&snapshot, [Correction(tableID: snapshot.table.id, runID: snapshot.run.id, cellID: nil, kind: .tableSettings,
                                       before: nil, after: nil,
                                       detail: "Number format \(settings.numberFormat.rawValue), date order \(settings.dateOrder.rawValue)")])
    }

    /// Suggested types depend on the decimal convention ("1,204" is decimal under a comma
    /// convention and an integer under a point convention); confirmed types stay as they are.
    private func reinferSuggestedTypes(in snapshot: inout TableSnapshot) {
        let rows = snapshot.strictDataRowIndexes
        let settings = snapshot.table.settings
        let all = rows.flatMap { r in snapshot.table.columns.indices.compactMap { snapshot.cell(row: r, column: $0)?.text } }
        let hint = TypeInference.decimalHint(all, settings: settings)
        for i in snapshot.table.columns.indices where !snapshot.table.columns[i].typeConfirmed {
            let values = rows.compactMap { snapshot.cell(row: $0, column: i)?.text }
            snapshot.table.columns[i].type = TypeInference.infer(header: snapshot.table.columns[i].sourceHeader, values: values,
                                                                  settings: settings, decimalHint: hint)
        }
    }

    public func rename(_ name: String, in snapshot: inout TableSnapshot) throws {
        snapshot.table.name = name
        try store.saveTable(snapshot.table)
    }
}
