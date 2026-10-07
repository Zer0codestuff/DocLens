import DocLensCore
import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var format = Preferences.exportFormat
    @State private var options = Preferences.exportOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportService.Format.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                Section("Values") {
                    Picker("Numbers", selection: $options.numericPolicy) {
                        ForEach(ExportOptions.NumericPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Missing values", selection: $options.missingPolicy) {
                        ForEach(ExportOptions.MissingPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Include total rows", isOn: $options.includeTotals)
                }
                if format == .csv {
                    Section("CSV") {
                        Picker("Delimiter", selection: $options.delimiter) {
                            ForEach(ExportOptions.Delimiter.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("Byte order mark for Excel", isOn: $options.includeBOM)
                        Toggle("Protect against formula injection", isOn: $options.protectFormulas)
                            .help("Prefixes text starting with =, +, -, or @ with an apostrophe so spreadsheets do not run it.")
                        Toggle("Add a review status column", isOn: $options.includeReviewColumn)
                    }
                }
                if format != .json {
                    Section {
                        Toggle("Write provenance file", isOn: $options.writeSidecar)
                    } footer: {
                        Text("A .provenance.json file next to the export records the source PDF hash, cell regions, engine, corrections, and checks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let disclosure {
                    Section {
                        Label {
                            Text(disclosure.summary)
                        } icon: {
                            Image(systemName: disclosure.isComplete ? "checkmark.seal" : "exclamationmark.triangle")
                                .foregroundStyle(disclosure.isComplete ? .green : .orange)
                        }
                    } footer: {
                        if !disclosure.isComplete {
                            Text("You can export now. The review state is included in the provenance data and, for Excel, in the About sheet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    let f = format, o = options
                    DispatchQueue.main.async { model.export(format: f, options: o) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 460)
        .frame(minHeight: 420)
    }

    private var disclosure: ReviewDisclosure? {
        guard let s = model.snapshot, let e = model.evaluation else { return nil }
        return ReviewDisclosure(snapshot: s, evaluation: e)
    }
}
