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

    @State private var category = "all"
    private let categories = ["all", "modified", "added", "deleted", "conflict"]
    private func matches(_ file: GitFile, _ category: String) -> Bool {
        switch category {
        case "conflict": return file.isConflict
        case "added": return !file.isConflict && (file.isUntracked || file.indexStatus == "A" || file.worktreeStatus == "A")
        case "deleted": return !file.isConflict && (file.indexStatus == "D" || file.worktreeStatus == "D")
        case "modified": return !file.isConflict && !matches(file, "added") && !matches(file, "deleted")
        default: return true
        }
    }
    private var visibleFiles: [GitFile] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { matches($0, category) && (query.isEmpty || RayGitPreferences.matches($0.path, query: query, caseMode: filterCase)) }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { statusControls; Spacer(minLength: 4); fileControls }
                VStack(spacing: 8) { HStack { statusControls; Spacer() }; HStack { fileControls; Spacer() } }
            }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 9).rayGitChrome()
            Divider()
            if treeMode { treeContent }
            else if visibleFiles.isEmpty {
                RayGitEmptyState(title: text(files.isEmpty ? "clean" : "noFiles"), systemImage: files.isEmpty ? "checkmark.circle" : "magnifyingglass")
            } else { fileTable }
        }
    }
    private var statusControls: some View {
        HStack(spacing: 7) {
            Text(designWorkspaceText("Status")).font(.system(size: 12)).foregroundStyle(.secondary)
            Picker(designWorkspaceText("Status"), selection: $category) {
                ForEach(categories, id: \.self) { item in Text(categoryTitle(item)).tag(item) }
            }.labelsHidden().frame(width: 96)
            ForEach(categories, id: \.self) { item in
                let tint: Color = item == "all" ? RayGitStyle.blue : item == "modified" ? .orange : item == "added" ? .green : .red
                Button { category = item; treeMode = false } label: {
                    HStack(spacing: 5) {
                        if item != "all" { Image(systemName: item == "conflict" ? "asterisk" : "circle.fill").font(.system(size: 8)) }
                        Text(categoryTitle(item))
                        Text(String(files.filter { matches($0, item) }.count)).foregroundStyle(.secondary)
                    }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(category == item ? tint : Color.primary)
                        .background(tint.opacity(category == item ? 0.17 : 0.07), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }
    private func categoryTitle(_ category: String) -> String { category == "all" ? designWorkspaceText("All") : text(category) }
    private var fileControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(text("filter"), text: $filter).textFieldStyle(.plain)
            }.padding(.horizontal, 9).frame(height: 28).rayGitInputSurface().frame(width: 170)
            Button { treeMode.toggle() } label: { Image(systemName: treeMode ? "folder" : "list.bullet") }
                .help(workflowText("Files view")).accessibilityLabel(workflowText("Files view"))
            Menu {
                actionButton("stage", .stage, selection)
                actionButton("unstage", .unstage, selection)
                actionButton("compare", .compare, selection, single: true)
                actionButton("history", .history, selection, single: true)
                actionButton("discard", .discard, selection)
                Divider()
                actionButton("stageAll", .stageAll, Set(files.map(\.path)))
                actionButton("unstageAll", .unstageAll, Set(files.map(\.path)))
            } label: { Image(systemName: "arrow.triangle.swap") }
                .menuStyle(.borderlessButton).frame(width: 24).help(text("allActions")).accessibilityLabel(text("allActions"))
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
                TableColumn(designWorkspaceText("Status")) { file in
                    status(file.isConflict ? "U" : file.isUntracked ? "?" : file.indexStatus != " " ? file.indexStatus : file.worktreeStatus, selected: false)
                }.width(min: 70, ideal: 90)
                TableColumn(text("workspace")) { file in status(file.worktreeStatus, selected: false) }.width(min: 65, ideal: 85)
                TableColumn(text("index")) { file in status(file.indexStatus, selected: false) }.width(min: 65, ideal: 85)
                TableColumn(text("directory")) { file in
                    let directory = (file.path as NSString).deletingLastPathComponent
                    Text(directory.isEmpty ? "—" : directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.width(min: 80, ideal: 180)
            }
            .font(.system(size: 12)).environment(\.defaultMinListRowHeight, 28)
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

    private func status(_ value: String, selected: Bool) -> some View {
        let key = [" ": "none", "?": "untracked", "M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type"][value]
        let color: Color = value == "A" || value == "?" ? .green : value == "D" ? .red : ["M", "R", "U"].contains(value) ? .orange : .secondary
        return Group {
            if selected { Text(key.map(text) ?? value).font(.system(size: 10, weight: .medium)).lineLimit(1) }
            else if value == " " { Text(text("none")).foregroundStyle(.tertiary).font(.system(size: 11)) }
            else { RayGitBadge(key.map(text) ?? value, tint: color) }
        }
    }
}
