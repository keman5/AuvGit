import SwiftUI
import AppKit
import GitCore
import AuvGitLocalization

private func historyText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Detail", arguments: arguments)
}

enum HistoryAction: String, CaseIterable {
    case viewLog, show, copyHash, copyMessage, createBranch, createTag, checkout, cherryPick, revert, reset, resetAdvanced, rebase, useCommitMessage
    var isMutation: Bool { ![Self.viewLog, .show, .copyHash, .copyMessage, .useCommitMessage].contains(self) }
}

func historyActionText(_ key: String) -> String { L10n.text(key, table: "HistoryActions") }

struct HistoryPaginationGate {
    let prefetchDistance: Int
    private var lastRequestedCount: Int?

    init(prefetchDistance: Int) {
        self.prefetchDistance = max(1, prefetchDistance)
    }

    mutating func shouldRequestMore(visibleIndex: Int, commitCount: Int, hasMore: Bool, isLoading: Bool) -> Bool {
        guard hasMore, !isLoading, commitCount > 0,
              visibleIndex >= max(0, commitCount - prefetchDistance),
              lastRequestedCount != commitCount else { return false }
        lastRequestedCount = commitCount
        return true
    }

    mutating func reset() { lastRequestedCount = nil }
}

struct HistoryPane: View {
    let commits: [GitCommit]
    @Binding var selection: String?
    @State private var collapsedMerges = Set<String>()
    @State private var pendingGraphDrop: HistoryGraphDropRequest?
    @StateObject private var overlapCache = HistoryOverlapCache()
    @Binding var search: String
    let isLoading: Bool
    let hasMore: Bool
    let onLoadMore: () -> Void

    var isBusy: Bool = false
    var onAction: (HistoryAction, GitCommit) -> Void = { _, _ in }
    var onShowChanges: () -> Void = {}
    var compact: Bool = false
    var showsSearch: Bool = true
    var showsDetails: Bool = true
    var remoteBranchNames: Set<String> = []
    var visibleRemoteBranchNames: Set<String>? = nil
    var currentBranch: GitBranch? = nil
    var localUnpushedCommitHashes: Set<String>? = nil
    var navigationGeneration: UUID? = nil
    var onJump: (String) -> Void = { _ in }
    var firstParentGraph: Bool = false
    var onFind: () -> Void = {}
    @State private var searchFocusRequest: UUID?

    @Binding var authorFilter: String
    var selectedCommitIDs: Set<String> = []
    var onSelectCommits: ((Set<String>) -> Void)? = nil
    var virtualRows: [HistoryVirtualRow] = []
    var onGraphDrop: ((HistoryGraphDropRequest) -> Void)? = nil
    var overlapLoader: ((String, [String]) async throws -> [String: Int])? = nil
    var graphRepositoryIdentity: UUID? = nil
    var branches: [GitBranch] = []
    var graphHeadCommitID: String? = nil
    var requiresSelectionActivation: Bool = false
    @AppStorage("history.showAuthorAvatars") private var showAvatars = true
    @AppStorage("history.showAuthorNames") private var showNames = true
    @AppStorage("history.showRemoteLabels") private var showRemoteLabels = true
    @AppStorage("history.showTagLabels") private var showTagLabels = true
    @AppStorage("history.identityMode") private var identityModeValue = HistoryIdentityMode.author.rawValue
    @AppStorage("history.showIdentityEmails") private var showEmails = false
    @AppStorage("history.showDateColumn") private var showDate = true
    @AppStorage("history.showHashColumn") private var showHash = true
    @AppStorage("history.showOverlapColumn") private var showOverlap = false
    private var identityMode: HistoryIdentityMode { HistoryIdentityMode(rawValue: identityModeValue) ?? .author }
    @StateObject private var graphCache = HistoryGraphCache()
    @State private var jumpHash = ""
    @State private var authorWidth: CGFloat = 110
    @State private var graphColumnWidth: CGFloat = HistoryColumn.graph.minimumWidth
    @State private var messageWidth: CGFloat = 360
    @State private var hashWidth: CGFloat = 75
    @State private var dateWidth: CGFloat = 150

