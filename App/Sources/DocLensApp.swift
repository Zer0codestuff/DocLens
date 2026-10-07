import DocLensCore
import SwiftUI

@main
struct DocLensApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel

    init() {
        let override = ProcessInfo.processInfo.environment["DOCLENS_LIBRARY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let model = AppModel(directory: override ?? LibraryStore.defaultDirectory)
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("DocLens", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { DocLensCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    @MainActor private var pending: [URL] = []
    @MainActor private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            launched = true
            if !pending.isEmpty {
                Self.model?.importFiles(pending)
                pending = []
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if launched { Self.model?.importFiles(urls) } else { pending.append(contentsOf: urls) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct DocLensCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import PDF…") { model.presentImportPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .importExport) {
            Button("Export Table…") { model.showExportSheet = true }
                .keyboardShortcut("e")
                .disabled(model.snapshot == nil)
        }
        CommandMenu("Table") {
            Button("Select Table Region") { model.beginRegionSelection(.newTable) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.pdfDocument == nil || model.isExtracting)
            Button("Detect Tables on Page") { model.detectTables() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.pdfDocument == nil || model.isDetecting)
            Button("Add Region on Another Page") { model.beginRegionSelection(.addSegment) }
                .disabled(model.currentTable == nil || model.isExtracting)
            Divider()
            Menu("Extract Again With") {
                ForEach(EngineKind.allCases) { kind in
                    Button(kind.label) { if let t = model.currentTable { model.extract(tableID: t.id, engine: kind) } }
                }
            }
            .disabled(model.currentTable == nil || model.isExtracting)
            Button("Cancel Extraction") { model.cancelExtraction() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isExtracting)
            Divider()
            Button("Mark Reviewed") { model.setReview(.reviewed) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selection == nil)
            Button("Mark Needs Review") { model.setReview(.needsReview) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.selection == nil)
            Button("Restore Extracted Value") { model.restoreExtracted() }
                .disabled(!model.selectedCells.contains(where: \.isCorrected))
            Divider()
            Button("Next Issue") { model.goToIssue(forward: true) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.snapshot == nil)
            Button("Previous Issue") { model.goToIssue(forward: false) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.snapshot == nil)
            Divider()
            Menu("Row Role") {
                ForEach(RowRole.allCases, id: \.self) { role in
                    Button(role.label) { model.setRole(role) }
                }
            }
            .disabled(model.selection == nil)
            Divider()
            Button("Save as Recipe…") { model.showSaveRecipeSheet = true }
                .disabled(model.snapshot == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Show Cell Boxes on PDF", isOn: Binding(get: { model.showCellBoxes }, set: { model.showCellBoxes = $0 }))
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Toggle("Show Issues on PDF", isOn: Binding(get: { model.showIssueBoxes }, set: { model.showIssueBoxes = $0 }))
            Divider()
        }
    }
}
