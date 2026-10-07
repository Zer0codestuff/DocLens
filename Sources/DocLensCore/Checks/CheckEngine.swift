import Foundation

public struct CheckRule: Sendable, Hashable, Identifiable {
    public var id: String
    public var version: Int
    public var title: String
    public var tests: String
    public var severity: CheckSeverity

    public static let typeConversion = CheckRule(
        id: "conversion.type", version: 1, title: "Type conversion",
        tests: "Each data value converts to its column type using the column's number format and date order.",
        severity: .error)
    public static let ambiguousFormat = CheckRule(
        id: "conversion.ambiguous", version: 1, title: "Ambiguous format",
        tests: "Numbers and dates have a single reading. Set the number format or date order to resolve.",
        severity: .warning)
    public static let rowStructure = CheckRule(
        id: "structure.row", version: 1, title: "Row structure",
        tests: "Each data row has a cell in every column and no text outside the detected columns.",
        severity: .warning)
    public static let sourceEvidence = CheckRule(
        id: "source.evidence", version: 1, title: "Source evidence",
        tests: "Each non-empty value has at least one source region in the PDF.",
        severity: .warning)
    public static let leadingZeros = CheckRule(
        id: "identifier.leadingZeros", version: 1, title: "Leading zeros",
        tests: "Numeric columns do not contain codes whose leading zeros would be lost.",
        severity: .warning)
    public static let engineScore = CheckRule(
        id: "engine.score", version: 1, title: "Low engine score",
        tests: "The engine's raw recognition score is at least 0.5. The score is not a probability of correctness.",
        severity: .warning)
    public static let totals = CheckRule(
        id: "totals.sum", version: 1, title: "Totals",
        tests: "Each value in a row marked Total equals the sum of the data rows above it, back to the previous total, within the tolerance.",
        severity: .error)
    public static let duplicates = CheckRule(
        id: "rows.duplicate", version: 1, title: "Duplicate rows",
        tests: "No two data rows contain identical values.",
        severity: .warning)
    public static let schema = CheckRule(
        id: "schema.recipe", version: 1, title: "Recipe schema",
        tests: "Column count and header text match the recipe used to create this table.",
        severity: .error)
    public static let reextraction = CheckRule(
        id: "reextraction.conflict", version: 1, title: "Re-extraction conflict",
        tests: "A corrected value was kept although the new extraction read the source differently.",
        severity: .warning)
    public static let continuation = CheckRule(
        id: "structure.continuation", version: 1, title: "Merged lines",
        tests: "Text lines that were merged into the row above as wrapped cell content.",
        severity: .info)

    public static let all: [CheckRule] = [
        .typeConversion, .ambiguousFormat, .rowStructure, .sourceEvidence, .leadingZeros, .engineScore,
        .totals, .duplicates, .schema, .reextraction, .continuation,
    ]

    public static func rule(id: String) -> CheckRule? { all.first { $0.id == id } }
}

public struct RuleSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String { ruleID }
    public var ruleID: String
    public var ruleVersion: Int
    public var status: CheckStatus
    public var tested: Int
    public var failed: Int
    public var explanation: String
}

/// Derived state for a snapshot: resolved formats, normalized values, and check results.
public struct TableEvaluation: Sendable {
    public var contexts: [ColumnContext]
    public var normalized: [UUID: NormalizedValue]
    public var results: [CheckResult]
    public var summaries: [RuleSummary]
    public var resultsByCell: [UUID: [CheckResult]]

    /// Failed checks on cells the user has not reviewed.
    public func unresolved(in snapshot: TableSnapshot) -> [CheckResult] {
        results.filter { r in
            guard r.status == .failed, r.severity != .info else { return false }
            if r.cellIDs.isEmpty { return true }
            return r.cellIDs.contains { id in snapshot.cell(id: id)?.review != .reviewed }
        }
    }

    public func isResolved(_ result: CheckResult, in snapshot: TableSnapshot) -> Bool {
        guard result.status == .failed else { return true }
        guard !result.cellIDs.isEmpty else { return false }
        return result.cellIDs.allSatisfy { snapshot.cell(id: $0)?.review == .reviewed }
    }
}

