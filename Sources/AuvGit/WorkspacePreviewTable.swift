import AppKit
import QuickLookUI

/// Quick Look belongs to the file table's responder chain, never to text editors
/// or the terminal. Keep the system panel's data source alive for its lifetime.
class WorkspacePreviewTable: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSViewToolTipOwner {
    final class FileToolTipOwner: NSObject, NSViewToolTipOwner {
        weak var table: WorkspacePreviewTable?
        init(table: WorkspacePreviewTable) { self.table = table }
        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
            guard let table, table.fileToolTipOwner === self, view === table,
                  table.fileToolTipTags.contains(tag) else { return "" }
            return table.fileToolTip(at: point) ?? ""
        }
    }
    var previewURLs: () -> [URL] = { [] }
    var previewRepositoryURL: () -> URL? = { nil }
    private(set) var previewItems: [URL] = []
    private(set) var fileToolTipTags = Set<NSView.ToolTipTag>()
    private(set) var fileToolTipOwner: FileToolTipOwner?
    private var fileToolTipRects: [NSRect] = []
    var fileToolTipsEnabled = true {
        didSet {
            guard oldValue != fileToolTipsEnabled else { return }
            refreshFileToolTips()
        }
    }

    // Resolve the current row when AppKit displays a hint. Reused cells must not
    // own filename strings that can outlive a commit, refresh or repository switch.
    func fileToolTip(row: Int, column: NSTableColumn) -> String? { nil }

    func fileToolTip(at point: NSPoint) -> String? {
        guard fileToolTipsEnabled, visibleRect.contains(point) else { return nil }
        let row = row(at: point), column = column(at: point)
        guard row >= 0, row < numberOfRows, tableColumns.indices.contains(column), !tableColumns[column].isHidden else { return nil }
        return fileToolTip(row: row, column: tableColumns[column])
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        fileToolTipOwner?.view(view, stringForToolTip: tag, point: point, userData: userData) ?? ""
    }

    override func reloadData() {
        invalidateFileToolTip()
        super.reloadData()
        updateFileToolTip()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        invalidateFileToolTip()
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        updateFileToolTip()
    }

    func refreshFileToolTips() {
        invalidateFileToolTip()
        updateFileToolTip()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateFileToolTip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateFileToolTip()
        updateFileToolTip()
    }

    private func invalidateFileToolTip() {
        // AppKit can reuse numeric tags. Revoke the owner identity as well so a
        // delayed callback from a previous registration can never become valid again.
        fileToolTipOwner?.table = nil
        for tag in fileToolTipTags { removeToolTip(tag) }
        fileToolTipOwner = nil
        fileToolTipTags.removeAll(keepingCapacity: true)
        fileToolTipRects.removeAll(keepingCapacity: true)
    }

    private func updateFileToolTip() {
        let rect = visibleRect.intersection(bounds)
        guard fileToolTipsEnabled, window != nil, numberOfRows > 0, !rect.isEmpty,
              let visibleRows = Range(rows(in: rect)) else { invalidateFileToolTip(); return }
        var regions: [NSRect] = []
        for row in visibleRows where row < numberOfRows {
            for column in tableColumns.indices where !tableColumns[column].isHidden {
                let region = frameOfCell(atColumn: column, row: row).intersection(rect)
                if !region.isEmpty { regions.append(region) }
            }
        }
        guard fileToolTipRects != regions else { return }
        invalidateFileToolTip()
        fileToolTipRects = regions
        let owner = FileToolTipOwner(table: self)
        fileToolTipOwner = owner
        for region in regions { fileToolTipTags.insert(addToolTip(region, owner: owner, userData: nil)) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           window?.attachedSheet == nil {
            togglePreview()
            return
        }
        super.keyDown(with: event)
    }

    func togglePreview() {
        if WorkspaceTextPreviewPresenter.closeVisiblePreview() { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        previewItems = previewURLs().filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = previewItems.first else { return }
        do {
            if let document = try WorkspaceTextPreviewDocument.open(first) {
                WorkspaceTextPreviewPresenter.show(document, repositoryURL: previewRepositoryURL())
                return
            }
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !previewItems.isEmpty }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index] as NSURL
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if [49, 53].contains(event.keyCode) {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}
