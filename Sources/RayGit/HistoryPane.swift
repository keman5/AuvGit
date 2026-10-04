import SwiftUI
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

    @Binding var authorFilter: String
    @AppStorage("history.showAuthorAvatars") private var showAvatars = true
    @AppStorage("history.showAuthorNames") private var showNames = true
    @AppStorage("history.showRemoteLabels") private var showRemoteLabels = true
    @AppStorage("history.showTagLabels") private var showTagLabels = true
    @State private var pendingNavigationScroll = true
    @State private var jumpHash = ""
    @State private var authorWidth: CGFloat = 135
    @AppStorage("preferences.dateStyle") private var dateStyle = "datetime"
    @State private var dateWidth: CGFloat = 125
    @State private var resizeOrigin: CGFloat?
    var body: some View {
        GeometryReader { geometry in
        let visible = commits
        let graph = CommitGraph(commits: visible)
        let showColumns = !compact && geometry.size.width >= 640
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
            if !compact {
            HStack(spacing: 8) {
                Text(historyText("history.graph")).frame(width: graphWidth(graph), alignment: .leading)
                Text(historyText("history.message")).frame(maxWidth: .infinity, alignment: .leading)
                if showColumns {
                    if showNames || showAvatars { columnHeader(historyText("history.author"), width: $authorWidth) }
                    columnHeader(historyText("history.date"), width: $dateWidth)
                }
                Text(historyText("history.hash")).frame(width: 75, alignment: .leading)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).rayGitChrome()
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
                        HStack(spacing: 8) {
                            CommitGraphCell(row: graph.rows[index], laneCount: graph.laneCount, selected: selection == commit.hash)
                                .frame(width: graphWidth(graph), height: 28)
                            HStack(spacing: 5) {
                                ForEach(visibleRefs(commit, compact: compact), id: \.self) { ref in
                                    Text(ref).font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .foregroundStyle(selection == commit.hash ? Color.white : (isRemoteRef(ref) ? RayGitStyle.blue : Color.primary))
                                        .background((selection == commit.hash ? Color.black : (isRemoteRef(ref) ? RayGitStyle.blue : Color.secondary)).opacity(selection == commit.hash ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 4))
                                        .frame(maxWidth: compact ? 90 : 120).lineLimit(1)
                                        .help(ref)
                                }
                                Text(commit.subject).lineLimit(1).help(commit.subject)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if showColumns {
                            if showNames || showAvatars {
                                HStack(spacing: 5) {
                                    if showAvatars { CommitAvatar(email: commit.authorEmail, size: 20) }
                                    if showNames { Text(commit.author).lineLimit(1) }
                                }.frame(width: authorWidth, alignment: .leading).help(commit.author + (commit.authorEmail.isEmpty ? "" : " <" + commit.authorEmail + ">"))
                            }
                            Text(preferencesDate(commit.date, style: dateStyle))
                                .font(.system(size: 11)).foregroundStyle(selection == commit.hash ? Color.white : Color.secondary)
                                .lineLimit(1).frame(width: dateWidth, alignment: .leading)
                            }
                            if compact, showAvatars { CommitAvatar(email: commit.authorEmail, size: 20) }
                            if compact, showNames { Text(commit.author).font(.system(size: 10)).lineLimit(1).frame(maxWidth: 85, alignment: .leading) }
                            if compact { Text(commit.date, style: .relative).font(.system(size: 10)).foregroundStyle(selection == commit.hash ? Color.white : Color.secondary).frame(width: 65, alignment: .trailing) }
                            Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(selection == commit.hash ? Color.white : Color.secondary).frame(width: 75, alignment: .leading)
                        }.font(.system(size: 12))
                            .foregroundStyle(selection == commit.hash ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .listRowBackground(selection == commit.hash ? RayGitStyle.blue : Color.clear)
                            .tag(commit.hash).id(commit.hash)
                            .listRowInsets(EdgeInsets())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(historyText("history.commitAccessibility", commit.subject, commit.author, commit.shortHash))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, RayGitStyle.rowHeight)
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
            HStack(spacing: 6) { Image(systemName: "person").foregroundStyle(.secondary); TextField(workflowText("Author"), text: $authorFilter).textFieldStyle(.plain) }.padding(.horizontal, 8).padding(.vertical, 4).rayGitInputSurface().frame(width: 140)
            HStack(spacing: 6) { Image(systemName: "number").foregroundStyle(.secondary); TextField(workflowText("Commit hash"), text: $jumpHash).textFieldStyle(.plain).onSubmit { onJump(jumpHash) } }.padding(.horizontal, 8).padding(.vertical, 4).rayGitInputSurface().frame(width: 110)
        }
    }
    private func graphWidth(_ graph: CommitGraph) -> CGFloat { min(compact ? 80 : 180, CGFloat(graph.laneCount) * 14 + 8) }
    private func columnHeader(_ title: String, width: Binding<CGFloat>) -> some View {
        HStack(spacing: 0) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 3, height: 13)
                .padding(.horizontal, 3)
                .gesture(DragGesture().onChanged { value in
                    if resizeOrigin == nil { resizeOrigin = width.wrappedValue }
                    width.wrappedValue = min(260, max(75, (resizeOrigin ?? width.wrappedValue) + value.translation.width))
                }.onEnded { _ in resizeOrigin = nil })
                .accessibilityLabel(historyText("history.resizeColumn", title))
        }.frame(width: width.wrappedValue)
    }
}

private struct CommitGraphCell: View {
    let row: CommitGraph.Row
    let laneCount: Int
    var selected = false
    private let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]
    var body: some View {
        Canvas { context, size in
            let spacing = min(14, (size.width - 8) / CGFloat(max(1, laneCount)))
            for segment in row.segments {
                var path = Path()
                let start = CGPoint(x: 7 + CGFloat(segment.fromLane) * spacing, y: size.height * segment.fromY)
                let end = CGPoint(x: 7 + CGFloat(segment.toLane) * spacing, y: size.height * segment.toY)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: (start.y + end.y) / 2), control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
                context.stroke(path, with: .color(selected ? .white.opacity(0.85) : colors[segment.colorLane % colors.count]), lineWidth: 1.5)
            }
            let point = CGRect(x: 3 + CGFloat(row.nodeLane) * spacing, y: size.height / 2 - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: point), with: .color(selected ? .white : colors[row.nodeLane % colors.count]))
        }.accessibilityHidden(true)
    }
}

struct HistorySearchControl: View {
    @Binding var search: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("", text: $search, prompt: Text(historyText("history.searchPlaceholder")))
                .labelsHidden().frame(height: 18)
                .textFieldStyle(.plain)
                .accessibilityLabel(historyText("history.searchAccessibility"))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(historyText("history.clearSearch"))
            }
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .rayGitInputSurface()
            .frame(minWidth: 160, maxWidth: .infinity)
    }
}
