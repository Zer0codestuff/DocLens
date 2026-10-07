import DocLensCore
import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ResizableSplit(showsTrailing: model.currentTable != nil, minLeading: 300, minTrailing: 360) {
            PDFColumn()
        } trailing: {
            TableColumn()
        }
        .navigationTitle(model.currentDocument?.title ?? "DocLens")
        .navigationSubtitle(model.currentTable?.name ?? "")
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
        }
        .toolbar { WorkspaceToolbar() }
    }
}

struct WorkspaceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button {
                model.beginRegionSelection(.newTable)
            } label: {
                Label("Select Table", systemImage: "rectangle.dashed")
            }
            .help("Drag a rectangle around a table to extract it (⇧⌘N)")
            .disabled(model.isExtracting)
            .background {
                if model.regionPurpose == .newTable {
                    Capsule().fill(Color.accentColor.opacity(0.2))
                }
            }

            Button {
                model.detectTables()
            } label: {
                if model.isDetecting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Detect Tables", systemImage: "viewfinder")
                }
            }
            .help("Find tables on the current page (⇧⌘D)")
            .disabled(model.isDetecting)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the table as CSV, Excel, or JSON (⌘E)")
            .disabled(model.snapshot == nil)
        }
    }
}

/// Two panes with a draggable divider. HSplitView is avoided because it enters a constraint
/// update loop when combined with `.inspector`.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    let showsTrailing: Bool
    let minLeading: CGFloat
    let minTrailing: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @AppStorage("workspaceSplitFraction") private var fraction = 0.45
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let width = leadingWidth(total)
            HStack(spacing: 0) {
                leading
                    .frame(width: showsTrailing ? width : total)
                if showsTrailing {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .overlay {
                            Color.clear
                                .frame(width: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = dragStart ?? fraction
                                        if dragStart == nil { dragStart = start }
                                        let proposed = (start * total + value.translation.width) / max(1, total)
                                        fraction = clamp(proposed, total: total)
                                    }
                                    .onEnded { _ in dragStart = nil })
                        }
                        .zIndex(1)
                    trailing
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func clamp(_ f: Double, total: CGFloat) -> Double {
        guard total > minLeading + minTrailing else { return 0.5 }
        return min(max(f, Double(minLeading / total)), Double(1 - minTrailing / total))
    }

    private func leadingWidth(_ total: CGFloat) -> CGFloat {
        (CGFloat(clamp(fraction, total: total)) * total).rounded()
    }
}

// MARK: - PDF column

struct PDFColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PDFPane(model: model, document: model.pdfDocument, overlay: model.overlay, focus: model.pdfFocus)
            .overlay(alignment: .top) {
                if let purpose = model.regionPurpose {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.dashed")
                        Text(purpose == .newTable ? "Drag around the table, including its header."
                            : "Drag around the continuation of the table on this or another page.")
                        Button("Cancel") { model.cancelRegionSelection() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 12)
                }
            }
            .overlay(alignment: .bottom) {
                if model.currentTable == nil, model.regionPurpose == nil, model.candidates.isEmpty, model.pdfDocument != nil {
                    HStack(spacing: 12) {
                        Text("Drag around a table to extract it, or detect tables on this page.")
                            .foregroundStyle(.secondary)
                        Button("Select Table") { model.beginRegionSelection(.newTable) }
                        Button("Detect Tables") { model.detectTables() }
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 64)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let doc = model.pdfDocument, doc.pageCount > 1 {
                    Text("Page \(model.currentPageIndex + 1) of \(doc.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: .capsule)
                        .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !model.candidates.isEmpty {
                    Button("Clear Detected Tables") { model.clearCandidates() }
                        .controlSize(.small)
                        .padding(10)
                }
            }
    }
}

// MARK: - Table column

struct TableColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TableHeaderBar()
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if let snapshot = model.snapshot {
            if snapshot.rowCount == 0 || snapshot.columnCount == 0 {
                ContentUnavailableView("No cells were extracted", systemImage: "tablecells",
                                       description: Text("Adjust the region or extract again with another engine."))
            } else {
                TableGridView(model: model, snapshot: snapshot, evaluation: model.evaluation, selection: model.selection,
                              revision: model.revision)
            }
        } else if let activity = model.activity, activity.tableID == model.currentTable?.id {
            VStack(spacing: 12) {
                ProgressView(value: activity.fraction)
                    .frame(width: 220)
                Text(activity.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelExtraction() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failed = model.lastFailedRun {
            ContentUnavailableView {
                Label(failed.status == .cancelled ? "Extraction cancelled" : "Extraction failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failed.errorMessage ?? "")
            } actions: {
                EngineRetryMenu()
            }
        } else {
            ContentUnavailableView {
                Label("Not extracted", systemImage: "tablecells")
            } actions: {
                EngineRetryMenu()
            }
        }
    }
}

struct EngineRetryMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu("Extract With") {
            ForEach(EngineKind.allCases) { kind in
                Button(kind.label) { if let t = model.currentTable { model.extract(tableID: t.id, engine: kind) } }
            }
        }
        .fixedSize()
    }
}

struct TableHeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let activity = model.activity, activity.tableID == model.currentTable?.id, model.snapshot != nil {
                ProgressView(value: activity.fraction)
                    .frame(width: 120)
                Text(activity.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Cancel") { model.cancelExtraction() }
                    .controlSize(.small)
            } else if let snapshot = model.snapshot {
                ReviewProgressLabel(snapshot: snapshot, issues: model.issues.count)
            }
            Spacer(minLength: 8)
            if model.snapshot != nil {
                ControlGroup {
                    Button {
                        model.goToIssue(forward: false)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help("Previous issue (⌘[)")
                    Button {
                        model.goToIssue(forward: true)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help("Next issue (⌘])")
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(model.issues.isEmpty)
            }
            Menu {
                ForEach(EngineKind.allCases) { kind in
                    Button {
                        if let t = model.currentTable { model.extract(tableID: t.id, engine: kind) }
                    } label: {
                        Text(kind.label)
                        Text(kind.summary)
                    }
                }
                Divider()
                Button("Add Region on Another Page") { model.beginRegionSelection(.addSegment) }
            } label: {
                Label("Extract Again", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isExtracting)
            .help("Extract this table again. Corrections carry over to the new version.")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

struct ReviewProgressLabel: View {
    let snapshot: TableSnapshot
    let issues: Int

    var body: some View {
        let progress = snapshot.reviewProgress
        HStack(spacing: 10) {
            Gauge(value: Double(progress.reviewed), in: 0...Double(max(1, progress.total))) {}
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(0.45)
                .frame(width: 20, height: 20)
                .tint(progress.reviewed == progress.total && progress.total > 0 ? .green : .accentColor)
            Text("\(progress.reviewed) of \(progress.total) reviewed")
                .font(.callout.monospacedDigit())
            if issues > 0 {
                Label("\(issues)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.orange)
                    .help("\(issues) unresolved issue\(issues == 1 ? "" : "s"). Review the cells to resolve them.")
            }
        }
    }
}
