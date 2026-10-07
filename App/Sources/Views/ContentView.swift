import DocLensCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) { NoticeBanner() }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(isPresented: $model.showExportSheet) { ExportSheet() }
        .sheet(isPresented: $model.showSaveRecipeSheet) { SaveRecipeSheet() }
        .sheet(item: $model.showApplyRecipeSheet) { recipe in ApplyRecipeSheet(recipe: recipe) }
    }

    @ViewBuilder private var detail: some View {
        if let error = model.storeError {
            ContentUnavailableView("The library could not be opened", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let recipe = model.activeRecipe {
            RecipeDetailView(recipe: recipe)
        } else if model.currentDocument != nil {
            WorkspaceView()
        } else if model.documents.isEmpty {
            ContentUnavailableView {
                Label("No Documents", systemImage: "tablecells.badge.ellipsis")
            } description: {
                Text("Drop PDF files here or import them to start extracting tables.")
            } actions: {
                Button("Import PDF…") { model.presentImportPanel() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("Select a Document", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Choose a document or table in the sidebar."))
        }
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let box = URLCollector()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [model] in
            MainActor.assumeIsolated { model.importFiles(box.urls) }
        }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
    var urls: [URL] { lock.withLock { storage } }
}

struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(notice.text)
                    .font(.callout)
                    .lineLimit(3)
                if let url = notice.revealURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(notice.revealURL == nil ? 6 : 12))
                if model.notice?.id == notice.id {
                    withAnimation { model.notice = nil }
                }
            }
        }
    }
}
