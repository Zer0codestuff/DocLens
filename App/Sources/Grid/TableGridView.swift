import AppKit
import DocLensCore
import SwiftUI

/// Spreadsheet-style grid over a table snapshot. Selection is per cell and kept in the model;
/// NSTableView row selection is not used.
struct TableGridView: NSViewRepresentable {
    let model: AppModel
    let snapshot: TableSnapshot
    let evaluation: TableEvaluation?
    let selection: GridSelection?
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.headerView = NSTableHeaderView()
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 24
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.backgroundColor = .textBackgroundColor
        table.menu = NSMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        context.coordinator.tableView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let table = c.tableView else { return }
        let structureChanged = c.snapshot?.table.id != snapshot.table.id || c.snapshot?.run.id != snapshot.run.id
            || c.snapshot?.columnCount != snapshot.columnCount
        let headerChanged = c.snapshot?.table.columns != snapshot.table.columns
        let oldSelection = c.selection
        c.snapshot = snapshot
        c.evaluation = evaluation
        c.selection = selection
        c.rebuildIssueIndex()

        if structureChanged {
            c.rebuildColumns()
            table.reloadData()
            c.lastRevision = revision
            table.scroll(.zero)
            if let s = selection { DispatchQueue.main.async { c.scrollTo(s.cursor) } }
            if table.window?.firstResponder !== table, table.window != nil { table.window?.makeFirstResponder(table) }
        } else {
            if headerChanged { c.updateHeaders() }
            if c.lastRevision != revision, !c.isEditing {
                c.lastRevision = revision
                table.reloadData()
            } else if oldSelection != selection {
                c.refreshSelection(old: oldSelection, new: selection)
            }
            if let s = selection, s.cursor != oldSelection?.cursor { c.scrollTo(s.cursor) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, NSMenuDelegate {
        let model: AppModel
        weak var tableView: GridTableView?
        var snapshot: TableSnapshot?
        var evaluation: TableEvaluation?
        var selection: GridSelection?
        var lastRevision = -1
        var isEditing = false
        private var editingPosition: CellPosition?
        private var worstIssue: [UUID: CheckSeverity] = [:]

        static let rowHeaderID = NSUserInterfaceItemIdentifier("row-header")

        init(model: AppModel) { self.model = model }

        func rebuildIssueIndex() {
            worstIssue = [:]
            guard let evaluation, let snapshot else { return }
            for r in evaluation.unresolved(in: snapshot) {
                for id in r.cellIDs where (worstIssue[id] ?? .info) <= r.severity { worstIssue[id] = r.severity }
            }
        }

        // MARK: Columns

        func rebuildColumns() {
            guard let table = tableView, let snapshot else { return }
            for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
            let rowHeader = NSTableColumn(identifier: Self.rowHeaderID)
            rowHeader.title = ""
            rowHeader.width = max(44, CGFloat(String(snapshot.rowCount).count) * 8 + 28)
            rowHeader.minWidth = 36
            rowHeader.resizingMask = []
            table.addTableColumn(rowHeader)
            for spec in snapshot.table.columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(spec.index)"))
                column.minWidth = 44
                column.maxWidth = 1200
                column.width = idealWidth(for: spec.index)
                column.resizingMask = .userResizingMask
                table.addTableColumn(column)
            }
            updateHeaders()
        }

        func updateHeaders() {
            guard let table = tableView, let snapshot else { return }
            for spec in snapshot.table.columns {
                guard let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("c\(spec.index)")) else { continue }
                let title = NSMutableAttributedString()
                title.append(NSAttributedString(string: spec.letter + "  ", attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                ]))
                title.append(NSAttributedString(string: spec.name, attributes: [
                    .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                ]))
                title.append(NSAttributedString(string: "  " + spec.type.shortLabel + (spec.typeConfirmed ? "" : "?"), attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 10),
                ]))
                column.headerCell.attributedStringValue = title
                column.headerToolTip = "\(spec.name)\nType: \(spec.type.label)\(spec.typeConfirmed ? "" : " (suggested)")"
                    + (spec.unit.isEmpty ? "" : "\nUnit: \(spec.unit)") + (spec.scale == "1" ? "" : "\nScale: × \(spec.scale)")
            }
            table.headerView?.needsDisplay = true
        }

        private func idealWidth(for column: Int) -> CGFloat {
            guard let snapshot else { return 100 }
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let spec = snapshot.table.columns[column]
            var width = (spec.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 60
            for r in 0..<min(snapshot.rowCount, 300) {
                guard let cell = snapshot.cell(row: r, column: column), cell.colSpan == 1 else { continue }
                width = max(width, (cell.text as NSString).size(withAttributes: [.font: font]).width + 20)
            }
            return min(max(width, 64), 340)
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { snapshot?.rowCount ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let snapshot, let tableColumn else { return nil }
            if tableColumn.identifier == Self.rowHeaderID {
                let view = (tableView.makeView(withIdentifier: Self.rowHeaderID, owner: nil) as? RowHeaderView) ?? RowHeaderView()
                view.identifier = Self.rowHeaderID
                let rowSelected = selection.map { $0.rows.contains(row) } ?? false
                view.configure(row: row, role: snapshot.role(of: row), selected: rowSelected)
                return view
            }
            guard let column = columnIndex(tableColumn) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let view = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCellView) ?? GridCellView()
            view.identifier = id
            configure(view, row: row, column: column)
            return view
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            if let c = columnIndex(tableColumn) { model.selectColumn(c) }
        }

        func columnIndex(_ column: NSTableColumn) -> Int? {
            let raw = column.identifier.rawValue
            guard raw.hasPrefix("c") else { return nil }
            return Int(raw.dropFirst())
        }

        func configure(_ view: GridCellView, row: Int, column: Int) {
            guard let snapshot, column < snapshot.columnCount else { return }
            let spec = snapshot.table.columns[column]
            let role = snapshot.role(of: row)
            let anchored = snapshot.cell(row: row, column: column)
            let covering = anchored ?? snapshot.coveringCell(row: row, column: column)
            var style = GridCellView.Style()
            style.text = anchored?.text ?? ""
            style.isCovered = anchored == nil && covering != nil
            style.alignment = (spec.type.isNumeric && role != .header) ? .right : .left
            style.role = role
            style.isCorrected = anchored?.isCorrected ?? false
            style.review = covering?.review ?? .unreviewed
            if let id = covering?.id, role == .data || role == .total { style.issue = worstIssue[id] }
            style.isInSelection = selection?.contains(row: row, column: column) ?? false
            style.isCursor = selection?.cursor == CellPosition(row: row, column: column)
            style.showsRangeSelection = !(selection?.isSingleCell ?? true)
            view.apply(style)
            view.textField?.delegate = self
            view.textField?.tag = row * 4096 + column
        }

        func refreshSelection(old: GridSelection?, new: GridSelection?) {
            guard let table = tableView, let snapshot else { return }
            var rows = IndexSet()
            for s in [old, new].compactMap({ $0 }) {
                rows.insert(integersIn: s.rows.clamped(to: 0...max(0, snapshot.rowCount - 1)))
            }
            for r in rows where r < table.numberOfRows {
                for (i, col) in table.tableColumns.enumerated() {
                    if let view = table.view(atColumn: i, row: r, makeIfNecessary: false) {
                        if let cellView = view as? GridCellView, let c = columnIndex(col) {
                            configure(cellView, row: r, column: c)
                        } else if let header = view as? RowHeaderView {
                            header.configure(row: r, role: snapshot.role(of: r), selected: new.map { $0.rows.contains(r) } ?? false)
                        }
                    }
                }
            }
        }

        func scrollTo(_ p: CellPosition) {
            guard let table = tableView, p.row < table.numberOfRows else { return }
            table.scrollRowToVisible(p.row)
            if let i = table.tableColumns.firstIndex(where: { columnIndex($0) == p.column }) { table.scrollColumnToVisible(i) }
        }

        // MARK: Mouse and keyboard

        func position(at point: NSPoint) -> CellPosition? {
            guard let table = tableView else { return nil }
            let r = table.row(at: point), c = table.column(at: point)
            guard r >= 0, c >= 0 else { return nil }
            if let index = columnIndex(table.tableColumns[c]) { return CellPosition(row: r, column: index) }
            return CellPosition(row: r, column: -1)
        }

        func mouseDown(at point: NSPoint, event: NSEvent) {
            guard let p = position(at: point) else { return }
            if p.column < 0 {
                if event.modifierFlags.contains(.shift), let s = selection {
                    model.selectRows(min(s.anchor.row, p.row)...max(s.anchor.row, p.row))
                } else {
                    model.selectRows(p.row...p.row)
                }
                return
            }
            if event.clickCount >= 2 {
                model.select(p)
                beginEditing(p, replacing: nil)
                return
            }
            model.select(p, extend: event.modifierFlags.contains(.shift))
        }

        func mouseDragged(to point: NSPoint) {
            guard let p = position(at: point), p.column >= 0, selection != nil else { return }
            if selection?.cursor != p { model.select(p, extend: true) }
        }

        func move(rows dr: Int, columns dc: Int, extend: Bool) {
            guard let s = selection else {
                model.select(CellPosition(row: 0, column: 0))
                return
            }
            model.select(CellPosition(row: s.cursor.row + dr, column: s.cursor.column + dc), extend: extend)
        }

        func handleKey(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
            let shift = flags.contains(.shift)
            let command = flags.contains(.command)
            guard let snapshot else { return false }
            switch event.keyCode {
            case 123: if command { move(rows: 0, columns: -snapshot.columnCount, extend: shift) } else { move(rows: 0, columns: -1, extend: shift) }; return true
            case 124: if command { move(rows: 0, columns: snapshot.columnCount, extend: shift) } else { move(rows: 0, columns: 1, extend: shift) }; return true
            case 125: if command { move(rows: snapshot.rowCount, columns: 0, extend: shift) } else { move(rows: 1, columns: 0, extend: shift) }; return true
            case 126: if command { move(rows: -snapshot.rowCount, columns: 0, extend: shift) } else { move(rows: -1, columns: 0, extend: shift) }; return true
            case 116: move(rows: -15, columns: 0, extend: shift); return true
            case 121: move(rows: 15, columns: 0, extend: shift); return true
            case 48: move(rows: 0, columns: shift ? -1 : 1, extend: false); return true
            case 36, 76, 120:
                if let p = selection?.cursor, flags.isEmpty || flags == [.shift] { beginEditing(p, replacing: nil); return true }
                return false
            case 49 where flags.isEmpty || flags == [.shift]:
                model.toggleReviewed(); return true
            case 51, 117:
                if flags.isEmpty { model.clearSelection(); return true }
                return false
            case 53:
                if let s = selection, !s.isSingleCell { model.select(s.cursor) }
                return true
            default:
                break
            }
            if flags.subtracting(.shift).isEmpty, let chars = event.characters, let first = chars.unicodeScalars.first,
               !CharacterSet.controlCharacters.contains(first), first.value < 0xF700, let p = selection?.cursor {
                beginEditing(p, replacing: chars)
                return true
            }
            return false
        }

        // MARK: Editing

        func beginEditing(_ p: CellPosition, replacing: String?) {
            guard let table = tableView, let snapshot, p.column >= 0,
                  let cell = snapshot.cell(row: p.row, column: p.column) ?? snapshot.coveringCell(row: p.row, column: p.column),
                  let colIndex = table.tableColumns.firstIndex(where: { columnIndex($0) == cell.column }) else { return }
            scrollTo(CellPosition(row: cell.row, column: cell.column))
            guard let view = table.view(atColumn: colIndex, row: cell.row, makeIfNecessary: true) as? GridCellView,
                  let field = view.textField else { return }
            isEditing = true
            editingPosition = CellPosition(row: cell.row, column: cell.column)
            field.stringValue = cell.text
            field.isEditable = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            table.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                if let replacing {
                    editor.string = replacing
                    editor.selectedRange = NSRange(location: (replacing as NSString).length, length: 0)
                } else {
                    editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                }
            }
        }

        private func endEditing(_ field: NSTextField, commit: Bool, move: (Int, Int)?) {
            guard isEditing, let p = editingPosition else { return }
            isEditing = false
            editingPosition = nil
            let text = field.stringValue
            field.isEditable = false
            field.drawsBackground = false
            tableView?.window?.makeFirstResponder(tableView)
            if commit { model.setText(text, row: p.row, column: p.column) }
            if let move { model.select(CellPosition(row: p.row + move.0, column: p.column + move.1)) }
            lastRevision = -1
            if !commit, let table = tableView { table.reloadData() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField, isEditing else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                endEditing(field, commit: true, move: (1, 0)); return true
            case #selector(NSResponder.insertTab(_:)):
                endEditing(field, commit: true, move: (0, 1)); return true
            case #selector(NSResponder.insertBacktab(_:)):
                endEditing(field, commit: true, move: (0, -1)); return true
            case #selector(NSResponder.cancelOperation(_:)):
                endEditing(field, commit: false, move: nil); return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange()); return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField, isEditing else { return }
            endEditing(field, commit: true, move: nil)
        }

        // MARK: Context menu

        func menu(for point: NSPoint) -> NSMenu? {
            guard let p = position(at: point) else { return nil }
            if let s = selection, (p.column < 0 ? s.rows.contains(p.row) : s.contains(row: p.row, column: p.column)) {
                // Keep the current selection.
            } else if p.column < 0 {
                model.selectRows(p.row...p.row)
            } else {
                model.select(p)
            }
            let menu = NSMenu()
            func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
                let i = ClosureMenuItem(title: title, action: action)
                return i
            }
            menu.addItem(item("Mark Reviewed") { [model] in model.setReview(.reviewed) })
            menu.addItem(item("Mark Needs Review") { [model] in model.setReview(.needsReview) })
            menu.addItem(item("Mark Unreviewed") { [model] in model.setReview(.unreviewed) })
            menu.addItem(.separator())
            let roles = NSMenuItem(title: "Row Role", action: nil, keyEquivalent: "")
            let roleMenu = NSMenu()
            for role in RowRole.allCases {
                let i = item(role.label) { [model] in model.setRole(role) }
                if let snapshot, model.selectedRows.allSatisfy({ snapshot.role(of: $0) == role }) { i.state = .on }
                roleMenu.addItem(i)
            }
            roles.submenu = roleMenu
            menu.addItem(roles)
            menu.addItem(.separator())
            menu.addItem(item("Copy") { [model] in model.copySelection() })
            menu.addItem(item("Paste") { [model] in model.paste() })
            menu.addItem(item("Clear") { [model] in model.clearSelection() })
            if model.selectedCells.contains(where: \.isCorrected) {
                menu.addItem(item("Restore Extracted Value") { [model] in model.restoreExtracted() })
            }
            menu.addItem(.separator())
            menu.addItem(item("Show in PDF") { [model] in model.showCellInPDF() })
            return menu
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

