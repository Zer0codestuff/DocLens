import DocLensCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var deleting: DeleteTarget?

    enum RenameTarget: Hashable { case document(UUID), table(UUID) }
    enum DeleteTarget: Hashable { case document(UUID, String), table(UUID, String), recipe(UUID, String) }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section("Documents") {
                ForEach(model.documents) { doc in
                    documentRow(doc)
                }
            }
            if !model.recipes.isEmpty {
                Section("Recipes") {
                    ForEach(model.recipes) { recipe in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(recipe.name)
                                Text("Version \(recipe.version) · \(recipe.columns.count) columns")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .tag(SidebarItem.recipe(recipe.id))
                        .contextMenu {
                            Button("Apply to Documents…") { model.showApplyRecipeSheet = recipe }
                            Divider()
                            Button("Delete Recipe…", role: .destructive) { deleting = .recipe(recipe.id, recipe.name) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !model.batchJobs.isEmpty { BatchStatusView() }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.presentImportPanel()
                } label: {
                    Label("Import PDF", systemImage: "plus")
                }
                .help("Import PDF files (⌘O)")
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                switch renaming {
                case .document(let id): model.renameDocument(id, to: renameText)
                case .table(let id): model.renameTable(id, to: renameText)
                case nil: break
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                switch deleting {
                case .document(let id, _): model.deleteDocument(id)
                case .table(let id, _): model.deleteTable(id)
                case .recipe(let id, _): model.deleteRecipe(id)
                case nil: break
                }
                deleting = nil
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private func documentRow(_ doc: DocumentRecord) -> some View {
        let tables = model.tables(for: doc)
        return Group {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(doc.title).lineLimit(1)
                    Text("\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")\(doc.hasTextLayer ? "" : " · scanned")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: doc.hasTextLayer ? "doc.text" : "doc.viewfinder")
            }
            .tag(SidebarItem.document(doc.id))
            .help(doc.filename)
            .contextMenu {
                Button("Rename…") {
                    renameText = doc.title
                    renaming = .document(doc.id)
                }
                Button("Show Stored Copy in Finder") { model.revealSource(doc.id) }
                if !model.recipes.isEmpty {
                    Menu("Apply Recipe") {
                        ForEach(model.recipes) { recipe in
                            Button(recipe.name) { model.applyRecipe(recipe, to: [doc.id]) }
                        }
                    }
                }
                Divider()
                Button("Delete Document…", role: .destructive) { deleting = .document(doc.id, doc.title) }
            }

            ForEach(tables) { table in
                Label {
                    HStack {
                        Text(table.name).lineLimit(1)
                        Spacer()
                        Text(pagesLabel(table))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: table.currentRunID == nil ? "tablecells.badge.ellipsis" : "tablecells")
                }
                .padding(.leading, 14)
                .tag(SidebarItem.table(table.id))
                .contextMenu {
                    Button("Rename…") {
                        renameText = table.name
                        renaming = .table(table.id)
                    }
                    Divider()
                    Button("Delete Table…", role: .destructive) { deleting = .table(table.id, table.name) }
                }
            }
        }
    }

    private func pagesLabel(_ table: TableRecord) -> String {
        let pages = table.pageIndexes.map { String($0 + 1) }
        return pages.count == 1 ? "p. \(pages[0])" : "pp. \(pages.first ?? "")–\(pages.last ?? "")"
    }

    private var deleteTitle: String {
        switch deleting {
        case .document(_, let name): "Delete “\(name)”?"
        case .table(_, let name): "Delete “\(name)”?"
        case .recipe(_, let name): "Delete recipe “\(name)”?"
        case nil: ""
        }
    }

    private var deleteMessage: String {
        switch deleting {
        case .document: "The stored PDF copy, its tables, extraction versions, and corrections are removed from the library. The original file you imported is not affected."
        case .table: "All extraction versions and corrections of this table are removed."
        case .recipe: "Tables created with this recipe keep their data."
        case nil: ""
        }
    }
}

struct BatchStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let done = model.batchJobs.filter { if case .done = $0.status { return true }; if case .failed = $0.status { return true }; return false }.count
        Button {
            model.showBatchPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                if model.batchIsRunning {
                    ProgressView(value: Double(done), total: Double(max(1, model.batchJobs.count)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(model.batchIsRunning ? "Applying recipe \(done + 1) of \(model.batchJobs.count)" : "Recipe applied to \(model.batchJobs.count) document\(model.batchJobs.count == 1 ? "" : "s")")
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $model.showBatchPopover, arrowEdge: .trailing) { BatchJobsPopover() }
    }
}

struct BatchJobsPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recipe Queue").font(.headline)
                Spacer()
                if model.batchIsRunning {
                    Button("Stop") { model.cancelBatch() }
                } else {
                    Button("Clear") { model.batchJobs.removeAll(); model.showBatchPopover = false }
                }
            }
            .padding(12)
            Divider()
            // A scroll view near the screen edge collapses to its minimum height, so only
            // long queues scroll.
            if model.batchJobs.count > 6 {
                ScrollView { jobList }
                    .frame(height: 360)
            } else {
                jobList
            }
        }
        .frame(width: 360)
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.batchJobs) { job in
                HStack(alignment: .top, spacing: 10) {
                    statusIcon(job.status)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.documentTitle).lineLimit(1)
                        Text(detail(job.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if case .done(let tableID, _) = job.status {
                        Button("Open") {
                            model.openTable(tableID)
                            model.showBatchPopover = false
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder private func statusIcon(_ status: BatchJob.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private func detail(_ status: BatchJob.Status) -> String {
        switch status {
        case .pending: "Waiting"
        case .running(let step): step
        case .done(_, let detail): detail
        case .failed(let message): message
        }
    }
}
