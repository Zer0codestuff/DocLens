import AppKit
import DocLensCore
import Observation
import PDFKit
import SwiftUI

enum SidebarItem: Hashable {
    case document(UUID)
    case table(UUID)
    case recipe(UUID)

    var storageValue: String {
        switch self {
        case .document(let id): "document:\(id.uuidString)"
        case .table(let id): "table:\(id.uuidString)"
        case .recipe(let id): "recipe:\(id.uuidString)"
        }
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "document": self = .document(id)
        case "table": self = .table(id)
        case "recipe": self = .recipe(id)
        default: return nil
        }
    }
}

struct CellPosition: Hashable {
    var row: Int
    var column: Int
}

/// A rectangular cell range. `cursor` is the active cell shown in the inspector.
struct GridSelection: Hashable {
    var anchor: CellPosition
    var cursor: CellPosition

    init(_ position: CellPosition) {
        anchor = position
        cursor = position
    }

    init(anchor: CellPosition, cursor: CellPosition) {
        self.anchor = anchor
        self.cursor = cursor
    }

    var rows: ClosedRange<Int> { min(anchor.row, cursor.row)...max(anchor.row, cursor.row) }
    var columns: ClosedRange<Int> { min(anchor.column, cursor.column)...max(anchor.column, cursor.column) }
    var isSingleCell: Bool { anchor == cursor }

    func contains(row: Int, column: Int) -> Bool { rows.contains(row) && columns.contains(column) }
}

enum RegionPurpose: Equatable {
    case newTable
    case addSegment
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case cell, column, table, checks
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cell: "Cell"
        case .column: "Column"
        case .table: "Table"
        case .checks: "Checks"
        }
    }
}

struct ExtractionActivity: Equatable {
    var tableID: UUID
    var title: String
    var fraction: Double
    var message: String
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var revealURL: URL?
}

struct PDFFocus: Equatable {
    var pageIndex: Int
    var rect: PageRect?
    /// Zooms so the rectangle fills the view width, used when a table opens.
    var zoom = false
    var token = UUID()
}

struct PageBox: Equatable {
    var pageIndex: Int
    var rect: PageRect
}

struct IssueBox: Equatable {
    var pageIndex: Int
    var rect: PageRect
    var severity: CheckSeverity
}

struct TableOutline: Equatable {
    var tableID: UUID
    var name: String
    var segment: TableSegment
}

/// Everything the PDF overlay draws, in page space.
struct PDFOverlayContent: Equatable {
    var currentSegments: [TableSegment] = []
    var otherTables: [TableOutline] = []
    var selected: [PageBox] = []
    var issues: [IssueBox] = []
    var cellBoxes: [PageBox] = []
    var candidates: [TableCandidate] = []
    var isSelectingRegion = false
}

struct BatchJob: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case running(String)
        case done(tableID: UUID, detail: String)
        case failed(String)
    }

    let id = UUID()
    var documentID: UUID
    var documentTitle: String
    var recipeID: UUID
    var recipeName: String
    var status: Status = .pending
}

@MainActor
@Observable
final class AppModel {
    let store: LibraryStore?
    let storeError: String?

    var documents: [DocumentRecord] = []
    var tablesByDocument: [UUID: [TableRecord]] = [:]
    var recipes: [Recipe] = []

    var sidebarSelection: SidebarItem? {
        didSet {
            guard sidebarSelection != oldValue else { return }
            openSidebarSelection()
            UserDefaults.standard.set(sidebarSelection?.storageValue, forKey: "lastSidebarSelection")
        }
    }

    private(set) var currentDocument: DocumentRecord?
    private(set) var pdfDocument: PDFDocument?
    private(set) var currentTable: TableRecord?
    private(set) var snapshot: TableSnapshot?
    private(set) var evaluation: TableEvaluation?
    private(set) var runs: [ExtractionRun] = []
    /// Incremented whenever the snapshot or its evaluation changes, so AppKit views know to reload.
    private(set) var revision = 0

    var selection: GridSelection? {
        didSet {
            if selection?.cursor != oldValue?.cursor { focusPDFOnSelection() }
        }
    }

    var currentPageIndex = 0
    var regionPurpose: RegionPurpose?
    var candidates: [TableCandidate] = []
    var isDetecting = false
    var pdfFocus: PDFFocus?

    private(set) var activity: ExtractionActivity?
    private var extractionTask: Task<Void, Never>?

    var batchJobs: [BatchJob] = []
    private var batchTask: Task<Void, Never>?

