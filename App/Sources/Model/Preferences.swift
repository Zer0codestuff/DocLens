import DocLensCore
import Foundation

/// User defaults keys and typed accessors. Views bind to the same keys with `@AppStorage`.
enum PreferenceKey {
    static let defaultEngine = "defaultEngine"
    static let recognitionLanguages = "recognitionLanguages"
    static let languageCorrection = "languageCorrection"
    static let ocrDPI = "ocrDPI"
    static let doclingPython = "doclingPython"
    static let exportOptions = "exportOptions"
    static let exportFormat = "exportFormat"
    static let showCellBoxes = "showCellBoxes"
    static let showIssueBoxes = "showIssueBoxes"
}

enum Preferences {
    static var defaults: UserDefaults { .standard }

    static var defaultEngine: EngineKind {
        EngineKind(rawValue: defaults.string(forKey: PreferenceKey.defaultEngine) ?? "") ?? .auto
    }

    static var extractionOptions: ExtractionOptions {
        let languages = (defaults.string(forKey: PreferenceKey.recognitionLanguages) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let dpi = defaults.double(forKey: PreferenceKey.ocrDPI)
        let python = defaults.string(forKey: PreferenceKey.doclingPython)?.trimmingCharacters(in: .whitespaces)
        return ExtractionOptions(recognitionLanguages: languages,
                                 usesLanguageCorrection: defaults.bool(forKey: PreferenceKey.languageCorrection),
                                 ocrScale: (dpi > 0 ? dpi : 300) / 72,
                                 doclingPython: (python?.isEmpty ?? true) ? nil : python)
    }

    static var exportOptions: ExportOptions {
        get {
            guard let data = defaults.data(forKey: PreferenceKey.exportOptions),
                  let options = try? JSONDecoder().decode(ExportOptions.self, from: data) else { return ExportOptions() }
            return options
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: PreferenceKey.exportOptions) }
    }

    static var exportFormat: ExportService.Format {
        get { ExportService.Format(rawValue: defaults.string(forKey: PreferenceKey.exportFormat) ?? "") ?? .csv }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.exportFormat) }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
