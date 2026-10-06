import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

func fileContextText(_ key: String) -> String { L10n.text(key, table: "FileContext") }

/// All context actions keep the clicked paths, including clean tree files.
struct WorkspaceContextEligibility {
    let paths: Set<String>
    let files: [GitFile]
    let existing: Set<String>
    var rows: [GitFile] { files.filter { paths.contains($0.path) } }
    var allExisting: Bool { !paths.isEmpty && paths.isSubset(of: existing) }
    var canIgnore: Bool { allExisting && rows.count == paths.count && rows.allSatisfy(\.isUntracked) }
    func canHistory(allowCleanFile: Bool) -> Bool {
        guard paths.count == 1 else { return false }
        if let row = rows.first { return !row.isUntracked && row.indexStatus != "A" }
        return allowCleanFile && allExisting
    }
    func canGit(_ action: FileAction) -> Bool {
        !paths.isEmpty && rows.count == paths.count && WorkspaceFileActionTargets.paths(for: action, files: files, selection: paths) == paths
    }
}

struct WorkspaceContextMenu: View {
    let paths: Set<String>
    let files: [GitFile]
    let repository: GitRepository?
    let isBusy: Bool
    var directories: Set<String> = []
    var readOnlyPaths: Set<String> = []
    var allowsCleanHistory = false
    let onAction: (FileAction, Set<String>) -> Void
    private var eligibility: WorkspaceContextEligibility {
        WorkspaceContextEligibility(paths: paths, files: files, existing: Set(paths.filter { path in repository.map { FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(path).path) } ?? false }))
    }
    var body: some View {
        if !paths.isEmpty {
            button("compare", .compare, enabled: paths.count == 1 && directories.isDisjoint(with: paths) && readOnlyPaths.isDisjoint(with: paths))
            button("history", .history, enabled: directories.isDisjoint(with: paths) && readOnlyPaths.isDisjoint(with: paths) && eligibility.canHistory(allowCleanFile: allowsCleanHistory))
            Divider()
            button("stage", .stage, enabled: eligibility.canGit(.stage))
            button("unstage", .unstage, enabled: eligibility.canGit(.unstage))
            button("discard", .discard, enabled: eligibility.canGit(.discard))
            Divider()
            button("rename", .rename, enabled: paths.count == 1 && eligibility.allExisting && readOnlyPaths.isDisjoint(with: paths))
            button("ignore", .ignore, enabled: eligibility.canIgnore)
            button("trash", .trash, enabled: eligibility.allExisting && readOnlyPaths.isDisjoint(with: paths))
            Divider()
            button("copyPath", .copyPath)
            Divider()
            button("open", .open, enabled: eligibility.allExisting)
            button("reveal", .reveal)
        }
    }
    private func button(_ key: String, _ action: FileAction, enabled: Bool = true) -> some View {
        Button(fileContextText(key)) { onAction(action, paths) }.disabled(isBusy || repository == nil || !enabled)
    }
}
