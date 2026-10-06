import GitCore

/// Call inside Store.operation so the UI cannot start a second mutation while
/// fresh status is being read or the dirty-worktree decision is pending.
@MainActor
enum BranchSwitch {
    static func perform(repository: GitRepository, branch: String,
                        isCurrentRepository: () -> Bool,
                        confirmChanges: ([GitFile]) async -> Bool) async throws {
        guard isCurrentRepository() else { throw CancellationError() }
        if try await repository.currentBranch() == branch { return }
        var approvedChanges: [GitFile]?
        while true {
            let changes = try await repository.status()
            guard isCurrentRepository() else { throw CancellationError() }
            if !changes.isEmpty, changes != approvedChanges {
                guard await confirmChanges(changes) else { throw CancellationError() }
                approvedChanges = changes
                // Re-read after the dialog: new paths/statuses require a new decision.
                continue
            }
            // A normal non-forced switch leaves Git's overwrite protection intact.
            try await repository.checkout(branch: branch)
            return
        }
    }
}

extension RepositoryStore {
    func switchBranch(to branch: String, confirmChanges: @escaping @MainActor ([GitFile]) async -> Bool) {
        operation("切换分支") { repository in
            try await BranchSwitch.perform(repository: repository, branch: branch,
                                           isCurrentRepository: { self.repository === repository },
                                           confirmChanges: confirmChanges)
        }
    }
}
