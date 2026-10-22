import AppKit
import QuickLookUI

/// Quick Look belongs to the file table's responder chain, never to text editors
/// or the terminal. Keep the system panel's data source alive for its lifetime.
class WorkspacePreviewTable: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var previewURLs: () -> [URL] = { [] }
    var previewRepositoryURL: () -> URL? = { nil }
    private(set) var previewItems: [URL] = []

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
