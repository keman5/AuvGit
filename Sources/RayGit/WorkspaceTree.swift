import SwiftUI
import AppKit
import RayGitLocalization
import GitCore

struct WorkspaceTree: View {
    let repository: GitRepository
    let openFile: (String) -> Void
    var visiblePaths: Set<String>? = nil
    var selection: Binding<Set<String>> = .constant([])
    var changedPaths: Set<String> = []
    var primaryAction: ((String) -> Void)? = nil
    var isBusy: Bool = false
    var setBusy: (Bool) -> Void = { _ in }
    var files: [GitFile] = []
    let onAction: (FileAction, Set<String>) -> Void
    @State private var mutationBusy = false
    @State private var editorError: String?
    @State private var nodes: [WorkspaceFileNode] = []
    @State private var error: String?
    @State private var loading = true
    @State private var trashed: [TrashedRepositoryFile] = []
    @State private var ignored: [String] = []
    @State private var showIgnored = false
    @State private var showIgnoreEditor = false
    @State private var ignoreDraft = ""
    @State private var expectedIgnore: Data?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { loadIgnoreEditor() } label: { Image(systemName: "doc.badge.gearshape") }
                    .help(compareText("Edit .gitignore")).accessibilityLabel(compareText("Edit .gitignore"))
                Button { Task { do { ignored = try await repository.ignoredWorkspacePaths(); showIgnored = true } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) } } } label: { Image(systemName: "eye.slash") }
                    .help(compareText("Ignored Files")).accessibilityLabel(compareText("Ignored Files"))
                Menu {
                    ForEach(trashed.indices, id: \.self) { index in Button(trashed[index].originalPath) { perform { try await repository.restoreWorkspaceFile(trashed[index]); trashed.remove(at: index) } } }
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 24)
                    .help(compareText("Restore from Trash")).accessibilityLabel(compareText("Restore from Trash")).disabled(trashed.isEmpty)
                Spacer()
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let error { Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal, 12).padding(.vertical, 8).textSelection(.enabled) }
            List(selection: treeSelection) {
                OutlineGroup(filteredNodes, children: \.outlineChildren) { node in
                    Label(node.path.split(separator: "/").last.map(String.init) ?? node.path, systemImage: node.isDirectory ? "folder" : "doc")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(node.path).tag(node.path)
                        .onTapGesture(count: 2) { if !node.isDirectory { (primaryAction ?? openFile)(node.path) } }
                        .contextMenu {
                            WorkspaceContextMenu(paths: [node.path], files: files, repository: repository, isBusy: isBusy || mutationBusy, directories: node.isDirectory ? [node.path] : [], allowsCleanHistory: true, onAction: { action, paths in
                                onAction(action, paths)
                            })

                        }
                }
            }.listStyle(.inset)
                .overlay { if loading && nodes.isEmpty { ProgressView().controlSize(.small) } }
        }.disabled(isBusy || mutationBusy).task { loadTrash(); await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { note in
                if let changed = note.object as? URL, changed == repository.url { Task { await reload() } }
            }
            .sheet(isPresented: $showIgnored) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(compareText("Ignored Files")).font(.headline)
                    List(ignored, id: \.self) { Text($0).font(.system(size: 12)).textSelection(.enabled) }
                    HStack { Spacer(); Button(compareText("Close")) { showIgnored = false }.keyboardShortcut(.cancelAction) }
                }.controlSize(.small).padding(20).frame(width: 600, height: 450)
            }
            .sheet(isPresented: $showIgnoreEditor) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(compareText("Edit .gitignore")).font(.headline)
                    if let editorError { Text(editorError).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
                    TextEditor(text: $ignoreDraft).font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    HStack {
                        Spacer()
                        Button(compareText("Cancel")) { showIgnoreEditor = false }.keyboardShortcut(.cancelAction)
                        Button(compareText("Save")) {
                            guard !isBusy, !mutationBusy else { return }
                            mutationBusy = true; setBusy(true)
                            Task {
                                defer { mutationBusy = false; setBusy(false) }
                                do { try await repository.saveGitignore(text: ignoreDraft, expected: expectedIgnore); editorError = nil; showIgnoreEditor = false; changed() }
                                catch { editorError = compareText(OperationFailure.message(error, repository: repository.url)) }
                            }
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(mutationBusy || isBusy)
                    }
                }.controlSize(.small).padding(20).frame(width: 650, height: 500)
            }
    }
    private var treeSelection: Binding<Set<String>> {
        Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = WorkspaceTreeSelection.resolve($0, changedPaths: changedPaths) })
    }
    private var filteredNodes: [WorkspaceFileNode] {
        guard let visiblePaths else { return nodes }
        func filtered(_ node: WorkspaceFileNode) -> WorkspaceFileNode? {
            if !node.isDirectory { return visiblePaths.contains(node.path) ? node : nil }
            let children = node.children.compactMap(filtered)
            return children.isEmpty ? nil : WorkspaceFileNode(path: node.path, isDirectory: true, children: children)
        }
        return nodes.compactMap(filtered)
    }
    private func loadIgnoreEditor() {
        do {
            let file = repository.url.appendingPathComponent(".gitignore")
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs?[.type] as? FileAttributeType != .typeSymbolicLink else { throw GitError("Symbolic links cannot be managed by this operation.") }
            expectedIgnore = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            guard let text = String(data: expectedIgnore ?? Data(), encoding: .utf8) else { throw GitError("The .gitignore file must use UTF-8.") }
            ignoreDraft = text; editorError = nil; showIgnoreEditor = true
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !isBusy, !mutationBusy else { return }
        mutationBusy = true; setBusy(true)
        Task { defer { mutationBusy = false; setBusy(false) }; do { try await action(); saveTrash(); error = nil; changed() } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) } }
    }
    private var trashKey: String { "RayGit.TrashRecords." + repository.url.standardizedFileURL.path }
    private func loadTrash() { if let data = UserDefaults.standard.data(forKey: trashKey), let records = try? JSONDecoder().decode([TrashedRepositoryFile].self, from: data) { trashed = records.filter { FileManager.default.fileExists(atPath: $0.trashURL.path) }; saveTrash() } }
    private func saveTrash() { if let data = try? JSONEncoder().encode(trashed) { UserDefaults.standard.set(data, forKey: trashKey) } }
    private func changed() { NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url) }
    private func reload() async { loading = true; defer { loading = false }; do { nodes = try await repository.workspaceTree(); error = nil } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) } }
}
private extension WorkspaceFileNode {
    var outlineChildren: [WorkspaceFileNode]? { isDirectory ? children : nil }
}

/// Expand directories to changed descendants. Preserve an unmatched path so a
/// clean or empty directory never becomes an empty/global toolbar selection.
enum WorkspaceTreeSelection {
    static func resolve(_ paths: Set<String>, changedPaths: Set<String>) -> Set<String> {
        Set(paths.flatMap { path in
            let descendants = changedPaths.filter { $0.hasPrefix(path + "/") }
            return descendants.isEmpty ? [path] : Array(descendants)
        })
    }
}
