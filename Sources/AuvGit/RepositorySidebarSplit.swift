import AppKit
import SwiftUI

struct RepositorySidebarSplit<Repositories: View, Branches: View>: NSViewRepresentable {
    let repositories: Repositories
    let branches: Branches
    var repositoryViewport: RepositoryListViewport? = nil
    var isActiveProject = true
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> RepositorySidebarSplitView {
        let split = RepositorySidebarSplitView()
        split.addArrangedSubview(context.coordinator.repositories)
        split.addArrangedSubview(context.coordinator.branches)
        return split
    }
    func updateNSView(_ split: RepositorySidebarSplitView, context: Context) {
        context.coordinator.repositories.setActive(isActiveProject)
        context.coordinator.repositories.rootView = AnyView(repositories.controlSize(.small).nativeFocusRoot())
        context.coordinator.branches.rootView = AnyView(branches.controlSize(.small).nativeFocusRoot())
    }
    final class Coordinator {
        let repositories: RepositoryListHostingView
        let branches: NSHostingView<AnyView>
        init(_ model: RepositorySidebarSplit) {
            repositories = RepositoryListHostingView(rootView: AnyView(model.repositories.controlSize(.small).nativeFocusRoot()),
                                                     viewport: model.repositoryViewport ?? RepositoryListViewport())
            repositories.setActive(model.isActiveProject)
            branches = NSHostingView(rootView: AnyView(model.branches.controlSize(.small).nativeFocusRoot()))
            repositories.sizingOptions = []; branches.sizingOptions = []
        }
    }
}

/// The project list is one navigation surface, even though project panels have
/// separate hosting views. Only its visible host may publish the scroll offset.
final class RepositoryListViewport {
    var origin = NSPoint.zero
    weak var owner: RepositoryListHostingView?
}

final class RepositoryListHostingView: NSHostingView<AnyView> {
    private let viewport: RepositoryListViewport
    private var isActive = false
    private var pendingRestore = false
    private weak var scrollView: NSScrollView?
    private var boundsObservation: NSObjectProtocol?

    init(rootView: AnyView, viewport: RepositoryListViewport) {
        self.viewport = viewport
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            viewport.owner?.recordPosition()
            pendingRestore = true
            viewport.owner = self
        } else if viewport.owner === self {
            recordPosition()
            viewport.owner = nil
        }
        isActive = active
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if scrollView == nil, let scroll = findScrollView(in: self) {
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil
            ) { [weak self] _ in self?.recordPosition() }
        }
        guard isActive, viewport.owner === self, pendingRestore,
              let scrollView, let document = scrollView.documentView,
              scrollView.contentView.bounds.height > 0,
              document.bounds.height >= scrollView.contentView.bounds.height else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin = viewport.origin
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        pendingRestore = false
    }

    private func recordPosition() {
        guard isActive, viewport.owner === self, !pendingRestore, let scrollView else { return }
        viewport.origin = scrollView.contentView.bounds.origin
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    deinit {
        if let boundsObservation { NotificationCenter.default.removeObserver(boundsObservation) }
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