    var body: some View {
        GeometryReader { geometry in
            let preserved = selectedCommitIDs.union(selection.map { [$0] } ?? [])
            let projection = HistoryMergeCollapse.project(commits, collapsed: collapsedMerges, preserving: preserved)
            let visible = projection.commits
            let graph = graphCache.graph(commits: visible, firstParent: firstParentGraph)
            let styles = graphCache.styles(commits: visible, remoteBranchNames: remoteBranchNames, localUnpushedHashes: localUnpushedCommitHashes, currentBranch: currentBranch, visibleRemoteBranchNames: visibleRemoteBranchNames)
            let nameWidth = compact ? graphCache.compactNameWidth(commits: visible, showsAvatar: showAvatars, mode: identityMode, names: showNames, emails: showEmails) : authorWidth
            let calendarWidth = compact ? graphCache.compactDateWidth(commits: visible) : dateWidth
            let identityWidth = (showAvatars || showNames || showEmails) ? (compact ? min(100, (showAvatars ? 18 : 0) + nameWidth + (showAvatars ? 4 : 0)) : authorWidth) : 0
            let contentWidth = graphWidth(graph) + (compact ? 220 : messageWidth) + identityWidth + (showDate ? calendarWidth + 4 : 0) + (showHash ? hashWidth + 4 : 0) + (showOverlap ? 69 : 0) + 24
            VStack(spacing: 0) {
                if showsSearch {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if compact { Label(designWorkspaceText("Commit history"), systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold)) }
                            searchControl
                            if !compact { filterControls }
                            HistoryDisplayMenu()
                        }
                        VStack(spacing: 8) { HStack { searchControl; HistoryDisplayMenu() }; if !compact { filterControls } }
                    }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).auvGitChrome()
                    Divider()
                }
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        if !compact {
                            HStack(spacing: 4) {
                                columnHeader(historyText("history.graph"), column: .graph, width: $graphColumnWidth, minimumWidth: HistoryColumnLayout.graphWidth(laneCount: graph.laneCount))
                                columnHeader(historyText("history.message"), column: .message, width: $messageWidth)
                                if identityWidth > 0 { columnHeader(graphFeatureText(identityMode == .author ? "Author" : "Committer"), column: .author, width: $authorWidth) }
                                if showDate { columnHeader(historyText("history.date"), column: .date, width: $dateWidth) }
                                if showHash { columnHeader(historyText("history.hash"), column: .hash, width: $hashWidth) }
                                if showOverlap { Text(graphFeatureText("Overlap")).frame(width: 65, alignment: .leading) }
                            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, HistoryColumnLayout.leadingInset).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading).auvGitChrome()
                            Divider()
                        }
                        NativeCompactHistoryTable(commits: visible, graph: graph, styles: styles,
                            selection: $selection, navigationGeneration: navigationGeneration,
                            graphWidth: graphWidth(graph), nameWidth: nameWidth, dateWidth: calendarWidth,
                            showAvatars: showAvatars, showNames: showNames,
                            showRemoteLabels: showRemoteLabels, showTagLabels: showTagLabels,
                            isBusy: isBusy, hasMore: hasMore, isLoading: isLoading, onLoadMore: onLoadMore, onAction: onAction,
                            virtualRows: virtualRows, selectedCommitIDs: selectedCommitIDs, onSelectCommits: onSelectCommits,
                            identityMode: identityMode, showEmails: showEmails, showDate: showDate, showHash: showHash,
                            showOverlap: showOverlap, overlapValues: overlapCache.values, overlapIsLoading: overlapCache.isLoading,
                            collapsedCounts: projection.hiddenCounts, collapsedMerges: collapsedMerges,
                            onToggleMerge: { hash in if !collapsedMerges.insert(hash).inserted { collapsedMerges.remove(hash) } },
                            onGraphDrop: onGraphDrop == nil ? nil : { pendingGraphDrop = preparedDrop($0) }, currentBranch: currentBranch, branches: branches,
                            compact: compact, messageWidth: messageWidth, identityWidth: authorWidth, hashWidth: hashWidth,
                            requiresSelectionActivation: requiresSelectionActivation)
                            .overlay { if visible.isEmpty && virtualRows.isEmpty { emptyHistory.allowsHitTesting(false) } }
                    }.frame(width: max(geometry.size.width, contentWidth), alignment: .leading)
                }
                if showOverlap {
                    HStack(spacing: 6) {
                        if overlapCache.isLoading { ProgressView().controlSize(.mini) }
                        Text(overlapCache.error ?? graphFeatureText("Overlap explanation")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 4)
                }
                if !compact, showsDetails, let commit = commits.first(where: { $0.hash == selection }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(commit.hash).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        CommitIdentityDetails(commit: commit)
                        ScrollView { Text(commit.body.isEmpty ? commit.subject : commit.body).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 45, maxHeight: 115)
                    }.padding(.horizontal, 12).padding(.vertical, 10).auvGitChrome().accessibilityLabel(historyText("history.details"))
                }
            }.background(AuvGitStyle.canvas)
                .background(HistoryKeyboardRegion(paneScoped: compact, action: { action in
                    guard let commit = commits.first(where: { $0.hash == selection }), !action.isMutation || !isBusy else { return }
                    onAction(action, commit)
                }, find: { if showsSearch { searchFocusRequest = UUID() } else { onFind() } }, navigate: { child in
                    guard let target = HistoryCommitNavigation.target(commits: commits, selection: selection, child: child) else { return }
                    selection = target
                    onSelectCommits?([target])
                }, showChanges: onShowChanges))
                .task(id: overlapTaskKey) {
                    await overlapCache.load(selected: selection, commits: commits, generation: navigationGeneration, enabled: showOverlap, loader: overlapLoader)
                }
                .onChange(of: navigationGeneration) { _, _ in collapsedMerges.removeAll(); pendingGraphDrop = nil }
                .sheet(isPresented: Binding(get: { pendingGraphDrop != nil }, set: { if !$0 { pendingGraphDrop = nil } })) {
                    if let request = pendingGraphDrop {
                        HistoryGraphDropPreview(request: request, confirm: { confirmed in
                            pendingGraphDrop = nil
                            guard !isBusy, commits.contains(where: { $0.hash == confirmed.targetCommitID }) else { return }
                            onGraphDrop?(confirmed)
                        }, cancel: { pendingGraphDrop = nil })
                    }
                }
        }
    }
    private func preparedDrop(_ request: HistoryGraphDropRequest) -> HistoryGraphDropRequest {
        var request = request
        request.repositoryIdentity = graphRepositoryIdentity
        request.expectedHeadCommitID = graphHeadCommitID ?? commits.first { commit in commit.refs.contains { HistoryGraphStylePlan.canonicalReference($0) == "HEAD" || $0.hasPrefix("HEAD -> ") && !$0.hasSuffix("~") } }?.hash
        switch request.source {
        case .head: request.expectedSourceCommitID = request.expectedHeadCommitID
        case .localBranch(let name):
            request.sourceIsCurrentBranch = currentBranch.map { "refs/heads/" + $0.name == name } ?? false
            request.expectedSourceCommitID = commits.first { commit in commit.refs.contains { HistoryGraphStylePlan.canonicalReference($0).replacingOccurrences(of: "HEAD -> ", with: "") == name && !$0.hasSuffix("~") } }?.hash
        case .commits(let ids):
            request.expectedSourceCommitID = ids.first
            let selected = Set(ids)
            let byHash = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0) })
            var cursor = request.expectedHeadCommitID
            var chain: [String] = []
            while let hash = cursor, chain.count < ids.count, let commit = byHash[hash], commit.parents.count == 1 {
                chain.append(hash); cursor = commit.parents.first
            }
            request.isContiguousHeadRange = chain.count == ids.count && Set(chain) == selected
        }
        return request
    }
    private var overlapTaskKey: String {
        (navigationGeneration?.uuidString ?? "") + "|" + (selection ?? "") + "|" + String(showOverlap) + "|" + commits.map(\.hash).joined(separator: ",")
    }
    private var emptyHistory: some View {
        ContentUnavailableView {
            Label(isLoading ? historyText("history.loading") : historyText("history.empty"), systemImage: "clock.arrow.circlepath")
        } description: {
            Text(search.isEmpty ? historyText("history.emptyDescription") : historyText("history.noResults"))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var searchControl: some View { HistorySearchControl(search: $search, focusRequest: searchFocusRequest) }
    private var filterControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) { Image(systemName: "person").foregroundStyle(.secondary); StableTextField(workflowText("Author"), text: $authorFilter, rounded: false) }.padding(.horizontal, 8).frame(height: 24).auvGitInputSurface().frame(width: 140)
            HStack(spacing: 6) { Image(systemName: "number").foregroundStyle(.secondary); StableTextField(workflowText("Commit hash"), text: $jumpHash, onSubmit: { onJump(jumpHash) }, rounded: false) }.padding(.horizontal, 8).frame(height: 24).auvGitInputSurface().frame(width: 110)
        }
    }
    private func graphWidth(_ graph: CommitGraph) -> CGFloat {
        max(compact ? HistoryColumnLayout.laneSpacing : graphColumnWidth,
            HistoryColumnLayout.graphWidth(laneCount: graph.laneCount))
    }
    private func columnHeader(_ title: String, column: HistoryColumn, width: Binding<CGFloat>, minimumWidth: CGFloat = 0) -> some View {
        HistoryColumnHeader(title: title, column: column, width: Binding(
            get: { max(minimumWidth, width.wrappedValue) },
            set: { width.wrappedValue = max(minimumWidth, $0) }
        ))
    }
}

