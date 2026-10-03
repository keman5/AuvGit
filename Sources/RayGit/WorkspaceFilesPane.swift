import SwiftUI
import GitCore
import RayGitLocalization

enum FileAction {
    case compare, open, reveal, history, stage, unstage, discard
    case copyName, copyPath, copyRelativePath, stageAll, unstageAll
}

struct WorkspaceFilesPane<TreeContent: View>: View {
    let files: [GitFile]
    @AppStorage("preferences.filterCase") private var filterCase = "insensitive"
    @Binding var selection: Set<String>
    @Binding var filter: String
    @Binding var treeMode: Bool
    let isBusy: Bool
    let onAction: (FileAction, Set<String>) -> Void
    let treeContent: TreeContent

    private var visibleFiles: [GitFile] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? files : files.filter { RayGitPreferences.matches($0.path, query: query, caseMode: filterCase) }
    }
    private func text(_ key: String) -> String { L10n.text(key, table: "Files") }
    private func selected(_ paths: Set<String>) -> [GitFile] { files.filter { paths.contains($0.path) } }
    private func eligible(_ action: FileAction, _ paths: Set<String>) -> Set<String> {
        Set(selected(paths).filter { file in
            switch action {
            case .compare: return true
            case .open: return file.worktreeStatus != "D" && !(file.indexStatus == "D" && !file.isUnstaged)
            case .history: return !file.isUntracked && file.indexStatus != "A"
            case .stage, .stageAll: return file.isUnstaged && !file.isConflict
            case .unstage, .unstageAll: return file.isStaged && !file.isConflict
            case .discard: return !file.isUntracked && !file.isConflict && file.isUnstaged
            default: return true
            }
        }.map(\.path))
    }
    private func performCompare(_ paths: Set<String>) {
        guard !isBusy, paths.count == 1, eligible(.compare, paths).count == 1 else { return }
        if RayGitPreferences.doubleClick == "stage", let file = selected(paths).first, !file.isConflict {
            onAction(file.isUnstaged ? .stage : .unstage, paths)
        } else { onAction(.compare, paths) }
    }
    private func actionButton(_ key: String, _ action: FileAction, _ paths: Set<String>, single: Bool = false) -> some View {
        let targets = eligible(action, paths)
        return Button(text(key)) { onAction(action, targets) }
            .disabled(isBusy || targets.isEmpty || (single && paths.count != 1) || (action == .discard && targets.count != paths.count))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(workflowText("Files view"), selection: $treeMode) {
                    Text(workflowText("Status list")).tag(false)
                    Text(workflowText("Directory tree")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(workflowText("Files view")).fixedSize(horizontal: true, vertical: false)
                if !treeMode {
                    TextField(text("filter"), text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: 80, maxWidth: 220)
                    Spacer(minLength: 0)
                    actionButton("stage", .stage, selection)
                    actionButton("unstage", .unstage, selection)
                } else { Spacer(minLength: 0) }
                Menu {
                    if !treeMode {
                        actionButton("compare", .compare, selection, single: true)
                        actionButton("history", .history, selection, single: true)
                        actionButton("discard", .discard, selection)
                        Divider()
                    }
                    actionButton("stageAll", .stageAll, Set(files.map(\.path)))
                    actionButton("unstageAll", .unstageAll, Set(files.map(\.path)))
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 24).help(text("allActions")).accessibilityLabel(text("allActions"))
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if treeMode { treeContent }
            else if visibleFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: files.isEmpty ? "checkmark.circle" : "magnifyingglass").font(.system(size: 28, weight: .light))
                    Text(text(files.isEmpty ? "clean" : "noFiles")).font(.system(size: 12))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else { fileTable }
        }
    }
    private var fileTable: some View {
            Table(visibleFiles, selection: $selection) {
                TableColumn(text("name")) { file in
                    HStack(spacing: 6) {
                        Image(systemName: file.isConflict ? "exclamationmark.triangle" : "doc.text")
                            .foregroundStyle(file.isConflict ? Color.orange : Color.secondary)
                        Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }.width(min: 120, ideal: 220)
                TableColumn(text("index")) { file in status(file.indexStatus) }.width(min: 65, ideal: 85)
                TableColumn(text("workspace")) { file in status(file.worktreeStatus) }.width(min: 65, ideal: 85)
                TableColumn(text("directory")) { file in
                    let directory = (file.path as NSString).deletingLastPathComponent
                    Text(directory.isEmpty ? "—" : directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.width(min: 80, ideal: 180)
            }
            .font(.system(size: 12))
            .contextMenu(forSelectionType: String.self) { paths in
                if paths.isEmpty {
                    actionButton("stageAll", .stageAll, Set(files.map(\.path)))
                    actionButton("unstageAll", .unstageAll, Set(files.map(\.path)))
                } else {
                    actionButton("open", .open, paths)
                    actionButton("reveal", .reveal, paths)
                    Divider()
                    actionButton("compare", .compare, paths, single: true)
                    actionButton("history", .history, paths, single: true)
                    Divider()
                    actionButton("stage", .stage, paths)
                    actionButton("unstage", .unstage, paths)
                    actionButton("discard", .discard, paths)
                    Divider()
                    actionButton("copyName", .copyName, paths)
                    actionButton("copyPath", .copyPath, paths)
                    actionButton("copyRelativePath", .copyRelativePath, paths)
                }
            } primaryAction: { paths in performCompare(paths) }
    }

    private func status(_ value: String) -> some View {
        let key = [" ": "none", "?": "untracked", "M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type"][value]
        let color: Color = value == "A" || value == "?" ? .green : value == "D" ? .red : ["M", "R", "U"].contains(value) ? .orange : .secondary
        return Text(key.map(text) ?? value).foregroundStyle(color).lineLimit(1)
    }
}
