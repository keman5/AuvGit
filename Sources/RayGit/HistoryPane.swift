import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

private func historyText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Detail", arguments: arguments)
}

enum HistoryAction: String, CaseIterable {
    case viewLog, show, copyHash, copyMessage, createBranch, createTag, checkout, cherryPick, revert
    var isMutation: Bool { ![Self.viewLog, .show, .copyHash, .copyMessage].contains(self) }
}

func historyActionText(_ key: String) -> String { L10n.text(key, table: "HistoryActions") }

struct HistoryPane: View {
    let commits: [GitCommit]
    @Binding var selection: String?
    @Binding var search: String
    let isLoading: Bool
    let hasMore: Bool
    let onLoadMore: () -> Void

    var isBusy: Bool = false
    var onAction: (HistoryAction, GitCommit) -> Void = { _, _ in }
    var compact: Bool = false
    var showsSearch: Bool = true
    var showsDetails: Bool = true
    var remoteBranchNames: Set<String> = []
    var navigationGeneration: UUID? = nil
    var onJump: (String) -> Void = { _ in }
    var firstParentGraph: Bool = false

    @Binding var authorFilter: String
    @AppStorage("history.showAuthorAvatars") private var showAvatars = true
    @AppStorage("history.showAuthorNames") private var showNames = true
    @AppStorage("history.showRemoteLabels") private var showRemoteLabels = true
    @AppStorage("history.showTagLabels") private var showTagLabels = true
    @StateObject private var graphCache = HistoryGraphCache()
    @State private var pendingNavigationScroll = true
    @State private var jumpHash = ""
    @State private var authorWidth: CGFloat = 110
    @State private var graphColumnWidth: CGFloat = 55
    @State private var messageWidth: CGFloat = 360
    @State private var hashWidth: CGFloat = 75
    @State private var dateWidth: CGFloat = 150

