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
        context.coordinator.history.rootView = AnyView(history.controlSize(.small))
        context.coordinator.commit.rootView = AnyView(commit.controlSize(.small))
    }
    final class Coordinator {
        let history: NSHostingView<AnyView>
        let commit: NSHostingView<AnyView>
        init(_ model: WorkspaceFooterSplit) {
            history = NSHostingView(rootView: AnyView(model.history.controlSize(.small)))
            commit = NSHostingView(rootView: AnyView(model.commit.controlSize(.small)))
            history.sizingOptions = []; commit.sizingOptions = []
        }
    }
}

final class HistoryCommitSplitView: NSSplitView, NSSplitViewDelegate {
    private var initialized = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true; dividerStyle = .thin; delegate = self
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
