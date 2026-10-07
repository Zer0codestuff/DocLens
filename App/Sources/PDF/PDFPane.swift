import AppKit
import DocLensCore
import PDFKit
import SwiftUI

struct PDFPane: NSViewRepresentable {
    let model: AppModel
    let document: PDFDocument?
    let overlay: PDFOverlayContent
    let focus: PDFFocus?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> DocLensPDFView {
        let view = DocLensPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = .underPageBackgroundColor
        view.pageOverlayViewProvider = context.coordinator.overlays
        context.coordinator.overlays.pdfView = view
        view.onRegionSelected = { [weak model] pageIndex, rect in model?.regionSelected(pageIndex: pageIndex, region: rect) }
        view.onClick = { [weak model] pageIndex, x, y in model?.handlePDFClick(pageIndex: pageIndex, x: x, y: y) ?? false }
        view.onCancelSelection = { [weak model] in model?.cancelRegionSelection() }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: DocLensPDFView, context: Context) {
        let coordinator = context.coordinator
        if view.document !== document {
            view.document = document
            coordinator.lastFocusToken = nil
            view.clearFit()
            view.autoScales = true
            // Autoscaling applies the new scale after this pass; scrolling earlier keeps the old
            // offset and hides the top of the page.
            if let page = document?.page(at: 0) { DispatchQueue.main.async { view.scrollToTop(of: page) } }
        }
        view.isSelectingRegion = overlay.isSelectingRegion
        if coordinator.overlays.content != overlay {
            coordinator.overlays.content = overlay
            view.pendingRegion = nil
            coordinator.overlays.refresh()
        }
        if let focus, focus.token != coordinator.lastFocusToken {
            coordinator.lastFocusToken = focus.token
            DispatchQueue.main.async { view.reveal(pageIndex: focus.pageIndex, rect: focus.rect, zoom: focus.zoom) }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        let overlays = OverlayProvider()
        var lastFocusToken: UUID?

        init(model: AppModel) { self.model = model }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage, let doc = view.document else { return }
            let index = doc.index(for: page)
            if model.currentPageIndex != index { model.currentPageIndex = index }
        }
    }
}

final class DocLensPDFView: PDFView {
    var isSelectingRegion = false {
        didSet {
            if !isSelectingRegion { pendingRegion = nil }
            window?.invalidateCursorRects(for: self)
        }
    }

    var onRegionSelected: ((Int, PageRect) -> Void)?
    var onClick: ((Int, Double, Double) -> Bool)?
    var onCancelSelection: (() -> Void)?

    private var dragStart: (page: PDFPage, point: CGPoint)?

