import GitCore

/// Resolve actual Git rows before mutation; an empty selection means all eligible rows.
enum WorkspaceFileActionTargets {
    static func paths(for action: FileAction, files: [GitFile], selection: Set<String>) -> Set<String> {
        let candidates = selection.isEmpty ? files : files.filter { selection.contains($0.path) }
        return Set(candidates.filter { file in
            switch action {
            case .stage, .stageAll: return file.isUnstaged && !file.isConflict
            case .unstage, .unstageAll: return file.isStaged && !file.isConflict
            case .discard: return !file.isUntracked && !file.isConflict && file.isUnstaged
            default: return false
            }
        }.map(\.path))
    }
}
