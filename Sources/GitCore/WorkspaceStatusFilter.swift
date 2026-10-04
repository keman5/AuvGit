import Foundation

public enum WorkspaceStatusFilter: String, CaseIterable, Sendable {
    case all, modified, added, deleted, conflict, untracked, renamed, staged
    public func includes(_ file: GitFile) -> Bool {
        if self == .all { return true }
        if self == .conflict { return file.isConflict }
        guard !file.isConflict else { return false }
        switch self {
        case .modified: return [file.indexStatus, file.worktreeStatus].contains { ["M", "T"].contains($0) }
        case .added: return !file.isUntracked && [file.indexStatus, file.worktreeStatus].contains("A")
        case .deleted: return [file.indexStatus, file.worktreeStatus].contains("D")
        case .untracked: return file.isUntracked
        case .renamed: return [file.indexStatus, file.worktreeStatus].contains("R")
        case .staged: return file.isStaged
        case .all, .conflict: return false
        }
    }
    public static func isHiddenPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
