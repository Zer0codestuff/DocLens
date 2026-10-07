import DocLensCore
import SwiftUI

struct SaveRecipeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("A recipe stores the column names, types, units, number format, and the table position so the same table can be extracted from similar documents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let s = model.snapshot {
                    Section("Columns") {
                        ForEach(s.table.columns) { c in
                            LabeledContent(c.name) {
                                Text(c.type.label + (c.typeConfirmed ? "" : " (suggested)")).foregroundStyle(.secondary)
                            }
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
                Button("Save Recipe") {
                    model.saveRecipe(name: name.trimmingCharacters(in: .whitespaces), notes: notes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
        .frame(minHeight: 360)
        .onAppear { name = defaultName }
    }

    /// Generic names like "Table 1" say nothing in a recipe list, so prefix the document name.
    private var defaultName: String {
        let table = model.snapshot?.table.name ?? ""
        guard table.wholeMatch(of: /Table \d+/) != nil, let doc = model.currentDocument else { return table }
        return "\((doc.filename as NSString).deletingPathExtension), \(table)"
    }
}

struct ApplyRecipeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe
    @State private var selected = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apply “\(recipe.name)”").font(.headline)
                Text("DocLens finds the table in each document, extracts it with \(recipe.engine.label), and applies the recipe columns. Each result is a new table that still needs your review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            List(model.documents) { doc in
                Toggle(isOn: Binding(
                    get: { selected.contains(doc.id) },
                    set: { if $0 { selected.insert(doc.id) } else { selected.remove(doc.id) } }
                )) {
                    HStack {
                        Text(doc.title)
                        Spacer()
                        Text(tableCount(doc)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 260)
            Divider()
            HStack {
                Button(selected.count == model.documents.count ? "Select None" : "Select All") {
                    selected = selected.count == model.documents.count ? [] : Set(model.documents.map(\.id))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply to \(selected.count) Document\(selected.count == 1 ? "" : "s")") {
                    model.applyRecipe(recipe, to: model.documents.map(\.id).filter(selected.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private func tableCount(_ doc: DocumentRecord) -> String {
        switch model.tables(for: doc).count {
        case 0: "No tables"
        case 1: "1 table"
        case let n: "\(n) tables"
        }
    }
}

struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    let recipe: Recipe
    @State private var draft: Recipe

    init(recipe: Recipe) {
        self.recipe = recipe
        _draft = State(initialValue: recipe)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...6)
                LabeledContent("Version", value: "\(recipe.version)")
                LabeledContent("Updated", value: AppModel.dateFormatter.string(from: recipe.updatedAt))
            }
            Section("Extraction") {
                Picker("Engine", selection: $draft.engine) {
                    ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("Number format", selection: $draft.settings.numberFormat) {
                    ForEach(NumberFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Date order", selection: $draft.settings.dateOrder) {
                    ForEach(DateOrder.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Located by") {
                    Text(recipe.anchorText.isEmpty ? "Saved position on page \(recipe.pageHint + 1)"
                        : "Text “\(recipe.anchorText)”, near page \(recipe.pageHint + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Columns") {
                ForEach($draft.columns) { $column in
                    HStack {
                        TextField("Name", text: $column.name)
                            .labelsHidden()
                        Picker("Type", selection: $column.type) {
                            ForEach(ColumnType.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        TextField("Unit", text: $column.unit, prompt: Text("Unit"))
                            .labelsHidden()
                            .frame(width: 70)
                    }
                    .help("Matches headers: \(column.aliases.joined(separator: ", "))")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(recipe.name)
        .navigationSubtitle("Recipe")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save Changes") { model.updateRecipe(draft) }
                    .disabled(draft == recipe)
                Button("Apply to Documents…") { model.showApplyRecipeSheet = recipe }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.documents.isEmpty)
            }
        }
        .onChange(of: recipe) { draft = recipe }
    }
}
