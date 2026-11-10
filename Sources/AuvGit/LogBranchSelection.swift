import SwiftUI
import GitCore

/// Sidebar highlighting navigates commits independently of checked history scope.
@MainActor
final class LogBranchSelection: ObservableObject {
    @Published private(set) var navigationGeneration = UUID()
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel(); task = nil }

    func reset() {
        cancel()
        navigationGeneration = UUID()
    }

    @discardableResult
    func select(_ references: Set<String>, in store: RepositoryStore) -> Task<Void, Never>? {
        cancel()
        guard references.count == 1, let reference = references.first,
              !store.isBusy, !store.isRestoringViewState,
              HistoryBranchScope.isChecked(reference, in: store.checkedHistoryRefs ?? []),
              reference == "HEAD" || store.branches.contains(where: { HistoryBranchScope.branchRef($0) == reference }),
              let repository = store.repository else { return nil }
        let scope = store.currentHistoryScope
        let previousSelection = store.selectedCommit
        let navigation = store.historyNavigationGeneration
        let request = Task { [weak self, weak store] in
            // List can publish intermediate selections while reconciling a range.
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                guard let commit = try await repository.log(limit: 1, ref: reference).first,
                      !Task.isCancelled, let self, let store,
                      store.repository === repository, !store.isRestoringViewState,
                      store.currentHistoryScope == scope,
                      store.historyNavigationGeneration == navigation,
                      store.selectedCommit == previousSelection,
                      HistoryBranchScope.isChecked(reference, in: store.checkedHistoryRefs ?? []) else { return }
                if !store.commits.contains(where: { $0.hash == commit.hash }) { store.commits.append(commit) }
                store.selectedCommit = commit.hash
                // Scroll only the commit list; keep sidebar range and filter intact.
                self.navigationGeneration = UUID()
            } catch {
                guard !Task.isCancelled, let store, store.repository === repository,
                      store.currentHistoryScope == scope,
                      store.historyNavigationGeneration == navigation else { return }
                store.report(error)
            }
        }
        task = request
        return request
    }

    deinit { task?.cancel() }
}
