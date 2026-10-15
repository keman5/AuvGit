import AppKit
import SwiftUI

struct RepositorySidebarSplit<Repositories: View, Branches: View>: NSViewRepresentable {
    let repositories: Repositories
    let branches: Branches
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> RepositorySidebarSplitView {
        let split = RepositorySidebarSplitView()
        split.addArrangedSubview(context.coordinator.repositories)
        split.addArrangedSubview(context.coordinator.branches)
        return split
    }
    func updateNSView(_ split: RepositorySidebarSplitView, context: Context) {
        context.coordinator.repositories.rootView = AnyView(repositories.controlSize(.small).nativeFocusRoot())
        context.coordinator.branches.rootView = AnyView(branches.controlSize(.small).nativeFocusRoot())
    }
    final class Coordinator {
        let repositories: NSHostingView<AnyView>
        let branches: NSHostingView<AnyView>
        init(_ model: RepositorySidebarSplit) {
            repositories = NSHostingView(rootView: AnyView(model.repositories.controlSize(.small).nativeFocusRoot()))
            branches = NSHostingView(rootView: AnyView(model.branches.controlSize(.small).nativeFocusRoot()))
            repositories.sizingOptions = []; branches.sizingOptions = []
        }
    }
}

final class RepositorySidebarSplitView: NSSplitView, NSSplitViewDelegate {
    private lazy var layoutDelegate = SplitViewLayoutDelegate(owner: self)
    private var initialized = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = false; dividerStyle = .thin; delegate = layoutDelegate
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard !initialized, subviews.count == 2, bounds.height >= 410 + dividerThickness else { return }
        setPosition(bounds.height - dividerThickness - 280, ofDividerAt: 0)
        initialized = true
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard initialized, subviews.count == 2 else { super.resizeSubviews(withOldSize: oldSize); return }
        let available = max(0, bounds.height - dividerThickness)
        let branches = min(max(170, subviews[1].frame.height), max(0, available - 130))
        subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: available - branches)
        subviews[1].frame = NSRect(x: 0, y: available - branches + dividerThickness, width: bounds.width, height: branches)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 130 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { bounds.height - dividerThickness - 170 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