public enum CheckEngine {
    public static func evaluate(_ snapshot: TableSnapshot, recipe: Recipe? = nil) -> TableEvaluation {
        let settings = snapshot.table.settings
        let columns = snapshot.table.columns
        let contexts = ValueNormalizer.contexts(columns: columns, settings: settings,
                                                valuesByColumn: snapshot.valuesByColumn())
        let dataRows = Set(snapshot.dataRowIndexes)

        var normalized: [UUID: NormalizedValue] = [:]
        for cell in snapshot.cells {
            guard cell.column < columns.count else { continue }
            if dataRows.contains(cell.row) {
                normalized[cell.id] = ValueNormalizer.normalize(cell.text, column: columns[cell.column],
                                                                context: contexts[cell.column], settings: settings)
            } else {
                let t = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized[cell.id] = t.isEmpty ? .empty : NormalizedValue(kind: .value, canonical: t)
            }
        }

        var results: [CheckResult] = []
        var tested: [String: Int] = [:]
        func add(_ rule: CheckRule, _ cell: CellRecord?, row: Int? = nil, column: Int? = nil, _ message: String,
                 status: CheckStatus = .failed, severity: CheckSeverity? = nil, tolerance: String? = nil, cells: [UUID]? = nil) {
            results.append(CheckResult(ruleID: rule.id, ruleVersion: rule.version, status: status,
                                       severity: severity ?? rule.severity,
                                       cellIDs: cells ?? (cell.map { [$0.id] } ?? []),
                                       row: row ?? cell?.row, column: column ?? cell?.column,
                                       message: message, tested: rule.tests, tolerance: tolerance))
        }

        // Per-cell rules.
        for cell in snapshot.cells where dataRows.contains(cell.row) && cell.column < columns.count {
            let column = columns[cell.column]
            let value = normalized[cell.id] ?? .empty
            if column.type != .text {
                tested[CheckRule.typeConversion.id, default: 0] += 1
                if value.kind == .invalid {
                    add(.typeConversion, cell, "\(cell.address): \(value.problem ?? "cannot convert to \(column.type.label.lowercased())")")
                }
            }
            if column.type.isNumeric || column.type == .date {
                tested[CheckRule.ambiguousFormat.id, default: 0] += 1
                if value.kind == .ambiguous {
                    add(.ambiguousFormat, cell, "\(cell.address): \(value.problem ?? "ambiguous value")")
                }
            }
            if column.type.isNumeric {
                tested[CheckRule.leadingZeros.id, default: 0] += 1
                if value.hadLeadingZeros {
                    add(.leadingZeros, cell, "\(cell.address): “\(cell.text)” has leading zeros. Use the Identifier type to keep them.")
                }
            }
            let hasText = !cell.text.trimmingCharacters(in: .whitespaces).isEmpty
            if hasText {
                tested[CheckRule.sourceEvidence.id, default: 0] += 1
                if !cell.hasSourceRegion {
                    if cell.extractedText.trimmingCharacters(in: .whitespaces).isEmpty {
                        add(.sourceEvidence, cell, "\(cell.address): value entered by the user, with no source evidence in the PDF.", severity: .info)
                    } else {
                        add(.sourceEvidence, cell, "\(cell.address): the engine reported no source region for this value.")
                    }
                }
            }
            if let score = cell.engineScore {
                tested[CheckRule.engineScore.id, default: 0] += 1
                if score < 0.5 && !cell.isCorrected {
                    add(.engineScore, cell, "\(cell.address): engine score \(String(format: "%.2f", score)) for “\(cell.extractedText)”.")
                }
            }
            if cell.flags.contains(CellFlag.reextractionConflict) {
                tested[CheckRule.reextraction.id, default: 0] += 1
                add(.reextraction, cell, "\(cell.address): your correction was kept, but the new extraction reads “\(cell.extractedText)”.")
            }
            if cell.flags.contains(CellFlag.continuationMerged) {
                tested[CheckRule.continuation.id, default: 0] += 1
                add(.continuation, cell, "\(cell.address): includes text from a following line.")
            }
        }

        // Row structure.
        for r in snapshot.strictDataRowIndexes {
            tested[CheckRule.rowStructure.id, default: 0] += 1
            var missing: [Int] = []
            var spans: [CellRecord] = []
            var outside: [CellRecord] = []
            for c in 0..<columns.count {
                guard let cell = snapshot.coveringCell(row: r, column: c) else { missing.append(c); continue }
                if cell.row == r && cell.column == c {
                    if cell.colSpan > 1 { spans.append(cell) }
                    if cell.flags.contains(CellFlag.outsideColumns) { outside.append(cell) }
                }
            }
            if !missing.isEmpty {
                add(.rowStructure, nil, row: r, column: missing.first,
                    "Row \(r + 1) has no cell in column \(missing.map { ColumnSpec.letter(for: $0) }.joined(separator: ", ")).")
            }
            for cell in spans {
                add(.rowStructure, cell, "\(cell.address) spans \(cell.colSpan) columns in a data row.")
            }
            for cell in outside {
                add(.rowStructure, cell, "\(cell.address) contains text that crossed a column boundary.")
            }
        }

        // Totals.
        let totalRows = snapshot.run.rows.filter { $0.role == .total }.map(\.index)
        for totalRow in totalRows {
            let previousTotal = totalRows.filter { $0 < totalRow }.max() ?? -1
            let contributing = snapshot.strictDataRowIndexes.filter { $0 > previousTotal && $0 < totalRow }
            for (c, column) in columns.enumerated() where column.type.isNumeric && column.type != .percent {
                guard let totalCell = snapshot.cell(row: totalRow, column: c),
                      let totalValue = normalized[totalCell.id], totalValue.kind == .value,
                      let expected = totalValue.canonical.flatMap(NumberParsing.decimal) else { continue }
                var sum = Decimal(0)
                var maxFraction = totalValue.fractionDigits ?? 0
                var inputs: [UUID] = [totalCell.id]
                var usable = true
                for r in contributing {
                    guard let cell = snapshot.cell(row: r, column: c) else { continue }
                    let v = normalized[cell.id] ?? .empty
                    switch v.kind {
                    case .value:
                        if let d = v.canonical.flatMap(NumberParsing.decimal) {
                            sum += d
                            maxFraction = max(maxFraction, v.fractionDigits ?? 0)
                            inputs.append(cell.id)
                        }
                    case .empty, .missing:
                        continue
                    case .invalid, .ambiguous:
                        usable = false
                    }
                }
                tested[CheckRule.totals.id, default: 0] += 1
                guard usable, inputs.count > 1 else {
                    add(.totals, totalCell, "\(totalCell.address): total not checked because some inputs are not valid numbers.",
                        status: .notApplicable, severity: .info, cells: inputs)
                    continue
                }
                let tolerance: Decimal = settings.totalTolerance.flatMap(NumberParsing.decimal)
                    ?? pow(Decimal(10), -maxFraction)
                let diff = expected - sum
                let absDiff = diff < 0 ? -diff : diff
                let toleranceText = NumberParsing.canonicalString(tolerance)
                if absDiff > tolerance {
                    add(.totals, totalCell, "\(totalCell.address): total \(NumberParsing.canonicalString(expected)) differs from the sum \(NumberParsing.canonicalString(sum)) of \(inputs.count - 1) values by \(NumberParsing.canonicalString(diff)).",
                        tolerance: toleranceText, cells: inputs)
                } else {
                    add(.totals, totalCell, "\(totalCell.address): total matches the sum of \(inputs.count - 1) values.",
                        status: .passed, severity: .info, tolerance: toleranceText, cells: inputs)
                }
            }
        }

        // Duplicate rows.
        var seen: [String: Int] = [:]
        for r in snapshot.strictDataRowIndexes {
            let values = (0..<columns.count).map { c -> String in
                guard let cell = snapshot.cell(row: r, column: c) else { return "" }
                return normalized[cell.id]?.canonical ?? cell.text
            }
            guard values.filter({ !$0.isEmpty }).count >= 2 else { continue }
            tested[CheckRule.duplicates.id, default: 0] += 1
            let key = values.joined(separator: "\u{1F}")
            if let first = seen[key] {
                let ids = (0..<columns.count).compactMap { snapshot.cell(row: r, column: $0)?.id }
                add(.duplicates, nil, row: r, column: 0, "Row \(r + 1) repeats row \(first + 1).", cells: ids)
            } else {
                seen[key] = r
            }
        }

        // Recipe schema.
        if let recipe {
            tested[CheckRule.schema.id, default: 0] += 1
            if recipe.columns.count != columns.count {
                add(.schema, nil, row: nil, column: nil,
                    "The recipe defines \(recipe.columns.count) columns, but this table has \(columns.count). Inspect the column mapping.")
            }
            for (c, column) in columns.enumerated() where c < recipe.columns.count {
                let expected = recipe.columns[c]
                let header = snapshot.headerText(column: c)
                guard !header.isEmpty else { continue }
                if !RecipeMatching.matches(header: header, aliases: expected.aliases + [expected.name]) {
                    let headerCells = snapshot.headerRowIndexes.compactMap { snapshot.coveringCell(row: $0, column: c)?.id }
                    add(.schema, nil, row: snapshot.headerRowIndexes.first, column: c,
                        "Column \(column.letter) header “\(header)” does not match the recipe column “\(expected.name)”.",
                        cells: headerCells)
                }
            }
        }

        var byCell: [UUID: [CheckResult]] = [:]
        for r in results { for id in r.cellIDs { byCell[id, default: []].append(r) } }

        let summaries: [RuleSummary] = CheckRule.all.map { rule in
            let failures = results.filter { $0.ruleID == rule.id && $0.status == .failed }.count
            let n = tested[rule.id, default: 0]
            let status: CheckStatus = n == 0 ? .notApplicable : (failures > 0 ? .failed : .passed)
            let explanation: String
            switch status {
            case .notApplicable: explanation = "No values to test."
            case .passed: explanation = "\(n) tested, none failed."
            case .failed: explanation = "\(failures) of \(n) tested failed."
            }
            return RuleSummary(ruleID: rule.id, ruleVersion: rule.version, status: status, tested: n,
                               failed: failures, explanation: explanation)
        }

        return TableEvaluation(contexts: contexts, normalized: normalized, results: results,
                               summaries: summaries, resultsByCell: byCell)
    }
}
