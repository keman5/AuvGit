import GitCore

/// Porcelain's index and working-tree columns are separate states; do not let
/// an index modification hide a later working-tree deletion or modification.
struct WorkspaceFileStatus {
    let keys: [String]
    var kind: String { keys.last ?? "none" }
    init(_ file: GitFile) {
        if file.isConflict { keys = ["conflict"]; return }
        if file.isUntracked { keys = ["untracked"]; return }
        func key(_ code: String) -> String {
            ["M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "T": "type"][code] ?? "none"
        }
        if file.isStaged {
            if file.isUnstaged { keys = ["stagedStatus", key(file.worktreeStatus)] }
            else if file.indexStatus == "M" { keys = ["stagedStatus"] }
            else { keys = ["stagedStatus", key(file.indexStatus)] }
        } else { keys = [key(file.worktreeStatus)] }
    }
}
