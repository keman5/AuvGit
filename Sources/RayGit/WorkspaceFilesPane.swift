import SwiftUI
import GitCore
import RayGitLocalization

enum FileAction {
    case compare, open, reveal, history, stage, unstage, discard
    case copyName, copyPath, copyRelativePath, stageAll, unstageAll
}

struct WorkspaceFilesPane: View {
    let files: [GitFile]
    @Binding var selection: Set<String>
    @Binding var filter: String
    let isBusy: Bool
    let onAction: (FileAction, Set<String>) -> Void

    private var visibleFiles: [GitFile] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(query) }
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
        onAction(.compare, paths)
    }
    private func actionButton(_ key: String, _ action: FileAction, _ paths: Set<String>, single: Bool = false) -> some View {
        let targets = eligible(action, paths)
        return Button(text(key)) { onAction(action, targets) }
            .disabled(isBusy || targets.isEmpty || (single && paths.count != 1) || (action == .discard && targets.count != paths.count))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(text("files")).font(.headline)
                Text("\(files.count)").foregroundStyle(.secondary)
                TextField(text("filter"), text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                actionButton("stage", .stage, selection)
                actionButton("unstage", .unstage, selection)
                Menu {
                    actionButton("stageAll", .stageAll, Set(files.map(\.path)))
                    actionButton("unstageAll", .unstageAll, Set(files.map(\.path)))
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 24).help(text("allActions"))
            }.padding(10)
            Divider()
            Table(visibleFiles, selection: $selection) {
                TableColumn(text("name")) { file in
                    HStack(spacing: 6) {
                        Image(systemName: file.isConflict ? "exclamationmark.triangle" : "doc.text")
                            .foregroundStyle(file.isConflict ? Color.orange : Color.secondary)
                        Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }.width(min: 140, ideal: 260)
                TableColumn(text("index")) { file in status(file.indexStatus) }.width(min: 80, ideal: 95)
                TableColumn(text("workspace")) { file in status(file.worktreeStatus) }.width(min: 80, ideal: 95)
                TableColumn(text("directory")) { file in
                    let directory = (file.path as NSString).deletingLastPathComponent
                    Text(directory.isEmpty ? "—" : directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.width(min: 100, ideal: 220)
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
            .overlay {
                if visibleFiles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: files.isEmpty ? "checkmark.circle" : "magnifyingglass").font(.largeTitle)
                        Text(text(files.isEmpty ? "clean" : "noFiles"))
                    }.foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
    }

    private func status(_ value: String) -> some View {
        let key = [" ": "none", "?": "untracked", "M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type"][value]
        let color: Color = value == "A" || value == "?" ? .green : value == "D" ? .red : ["M", "R", "U"].contains(value) ? .orange : .secondary
        return Text(key.map(text) ?? value).foregroundStyle(color).lineLimit(1)
    }
}