enum HistoryCommitNavigation {
    static func target(commits: [GitCommit], selection: String?, child: Bool) -> String? {
        guard let selected = commits.first(where: { $0.hash == selection }) else { return nil }
        if child { return commits.first { $0.parents.contains(selected.hash) }?.hash }
        return selected.parents.first { parent in commits.contains { $0.hash == parent } }
    }
}

// Selection and column layout do not change graph topology. Reuse it until inputs change.
private final class HistoryGraphCache: ObservableObject {
    private var commits: [GitCommit] = []
    private var firstParent = false
    private var cachedGraph: CommitGraph?
    private var colorCommits: [GitCommit] = []
    private var colorRemoteBranchNames: Set<String> = []
    private var colorVisibleRemoteBranchNames: Set<String>?
    private var colorLocalUnpushedHashes: Set<String>?
    private var colorCurrentBranch: GitBranch?
    private var cachedStyles: HistoryGraphStylePlan?
    private var measuredAuthors: [String] = []
    private var measuredNameWidth: CGFloat = 0
    private var measuredDates: [Date] = []
    private var datePresentationKey = ""
    private var measuredDateWidth: CGFloat = 0

    func compactDateWidth(commits: [GitCommit]) -> CGFloat {
        let dates = commits.map(\.committedDate)
        let key = L10n.locale.identifier + "|" + TimeZone.current.identifier + "|" + String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        if dates != measuredDates || key != datePresentationKey {
            measuredDates = dates
            datePresentationKey = key
            measuredDateWidth = dates.map { (HistoryCalendarDate.text($0) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width }.max() ?? 0
        }
        return HistoryColumnLayout.compactDateWidth(measuredWidth: measuredDateWidth)
    }

    func compactNameWidth(commits: [GitCommit], showsAvatar: Bool, mode: HistoryIdentityMode = .author, names: Bool = true, emails: Bool = false) -> CGFloat {
        let authors = commits.map { mode.text($0, names: names, emails: emails) }
        if authors != measuredAuthors {
            measuredAuthors = authors
            measuredNameWidth = authors.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width }.max() ?? 0
        }
        return HistoryColumnLayout.compactAuthorNameWidth(measuredWidth: measuredNameWidth, showsAvatar: showsAvatar)
    }

