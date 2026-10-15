import Foundation
import GitCore

/// Pin a stash to its object ID: later stash creation/drop cannot retarget the view.
enum StashHistory {
    static func files(repository: GitRepository, hash: String) async throws -> (files: [GitCommitFile], untracked: Set<String>) {
        let tracked = try await repository.commitFiles(hash: hash)
        let commit = try await repository.log(limit: 1, ref: hash).first
        let untracked = commit?.parents.count == 3 ? try await repository.commitFiles(hash: hash + "^3") : []
        let paths = Set(tracked.map(\.path))
        return (tracked + untracked.filter { !paths.contains($0.path) }, Set(untracked.map(\.path)))
    }
    static func diff(repository: GitRepository, hash: String, path: String, untracked: Bool) async throws -> String {
        let args = untracked
            ? ["show", "--format=", "--root", "--patch", "--no-ext-diff", "--no-textconv", "--no-color", hash + "^3", "--", path]
            : ["diff", "--no-ext-diff", "--no-textconv", "--no-color", hash + "^1", hash, "--", path]
        return try await repository.workflowRead(args)
    }
}
