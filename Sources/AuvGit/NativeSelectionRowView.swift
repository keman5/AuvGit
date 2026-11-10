import AppKit

protocol NativeSelectionCellStyling: AnyObject {
    var nativeSelection: Bool? { get set }
}

/// Propagate native selection while AppKit is still tracking the mouse.
class NativeSelectionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { super.isEmphasized = true }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(AuvGitStyle.blue).setFill()
        bounds.fill()
    }
    override var isSelected: Bool {
        didSet { refreshSelection() }
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        refreshSelection()
    }
    private func refreshSelection() {
        needsDisplay = true
        for view in subviews {
            if let cell = view as? NativeSelectionCellStyling { cell.nativeSelection = isSelected }
            if let cell = view as? NSTableCellView { cell.backgroundStyle = isSelected ? .emphasized : .normal }
            view.needsDisplay = true
        }
    }
}

/// SwiftUI owns its List/Table row classes. Preserve their native active palette
/// without replacing delegates, changing selection, or moving keyboard focus.
@MainActor
final class PersistentListSelection {
    private final class Entry {
        weak var row: NSTableRowView?
        var observation: NSKeyValueObservation?
        init(_ row: NSTableRowView) {
            self.row = row
            observation = row.observe(\.isEmphasized, options: [.initial, .new]) { row, _ in
                MainActor.assumeIsolated {
                    if !row.isEmphasized { row.isEmphasized = true; row.needsDisplay = true }
                }
            }
        }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    func retainRows(in window: NSWindow) {
        entries = entries.filter { $0.value.row?.window === window }
    }
    func register(_ row: NSTableRowView) {
        guard !(row is NativeSelectionRowView) else { return }
        let id = ObjectIdentifier(row)
        if entries[id]?.row !== row { entries[id] = Entry(row) }
    }
}