    func graph(commits: [GitCommit], firstParent: Bool) -> CommitGraph {
        if let cachedGraph, self.commits == commits, self.firstParent == firstParent { return cachedGraph }
        let graph = CommitGraph(commits: commits, firstParent: firstParent)
        self.commits = commits
        self.firstParent = firstParent
        cachedGraph = graph
        return graph
    }

    func styles(commits: [GitCommit], remoteBranchNames: Set<String>, localUnpushedHashes: Set<String>?, currentBranch: GitBranch?, visibleRemoteBranchNames: Set<String>?) -> HistoryGraphStylePlan {
        if let cachedStyles, colorCommits == commits, colorRemoteBranchNames == remoteBranchNames, colorVisibleRemoteBranchNames == visibleRemoteBranchNames, colorLocalUnpushedHashes == localUnpushedHashes, colorCurrentBranch == currentBranch { return cachedStyles }
        let styles = HistoryGraphStylePlan(commits: commits, remoteBranchNames: remoteBranchNames, localUnpushedHashes: localUnpushedHashes, currentBranch: currentBranch, visibleRemoteBranchNames: visibleRemoteBranchNames)
        colorCommits = commits
        colorRemoteBranchNames = remoteBranchNames
        colorVisibleRemoteBranchNames = visibleRemoteBranchNames
        colorLocalUnpushedHashes = localUnpushedHashes
        colorCurrentBranch = currentBranch
        cachedStyles = styles
        return styles
    }
}