    var alert: AppAlert?
    var notice: Notice?
    var showInspector = true
    var inspectorTab: InspectorTab = .cell
    var showExportSheet = false
    var showSaveRecipeSheet = false
    var showApplyRecipeSheet: Recipe?
    var showBatchPopover = false
    var showCellBoxes = UserDefaults.standard.bool(forKey: PreferenceKey.showCellBoxes) {
        didSet { UserDefaults.standard.set(showCellBoxes, forKey: PreferenceKey.showCellBoxes) }
    }
    var showIssueBoxes = (UserDefaults.standard.object(forKey: PreferenceKey.showIssueBoxes) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showIssueBoxes, forKey: PreferenceKey.showIssueBoxes) }
    }

    weak var undoManager: UndoManager?

    init(directory: URL = LibraryStore.defaultDirectory) {
        do {
            store = try LibraryStore(directory: directory)
            storeError = nil
        } catch {
            store = nil
            storeError = error.localizedDescription
        }
        reloadLibrary()
        if let saved = UserDefaults.standard.string(forKey: "lastSidebarSelection"), let item = SidebarItem(storageValue: saved) {
            switch item {
            case .document(let id) where documents.contains(where: { $0.id == id }): sidebarSelection = item
            case .table(let id) where tablesByDocument.values.contains(where: { $0.contains { $0.id == id } }): sidebarSelection = item
            case .recipe(let id) where recipes.contains(where: { $0.id == id }): sidebarSelection = item
            default: break
            }
        }
    }

    // MARK: Library

    func reloadLibrary() {
        guard let store else { return }
        do {
            documents = try store.documents()
            let tables = try store.tables()
            tablesByDocument = Dictionary(grouping: tables, by: \.documentID)
            recipes = try store.recipes()
        } catch {
            show(error, title: "The library could not be read")
        }
    }

    func tables(for document: DocumentRecord) -> [TableRecord] { tablesByDocument[document.id] ?? [] }

    func importFiles(_ urls: [URL]) {
        guard let store else { return }
        var last: DocumentRecord?
        var failures: [String] = []
        var duplicates = 0
        for url in urls where !url.hasDirectoryPath {
            do {
                let (doc, isNew) = try store.importDocument(from: url)
                if !isNew { duplicates += 1 }
                last = doc
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reloadLibrary()
        if let last { sidebarSelection = .document(last.id) }
        if !failures.isEmpty {
            alert = AppAlert(title: failures.count == 1 ? "A file could not be imported" : "\(failures.count) files could not be imported",
                             message: failures.joined(separator: "\n"))
        } else if duplicates > 0 {
            notice = Notice(text: duplicates == 1 ? "This PDF is already in the library. Opened the existing copy."
                : "\(duplicates) PDFs were already in the library.")
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDF files to add to the library. DocLens keeps a read-only copy."
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func renameDocument(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !t.isEmpty else { return }
        do {
            try store.renameDocument(id: id, title: t)
            reloadLibrary()
            if currentDocument?.id == id { currentDocument = try store.document(id: id) }
        } catch { show(error) }
    }

    func deleteDocument(_ id: UUID) {
        guard let store else { return }
        do {
            if currentDocument?.id == id { closeDocument() }
            try store.deleteDocument(id: id)
            reloadLibrary()
            if case .document(id) = sidebarSelection { sidebarSelection = nil }
        } catch { show(error) }
    }

    func revealSource(_ id: UUID) {
        guard let store, let doc = documents.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.sourceURL(for: doc)])
    }

    // MARK: Opening

    private func openSidebarSelection() {
        guard let store else { return }
        switch sidebarSelection {
        case .document(let id):
            guard let doc = documents.first(where: { $0.id == id }) else { return }
            openDocument(doc)
            if let first = tables(for: doc).first { openTable(first.id, updateSidebar: false) } else { closeTable() }
        case .table(let id):
            guard let table = try? store.table(id: id), let doc = documents.first(where: { $0.id == table.documentID }) else { return }
            if currentDocument?.id != doc.id { openDocument(doc) }
            openTable(id, updateSidebar: false)
        case .recipe, nil:
            break
        }
    }

    private func openDocument(_ doc: DocumentRecord) {
        guard let store else { return }
        currentDocument = doc
        candidates = []
        regionPurpose = nil
        currentPageIndex = 0
        pdfDocument = PDFDocument(url: store.sourceURL(for: doc))
        if pdfDocument == nil {
            alert = AppAlert(title: "The PDF could not be opened",
                             message: "The stored copy of “\(doc.filename)” is missing or unreadable.")
        }
    }

    private func closeDocument() {
        closeTable()
        currentDocument = nil
        pdfDocument = nil
        candidates = []
    }

    func openTable(_ id: UUID, updateSidebar: Bool = true) {
        guard let store else { return }
        do {
            let table = try store.table(id: id)
            if currentDocument?.id != table.documentID, let doc = documents.first(where: { $0.id == table.documentID }) {
                openDocument(doc)
            }
            let switching = currentTable?.id != id
            currentTable = table
            snapshot = try store.snapshot(tableID: id)
            runs = try store.runs(tableID: id)
            reevaluate()
            if switching {
                selection = snapshot.flatMap(firstDataPosition).map(GridSelection.init)
                if let segment = table.segments.first { pdfFocus = PDFFocus(pageIndex: segment.pageIndex, rect: segment.region, zoom: true) }
            }
            if updateSidebar, sidebarSelection != .table(id) { sidebarSelection = .table(id) }
        } catch { show(error) }
    }

    private func closeTable() {
        currentTable = nil
        snapshot = nil
        evaluation = nil
        runs = []
        selection = nil
        revision += 1
    }

    private func firstDataPosition(_ s: TableSnapshot) -> CellPosition? {
        guard s.columnCount > 0, s.rowCount > 0 else { return nil }
        return CellPosition(row: s.strictDataRowIndexes.first ?? 0, column: 0)
    }

    private func reevaluate() {
        if let store, let snapshot {
            evaluation = store.evaluate(snapshot)
        } else {
            evaluation = nil
        }
        revision += 1
    }

    // MARK: Derived state

    var issues: [CheckResult] {
        guard let snapshot, let evaluation else { return [] }
        return evaluation.unresolved(in: snapshot).sorted { ($0.row ?? -1, $0.column ?? -1) < ($1.row ?? -1, $1.column ?? -1) }
    }

    var cursorCell: CellRecord? {
        guard let snapshot, let p = selection?.cursor else { return nil }
        return snapshot.cell(row: p.row, column: p.column) ?? snapshot.coveringCell(row: p.row, column: p.column)
    }

    var selectedCells: [CellRecord] {
        guard let snapshot, let selection else { return [] }
        var seen = Set<UUID>()
        var out: [CellRecord] = []
        for r in selection.rows {
            for c in selection.columns {
                guard let cell = snapshot.coveringCell(row: r, column: c), seen.insert(cell.id).inserted else { continue }
                out.append(cell)
            }
        }
        return out
    }

    var selectedRows: [Int] {
        guard let selection, let snapshot else { return [] }
        return selection.rows.filter { $0 < snapshot.rowCount }
    }

    var overlay: PDFOverlayContent {
        var content = PDFOverlayContent()
        content.isSelectingRegion = regionPurpose != nil
        content.candidates = candidates
        if let doc = currentDocument {
            content.otherTables = tables(for: doc).filter { $0.id != currentTable?.id }
                .flatMap { t in t.segments.map { TableOutline(tableID: t.id, name: t.name, segment: $0) } }
        }
        content.currentSegments = currentTable?.segments ?? []
        guard let snapshot else { return content }
        content.selected = selectedCells.flatMap { cell in
            cell.sources.flatMap { s in s.regions.map { PageBox(pageIndex: s.pageIndex, rect: $0) } }
        }
        if showIssueBoxes, let evaluation {
            var worst: [UUID: CheckSeverity] = [:]
            for r in evaluation.unresolved(in: snapshot) {
                for id in r.cellIDs where (worst[id] ?? .info) <= r.severity { worst[id] = r.severity }
            }
            content.issues = worst.compactMap { id, severity -> [IssueBox]? in
                guard let cell = snapshot.cell(id: id), cell.review != .reviewed else { return nil }
                return cell.sources.flatMap { s in s.regions.map { IssueBox(pageIndex: s.pageIndex, rect: $0, severity: severity) } }
            }.flatMap { $0 }
        }
        if showCellBoxes {
            content.cellBoxes = snapshot.cells.flatMap { cell in
                cell.sources.compactMap { s in s.bounds.map { PageBox(pageIndex: s.pageIndex, rect: $0) } }
            }
        }
        return content
    }

    var isExtracting: Bool { activity != nil }

    // MARK: Selection

    func select(_ position: CellPosition, extend: Bool = false) {
        guard let snapshot, snapshot.rowCount > 0, snapshot.columnCount > 0 else { return }
        let p = CellPosition(row: min(max(0, position.row), snapshot.rowCount - 1),
                             column: min(max(0, position.column), snapshot.columnCount - 1))
        if extend, let current = selection {
            selection = GridSelection(anchor: current.anchor, cursor: p)
        } else {
            selection = GridSelection(p)
        }
    }

    func selectRows(_ rows: ClosedRange<Int>) {
        guard let snapshot, snapshot.columnCount > 0 else { return }
        selection = GridSelection(anchor: CellPosition(row: rows.lowerBound, column: 0),
                                  cursor: CellPosition(row: rows.upperBound, column: snapshot.columnCount - 1))
    }

    func selectColumn(_ column: Int) {
        guard let snapshot, snapshot.rowCount > 0 else { return }
        selection = GridSelection(anchor: CellPosition(row: 0, column: column),
                                  cursor: CellPosition(row: snapshot.rowCount - 1, column: column))
        inspectorTab = .column
    }

    func selectAll() {
        guard let snapshot, snapshot.rowCount > 0, snapshot.columnCount > 0 else { return }
        selection = GridSelection(anchor: CellPosition(row: 0, column: 0),
                                  cursor: CellPosition(row: snapshot.rowCount - 1, column: snapshot.columnCount - 1))
    }

    private func focusPDFOnSelection() {
        guard let cell = cursorCell, let source = cell.sources.first, let bounds = source.bounds else { return }
        pdfFocus = PDFFocus(pageIndex: source.pageIndex, rect: bounds)
    }

    func showCellInPDF() {
        guard let cell = cursorCell, let source = cell.sources.first else { return }
        pdfFocus = PDFFocus(pageIndex: source.pageIndex, rect: source.bounds)
    }

    /// Handles a click on the PDF in browse mode. Returns true when the click selected something.
    func handlePDFClick(pageIndex: Int, x: Double, y: Double) -> Bool {
        if let candidate = candidates.first(where: { $0.pageIndex == pageIndex && $0.region.contains(x: x, y: y) }) {
            createTable(pageIndex: candidate.pageIndex, region: candidate.region)
            return true
        }
        if let snapshot {
            let hit = snapshot.cells.first { cell in
                cell.sources.contains { s in s.pageIndex == pageIndex && s.regions.contains { $0.insetBy(-1).contains(x: x, y: y) } }
            }
            if let hit {
                selection = GridSelection(CellPosition(row: hit.row, column: hit.column))
                return true
            }
        }
        if let other = overlay.otherTables.first(where: { $0.segment.pageIndex == pageIndex && $0.segment.region.contains(x: x, y: y) }) {
            openTable(other.tableID)
            return true
        }
        return false
    }

    // MARK: Issues

    func goToIssue(forward: Bool) {
        let list = issues.filter { $0.row != nil }
        guard !list.isEmpty else {
            notice = Notice(text: "No unresolved issues in this table.")
            return
        }
        let current = selection?.cursor ?? CellPosition(row: forward ? -1 : Int.max, column: 0)
        func key(_ r: CheckResult) -> (Int, Int) { (r.row ?? 0, r.column ?? 0) }
        let cur = (current.row, current.column)
        let target = forward
            ? (list.first { key($0) > cur } ?? list.first!)
            : (list.last { key($0) < cur } ?? list.last!)
        selectIssue(target)
    }

    func selectIssue(_ result: CheckResult) {
        if let row = result.row {
            selection = GridSelection(CellPosition(row: row, column: result.column ?? 0))
            if inspectorTab != .checks { inspectorTab = .cell }
        }
    }

    // MARK: Region selection and detection

    func beginRegionSelection(_ purpose: RegionPurpose) {
        guard pdfDocument != nil else { return }
        regionPurpose = regionPurpose == purpose ? nil : purpose
    }

    func cancelRegionSelection() { regionPurpose = nil }

    func regionSelected(pageIndex: Int, region: PageRect) {
        let purpose = regionPurpose
        regionPurpose = nil
        guard region.width > 6, region.height > 6 else { return }
        switch purpose {
        case .newTable: createTable(pageIndex: pageIndex, region: region)
        case .addSegment: addSegment(pageIndex: pageIndex, region: region)
        case nil: break
        }
    }

    func detectTables() {
        guard let store, let doc = currentDocument, !isDetecting else { return }
        let url = store.sourceURL(for: doc)
        let page = currentPageIndex
        isDetecting = true
        Task {
            defer { isDetecting = false }
            do {
                let found = try await VisionDocumentEngine.detectTables(documentURL: url, pageIndex: page, options: Preferences.extractionOptions)
                guard currentDocument?.id == doc.id else { return }
                let existing = tables(for: doc).flatMap(\.segments).filter { $0.pageIndex == page }
                candidates = found.filter { c in !existing.contains { $0.region.intersectionOverUnion(c.region) > 0.5 } }
                if found.isEmpty {
                    notice = Notice(text: "No tables were detected on page \(page + 1). Drag a rectangle around the table instead.")
                } else if candidates.isEmpty {
                    notice = Notice(text: "The tables on page \(page + 1) are already in the library.")
                } else {
                    notice = Notice(text: candidates.count == 1 ? "Found 1 table. Click it to extract."
                        : "Found \(candidates.count) tables. Click one to extract.")
                }
            } catch {
                show(error, title: "Table detection failed")
            }
        }
    }

    func clearCandidates() { candidates = [] }

    // MARK: Tables

    func createTable(pageIndex: Int, region: PageRect) {
        guard let store, let doc = currentDocument else { return }
        do {
            let table = try store.createTable(document: doc, segments: [TableSegment(pageIndex: pageIndex, region: region)])
            candidates.removeAll { $0.pageIndex == pageIndex && $0.region.intersectionOverUnion(region) > 0.5 }
            reloadLibrary()
            openTable(table.id)
            extract(tableID: table.id, engine: Preferences.defaultEngine)
        } catch { show(error) }
    }

    func addSegment(pageIndex: Int, region: PageRect) {
        guard let store, var table = currentTable else { return }
        table.segments.append(TableSegment(pageIndex: pageIndex, region: region))
        do {
            try store.saveTable(table)
            currentTable = table
            reloadLibrary()
            extract(tableID: table.id, engine: snapshot?.run.engine.configuration["requested"].flatMap(EngineKind.init) ?? snapshot?.run.engine.kind)
        } catch { show(error) }
    }

    func removeSegment(at index: Int) {
        guard let store, var table = currentTable, table.segments.count > 1, index < table.segments.count else { return }
        table.segments.remove(at: index)
        do {
            try store.saveTable(table)
            currentTable = table
            reloadLibrary()
            extract(tableID: table.id, engine: snapshot?.run.engine.kind)
        } catch { show(error) }
    }

    func renameTable(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !n.isEmpty else { return }
        do {
            if var s = snapshot, s.table.id == id {
                try TableEditor(store: store).rename(n, in: &s)
                snapshot = s
                currentTable = s.table
            } else {
                var t = try store.table(id: id)
                t.name = n
                try store.saveTable(t)
                if currentTable?.id == id { currentTable = t }
            }
            reloadLibrary()
        } catch { show(error) }
    }

    func deleteTable(_ id: UUID) {
        guard let store else { return }
        do {
            let docID = try store.table(id: id).documentID
            try store.deleteTable(id: id)
            if currentTable?.id == id {
                closeTable()
                undoManager?.removeAllActions()
            }
            reloadLibrary()
            if sidebarSelection == .table(id) { sidebarSelection = .document(docID) }
        } catch { show(error) }
    }

    func switchVersion(_ runID: UUID) {
        guard let store, let table = currentTable else { return }
        do {
            _ = try store.setCurrentRun(tableID: table.id, runID: runID)
            undoManager?.removeAllActions()
            openTable(table.id, updateSidebar: false)
            notice = Notice(text: "Switched to the version from \(runs.first { $0.id == runID }.map { Self.dateFormatter.string(from: $0.startedAt) } ?? "the selected run").")
        } catch { show(error) }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: Extraction

    func extract(tableID: UUID, engine: EngineKind? = nil, recipe: Recipe? = nil) {
        guard let store, extractionTask == nil else { return }
        let kind = engine ?? Preferences.defaultEngine
        let options = Preferences.extractionOptions
        let table: TableRecord, document: DocumentRecord
        do {
            table = try store.table(id: tableID)
            document = try store.document(id: table.documentID)
        } catch { show(error); return }

        let url = store.sourceURL(for: document)
        var descriptor = ExtractionService.engine(for: kind).descriptor(options: options)
        descriptor.configuration["requested"] = kind.rawValue
        let key = ExtractionService.cacheKey(documentSHA256: document.sha256, engine: descriptor, segments: table.segments)
        let started = Date()
        let hadVersion = table.currentRunID != nil
        activity = ExtractionActivity(tableID: tableID, title: "Extracting \(table.name)", fraction: 0, message: "Starting")

        extractionTask = Task {
            defer {
                activity = nil
                extractionTask = nil
            }
            do {
                let extracted: ExtractedTable
                if let cached = try? store.cachedExtraction(key: key) {
                    extracted = cached
                } else {
                    extracted = try await ExtractionService.extract(
                        documentURL: url, documentID: document.id, segments: table.segments, engine: kind, options: options,
                        progress: { [weak self] fraction, message in
                            Task { @MainActor in
                                guard let self, self.activity?.tableID == tableID else { return }
                                self.activity?.fraction = fraction
                                self.activity?.message = message
                            }
                        })
                    try Task.checkCancellation()
                    try? store.cacheExtraction(extracted, key: key)
                }
                let (_, summary) = try store.commitExtraction(tableID: tableID, extracted: extracted, startedAt: started,
                                                              cacheKey: key, recipe: recipe)
                if currentTable?.id == tableID {
                    undoManager?.removeAllActions()
                    openTable(tableID, updateSidebar: false)
                    selection = snapshot.flatMap(firstDataPosition).map(GridSelection.init)
                    // The pane width changes while a new table's column appears, so zoom again once it has settled.
                    if !hadVersion, let segment = table.segments.first {
                        pdfFocus = PDFFocus(pageIndex: segment.pageIndex, rect: segment.region, zoom: true)
                    }
                }
                reloadLibrary()
                var parts: [String] = []
                if let snap = snapshot, snap.table.id == tableID {
                    parts.append("\(snap.strictDataRowIndexes.count) rows, \(snap.columnCount) columns with \(snap.run.engine.name)")
                }
                if hadVersion { parts.append(summary.message) }
                notice = Notice(text: parts.joined(separator: ". "))
            } catch {
                let cancelled = error is CancellationError || (error as? ExtractionError) == .cancelled
                try? store.recordFailedRun(tableID: tableID, engine: descriptor, startedAt: started, error: error, cancelled: cancelled)
                if currentTable?.id == tableID { runs = (try? store.runs(tableID: tableID)) ?? runs }
                if cancelled {
                    notice = Notice(text: hadVersion ? "Extraction cancelled. The current version is unchanged." : "Extraction cancelled.")
                } else {
                    alert = AppAlert(title: "Extraction failed", message: error.localizedDescription)
                }
            }
        }
    }

    func cancelExtraction() {
        extractionTask?.cancel()
    }

    var lastFailedRun: ExtractionRun? {
        guard snapshot == nil else { return nil }
        return runs.first { $0.status == .failed || $0.status == .cancelled }
    }

    // MARK: Editing

    private var editKind: CorrectionKind {
        if undoManager?.isUndoing == true { return .undo }
        if undoManager?.isRedoing == true { return .redo }
        return .edit
    }

    private func registerUndo(_ name: String, tableID: UUID, _ action: @escaping @MainActor (AppModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if model.currentTable?.id != tableID { model.openTable(tableID) }
                action(model)
            }
        }
        undoManager.setActionName(name)
    }

    private func mutate(_ body: (TableEditor, inout TableSnapshot) throws -> Void) {
        guard let store, var s = snapshot else { return }
        do {
            try body(TableEditor(store: store), &s)
            snapshot = s
            currentTable = s.table
            reevaluate()
        } catch {
            show(error, title: "The change could not be saved")
            if let fresh = try? store.snapshot(tableID: s.table.id) { snapshot = fresh }
            reevaluate()
        }
    }

    /// Sets cell values. Each change is logged as a correction; the extracted text is kept.
    func setTexts(_ edits: [(cellID: UUID, text: String)], actionName: String = "Edit Cell") {
        guard let s = snapshot else { return }
        let changes = edits.compactMap { e -> (UUID, String, String)? in
            guard let cell = s.cell(id: e.cellID), cell.text != e.text else { return nil }
            return (e.cellID, cell.text, e.text)
        }
        guard !changes.isEmpty else { return }
        let kind = editKind
        mutate { editor, snap in
            for (id, _, new) in changes { try editor.setText(new, cellID: id, in: &snap, kind: kind) }
        }
        let inverse = changes.map { (cellID: $0.0, text: $0.1) }
        registerUndo(changes.count == 1 ? actionName : "\(actionName)s", tableID: s.table.id) { model in
            model.setTexts(inverse, actionName: actionName)
        }
    }

    func setText(_ text: String, row: Int, column: Int) {
        guard let s = snapshot, let cell = s.cell(row: row, column: column) ?? s.coveringCell(row: row, column: column) else { return }
        setTexts([(cell.id, text)])
    }

    func clearSelection() {
        setTexts(selectedCells.map { ($0.id, "") }, actionName: "Clear Cell")
    }

    func restoreExtracted() {
        setTexts(selectedCells.filter(\.isCorrected).map { ($0.id, $0.extractedText) }, actionName: "Restore Extracted Value")
    }

    func setReview(_ state: ReviewState, cellIDs: [UUID]? = nil) {
        guard let s = snapshot else { return }
        let ids = cellIDs ?? selectedCells.map(\.id)
        let previous = ids.compactMap { id in s.cell(id: id).map { (id, $0.review) } }.filter { $0.1 != state }
        guard !previous.isEmpty else { return }
        mutate { editor, snap in try editor.setReview(state, cellIDs: previous.map(\.0), in: &snap) }
        registerUndo(state == .reviewed ? "Mark Reviewed" : "Change Review State", tableID: s.table.id) { model in
            for (oldState, group) in Dictionary(grouping: previous, by: \.1) {
                model.setReview(oldState, cellIDs: group.map(\.0))
            }
        }
    }

    /// Marks the selection reviewed, or unreviewed when every selected cell is already reviewed.
    func toggleReviewed() {
        let cells = selectedCells
        guard !cells.isEmpty else { return }
        setReview(cells.allSatisfy { $0.review == .reviewed } ? .unreviewed : .reviewed)
    }

    func markTableReviewed() {
        guard let s = snapshot else { return }
        let rows = Set(s.dataRowIndexes)
        setReview(.reviewed, cellIDs: s.cells.filter { rows.contains($0.row) }.map(\.id))
    }

    func setRole(_ role: RowRole, rows: [Int]? = nil) {
        guard let s = snapshot else { return }
        let target = rows ?? selectedRows
        let previous = target.filter { $0 < s.run.rows.count && s.run.rows[$0].role != role }.map { ($0, s.run.rows[$0].role) }
        guard !previous.isEmpty else { return }
        mutate { editor, snap in
            try editor.setRole(role, rows: previous.map(\.0), in: &snap)
            if role == .header || previous.contains(where: { $0.1 == .header }) { try editor.refreshHeaderNames(in: &snap) }
        }
        registerUndo("Set Row Role", tableID: s.table.id) { model in
            for (oldRole, group) in Dictionary(grouping: previous, by: \.1) { model.setRole(oldRole, rows: group.map(\.0)) }
        }
    }

    func updateColumn(_ column: ColumnSpec) {
        guard let s = snapshot, column.index < s.table.columns.count else { return }
        let old = s.table.columns[column.index]
        guard old != column else { return }
        mutate { editor, snap in try editor.updateColumn(column, in: &snap) }
        registerUndo("Change Column", tableID: s.table.id) { model in model.updateColumn(old) }
    }

    func updateSettings(_ settings: TableSettings) {
        guard let s = snapshot else { return }
        let old = s.table.settings
        guard old != settings else { return }
        mutate { editor, snap in try editor.updateSettings(settings, in: &snap) }
        registerUndo("Change Table Settings", tableID: s.table.id) { model in model.updateSettings(old) }
    }

    func copySelection() {
        guard let s = snapshot, let selection else { return }
        let text = selection.rows.map { r in
            selection.columns.map { c in s.cell(row: r, column: c)?.text ?? "" }
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Pastes tab-separated text starting at the cursor. Values outside the table are ignored.
    func paste() {
        guard let s = snapshot, let start = selection?.cursor,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let trimmed = lines.last == [""] ? Array(lines.dropLast()) : lines
        var edits: [(cellID: UUID, text: String)] = []
        if trimmed.count == 1, trimmed[0].count == 1, let selection, !selection.isSingleCell {
            for cell in selectedCells { edits.append((cell.id, trimmed[0][0])) }
        } else {
            for (i, values) in trimmed.enumerated() {
                for (j, value) in values.enumerated() {
                    guard let cell = s.cell(row: start.row + i, column: start.column + j) else { continue }
                    edits.append((cell.id, value))
                }
            }
        }
        setTexts(edits, actionName: "Paste")
    }

    // MARK: Export

    func export(format: ExportService.Format, options: ExportOptions) {
        guard let snapshot, let evaluation else { return }
        let panel = NSSavePanel()
        let base = "\(snapshot.document.title) - \(snapshot.table.name)"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : format == .json ? .json
            : .init(filenameExtension: "xlsx") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let written = try ExportService.export(snapshot: snapshot, evaluation: evaluation, format: format, options: options,
                                                   to: url, appVersion: Preferences.appVersion)
            Preferences.exportOptions = options
            Preferences.exportFormat = format
            let extra = written.count > 1 ? " with a provenance file" : ""
            notice = Notice(text: "Exported \(url.lastPathComponent)\(extra).", revealURL: url)
        } catch {
            show(error, title: "Export failed")
        }
    }

    // MARK: Recipes

    func saveRecipe(name: String, notes: String) {
        guard let store, let snapshot else { return }
        var recipe = RecipeBuilder.make(name: name, from: snapshot,
                                        engine: snapshot.run.engine.configuration["requested"].flatMap(EngineKind.init) ?? snapshot.run.engine.kind)
        recipe.notes = notes
        do {
            let saved = try store.saveRecipe(recipe)
            var table = snapshot.table
            table.recipeID = saved.id
            table.recipeVersion = saved.version
            try store.saveTable(table)
            self.snapshot?.table = table
            currentTable = table
            reloadLibrary()
            notice = Notice(text: "Saved recipe “\(saved.name)”.")
        } catch { show(error) }
    }

    func updateRecipe(_ recipe: Recipe) {
        guard let store else { return }
        do {
            _ = try store.saveRecipe(recipe)
            reloadLibrary()
        } catch { show(error) }
    }

    func deleteRecipe(_ id: UUID) {
        guard let store else { return }
        do {
            try store.deleteRecipe(id: id)
            if sidebarSelection == .recipe(id) { sidebarSelection = nil }
            reloadLibrary()
        } catch { show(error) }
    }

    var activeRecipe: Recipe? {
        guard case .recipe(let id) = sidebarSelection else { return nil }
        return recipes.first { $0.id == id }
    }

    /// Queues the recipe for each document. Jobs run one at a time.
    func applyRecipe(_ recipe: Recipe, to documentIDs: [UUID]) {
        let jobs = documentIDs.compactMap { id in documents.first { $0.id == id } }.map {
            BatchJob(documentID: $0.id, documentTitle: $0.title, recipeID: recipe.id, recipeName: recipe.name)
        }
        guard !jobs.isEmpty else { return }
        batchJobs.removeAll { if case .done = $0.status { return true }; if case .failed = $0.status { return true }; return false }
        batchJobs.append(contentsOf: jobs)
        showBatchPopover = true
        runBatch()
    }

    private func runBatch() {
        guard batchTask == nil, let store else { return }
        batchTask = Task {
            defer { batchTask = nil }
            while let index = batchJobs.firstIndex(where: { $0.status == .pending }) {
                if Task.isCancelled { break }
                let job = batchJobs[index]
                batchJobs[index].status = .running("Locating table")
                do {
                    guard let recipe = try store.recipe(id: job.recipeID) else { throw LibraryError.notFound("The recipe") }
                    let doc = try store.document(id: job.documentID)
                    let url = store.sourceURL(for: doc)
                    let options = Preferences.extractionOptions
                    let location = try await Task.detached {
                        try await RecipeApplier.locate(recipe: recipe, documentURL: url, options: options)
                    }.value
                    let table = try store.createTable(document: doc, segments: [location.segment],
                                                      name: "\(recipe.name)", recipe: recipe)
                    batchJobs[index].status = .running("Extracting")
                    let extracted = try await ExtractionService.extract(
                        documentURL: url, documentID: doc.id, segments: [location.segment], engine: recipe.engine,
                        options: Preferences.extractionOptions, progress: { _, _ in })
                    let (snap, _) = try store.commitExtraction(tableID: table.id, extracted: extracted, startedAt: Date(),
                                                               cacheKey: nil, recipe: recipe)
                    let evaluation = store.evaluate(snap)
                    let issues = evaluation.unresolved(in: snap).count
                    batchJobs[index].status = .done(tableID: table.id,
                                                    detail: "\(snap.strictDataRowIndexes.count) rows, found by \(location.method)"
                                                        + (issues > 0 ? ", \(issues) issue\(issues == 1 ? "" : "s")" : ""))
                } catch {
                    batchJobs[index].status = .failed(error.localizedDescription)
                }
                reloadLibrary()
            }
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
        for i in batchJobs.indices where batchJobs[i].status == .pending { batchJobs[i].status = .failed("Cancelled") }
    }

    var batchIsRunning: Bool { batchJobs.contains { if case .running = $0.status { return true }; return $0.status == .pending } }

    // MARK: Errors

    func show(_ error: Error, title: String = "Something went wrong") {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }
}
