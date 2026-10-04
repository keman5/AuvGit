import Foundation

public enum HistoryReference {
    public static func canonical(_ reference: String?, branches: [GitBranch]) -> String? {
        guard let reference, !reference.isEmpty else { return nil }
        if reference.hasPrefix("refs/") { return reference }
        let matches = branches.filter { $0.name == reference }
        if matches.count == 1, let branch = matches.first {
            return (branch.isRemote ? "refs/remotes/" : "refs/heads/") + branch.name
        }
        return reference // Pinned hashes, HEAD and stash refs are already exact inputs.
    }
}