// Native tracking uses window coordinates while the table resizes live.
private struct HistoryColumnHeader: View {
    let title: String
    let column: HistoryColumn
    @Binding var width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(title).lineLimit(1).truncationMode(.tail)
                .padding(.leading, column == .graph ? HistoryColumnLayout.headerLeadingInset - HistoryColumnLayout.leadingInset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            if column != .hash {
                HistoryResizeHandle(title: title, column: column, width: $width)
                    .frame(width: 9, height: 13)
                    .accessibilityLabel(historyText("history.resizeColumn", title))
            }
        }.frame(width: column.clampedWidth(width), height: 28).clipped()
    }
}

private struct HistoryResizeHandle: NSViewRepresentable {
    let title: String
    let column: HistoryColumn
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> HistoryResizeHandleView { HistoryResizeHandleView() }
    func updateNSView(_ view: HistoryResizeHandleView, context: Context) {
        view.column = column
        view.width = width
        view.commit = { width = $0 }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(historyText("history.resizeColumn", title))
    }
}

final class HistoryResizeHandleView: NSView {
    var column: HistoryColumn = .message
    var width: CGFloat = 360
    var commit: (CGFloat) -> Void = { _ in }
    private var originWidth: CGFloat?
    private var pointerOrigin: CGFloat = 0
    private weak var previousResponder: NSResponder?
    private var proposedWidth: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        finishResize(commitWidth: false)
        originWidth = width
        proposedWidth = width
        pointerOrigin = event.locationInWindow.x
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)

    }

    override func mouseDragged(with event: NSEvent) { updateResize(pointerX: event.locationInWindow.x) }
    override func mouseUp(with event: NSEvent) {
        updateResize(pointerX: event.locationInWindow.x)
        finishResize(commitWidth: true)
    }
    override func cancelOperation(_ sender: Any?) { finishResize(commitWidth: false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishResize(commitWidth: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateResize(pointerX: CGFloat) {
        guard let originWidth else { return }
        proposedWidth = column.resizedWidth(origin: originWidth, translation: pointerX - pointerOrigin)
        if proposedWidth != width {
            width = proposedWidth
            commit(proposedWidth)
        }
    }
    private func finishResize(commitWidth: Bool) {
        guard let original = originWidth else { return }
        originWidth = nil
        if let window, window.firstResponder === self { window.makeFirstResponder(previousResponder) }
        previousResponder = nil
        if !commitWidth, width != original { width = original; commit(original) }
    }
}

private struct CommitGraphCell: NSViewRepresentable {
    let row: CommitGraph.Row
    let rowIndex: Int
    let styles: HistoryGraphStylePlan
    var selected = false
    func makeNSView(context: Context) -> CommitGraphView { CommitGraphView() }
    func updateNSView(_ view: CommitGraphView, context: Context) {
        view.configure(row: row, rowIndex: rowIndex, styles: styles, selected: selected)
    }
}

/// Read selection during AppKit tracking, before SwiftUI publishes the new binding.
class HistorySelectionView: NSView {
    var selected = false
    private(set) var drawnSelection: Bool?
    override var isFlipped: Bool { true }
    private var selectionObservation: NSKeyValueObservation?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeSelection()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeSelection()
    }
    private func observeSelection() {
        selectionObservation = nativeRow?.observe(\.isSelected) { [weak self] row, _ in
            MainActor.assumeIsolated {
                guard let self, self.drawnSelection != row.isSelected else { return }
                self.needsDisplay = true
                row.display()
                self.layer?.displayIfNeeded()
            }
        }
    }
    private var nativeRow: NSTableRowView? {
        var ancestor = superview
        while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
        return ancestor as? NSTableRowView
    }
    var nativeSelected: Bool { nativeRow?.isSelected ?? selected }
    override func draw(_ dirtyRect: NSRect) { drawnSelection = nativeSelected }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct HistoryReferenceBadge: NSViewRepresentable {
    let label: String
    let tint: NSColor
    let selected: Bool
    func makeNSView(context: Context) -> HistoryReferenceBadgeView { HistoryReferenceBadgeView() }
    func updateNSView(_ view: HistoryReferenceBadgeView, context: Context) {
        view.label = label; view.tint = tint; view.selected = selected
        view.needsDisplay = true
        view.setAccessibilityLabel(label)
    }
}

final class HistoryReferenceBadgeView: HistorySelectionView {
    var label = ""
    var tint: NSColor = .labelColor
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let badge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
        (nativeSelected ? NSColor.white.withAlphaComponent(0.92) : tint.withAlphaComponent(0.13)).setFill()
        badge.fill()
        tint.withAlphaComponent(0.4).setStroke(); badge.lineWidth = 0.5; badge.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let height = ceil(font.ascender - font.descender + font.leading)
        (label as NSString).draw(in: NSRect(x: 4, y: (bounds.height - height) / 2, width: max(0, bounds.width - 8), height: height),
            withAttributes: [.font: font, .foregroundColor: tint, .paragraphStyle: paragraph])
    }
}

final class CommitGraphView: HistorySelectionView {
    var row: CommitGraph.Row?
    var rowIndex = 0
    var styles: HistoryGraphStylePlan?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(row: CommitGraph.Row, rowIndex: Int, styles: HistoryGraphStylePlan, selected: Bool) {
        let changed = self.row != row || self.rowIndex != rowIndex
            || self.styles?.nodeStyle(for: row.hash) != styles.nodeStyle(for: row.hash)
            || row.segments.contains { self.styles?.lineStyle(for: $0) != styles.lineStyle(for: $0) }
        self.row = row; self.rowIndex = rowIndex; self.styles = styles; self.selected = selected
        if changed || drawnSelection != nativeSelected { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let row, let styles else { return }
        let selected = nativeSelected
        HistoryGraphPainter.draw(row: row, styles: styles, rowIndex: rowIndex, height: bounds.height, selected: selected)
        super.draw(dirtyRect)
    }
}


struct HistorySearchControl: View {
    @Binding var search: String
    var focusRequest: UUID? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            HistorySearchField(text: $search, placeholder: historyText("history.searchPlaceholder"),
                               accessibilityLabel: historyText("history.searchAccessibility"), focusRequest: focusRequest)
                .frame(height: 18)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(historyText("history.clearSearch"))
            }
        }.padding(.horizontal, 8).frame(height: 24)
            .auvGitInputSurface()
            .frame(minWidth: 160, maxWidth: .infinity)
    }
}
