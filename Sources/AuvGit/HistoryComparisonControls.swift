import SwiftUI
import GitCore
import AuvGitLocalization

func historyComparisonText(_ key: String) -> String { L10n.text(key, table: "HistoryComparison") }
func historyEndpointTitle(_ endpoint: HistoryEndpoint) -> String {
    switch endpoint {
    case .index: historyComparisonText("index")
    case .workingTree: historyComparisonText("worktree")
    case let .commit(hash): String(hash.prefix(8))
    }
}

struct HistoryComparisonControls: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        if let range = store.historyComparisonRange {
            HStack(spacing: 8) {
                Text(historyEndpointTitle(range.from) + " → " + historyEndpointTitle(range.to))
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                Button { store.reverseHistoryComparison() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.plain).help(historyComparisonText("reverse"))
                    .accessibilityLabel(historyComparisonText("reverse"))
            }.padding(.horizontal, 12).frame(height: 28).auvGitSectionChrome()
        }
    }
}

struct HistoryAuxiliaryBranchMenu: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        Menu {
            Button(historyComparisonText("none")) { store.setAuxiliaryHistoryBranch(nil) }
            ForEach(store.branches) { branch in
                let reference = HistoryBranchScope.branchRef(branch)
                Button {
                    store.setAuxiliaryHistoryBranch(reference)
                } label: {
                    if store.auxiliaryHistoryBranch == reference { Label(branch.name, systemImage: "checkmark") }
                    else { Text(branch.name) }
                }
            }
        } label: { Image(systemName: "arrow.triangle.branch") }
            .menuStyle(.borderlessButton).fixedSize()
            .help(historyComparisonText("auxiliary"))
            .accessibilityLabel(historyComparisonText("auxiliary"))
    }
}