    var body: some View {
        GeometryReader { geometry in
        let visible = commits
        let graph = graphCache.graph(commits: visible, firstParent: firstParentGraph)
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
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).rayGitChrome()
            Divider()
            }
            ScrollView(.horizontal) {
            VStack(spacing: 0) {
            if !compact {
            HStack(spacing: 8) {
                columnHeader(historyText("history.graph"), column: .graph, width: $graphColumnWidth)
                columnHeader(historyText("history.message"), column: .message, width: $messageWidth)
                if showColumns {
                    if showNames { columnHeader(historyText("history.author"), column: .author, width: $authorWidth) }
                    else { Color.clear.frame(width: 18) }
                }
                columnHeader(historyText("history.date"), column: .date, width: $dateWidth)
                columnHeader(historyText("history.hash"), column: .hash, width: $hashWidth)
            }.frame(maxWidth: .infinity, alignment: .leading).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28).fixedSize(horizontal: false, vertical: true).rayGitChrome()
            Divider()
            }
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(isLoading ? historyText("history.loading") : historyText("history.empty"), systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(search.isEmpty ? historyText("history.emptyDescription") : historyText("history.noResults"))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Array(visible.enumerated()), id: \.element.hash) { index, commit in
                        HStack(spacing: compact ? 4 : 8) {
                            CommitGraphCell(row: graph.rows[index], laneCount: graph.laneCount, selected: selection == commit.hash)
                                .frame(width: graphWidth(graph), height: compact ? 22 : 28).clipped()
                            HStack(spacing: 5) {
                                ForEach(visibleRefs(commit, compact: compact), id: \.self) { ref in
                                    Text(ref).font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .foregroundStyle(selection == commit.hash ? Color.white : (isRemoteRef(ref) ? RayGitStyle.blue : Color.primary))
                                        .background((selection == commit.hash ? Color.black : (isRemoteRef(ref) ? RayGitStyle.blue : Color.secondary)).opacity(selection == commit.hash ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 4))
                                        .lineLimit(1).frame(maxWidth: compact ? 90 : 120, alignment: .leading)
                                        .help(ref)
                                }
                                Text(commit.subject).lineLimit(1).help(commit.subject)
                            }.frame(width: compact ? 220 : messageWidth, alignment: .leading).clipped()
                            if showColumns {
                                HStack(spacing: 5) {
                                    if showAvatars { CommitAvatar(email: commit.authorEmail, size: 18).frame(width: 18, height: 18).clipped() }
                                    if showNames { Text(commit.author).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                                }.frame(width: displayedAuthorWidth, alignment: .leading).clipped().help(commit.author + (commit.authorEmail.isEmpty ? "" : " <" + commit.authorEmail + ">"))
                            }
                            if !compact {
                            Text(HistoryCalendarDate.text(commit.committedDate))
                                .font(.system(size: 11)).foregroundStyle(selection == commit.hash ? Color.white : Color.secondary)
                                .lineLimit(1).frame(width: dateWidth, alignment: .leading).clipped().help(HistoryCalendarDate.text(commit.committedDate))
                            }
                            if compact, showAvatars || showNames {
                                HStack(spacing: 4) {
                                    if showAvatars { CommitAvatar(email: commit.authorEmail, size: 18).frame(width: 18, height: 18).clipped() }
                                    if showNames { Text(commit.author).font(.system(size: 10)).lineLimit(1).frame(width: compactNameWidth, alignment: .leading).help(commit.author) }
                                }.frame(width: min(100, compactIdentityWidth), alignment: .leading).clipped()
                            }
                            if compact { Text(HistoryCalendarDate.text(commit.committedDate)).font(.system(size: 10)).lineLimit(1).foregroundStyle(selection == commit.hash ? Color.white : Color.secondary).frame(width: compactDateWidth, alignment: .leading).clipped().help(HistoryCalendarDate.text(commit.committedDate)) }
                            Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(selection == commit.hash ? Color.white : Color.secondary).lineLimit(1).frame(width: compact ? 75 : hashWidth, alignment: .leading).clipped()
                        }.font(.system(size: 12))
                            .foregroundStyle(selection == commit.hash ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .listRowBackground(selection == commit.hash ? RayGitStyle.blue : Color.clear)
                            .tag(commit.hash).id(commit.hash)
                            .listRowInsets(EdgeInsets())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(historyText("history.commitAccessibility", commit.subject, commit.author, commit.shortHash))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, compact ? 22 : RayGitStyle.rowHeight)
                    .contextMenu(forSelectionType: String.self) { hashes in
                        if let hash = hashes.first, let commit = commits.first(where: { $0.hash == hash }) {
                            Button(sidebarRefinementText("viewLog")) { onAction(.viewLog, commit) }
                            Button(sidebarRefinementText("commitDetails")) { onAction(.show, commit) }
                            Divider()
                            ForEach([HistoryAction.cherryPick, .revert, .createBranch, .createTag, .checkout], id: \.self) { action in
                                Button(historyActionText(action.rawValue)) { onAction(action, commit) }.disabled(isBusy)
                            }
                            Divider()
                            Button(historyActionText("copyHash")) { onAction(.copyHash, commit) }
                            Button(historyActionText("copyMessage")) { onAction(.copyMessage, commit) }
                        }
                    } primaryAction: { hashes in
                        if let hash = hashes.first, let commit = commits.first(where: { $0.hash == hash }) { onAction(.show, commit) }
                    }
                    .onChange(of: navigationGeneration) { _, _ in pendingNavigationScroll = true; scrollAfterNavigation(proxy) }
                    .onChange(of: selection) { _, _ in scrollAfterNavigation(proxy) }
                    .onChange(of: commits) { _, _ in scrollAfterNavigation(proxy) }
                    .onAppear { scrollAfterNavigation(proxy) }
                }
            }
            }.frame(width: max(geometry.size.width, compact
                ? graphWidth(graph) + 220 + compactIdentityWidth + compactDateWidth + 75 + 24 + CGFloat(3 + (showAvatars || showNames ? 1 : 0)) * 4
                : graphColumnWidth + messageWidth + (showColumns ? displayedAuthorWidth : 0) + dateWidth + hashWidth + 24 + CGFloat(showColumns ? 4 : 3) * 8), alignment: .leading)
            }
            if hasMore {
                Divider()
                Button(action: onLoadMore) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text(isLoading ? historyText("history.loadingMore") : historyText("history.loadMore"))
                    }
                }.disabled(isLoading).padding(8)
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
                }.padding(.horizontal, 12).padding(.vertical, 10).rayGitChrome()
                    .accessibilityLabel(historyText("history.details"))
            }
        }.background(RayGitStyle.canvas)
        }
    }
    private func scrollAfterNavigation(_ proxy: ScrollViewProxy) {
        guard pendingNavigationScroll, let selection, commits.contains(where: { $0.hash == selection }) else { return }
        pendingNavigationScroll = false
        DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .top) }
    }
    private func isRemoteRef(_ ref: String) -> Bool {
        remoteBranchNames.contains(ref) || ref.hasPrefix("refs/remotes/")
    }
    private func visibleRefs(_ commit: GitCommit, compact: Bool) -> [String] {
        let values = commit.refs.filter { (showRemoteLabels || !isRemoteRef($0)) && (showTagLabels || !$0.hasPrefix("tag: ")) }
        return compact ? Array(values.prefix(1)) : values
    }
    private var searchControl: some View { HistorySearchControl(search: $search) }
    private var filterControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) { Image(systemName: "person").foregroundStyle(.secondary); StableTextField(workflowText("Author"), text: $authorFilter, rounded: false) }.padding(.horizontal, 8).frame(height: 24).rayGitInputSurface().frame(width: 140)
            HStack(spacing: 6) { Image(systemName: "number").foregroundStyle(.secondary); StableTextField(workflowText("Commit hash"), text: $jumpHash, onSubmit: { onJump(jumpHash) }, rounded: false) }.padding(.horizontal, 8).frame(height: 24).rayGitInputSurface().frame(width: 110)
        }
    }
    private func graphWidth(_ graph: CommitGraph) -> CGFloat { compact ? min(80, CGFloat(max(0, graph.laneCount - 1)) * 14 + 14) : graphColumnWidth }
    private func columnHeader(_ title: String, column: HistoryColumn, width: Binding<CGFloat>) -> some View {
        HistoryColumnHeader(title: title, column: column, width: width)
    }
}

