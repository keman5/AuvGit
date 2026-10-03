import SwiftUI
import GitCore
import RayGitLocalization

private func historyText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Detail", arguments: arguments)
}

enum HistoryAction: String, CaseIterable {
    case show, copyHash, copyMessage, createBranch, createTag, checkout, cherryPick, revert
    var isMutation: Bool { ![Self.show, .copyHash, .copyMessage].contains(self) }
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

    @State private var authorWidth: CGFloat = 135
    @State private var dateWidth: CGFloat = 125
    @State private var resizeOrigin: CGFloat?
    var body: some View {
        let visible = commits
        let graph = CommitGraph(commits: visible)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(historyText("history.searchPlaceholder"), text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(historyText("history.searchAccessibility"))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(historyText("history.clearSearch"))
                }
                if isLoading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            HStack(spacing: 8) {
                Text(historyText("history.graph")).frame(width: graphWidth(graph), alignment: .leading)
                Text(historyText("history.message")).frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    columnHeader(historyText("history.author"), width: $authorWidth)
                    columnHeader(historyText("history.date"), width: $dateWidth)
                }
                Text(historyText("history.hash")).frame(width: 75, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(isLoading ? historyText("history.loading") : historyText("history.empty"), systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(search.isEmpty ? historyText("history.emptyDescription") : historyText("history.noResults"))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(visible.enumerated()), id: \.element.hash) { index, commit in
                        HStack(spacing: 8) {
                            CommitGraphCell(row: graph.rows[index], laneCount: graph.laneCount)
                                .frame(width: graphWidth(graph), height: 28)
                            HStack(spacing: 5) {
                                ForEach(compact ? Array(commit.refs.prefix(1)) : commit.refs, id: \.self) { ref in
                                    Text(ref).font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                                        .frame(maxWidth: compact ? 90 : nil).lineLimit(1)
                                        .help(ref)
                                }
                                Text(commit.subject).lineLimit(1).help(commit.subject)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if !compact {
                            Text(commit.author).lineLimit(1).frame(width: authorWidth, alignment: .leading).help(commit.author)
                            Text(commit.date, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(L10n.locale))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: dateWidth, alignment: .leading)
                            }
                            Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 75, alignment: .leading)
                        }.font(.system(size: 12))
                            .padding(.horizontal, 12)
                            .tag(commit.hash)
                            .listRowInsets(EdgeInsets())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(historyText("history.commitAccessibility", commit.subject, commit.author, commit.shortHash))
                    }
                }.listStyle(.plain).environment(\.defaultMinListRowHeight, 28)
                    .contextMenu(forSelectionType: String.self) { hashes in
                        if let hash = hashes.first, let commit = commits.first(where: { $0.hash == hash }) {
                            Button(historyActionText("show")) { onAction(.show, commit) }
                            Divider()
                            ForEach([HistoryAction.cherryPick, .revert, .createBranch, .createTag, .checkout], id: \.self) { action in
                                Button(historyActionText(action.rawValue)) { onAction(action, commit) }.disabled(isBusy || (commit.parents.count > 1 && (action == .cherryPick || action == .revert)))
                            }
                            Divider()
                            Button(historyActionText("copyHash")) { onAction(.copyHash, commit) }
                            Button(historyActionText("copyMessage")) { onAction(.copyMessage, commit) }
                        }
                    } primaryAction: { hashes in
                        if let hash = hashes.first, let commit = commits.first(where: { $0.hash == hash }) { onAction(.show, commit) }
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
            if !compact, let commit = commits.first(where: { $0.hash == selection }) {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 12) {
                        Text(commit.hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Text(commit.author).lineLimit(1).textSelection(.enabled)
                        Text(commit.date, format: .dateTime.year().month().day().hour().minute().second().locale(L10n.locale))
                            .foregroundStyle(.secondary)
                    }.font(.caption)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(commit.body.isEmpty ? commit.subject : commit.body).font(.system(size: 12))
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(minHeight: 45, maxHeight: 115)
                }.padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityLabel(historyText("history.details"))
            }
        }.background(.background)
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
                context.stroke(path, with: .color(colors[segment.colorLane % colors.count]), lineWidth: 1.5)
            }
            let point = CGRect(x: 3 + CGFloat(row.nodeLane) * spacing, y: size.height / 2 - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: point), with: .color(colors[row.nodeLane % colors.count]))
        }.accessibilityHidden(true)
    }
}
