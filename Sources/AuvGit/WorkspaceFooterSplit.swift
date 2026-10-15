import AppKit
import SwiftUI

struct WorkspaceFooterSplit<History: View, Commit: View>: NSViewRepresentable {
    let history: History
    let commit: Commit
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> HistoryCommitSplitView {
        let view = HistoryCommitSplitView()
        view.addArrangedSubview(context.coordinator.history)
        view.addArrangedSubview(context.coordinator.commit)
        return view
    }
    func updateNSView(_ view: HistoryCommitSplitView, context: Context) {
        context.coordinator.history.rootView = Coordinator.focusRoot(history)
        context.coordinator.commit.rootView = Coordinator.focusRoot(commit)
    }
    final class Coordinator {
        let history: NSHostingView<AnyView>
        let commit: NSHostingView<AnyView>
        init(_ model: WorkspaceFooterSplit) {
            history = NSHostingView(rootView: Self.focusRoot(model.history))
            commit = NSHostingView(rootView: Self.focusRoot(model.commit))
            history.sizingOptions = []; commit.sizingOptions = []
        }
        static func focusRoot<V: View>(_ view: V) -> AnyView { AnyView(view.controlSize(.small).nativeFocusRoot()) }
    }
}

final class HistoryCommitSplitView: NSSplitView, NSSplitViewDelegate {
    private lazy var layoutDelegate = SplitViewLayoutDelegate(owner: self)
    private var initialized = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true; dividerStyle = .thin; delegate = layoutDelegate
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard !initialized, subviews.count == 2, bounds.width >= 600 else { return }
        setPosition(min(550, bounds.width - dividerThickness - 280), ofDividerAt: 0)
        initialized = true
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 300 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { bounds.width - dividerThickness - 280 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
