import AppKit

/// NSSplitView forwards sidebar action discovery to its delegate on macOS 27.
/// Keep the delegate separate from the view to prevent recursive responds(to:).
final class SplitViewLayoutDelegate: NSObject, NSSplitViewDelegate {
    private weak var owner: (any NSSplitViewDelegate)?

    init(owner: any NSSplitViewDelegate) { self.owner = owner }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        owner?.splitView?(splitView, constrainMinCoordinate: proposedMinimumPosition, ofSubviewAt: dividerIndex) ?? proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        owner?.splitView?(splitView, constrainMaxCoordinate: proposedMaximumPosition, ofSubviewAt: dividerIndex) ?? proposedMaximumPosition
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
