import AppKit
import SwiftUI

/// Keep the comparison's height in points when resizing or reopening a log window.
struct LogComparisonSplit<Overview: View, Comparison: View>: NSViewRepresentable {
    let overview: Overview
    let comparison: Comparison
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> LogComparisonSplitView {
        let split = LogComparisonSplitView()
        split.addArrangedSubview(context.coordinator.overview)
        split.addArrangedSubview(context.coordinator.comparison)
        return split
    }
    func updateNSView(_ split: LogComparisonSplitView, context: Context) {
        context.coordinator.overview.rootView = AnyView(overview.nativeFocusRoot())
        context.coordinator.comparison.rootView = AnyView(comparison.nativeFocusRoot())
    }
    final class Coordinator {
        let overview: NSHostingView<AnyView>
        let comparison: NSHostingView<AnyView>
        init(_ model: LogComparisonSplit) {
            overview = NSHostingView(rootView: AnyView(model.overview.nativeFocusRoot()))
            comparison = NSHostingView(rootView: AnyView(model.comparison.nativeFocusRoot()))
            overview.sizingOptions = []; comparison.sizingOptions = []
        }
    }
}

final class LogComparisonSplitView: NSSplitView, NSSplitViewDelegate {
    static let heightKey = "log.comparisonHeight.v1"
    static let defaultHeight: CGFloat = 300
    private lazy var layoutDelegate = SplitViewLayoutDelegate(owner: self)
    private let defaults: UserDefaults
    private var preferredHeight: CGFloat
    private var distributing = false
    private var trackingDivider = false
    override var isFlipped: Bool { true }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.heightKey)
        preferredHeight = saved.isFinite && saved >= 140 && saved <= 20_000 ? saved : Self.defaultHeight
        super.init(frame: .zero)
        isVertical = false; dividerStyle = .thin; delegate = layoutDelegate
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); distribute() }
    override func resizeSubviews(withOldSize oldSize: NSSize) { distribute() }
    override func mouseDown(with event: NSEvent) {
        trackingDivider = true
        defer { trackingDivider = false; rememberHeight() }
        super.mouseDown(with: event)
    }
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        super.setPosition(position, ofDividerAt: dividerIndex)
        rememberHeight()
    }
    private func distribute() {
        guard !distributing, !trackingDivider, subviews.count == 2, bounds.height > 0 else { return }
        distributing = true; defer { distributing = false }
        let available = max(0, bounds.height - dividerThickness)
        let bottom = min(preferredHeight, max(0, available - 300))
        let top = available - bottom
        let frames = [NSRect(x: 0, y: 0, width: bounds.width, height: top),
                      NSRect(x: 0, y: top + dividerThickness, width: bounds.width, height: bottom)]
        for (view, frame) in zip(subviews, frames) where view.frame != frame { view.frame = frame }
    }
    private func rememberHeight() {
        guard !distributing, !trackingDivider, subviews.count == 2, subviews[1].frame.height >= 140 else { return }
        preferredHeight = subviews[1].frame.height
        defaults.set(Double(preferredHeight), forKey: Self.heightKey)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 300 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { bounds.height - dividerThickness - 140 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
