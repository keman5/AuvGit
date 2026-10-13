import GitCore

/// Resolve actual Git rows before mutation; an empty selection means all eligible rows.
enum WorkspaceFileActionTargets {
    static func hasEligibleTarget(for action: FileAction, files: [GitFile], selection: Set<String>) -> Bool {
        files.contains { (selection.isEmpty || selection.contains($0.path)) && isEligible($0, for: action) }
    }

    static func paths(for action: FileAction, files: [GitFile], selection: Set<String>) -> Set<String> {
        let candidates = selection.isEmpty ? files : files.filter { selection.contains($0.path) }
        return Set(candidates.filter { isEligible($0, for: action) }.map(\.path))
    }

    private static func isEligible(_ file: GitFile, for action: FileAction) -> Bool {
        switch action {
        case .stage, .stageAll: return file.isUnstaged && !file.isConflict
        case .unstage, .unstageAll: return file.isStaged && !file.isConflict
        case .discard: return file.isUnstaged || file.isConflict
        default: return false
        }
    }
}