// Selection and column layout do not change graph topology. Reuse it until inputs change.
private final class HistoryGraphCache: ObservableObject {
    private var commits: [GitCommit] = []
    private var firstParent = false
    private var cachedGraph: CommitGraph?
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

private struct CommitGraphCell: View {
    let row: CommitGraph.Row
    let laneCount: Int
    var selected = false
    var body: some View {
        Canvas { context, size in
            let spacing = min(14, (size.width - 8) / CGFloat(max(1, laneCount)))
            for segment in row.segments {
                var path = Path()
                let start = CGPoint(x: 7 + CGFloat(segment.fromLane) * spacing, y: size.height * segment.fromY)
                let end = CGPoint(x: 7 + CGFloat(segment.toLane) * spacing, y: size.height * segment.toY)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: (start.y + end.y) / 2), control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
                context.stroke(path, with: .color(selected ? .white.opacity(0.85) : Color.secondary.opacity(0.55)), lineWidth: 1.5)
            }
            let point = CGRect(x: 3 + CGFloat(row.nodeLane) * spacing, y: size.height / 2 - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: point), with: .color(selected ? RayGitStyle.blue : RayGitStyle.canvas))
            context.stroke(Path(ellipseIn: point), with: .color(selected ? .white : Color.secondary.opacity(0.75)), lineWidth: 1.5)
        }.accessibilityHidden(true)
    }
}

struct HistorySearchControl: View {
    @Binding var search: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            HistorySearchField(text: $search, placeholder: historyText("history.searchPlaceholder"),
                               accessibilityLabel: historyText("history.searchAccessibility"))
                .frame(height: 18)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(historyText("history.clearSearch"))
            }
        }.padding(.horizontal, 8).frame(height: 24)
            .rayGitInputSurface()
            .frame(minWidth: 160, maxWidth: .infinity)
    }
}