    /// The rectangle being dragged, in page space.
    var pendingRegion: (pageIndex: Int, rect: PageRect)? {
        didSet { (pageOverlayViewProvider as? OverlayProvider)?.pending = pendingRegion; (pageOverlayViewProvider as? OverlayProvider)?.refresh() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isSelectingRegion { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseMoved(with event: NSEvent) {
        if isSelectingRegion { NSCursor.crosshair.set() } else { super.mouseMoved(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true), let doc = document else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(point, to: page)
        if isSelectingRegion {
            dragStart = (page, pagePoint)
            pendingRegion = (doc.index(for: page), PageRect(x: pagePoint.x, y: pagePoint.y, width: 0, height: 0))
            return
        }
        if event.clickCount == 1, onClick?(doc.index(for: page), pagePoint.x, pagePoint.y) == true { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelectingRegion, let start = dragStart, let doc = document else {
            super.mouseDragged(with: event)
            return
        }
        autoscroll(with: event)
        let point = convert(convert(event.locationInWindow, from: nil), to: start.page)
        let bounds = start.page.bounds(for: displayBox)
        let x = min(max(point.x, bounds.minX), bounds.maxX), y = min(max(point.y, bounds.minY), bounds.maxY)
        let rect = CGRect(x: min(start.point.x, x), y: min(start.point.y, y), width: abs(x - start.point.x), height: abs(y - start.point.y))
        pendingRegion = (doc.index(for: start.page), PageRect(rect))
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelectingRegion, dragStart != nil else {
            super.mouseUp(with: event)
            return
        }
        dragStart = nil
        if let pending = pendingRegion, pending.rect.width > 6, pending.rect.height > 6 {
            onRegionSelected?(pending.pageIndex, pending.rect)
        }
        pendingRegion = nil
    }

    /// The table the view was last zoomed to fit. While set, width changes (window restore,
    /// split or inspector resizing) re-fit the table; any manual zoom clears it.
    private var fittedTable: (pageIndex: Int, rect: PageRect)?
    private var fittedWidth: CGFloat = 0

    // Not a `document` override: PDFKit reads `document` from background queues while
    // analyzing scanned pages, and an override would be main-actor isolated.
    func clearFit() { fittedTable = nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let fitted = fittedTable, abs(newSize.width - fittedWidth) > 1 else { return }
        fittedWidth = newSize.width
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.fittedTable, current.pageIndex == fitted.pageIndex, current.rect == fitted.rect else { return }
            self.reveal(pageIndex: fitted.pageIndex, rect: fitted.rect, zoom: true)
        }
    }

    override func magnify(with event: NSEvent) {
        fittedTable = nil
        super.magnify(with: event)
    }

    override func zoomIn(_ sender: Any?) {
        fittedTable = nil
        super.zoomIn(sender)
    }

    override func zoomOut(_ sender: Any?) {
        fittedTable = nil
        super.zoomOut(sender)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) { fittedTable = nil }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isSelectingRegion {
            onCancelSelection?()
            return
        }
        super.keyDown(with: event)
    }

    /// Scrolls so `rect` is visible, without moving when it already is.
    func reveal(pageIndex: Int, rect: PageRect?, zoom: Bool = false) {
        guard let doc = document, let page = doc.page(at: pageIndex) else { return }
        guard let rect else {
            go(to: page)
            return
        }
        if zoom {
            fittedTable = (pageIndex, rect)
            fittedWidth = bounds.width
            let widthAtUnitScale = convert(rect.cgRect, from: page).width / max(scaleFactor, 0.01)
            guard widthAtUnitScale > 1, bounds.width > 100 else { return }
            let target = (bounds.width - 48) / widthAtUnitScale
            autoScales = false
            scaleFactor = min(max(target, scaleFactorForSizeToFit * 0.9, 0.25), 4)
            layoutDocumentView()
            center(rect.cgRect, on: page, topMargin: 24)
            return
        }
        let inView = convert(rect.cgRect, from: page)
        let visible = documentView.map { convert($0.visibleRect, from: $0) } ?? bounds
        if visible.insetBy(dx: 8, dy: 8).contains(inView) { return }
        center(rect.cgRect, on: page, topMargin: 60)
    }

    func scrollToTop(of page: PDFPage) {
        layoutDocumentView()
        center(page.bounds(for: displayBox), on: page, topMargin: pageBreakMargins.top)
    }

    /// `go(to:on:)` only guarantees the rect is somewhere on screen and often leaves it
    /// clipped at the left edge, so scroll the clip view explicitly instead.
    private func center(_ rect: CGRect, on page: PDFPage, topMargin: CGFloat) {
        guard let docView = documentView, let scrollView = docView.enclosingScrollView else {
            go(to: rect, on: page)
            return
        }
        let clip = scrollView.contentView
        let target = convert(convert(rect, from: page), to: docView)
        let size = clip.bounds.size
        var origin = clip.bounds.origin
        origin.x = target.midX - size.width / 2
        origin.y = docView.isFlipped ? target.minY - topMargin : target.maxY + topMargin - size.height
        origin.x = min(max(origin.x, docView.bounds.minX), max(docView.bounds.maxX - size.width, docView.bounds.minX))
        origin.y = min(max(origin.y, docView.bounds.minY), max(docView.bounds.maxY - size.height, docView.bounds.minY))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Supplies one transparent overlay view per visible page.
@MainActor
final class OverlayProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    var content = PDFOverlayContent()
    var pending: (pageIndex: Int, rect: PageRect)?
    private var views: [ObjectIdentifier: PageOverlayView] = [:]

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageOverlayView(page: page, provider: self)
        views[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        views.removeValue(forKey: ObjectIdentifier(page))
    }

    func refresh() {
        for view in views.values { view.needsDisplay = true }
    }
}

final class PageOverlayView: NSView {
    weak var page: PDFPage?
    weak var provider: OverlayProvider?

    init(page: PDFPage, provider: OverlayProvider) {
        self.page = page
        self.provider = provider
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func viewRect(_ rect: PageRect, page: PDFPage, pdfView: PDFView) -> CGRect {
        convert(pdfView.convert(rect.cgRect, from: page), from: pdfView)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let provider, let pdfView = provider.pdfView, let doc = pdfView.document else { return }
        let index = doc.index(for: page)
        let content = provider.content
        let accent = NSColor.controlAccentColor

        func stroke(_ r: CGRect, color: NSColor, width: CGFloat, dash: [CGFloat]? = nil, fill: NSColor? = nil, radius: CGFloat = 2) {
            let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            if let fill {
                fill.setFill()
                path.fill()
            }
            if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
            path.lineWidth = width
            color.setStroke()
            path.stroke()
        }

        func label(_ text: String, at r: CGRect, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
            ]
            let s = NSAttributedString(string: text, attributes: attributes)
            let size = s.size()
            let pill = CGRect(x: r.minX, y: (isFlipped ? r.minY - size.height - 6 : r.maxY + 2), width: size.width + 12, height: size.height + 4)
            color.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            s.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
        }

        for box in content.cellBoxes where box.pageIndex == index {
            stroke(viewRect(box.rect, page: page, pdfView: pdfView).insetBy(dx: -1, dy: -1),
                   color: NSColor.secondaryLabelColor.withAlphaComponent(0.35), width: 0.5, radius: 1)
        }
        for other in content.otherTables where other.segment.pageIndex == index {
            let r = viewRect(other.segment.region, page: page, pdfView: pdfView)
            stroke(r, color: NSColor.secondaryLabelColor.withAlphaComponent(0.6), width: 1, dash: [4, 3], radius: 3)
            label(other.name, at: r, color: NSColor.secondaryLabelColor.withAlphaComponent(0.85))
        }
        for segment in content.currentSegments where segment.pageIndex == index {
            stroke(viewRect(segment.region, page: page, pdfView: pdfView), color: accent.withAlphaComponent(0.7), width: 1.5,
                   fill: accent.withAlphaComponent(0.035), radius: 3)
        }
        for candidate in content.candidates where candidate.pageIndex == index {
            let r = viewRect(candidate.region, page: page, pdfView: pdfView)
            stroke(r, color: accent, width: 1.5, dash: [6, 4], fill: accent.withAlphaComponent(0.06), radius: 3)
            // Vision's row and column counts often differ from the extracted grid, so they are not shown.
            label("Click to extract", at: r, color: accent)
        }
        for issue in content.issues where issue.pageIndex == index {
            let color: NSColor = issue.severity == .error ? .systemRed : .systemOrange
            stroke(viewRect(issue.rect, page: page, pdfView: pdfView).insetBy(dx: -1.5, dy: -1.5), color: color.withAlphaComponent(0.8),
                   width: 1, fill: color.withAlphaComponent(0.08))
        }
        for box in content.selected where box.pageIndex == index {
            stroke(viewRect(box.rect, page: page, pdfView: pdfView).insetBy(dx: -2, dy: -2), color: accent, width: 2,
                   fill: accent.withAlphaComponent(0.22))
        }
        if let pending = provider.pending, pending.pageIndex == index {
            stroke(viewRect(pending.rect, page: page, pdfView: pdfView), color: accent, width: 1.5, dash: [5, 3],
                   fill: accent.withAlphaComponent(0.08), radius: 1)
        }
    }
}
