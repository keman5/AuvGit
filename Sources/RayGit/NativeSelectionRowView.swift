import AppKit

protocol NativeSelectionCellStyling: AnyObject {
    var nativeSelection: Bool? { get set }
}

/// Propagate native selection while AppKit is still tracking the mouse.
class NativeSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(RayGitStyle.blue).setFill()
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
