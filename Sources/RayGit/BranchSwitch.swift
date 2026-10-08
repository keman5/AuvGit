import GitCore
import Foundation

@MainActor
enum BranchSwitch {
    /// Git first carries transferable changes across. Only its overwrite refusal
    /// permits an automatic stash; the stash is retained even if retry fails.
    static func perform(repository: GitRepository, branch: String,
                        isCurrentRepository: () -> Bool) async throws -> String? {
        guard isCurrentRepository() else { throw CancellationError() }
        if try await repository.currentBranch() == branch { return nil }
        guard isCurrentRepository() else { throw CancellationError() }
        do { try await repository.checkout(branch: branch); return nil }
        catch {
            let message = error.localizedDescription.lowercased()
            guard message.contains("would be overwritten by checkout"),
                  isCurrentRepository(), !(try await repository.status()).contains(where: \.isConflict) else { throw error }
            for state in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
                let path = try await repository.workflowRead(["rev-parse", "--git-path", state]).trimmingCharacters(in: .newlines)
                let location = path.hasPrefix("/") ? path : repository.url.appendingPathComponent(path).path
                guard !FileManager.default.fileExists(atPath: location) else { throw error }
            }
            let source = try await repository.currentBranch()
            let previousStash = try? await repository.workflowRevision("refs/stash")
            guard isCurrentRepository() else { throw CancellationError() }
            try await repository.stash(message: "RayGit auto-stash: " + source + " → " + branch)
            let stash = try await repository.workflowRevision("refs/stash")
            guard stash != previousStash else { throw GitError("No recoverable auto-stash was created; branch switch stopped.") }
            guard isCurrentRepository() else { throw GitError("Branch switch cancelled; saved changes remain in stash " + stash) }
            do { try await repository.checkout(branch: branch) }
            catch { throw GitError(error.localizedDescription + "\nSaved changes remain in stash " + stash) }
            return stash
        }
    }
}

extension RepositoryStore {
    func switchBranch(to branch: String, savedChanges: @escaping @MainActor (String) -> Void = { _ in }) {
        guard let source = repository, !isBusy, pendingRepositoryPath == nil else { return }
        Task {
            if let worktrees = try? await source.worktrees(),
               let target = worktrees.first(where: {
                   $0.branch == branch && !$0.isBare && !$0.isPrunable && !Self.sameRepositoryLocation(URL(fileURLWithPath: $0.path), source.url)
               }),
               let linked = try? await GitRepository.open(URL(fileURLWithPath: target.path)),
               self.repository === source, !self.isBusy, self.pendingRepositoryPath == nil {
                self.requestOpen(linked.url)
                return
            }
            guard self.repository === source, !self.isBusy, self.pendingRepositoryPath == nil else { return }
            self.operation("切换分支") { repository in
                if let stash = try await BranchSwitch.perform(repository: repository, branch: branch,
                                               isCurrentRepository: { self.repository === repository }) {
                    savedChanges(stash)
                }
            }
        }
    }
}
