import DocLensCore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in Text(tab.label).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if let snapshot = model.snapshot {
                switch model.inspectorTab {
                case .cell: CellInspector(snapshot: snapshot)
                case .column: ColumnInspector(snapshot: snapshot)
                case .table: TableInspector(snapshot: snapshot)
                case .checks: ChecksInspector(snapshot: snapshot)
                }
            } else if model.currentTable != nil {
                TableInspectorWithoutVersion()
            } else {
                ContentUnavailableView("No Table", systemImage: "sidebar.right",
                                       description: Text("Select or extract a table to inspect its cells, columns, and checks."))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Shared pieces

struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        LabeledContent(label) { content }
    }
}

struct SeverityIcon: View {
    let severity: CheckSeverity
    var body: some View {
        switch severity {
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct CheckResultRow: View {
    let result: CheckResult
    let resolved: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SeverityIcon(severity: result.severity)
                .opacity(resolved ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(CheckRule.rule(id: result.ruleID)?.title ?? result.ruleID)
                    if let tolerance = result.tolerance { Text("Tolerance \(tolerance)") }
                    if resolved { Text("Reviewed") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .help(result.tested)
    }
}

extension CorrectionKind {
    var label: String {
        switch self {
        case .edit: "Edited"
        case .undo: "Undo"
        case .redo: "Redo"
        case .review: "Review"
        case .columnType: "Column type"
        case .columnRename: "Column name"
        case .columnSettings: "Column settings"
        case .rowRole: "Row role"
        case .carriedOver: "Carried over"
        case .conflict: "Conflict"
        case .tableSettings: "Table settings"
        }
    }
}

struct CorrectionRow: View {
    let correction: Correction

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(correction.kind.label).font(.callout.weight(.medium))
                Spacer()
                Text(correction.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if correction.before != nil || correction.after != nil {
                HStack(spacing: 4) {
                    Text(display(correction.before)).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(display(correction.after))
                }
                .font(.caption.monospaced())
                .lineLimit(2)
            }
            if !correction.detail.isEmpty {
                Text(correction.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func display(_ s: String?) -> String {
        guard let s else { return "none" }
        return s.isEmpty ? "empty" : s
    }
}

// MARK: - Cell

struct CellInspector: View {
    @Environment(AppModel.self) private var model
    let snapshot: TableSnapshot
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        if let cell = model.cursorCell {
            Form {
                header(cell)
                valueSection(cell)
                interpretationSection(cell)
                sourceSection(cell)
                checksSection(cell)
                historySection(cell)
            }
            .formStyle(.grouped)
            .onAppear { draft = cell.text }
            .onChange(of: cell.id) { draft = cell.text }
            .onChange(of: cell.text) { if !editing { draft = cell.text } }
        } else {
            ContentUnavailableView("No Cell Selected", systemImage: "square.dashed",
                                   description: Text("Select a cell in the table or click its text in the PDF."))
        }
    }

    @ViewBuilder private func header(_ cell: CellRecord) -> some View {
        Section {
            LabeledContent("Cell") {
                Text(cell.address + (cell.rowSpan > 1 || cell.colSpan > 1 ? "  (spans \(cell.rowSpan) × \(cell.colSpan))" : ""))
                    .font(.body.monospaced())
            }
            LabeledContent("Row") {
                Text("\(snapshot.role(of: cell.row).label)")
            }
            Picker("Review", selection: Binding(get: { cell.review }, set: { model.setReview($0, cellIDs: [cell.id]) })) {
                ForEach(ReviewState.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .help("Review is your confirmation that the value matches the source. Automatic checks never set it.")
        }
    }

    @ViewBuilder private func valueSection(_ cell: CellRecord) -> some View {
        Section("Value") {
            TextField("Value", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($editing)
                .onSubmit { model.setTexts([(cell.id, draft)]) }
                .onChange(of: editing) { _, now in if !now, draft != cell.text { model.setTexts([(cell.id, draft)]) } }
                .labelsHidden()
            LabeledContent("Extracted") {
                Text(cell.extractedText.isEmpty ? "empty" : cell.extractedText)
                    .font(.callout.monospaced())
                    .foregroundStyle(cell.extractedText.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            if cell.isCorrected {
                Button("Restore Extracted Value") { model.setTexts([(cell.id, cell.extractedText)], actionName: "Restore Extracted Value") }
            }
        }
    }

    @ViewBuilder private func interpretationSection(_ cell: CellRecord) -> some View {
        let column = cell.column < snapshot.table.columns.count ? snapshot.table.columns[cell.column] : nil
        if let value = model.evaluation?.normalized[cell.id], let column, snapshot.dataRowIndexes.contains(cell.row) {
            Section("Interpretation") {
                LabeledContent("Column type", value: column.type.label + (column.typeConfirmed ? "" : " (suggested)"))
                LabeledContent("Result") {
                    Text(kindLabel(value.kind))
                        .foregroundStyle(value.kind == .invalid || value.kind == .ambiguous ? .orange : .primary)
                }
                if let canonical = value.canonical, value.kind == .value {
                    LabeledContent("Exported as") {
                        Text(canonical).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if let problem = value.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                if value.kind == .ambiguous, !value.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Possible readings").font(.caption).foregroundStyle(.secondary)
                        ForEach(value.candidates, id: \.self) { c in
                            Text(c).font(.callout.monospaced())
                        }
                        if column.type.isNumeric {
                            HStack {
                                Button("Point decimal") { setColumnFormat(column, .pointDecimal) }
                                Button("Comma decimal") { setColumnFormat(column, .commaDecimal) }
                            }
                            .controlSize(.small)
                            Text(column.numberFormat == nil || column.numberFormat == .auto
                                 ? "Applies to every column without its own number format."
                                 : "Applies to this column.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if column.type == .date {
                            HStack {
                                Button("Day first") { setDateOrder(.dmy) }
                                Button("Month first") { setDateOrder(.mdy) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if !value.transformations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Steps").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(value.transformations.enumerated()), id: \.offset) { _, t in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.operation).font(.callout)
                                Text("\(t.input)  →  \(t.output)\(t.detail.isEmpty ? "" : "  (\(t.detail))")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let ctx = model.evaluation?.contexts[safe: cell.column], column.type.isNumeric {
                    LabeledContent("Decimal separator") {
                        DecimalSeparatorLabel(context: ctx)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func kindLabel(_ kind: ValueKind) -> String {
        switch kind {
        case .empty: "Empty"
        case .missing: "Missing value marker"
        case .value: "Converted"
        case .ambiguous: "Ambiguous"
        case .invalid: "Cannot convert"
        }
    }

    /// Decimal conventions almost always hold for a whole table, so resolve at table level
    /// unless this column already overrides the table format.
    private func setColumnFormat(_ column: ColumnSpec, _ format: NumberFormat) {
        if column.numberFormat == nil || column.numberFormat == .auto {
            var settings = snapshot.table.settings
            settings.numberFormat = format
            model.updateSettings(settings)
        } else {
            var c = column
            c.numberFormat = format
            model.updateColumn(c)
        }
    }

    private func setDateOrder(_ order: DateOrder) {
        var settings = snapshot.table.settings
        settings.dateOrder = order
        model.updateSettings(settings)
    }

    @ViewBuilder private func sourceSection(_ cell: CellRecord) -> some View {
        Section("Source") {
            if let source = cell.sources.first, let bounds = source.bounds {
                LabeledContent("Page", value: "\(source.pageIndex + 1)")
                LabeledContent("Located by", value: source.method.label)
                LabeledContent("Region") {
                    Text(bounds.formatted).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let score = cell.engineScore {
                    LabeledContent("Engine score") {
                        Text(String(format: "%.2f", score)).font(.callout.monospacedDigit())
                    }
                    .help("The raw score reported by the recognition engine. It is not a calibrated probability that the value is correct.")
                }
                Button("Show in PDF") { model.showCellInPDF() }
            } else {
                Text(cell.text.isEmpty ? "Empty cell, no source region." : "No source region was recorded for this value.")
                    .foregroundStyle(.secondary)
            }
            if !cell.flags.isEmpty {
                LabeledContent("Flags") {
                    Text(cell.flags.map(flagLabel).joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func flagLabel(_ flag: String) -> String {
        switch flag {
        case CellFlag.continuationMerged: "merged wrapped lines"
        case CellFlag.spansColumns: "spans columns"
        case CellFlag.outsideColumns: "text outside columns"
        case CellFlag.repeatedHeader: "repeated header"
        case CellFlag.carriedOver: "correction carried over"
        case CellFlag.reextractionConflict: "re-extraction conflict"
        default: flag
        }
    }

    @ViewBuilder private func checksSection(_ cell: CellRecord) -> some View {
        let results = model.evaluation?.resultsByCell[cell.id]?.filter { $0.status == .failed } ?? []
        if !results.isEmpty {
            Section("Checks") {
                ForEach(results) { r in
                    CheckResultRow(result: r, resolved: cell.review == .reviewed)
                }
            }
        }
    }

    @ViewBuilder private func historySection(_ cell: CellRecord) -> some View {
        let history = snapshot.corrections(for: cell.id)
        if !history.isEmpty {
            Section("History") {
                ForEach(history.reversed()) { CorrectionRow(correction: $0) }
            }
        }
    }
}

struct DecimalSeparatorLabel: View {
    let context: ColumnContext

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(context.decimal.map { "“\(String($0))”" } ?? "unknown")
            Text(context.resolution.label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Column

struct ColumnInspector: View {
    @Environment(AppModel.self) private var model
    let snapshot: TableSnapshot
    @State private var name = ""
    @State private var unit = ""
    @State private var scale = ""

    var body: some View {
        if let index = model.selection?.cursor.column, let column = snapshot.table.columns[safe: index] {
            Form {
                Section {
                    LabeledContent("Column", value: column.letter)
                    TextField("Name", text: $name)
                        .onSubmit { commit(column) }
                    if !column.sourceHeader.isEmpty, column.sourceHeader != column.name {
                        LabeledContent("Header in PDF") { Text(column.sourceHeader).foregroundStyle(.secondary) }
                    }
                }
                Section("Type") {
                    Picker("Type", selection: Binding(get: { column.type }, set: { t in
                        var c = column
                        c.type = t
                        c.typeConfirmed = true
                        model.updateColumn(c)
                    })) {
                        ForEach(ColumnType.allCases) { Text($0.label).tag($0) }
                    }
                    if !column.typeConfirmed {
                        HStack {
                            Text("Suggested from the values.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Confirm") {
                                var c = column
                                c.typeConfirmed = true
                                model.updateColumn(c)
                            }
                            .controlSize(.small)
                        }
                    }
                    if column.type.isNumeric {
                        Picker("Number format", selection: Binding(get: { column.numberFormat }, set: { f in
                            var c = column
                            c.numberFormat = f
                            model.updateColumn(c)
                        })) {
                            Text("Table setting").tag(NumberFormat?.none)
                            ForEach(NumberFormat.allCases.filter { $0 != .auto }) { Text($0.label).tag(NumberFormat?.some($0)) }
                        }
                        if let ctx = model.evaluation?.contexts[safe: index] {
                            LabeledContent("Decimal separator") {
                                DecimalSeparatorLabel(context: ctx)
                            }
                            .font(.callout)
                        }
                        TextField("Unit", text: $unit, prompt: Text("e.g. EUR, km²"))
                            .onSubmit { commit(column) }
                        TextField("Scale", text: $scale, prompt: Text("1"))
                            .onSubmit { commit(column) }
                            .help("Multiplier applied to exported numbers, for example 1000 for a column in thousands.")
                    }
                }
                Section("Values") {
                    let stats = statistics(index)
                    LabeledContent("Data cells", value: "\(stats.total)")
                    LabeledContent("Reviewed", value: "\(stats.reviewed)")
                    LabeledContent("Corrected", value: "\(stats.corrected)")
                    if stats.problems > 0 { LabeledContent("Not converted", value: "\(stats.problems)") }
                    Button("Mark Column Reviewed") {
                        let rows = Set(snapshot.dataRowIndexes)
                        model.setReview(.reviewed, cellIDs: snapshot.cells.filter { $0.column == index && rows.contains($0.row) }.map(\.id))
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { load(column) }
            .onChange(of: column) { load(column) }
        } else {
            ContentUnavailableView("No Column Selected", systemImage: "rectangle.split.3x1")
        }
    }

    private func load(_ c: ColumnSpec) {
        name = c.name
        unit = c.unit
        scale = c.scale
    }

    private func commit(_ column: ColumnSpec) {
        var c = column
        c.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? column.name : name
        c.unit = unit.trimmingCharacters(in: .whitespaces)
        let s = scale.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || NumberParsing.decimal(s) != nil { c.scale = s.isEmpty ? "1" : s } else { scale = column.scale }
        model.updateColumn(c)
    }

    private func statistics(_ column: Int) -> (total: Int, reviewed: Int, corrected: Int, problems: Int) {
        let rows = Set(snapshot.dataRowIndexes)
        let cells = snapshot.cells.filter { $0.column == column && rows.contains($0.row) }
        let problems = cells.filter { c in
            let k = model.evaluation?.normalized[c.id]?.kind
            return k == .invalid || k == .ambiguous
        }.count
        return (cells.count, cells.filter { $0.review == .reviewed }.count, cells.filter(\.isCorrected).count, problems)
    }
}

// MARK: - Table

struct TableInspector: View {
    @Environment(AppModel.self) private var model
    let snapshot: TableSnapshot
    @State private var missingTokens = ""
    @State private var tolerance = ""
    @State private var confirmVersion: ExtractionRun?
    @State private var confirmReviewAll = false

    var body: some View {
        let settings = snapshot.table.settings
        Form {
            Section("Interpretation") {
                Picker("Number format", selection: Binding(get: { settings.numberFormat }, set: { f in
                    var s = settings
                    s.numberFormat = f
                    model.updateSettings(s)
                })) {
                    ForEach(NumberFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Date order", selection: Binding(get: { settings.dateOrder }, set: { o in
                    var s = settings
                    s.dateOrder = o
                    model.updateSettings(s)
                })) {
                    ForEach(DateOrder.allCases) { Text($0.label).tag($0) }
                }
                TextField("Missing values", text: $missingTokens)
                    .onSubmit {
                        var s = settings
                        s.missingTokens = missingTokens.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                        model.updateSettings(s)
                    }
                    .help("Markers that mean a value is missing in typed columns, separated by spaces.")
                TextField("Total tolerance", text: $tolerance, prompt: Text("Smallest decimal place"))
                    .onSubmit {
                        var s = settings
                        let t = tolerance.trimmingCharacters(in: .whitespaces)
                        s.totalTolerance = t.isEmpty ? nil : (NumberParsing.decimal(t) != nil ? t : settings.totalTolerance)
                        model.updateSettings(s)
                    }
                Toggle("Remove footnote markers", isOn: Binding(get: { settings.stripFootnoteMarkers }, set: { v in
                    var s = settings
                    s.stripFootnoteMarkers = v
                    model.updateSettings(s)
                }))
            }

            Section("Regions") {
                ForEach(Array(snapshot.table.segments.enumerated()), id: \.offset) { i, segment in
                    HStack {
                        Text("Page \(segment.pageIndex + 1)")
                        Spacer()
                        Button("Show") { model.pdfFocus = PDFFocus(pageIndex: segment.pageIndex, rect: segment.region) }
                            .controlSize(.small)
                        if snapshot.table.segments.count > 1 {
                            Button(role: .destructive) { model.removeSegment(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove this region and extract again")
                        }
                    }
                }
                Button("Add Region on Another Page") { model.beginRegionSelection(.addSegment) }
            }

            Section("Extraction") {
                let run = snapshot.run
                LabeledContent("Engine", value: run.engine.name)
                LabeledContent("Version", value: run.engine.version)
                if let requested = run.engine.configuration["requested"], let kind = EngineKind(rawValue: requested) {
                    LabeledContent("Requested", value: kind.label)
                }
                if let finished = run.finishedAt {
                    LabeledContent("Duration", value: String(format: "%.2f s", finished.timeIntervalSince(run.startedAt)))
                }
                LabeledContent("Extracted", value: AppModel.dateFormatter.string(from: run.startedAt))
                DisclosureGroup("Configuration") {
                    ForEach(run.engine.configuration.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        LabeledContent(k) { Text(v).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    LabeledContent("Source SHA-256") {
                        Text(run.documentSHA256.prefix(16) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .help(run.documentSHA256)
                }
                ForEach(run.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            }

            if model.runs.count > 1 {
                Section("Versions") {
                    ForEach(model.runs) { run in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(AppModel.dateFormatter.string(from: run.startedAt))
                                Text(run.status == .completed ? run.engine.name : "\(run.status.rawValue.capitalized): \(run.errorMessage ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if run.id == snapshot.run.id {
                                Text("Current").font(.caption).foregroundStyle(.secondary)
                            } else if run.status == .completed {
                                Button("Use") { confirmVersion = run }.controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section("Recipe") {
                if let id = snapshot.table.recipeID, let recipe = model.recipes.first(where: { $0.id == id }) {
                    LabeledContent("Recipe", value: "\(recipe.name), version \(snapshot.table.recipeVersion ?? recipe.version)")
                }
                Button("Save as Recipe…") { model.showSaveRecipeSheet = true }
            }

            Section {
                Button("Mark All Data Cells Reviewed…") { confirmReviewAll = true }
            } footer: {
                Text("Marking reviewed records that you checked the values against the PDF. Passing checks never mark cells reviewed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: snapshot.table.settings) { load() }
        .confirmationDialog("Use this version?", isPresented: Binding(get: { confirmVersion != nil }, set: { if !$0 { confirmVersion = nil } })) {
            Button("Use Version") { if let r = confirmVersion { model.switchVersion(r.id) } }
        } message: {
            Text("The table shows the selected extraction with its own corrections. No version is deleted.")
        }
        .confirmationDialog("Mark every data cell reviewed?", isPresented: $confirmReviewAll) {
            Button("Mark Reviewed") { model.markTableReviewed() }
        } message: {
            Text("Only do this after checking every value against the PDF.")
        }
    }

    private func load() {
        missingTokens = snapshot.table.settings.missingTokens.joined(separator: " ")
        tolerance = snapshot.table.settings.totalTolerance ?? ""
    }
}

struct TableInspectorWithoutVersion: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let table = model.currentTable {
                Section("Regions") {
                    ForEach(Array(table.segments.enumerated()), id: \.offset) { _, s in
                        LabeledContent("Page \(s.pageIndex + 1)") { Text(s.region.formatted).font(.caption.monospaced()) }
                    }
                }
            }
            if !model.runs.isEmpty {
                Section("Attempts") {
                    ForEach(model.runs) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(run.engine.name): \(run.status.rawValue)")
                            if let e = run.errorMessage { Text(e).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Checks

struct ChecksInspector: View {
    @Environment(AppModel.self) private var model
    let snapshot: TableSnapshot

    var body: some View {
        let evaluation = model.evaluation
        let disclosure = evaluation.map { ReviewDisclosure(snapshot: snapshot, evaluation: $0) }
        Form {
            if let d = disclosure {
                Section("Review") {
                    ProgressView(value: Double(d.reviewed), total: Double(max(1, d.cells))) {
                        Text("\(d.reviewed) of \(d.cells) cells reviewed")
                    }
                    LabeledContent("Unresolved issues", value: "\(d.unresolvedIssues)")
                    LabeledContent("Corrected cells", value: "\(d.correctedCells)")
                    if d.cellsWithoutSource > 0 { LabeledContent("Values without source", value: "\(d.cellsWithoutSource)") }
                }
            }
            let issues = model.issues
            if !issues.isEmpty {
                Section("Issues") {
                    ForEach(issues.prefix(300)) { issue in
                        Button {
                            model.selectIssue(issue)
                        } label: {
                            HStack(alignment: .top) {
                                CheckResultRow(result: issue, resolved: false)
                                Spacer()
                                if let r = issue.row {
                                    Text("\(ColumnSpec.letter(for: issue.column ?? 0))\(r + 1)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if issues.count > 300 {
                        Text("\(issues.count - 300) more. Use Next Issue to step through them.").foregroundStyle(.secondary)
                    }
                }
            }
            if let evaluation {
                Section("Rules") {
                    ForEach(evaluation.summaries) { s in
                        if let rule = CheckRule.rule(id: s.ruleID) {
                            HStack(alignment: .top, spacing: 8) {
                                ruleIcon(s, rule: rule)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.title)
                                    Text(s.explanation.isEmpty ? rule.tests : s.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(s.status == .notApplicable ? "n/a" : "\(s.failed)/\(s.tested)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .help("\(rule.tests) Rule \(rule.id), version \(rule.version).")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func ruleIcon(_ s: RuleSummary, rule: CheckRule) -> some View {
        switch s.status {
        case .passed: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .notApplicable: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .failed: SeverityIcon(severity: rule.severity)
        }
    }
}
