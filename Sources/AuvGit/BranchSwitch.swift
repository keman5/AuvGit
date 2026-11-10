import GitCore
import Foundation

@MainActor
enum BranchSwitch {
    struct Destination {
        let branch: String
        var trackingRemote: String? = nil
    }

    static func remoteDestination(repository: GitRepository, branch: String) async throws -> Destination {
        let reference = "refs/remotes/" + branch
        let branches = try await repository.branches()
        guard branches.contains(where: { $0.isRemote && $0.name == branch }) else { throw GitError("Invalid remote branch") }
        let remote = try await repository.remoteBranchDestination(reference)
        let name = String(remote.branch.dropFirst("refs/heads/".count))
        let locals = branches.filter { !$0.isRemote }
        if locals.contains(where: { $0.name == name }) { return Destination(branch: name) }
        let tracking = locals.filter { $0.upstream == branch || $0.upstream == reference }
        if tracking.count == 1, let existing = tracking.first { return Destination(branch: existing.name) }
        return Destination(branch: name, trackingRemote: reference)
    }

    /// Git first carries transferable changes across. Only its overwrite refusal
    /// permits an automatic stash; the stash is retained even if retry fails.
    static func perform(repository: GitRepository, branch: String, trackingRemote: String? = nil,
                        isCurrentRepository: () -> Bool) async throws -> String? {
        guard isCurrentRepository() else { throw CancellationError() }
        if trackingRemote == nil, try await repository.currentBranch() == branch { return nil }
        guard isCurrentRepository() else { throw CancellationError() }
        func checkout() async throws {
            if let trackingRemote { try await repository.checkoutNewTrackingBranch(name: branch, remoteReference: trackingRemote) }
            else { try await repository.checkout(branch: branch) }
        }
        do { try await checkout(); return nil }
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
            try await repository.stash(message: "AuvGit auto-stash: " + source + " → " + branch)
            let stash = try await repository.workflowRevision("refs/stash")
            guard stash != previousStash else { throw GitError("No recoverable auto-stash was created; branch switch stopped.") }
            guard isCurrentRepository() else { throw GitError("Branch switch cancelled; saved changes remain in stash " + stash) }
            do { try await checkout() }
            catch { throw GitError(error.localizedDescription + "\nSaved changes remain in stash " + stash) }
            return stash
        }
    }
}

extension RepositoryStore {
    func switchBranch(to branch: String, isRemote: Bool = false, savedChanges: @escaping @MainActor (String) -> Void = { _ in }) {
        guard let source = repository, !isBusy, pendingRepositoryPath == nil else { return }
        Task {
            let destination: BranchSwitch.Destination
            do {
                destination = isRemote ? try await BranchSwitch.remoteDestination(repository: source, branch: branch) : .init(branch: branch)
            } catch {
                if self.repository === source, !self.isBusy, self.pendingRepositoryPath == nil { self.report(error) }
                return
            }
            if let worktrees = try? await source.worktrees(),
               let target = worktrees.first(where: {
                   $0.branch == destination.branch && !$0.isBare && !$0.isPrunable && !Self.sameRepositoryLocation(URL(fileURLWithPath: $0.path), source.url)
               }),
               let linked = try? await GitRepository.open(URL(fileURLWithPath: target.path)),
               self.repository === source, !self.isBusy, self.pendingRepositoryPath == nil {
                self.requestOpen(linked.url)
                return
            }
            guard self.repository === source, !self.isBusy, self.pendingRepositoryPath == nil else { return }
            self.operation("切换分支") { repository in
                if let stash = try await BranchSwitch.perform(repository: repository, branch: destination.branch, trackingRemote: destination.trackingRemote,
                                               isCurrentRepository: { self.repository === repository }) {
                    savedChanges(stash)
                }
            }
        }
    }
}
