import Foundation

public enum ComparisonLayout: String, Equatable, Sendable { case two, three }
public enum ComparisonRevision: String, Equatable, Sendable { case head, index, worktree, base, ours, theirs }

/// The result is always the current working-tree file, never a synthesized merge.
public struct ComparisonPresentation: Equatable, Sendable {
    public let layout: ComparisonLayout
    public let leftRevision: ComparisonRevision
    public let rightRevision: ComparisonRevision?
    public var editableRevision: ComparisonRevision { .worktree }
    public var columns: [ComparisonRevision] {
        [leftRevision, .worktree] + (rightRevision.map { [$0] } ?? [])
    }
}

extension FileComparisonSnapshot {
    public var presentation: ComparisonPresentation {
        if isConflict { return ComparisonPresentation(layout: .three, leftRevision: .ours, rightRevision: .theirs) }
        let staged: Bool, unstaged: Bool
        if let status {
            // Git status includes mode changes and staged rename identity even when bytes match.
            staged = status.isStaged && !status.isUntracked
            unstaged = status.isUnstaged
        } else {
            // A snapshot assembled by a caller can still use existence, mode, and exact bytes.
            staged = revisionDiffers(head, index)
            unstaged = revisionDiffers(index, worktree)
        }
        if staged && unstaged { return ComparisonPresentation(layout: .three, leftRevision: .head, rightRevision: .index) }
        return ComparisonPresentation(layout: .two, leftRevision: staged ? .head : .index, rightRevision: nil)
    }
    private func revisionDiffers(_ lhs: FileRevisionContent, _ rhs: FileRevisionContent) -> Bool {
        if lhs.exists != rhs.exists { return true }
        guard lhs.exists else { return false }
        if let leftMode = lhs.gitMode, let rightMode = rhs.gitMode, leftMode != rightMode { return true }
        if let left = lhs.data, let right = rhs.data { return left != right }
        if let left = lhs.objectID, let right = rhs.objectID { return left != right }
        return false
    }
}
