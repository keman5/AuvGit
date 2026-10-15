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
    @AppStorage("history.showAuthorAvatars") private var showAvatars = true
    @AppStorage("history.showAuthorNames") private var showNames = true
    @AppStorage("history.showRemoteLabels") private var showRemoteLabels = true
    @AppStorage("history.showTagLabels") private var showTagLabels = true
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @StateObject private var graphCache = HistoryGraphCache()
    @State private var pendingNavigationScroll = true
    @State private var jumpHash = ""
    @State private var authorWidth: CGFloat = 110
    @State private var graphColumnWidth: CGFloat = HistoryColumn.graph.minimumWidth
    @State private var messageWidth: CGFloat = 360
    @State private var hashWidth: CGFloat = 75
    @State private var dateWidth: CGFloat = 150
    @State private var paginationGate = HistoryPaginationGate(prefetchDistance: 10)

    var body: some View {
        GeometryReader { geometry in
        let visible = commits
        let graph = graphCache.graph(commits: visible, firstParent: firstParentGraph)
        let graphStyles = graphCache.styles(commits: visible, remoteBranchNames: remoteBranchNames, localUnpushedHashes: localUnpushedCommitHashes, currentBranch: currentBranch, visibleRemoteBranchNames: visibleRemoteBranchNames)
        let showColumns = !compact && (showAvatars || showNames)
        let compactNameWidth = compact && showNames ? graphCache.compactNameWidth(commits: visible, showsAvatar: showAvatars) : 0
        let compactDateWidth = compact ? graphCache.compactDateWidth(commits: visible) : 0
        let compactIdentityWidth = (showAvatars ? 18 : 0) + (showNames ? compactNameWidth : 0) + (showAvatars && showNames ? 4 : 0)
        let displayedAuthorWidth: CGFloat = showNames ? authorWidth : 18
        VStack(spacing: 0) {
            if showsSearch {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if compact { Label(designWorkspaceText("Commit history"), systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold)) }
                    searchControl
                    if !compact { filterControls }; HistoryDisplayMenu()
                }
                VStack(spacing: 8) {
                    searchControl
                    if !compact { filterControls.frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).auvGitChrome()
            Divider()
            }
            ScrollView(.horizontal) {
            VStack(spacing: 0) {
            if !compact {
            HStack(spacing: 8) {
                columnHeader(historyText("history.graph"), column: .graph, width: $graphColumnWidth,
                             minimumWidth: HistoryColumnLayout.graphWidth(laneCount: graph.laneCount))
                    .help(historyText("history.graphLegend"))
                columnHeader(historyText("history.message"), column: .message, width: $messageWidth)
                if showColumns {
                    if showNames { columnHeader(historyText("history.author"), column: .author, width: $authorWidth) }
                    else { Color.clear.frame(width: 18) }
                }
                columnHeader(historyText("history.date"), column: .date, width: $dateWidth)
                columnHeader(historyText("history.hash"), column: .hash, width: $hashWidth)
            }.frame(maxWidth: .infinity, alignment: .leading).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, HistoryColumnLayout.headerLeadingInset).padding(.trailing, HistoryColumnLayout.trailingInset).frame(height: 28).fixedSize(horizontal: false, vertical: true).auvGitChrome()
            Divider()
            }
            if compact {
                NativeCompactHistoryTable(commits: visible, graph: graph, styles: graphStyles,
                    selection: $selection, navigationGeneration: navigationGeneration,
                    graphWidth: graphWidth(graph), nameWidth: compactNameWidth, dateWidth: compactDateWidth,
                    showAvatars: showAvatars, showNames: showNames,
                    showRemoteLabels: showRemoteLabels, showTagLabels: showTagLabels,
                    isBusy: isBusy, hasMore: hasMore, isLoading: isLoading,
                    onLoadMore: onLoadMore, onAction: onAction)
                    .overlay {
                        if visible.isEmpty { emptyHistory.allowsHitTesting(false) }
                    }
            } else if visible.isEmpty {
                emptyHistory
            } else {
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Array(visible.enumerated()), id: \.element.hash) { index, commit in
                        let row = graph.rows[index]
                        let rowWidths = HistoryColumnLayout.graphMessageWidths(
                            activeLaneCount: row.laneCount,
                            maximumLaneCount: graph.laneCount,
                            maximumGraphWidth: graphWidth(graph),
                            baseMessageWidth: compact ? 220 : messageWidth
                        )
                        HStack(spacing: compact ? 4 : 8) {
                            CommitGraphCell(row: row, rowIndex: index, styles: graphStyles, selected: selection == commit.hash)
                                .frame(width: rowWidths.graph, height: HistoryColumnLayout.rowHeight(compact: compact)).clipped()
                            HStack(spacing: 5) {
                                ForEach(visibleRefs(commit, compact: compact, styles: graphStyles), id: \.self) { ref in
                                    let tint = graphStyles.referenceStyle(for: ref, commitHash: commit.hash).color.color
                                    Text(graphStyles.referenceLabel(ref)).font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .foregroundStyle(tint)
                                        .background(selection == commit.hash ? Color.white.opacity(0.92) : tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.4), lineWidth: 0.5) }
                                        .lineLimit(1).frame(maxWidth: compact ? 90 : 120, alignment: .leading)
                                        .help(ref)
                                }
                                Text(commit.subject).lineLimit(1).help(commit.subject)
                            }.frame(width: rowWidths.message, alignment: .leading).clipped()
                            if showColumns {
                                HStack(spacing: 5) {
                                    if showAvatars { CommitAvatar(email: commit.authorEmail, size: 18).frame(width: 18, height: 18).clipped() }
                                    if showNames { Text(commit.author).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                                }.frame(width: displayedAuthorWidth, alignment: .leading).clipped().help(commit.author + (commit.authorEmail.isEmpty ? "" : " <" + commit.authorEmail + ">"))
                            }
                            if !compact {
                            Text(HistoryCalendarDate.text(commit.committedDate))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: dateWidth, alignment: .leading).clipped().help(HistoryCalendarDate.text(commit.committedDate))
                            }
                            if compact, showAvatars || showNames {
                                HStack(spacing: 4) {
                                    if showAvatars { CommitAvatar(email: commit.authorEmail, size: 18).frame(width: 18, height: 18).clipped() }
                                    if showNames { Text(commit.author).font(.system(size: 10)).lineLimit(1).frame(width: compactNameWidth, alignment: .leading).help(commit.author) }
                                }.frame(width: min(100, compactIdentityWidth), alignment: .leading).clipped()
                            }
                            if compact { Text(HistoryCalendarDate.text(commit.committedDate)).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary).frame(width: compactDateWidth, alignment: .leading).clipped().help(HistoryCalendarDate.text(commit.committedDate)) }
                            Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).frame(width: compact ? 75 : hashWidth, alignment: .leading).clipped()
                        }.font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .padding(.leading, HistoryColumnLayout.leadingInset)
                            .padding(.trailing, HistoryColumnLayout.trailingInset)
                            .listRowBackground(Color.clear)
                            .tag(commit.hash).id(commit.hash)
                            .listRowInsets(EdgeInsets())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(historyText("history.commitAccessibility", commit.subject, commit.author, commit.shortHash))
                            .onAppear {
                                if paginationGate.shouldRequestMore(visibleIndex: index, commitCount: visible.count, hasMore: hasMore, isLoading: isLoading) {
                                    onLoadMore()
                                }
                            }
                    }
                }.listStyle(.plain).contentMargins(.horizontal, 0).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, HistoryColumnLayout.rowHeight(compact: compact))
                    .contextMenu(forSelectionType: String.self) { hashes in
                        if let hash = hashes.first, let commit = commits.first(where: { $0.hash == hash }) {
                            Button(sidebarRefinementText("viewLog")) { onAction(.viewLog, commit) }.configuredShortcut(.viewLog, using: shortcuts)
                            Button(sidebarRefinementText("commitDetails")) { onAction(.show, commit) }.configuredShortcut(.show, using: shortcuts)
                            Divider()
                            Button(historyActionText("reset")) { onAction(.reset, commit) }.configuredShortcut(.reset, using: shortcuts).disabled(isBusy)
                            Button(historyActionText("resetAdvanced")) { onAction(.resetAdvanced, commit) }.configuredShortcut(.resetAdvanced, using: shortcuts).disabled(isBusy)
                            Button(historyActionText("createBranch")) { onAction(.createBranch, commit) }.configuredShortcut(.createBranch, using: shortcuts).disabled(isBusy)
                            Button(historyActionText("createTag")) { onAction(.createTag, commit) }.configuredShortcut(.createTag, using: shortcuts).disabled(isBusy)
                            Button(historyActionText("checkout")) { onAction(.checkout, commit) }.configuredShortcut(.checkout, using: shortcuts).disabled(isBusy)
                            Button(designText("Interactive Rebase")) { onAction(.rebase, commit) }.configuredShortcut(.rebase, using: shortcuts).disabled(isBusy)
                            ForEach([HistoryAction.cherryPick, .revert], id: \.self) { action in
                                Button(historyActionText(action.rawValue)) { onAction(action, commit) }.disabled(isBusy)
                            }
                            Divider()
                            Button(historyActionText("copyHash")) { onAction(.copyHash, commit) }.configuredShortcut(.copyHash, using: shortcuts)
                            Button(historyActionText("copyMessage")) { onAction(.copyMessage, commit) }.configuredShortcut(.copyMessage, using: shortcuts)
                            Button(shortcutText("Use Message for Commit")) { onAction(.useCommitMessage, commit) }.configuredShortcut(.useCommitMessage, using: shortcuts)
                        }
                    } primaryAction: { hashes in
                        if let hash = hashes.first, let commit = commits.first(where: { $0.hash == hash }) { onAction(.show, commit) }
                    }
                    .onChange(of: navigationGeneration) { _, _ in pendingNavigationScroll = true; scrollAfterNavigation(proxy) }
                    .onChange(of: visible.first?.hash) { _, _ in paginationGate.reset() }
                    .onChange(of: selection) { _, _ in scrollAfterNavigation(proxy) }
                    .onChange(of: commits) { _, _ in scrollAfterNavigation(proxy) }
                    .onAppear { scrollAfterNavigation(proxy) }
                }
            }
            }.frame(width: max(geometry.size.width, compact
                ? graphWidth(graph) + 220 + compactIdentityWidth + compactDateWidth + 75 + HistoryColumnLayout.leadingInset + HistoryColumnLayout.trailingInset + CGFloat(3 + (showAvatars || showNames ? 1 : 0)) * 4
                : graphWidth(graph) + messageWidth + (showColumns ? displayedAuthorWidth : 0) + dateWidth + hashWidth + HistoryColumnLayout.leadingInset + HistoryColumnLayout.trailingInset + CGFloat(showColumns ? 4 : 3) * 8), alignment: .leading)
            }
            if !compact, showsDetails, let commit = commits.first(where: { $0.hash == selection }) {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(commit.hash).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    CommitIdentityDetails(commit: commit)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(commit.body.isEmpty ? commit.subject : commit.body).font(.system(size: 12))
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(minHeight: 45, maxHeight: 115)
                }.padding(.horizontal, 12).padding(.vertical, 10).auvGitChrome()
                    .accessibilityLabel(historyText("history.details"))
            }
        }.background(AuvGitStyle.canvas)
            .background(HistoryKeyboardRegion(paneScoped: compact, action: { action in
                guard let commit = commits.first(where: { $0.hash == selection }), !action.isMutation || !isBusy else { return }
                onAction(action, commit)
            }, find: {
                if showsSearch { searchFocusRequest = UUID() } else { onFind() }
            }, navigate: { child in
                guard let target = HistoryCommitNavigation.target(commits: commits, selection: selection, child: child) else { return }
                pendingNavigationScroll = true
                selection = target
            }, showChanges: onShowChanges))
        }
    }
    private var emptyHistory: some View {
        ContentUnavailableView {
            Label(isLoading ? historyText("history.loading") : historyText("history.empty"), systemImage: "clock.arrow.circlepath")
        } description: {
            Text(search.isEmpty ? historyText("history.emptyDescription") : historyText("history.noResults"))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func scrollAfterNavigation(_ proxy: ScrollViewProxy) {
        guard pendingNavigationScroll, let selection, commits.contains(where: { $0.hash == selection }) else { return }
        pendingNavigationScroll = false
        DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .top) }
    }
    private func visibleRefs(_ commit: GitCommit, compact: Bool, styles: HistoryGraphStylePlan) -> [String] {
        let values = commit.refs.filter { styles.isVisibleReference($0) && (showRemoteLabels || !styles.isRemoteReference($0)) && (showTagLabels || !styles.isTagReference($0)) }
        return compact ? Array(values.prefix(1)) : values
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

    func compactNameWidth(commits: [GitCommit], showsAvatar: Bool) -> CGFloat {
        let authors = commits.map(\.author)
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
            Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
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
        view.row = row; view.rowIndex = rowIndex; view.styles = styles; view.selected = selected
        view.needsDisplay = true
    }
}

final class CommitGraphView: NSView {
    var row: CommitGraph.Row?
    var rowIndex = 0
    var styles: HistoryGraphStylePlan?
    var selected = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: NSTableView.selectionDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func selectionChanged() { needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var nativeSelected: Bool {
        var ancestor = superview
        while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
        return (ancestor as? NSTableRowView)?.isSelected ?? selected
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let row, let styles else { return }
        HistoryGraphPainter.draw(row: row, styles: styles, rowIndex: rowIndex, height: bounds.height, selected: nativeSelected)
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