final class GridTableView: NSTableView {
    weak var coordinator: TableGridView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    /// Draws grid lines only behind existing rows, not in the empty area below the table.
    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        let rowsRect = NSRect(x: clipRect.minX, y: 0, width: clipRect.width, height: rect(ofRow: numberOfRows - 1).maxY)
        super.drawGrid(inClipRect: clipRect.intersection(rowsRect))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.mouseDown(at: point, event: event)
        guard event.clickCount == 1 else { return }
        // Track a drag to extend the selection.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            coordinator?.mouseDragged(to: convert(next.locationInWindow, from: nil))
        }
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(for: convert(event.locationInWindow, from: nil))
    }

    @objc func copy(_ sender: Any?) { coordinator?.model.copySelection() }
    @objc func paste(_ sender: Any?) { coordinator?.model.paste() }
    @objc override func selectAll(_ sender: Any?) { coordinator?.model.selectAll() }
    @objc func delete(_ sender: Any?) { coordinator?.model.clearSelection() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(paste(_:)), #selector(selectAll(_:)), #selector(delete(_:)):
            return coordinator?.model.snapshot != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

final class RowHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let roleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [label, roleLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.lineBreakMode = .byClipping
            addSubview(l)
        }
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.alignment = .right
        roleLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        NSLayoutConstraint.activate([
            roleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            roleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(row: Int, role: RowRole, selected: Bool) {
        label.stringValue = String(row + 1)
        label.textColor = selected ? .controlAccentColor : .secondaryLabelColor
        switch role {
        case .header: roleLabel.stringValue = "H"
        case .total: roleLabel.stringValue = "Σ"
        case .excluded: roleLabel.stringValue = "×"
        case .data: roleLabel.stringValue = ""
        }
        roleLabel.textColor = .tertiaryLabelColor
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.labelColor.withAlphaComponent(0.035)).cgColor
        toolTip = "Row \(row + 1): \(role.label)"
    }
}

final class GridCellView: NSTableCellView {
    struct Style {
        var text = ""
        var isCovered = false
        var alignment: NSTextAlignment = .left
        var role: RowRole = .data
        var isCorrected = false
        var review: ReviewState = .unreviewed
        var issue: CheckSeverity?
        var isInSelection = false
        var isCursor = false
        var showsRangeSelection = false
    }

    private let field = NSTextField(labelWithString: "")
    private let marker = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = false
        field.isSelectable = false
        addSubview(field)
        textField = field
        marker.wantsLayer = true
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.layer?.cornerRadius = 2.5
        addSubview(marker)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 5),
            marker.heightAnchor.constraint(equalToConstant: 5),
            marker.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            marker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ s: Style) {
        field.isEditable = false
        field.drawsBackground = false
        field.stringValue = s.text.replacingOccurrences(of: "\n", with: " ")
        field.alignment = s.alignment
        var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        switch s.role {
        case .header: font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        case .total: font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        default: break
        }
        if s.alignment == .right { font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: s.role == .total ? .medium : .regular) }
        field.font = font
        if s.role == .excluded {
            field.textColor = .tertiaryLabelColor
            field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.tertiaryLabelColor, .font: font,
            ])
        } else {
            field.textColor = s.isCorrected ? .systemBlue : .labelColor
        }

        var background: NSColor = .clear
        if s.role == .header { background = NSColor.labelColor.withAlphaComponent(0.05) }
        if s.isCovered { background = NSColor.labelColor.withAlphaComponent(0.03) }
        if s.review == .reviewed { background = NSColor.systemGreen.withAlphaComponent(0.10) }
        if let issue = s.issue, s.review != .reviewed {
            background = (issue == .error ? NSColor.systemRed : NSColor.systemOrange).withAlphaComponent(0.15)
        }
        if s.isInSelection && s.showsRangeSelection { background = NSColor.controlAccentColor.withAlphaComponent(0.16) }
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = s.isCursor ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        marker.isHidden = s.review != .needsReview
        marker.layer?.backgroundColor = NSColor.systemOrange.cgColor

        var tip: [String] = []
        if s.isCorrected { tip.append("Corrected by user") }
        if s.review != .unreviewed { tip.append(s.review.label) }
        toolTip = tip.isEmpty ? nil : tip.joined(separator: " · ")
    }
}
