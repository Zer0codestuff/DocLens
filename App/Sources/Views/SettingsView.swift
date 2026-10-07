import DocLensCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            // Grouped forms have no ideal height, so each tab sets one that fits its content.
            Tab("Extraction", systemImage: "tablecells") { EngineSettings().frame(height: 560) }
            Tab("Library", systemImage: "books.vertical") { LibrarySettings().frame(height: 420) }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

struct EngineSettings: View {
    @AppStorage(PreferenceKey.defaultEngine) private var engine = EngineKind.auto.rawValue
    @AppStorage(PreferenceKey.recognitionLanguages) private var languages = ""
    @AppStorage(PreferenceKey.languageCorrection) private var languageCorrection = false
    @AppStorage(PreferenceKey.ocrDPI) private var dpi = 300.0
    @AppStorage(PreferenceKey.doclingPython) private var python = ""
    @State private var doclingStatus: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Picker("Default engine", selection: $engine) {
                    ForEach(EngineKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text(EngineKind(rawValue: engine)?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Text recognition") {
                TextField("Languages", text: $languages, prompt: Text("Automatic"))
                    .help("Recognition languages as BCP 47 codes, for example en-US, it-IT, de-DE.")
                Picker("Resolution", selection: $dpi) {
                    Text("200 dpi").tag(200.0)
                    Text("300 dpi").tag(300.0)
                    Text("400 dpi").tag(400.0)
                }
                Toggle("Language correction", isOn: $languageCorrection)
                Text("Language correction can change digits and codes. Keep it off for numeric tables.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Python interpreter", text: $python, prompt: Text("/path/to/venv/bin/python3"))
                HStack {
                    Button("Test") { test() }
                        .disabled(python.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let doclingStatus {
                        Text(doclingStatus).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } header: {
                Text("Docling (optional)")
            } footer: {
                Text("Docling runs as a separate local process. DocLens does not need it; the built-in engines work offline without Python.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        doclingStatus = nil
        let path = python.trimmingCharacters(in: .whitespaces)
        Task {
            defer { testing = false }
            do {
                let hello = try await DoclingEngine.handshake(python: path)
                doclingStatus = hello.docling.map { "Docling \($0) with Python \(hello.python)." }
                    ?? "Python \(hello.python) runs the worker, but Docling is not installed in this environment."
            } catch {
                doclingStatus = error.localizedDescription
            }
        }
    }
}

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var cleared = false

    var body: some View {
        Form {
            if let store = model.store {
                Section {
                    LabeledContent("Location") {
                        Text(store.directory.path(percentEncoded: false))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
                } footer: {
                    Text("Imported PDFs are stored read-only and named by their SHA-256 hash. The database keeps extraction versions and every correction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Clear Extraction Cache") {
                            try? store.clearCache()
                            cleared = true
                        }
                        if cleared { Text("Cleared").foregroundStyle(.secondary) }
                    }
                } footer: {
                    Text("The cache reuses results when the same region is extracted again with the same engine and settings. Clearing it does not affect tables or corrections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Version", value: Preferences.appVersion)
                LabeledContent("Library schema", value: "\(LibraryStore.schemaVersion)")
                LabeledContent("Export schema", value: "\(JSONExporter.schemaVersion)")
            }
        }
        .formStyle(.grouped)
    }
}
