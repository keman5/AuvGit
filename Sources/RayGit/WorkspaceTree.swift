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
    var permitsMutation: () -> Bool = { true }
    var setBusy: (Bool) -> Void = { _ in }
    var files: [GitFile] = []
    var refreshID: UUID? = nil
    let onAction: (FileAction, Set<String>) -> Void
    @State private var mutationBusy = false
    @State private var editorError: String?
    @State private var nodes: [WorkspaceFileNode] = []
    @State private var nodesRepositoryPath: String?
    @State private var expandedPaths: Set<String> = []
    @State private var selectedTreePaths: Set<String> = []
    @State private var error: String?
    @State private var loading = true
    @State private var reloadID = UUID()
    @State private var stateID = UUID()
    @State private var stateRepositoryPath: String?
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
                Button { loadIgnored() } label: { Image(systemName: "eye.slash") }
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
            WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten(filteredNodes, expanded: displayedExpansion), expanded: treeExpansion,
                selection: treeSelection, repository: repository, files: files, isBusy: isBusy || mutationBusy,
                openFile: primaryAction ?? openFile, onAction: onAction)
                .overlay { if loading && displayedNodes.isEmpty { ProgressView().controlSize(.small) } }
        }.disabled(isBusy || mutationBusy).task(id: repository.url.path) {
            reloadID = UUID()
            stateID = UUID(); stateRepositoryPath = repository.url.path
            expandedPaths = []; selectedTreePaths = []; trashed = []; ignored = []
            error = nil; editorError = nil; showIgnored = false; showIgnoreEditor = false
            ignoreDraft = ""; expectedIgnore = nil
            nodes = []; nodesRepositoryPath = nil; loading = true
            loadTrash()
            if let cached = WorkspaceTreeCache.shared.nodes(for: repository.url.path) {
                nodes = cached; nodesRepositoryPath = repository.url.path
                if isBusy { loading = false; return }
            }
            await reload(stateID: stateID)
        }
            .onChange(of: refreshID) { _, _ in if !isBusy { scheduleReload() } }
            .onChange(of: isBusy) { wasBusy, busy in if wasBusy && !busy { scheduleReload() } }
            .onDisappear { reloadID = UUID(); stateID = UUID() }
            .onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { note in
                if let changed = note.object as? URL, changed == repository.url { scheduleReload() }
            }
            .rayGitSheet(isPresented: $showIgnored) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(compareText("Ignored Files")).font(.headline)
                    List(ignored, id: \.self) { Text($0).font(.system(size: 12)).textSelection(.enabled) }
                    HStack { DialogButton(compareText("Close"), prominent: true, role: .cancel) { showIgnored = false } }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
                }.controlSize(.small).padding(20).frame(width: 600, height: 450)
            }
            .rayGitSheet(isPresented: $showIgnoreEditor) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(compareText("Edit .gitignore")).font(.headline)
                    if let editorError { Text(editorError).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
                    TextEditor(text: $ignoreDraft).font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    HStack {
                        DialogButton(compareText("Cancel"), role: .cancel) { showIgnoreEditor = false }
                        DialogButton(compareText("Save"), prominent: true) {
                            guard !isBusy, !mutationBusy, permitsMutation() else { return }
                            mutationBusy = true; setBusy(true)
                            Task {
                                defer { mutationBusy = false; setBusy(false) }
                                do { try await repository.saveGitignore(text: ignoreDraft, expected: expectedIgnore); editorError = nil; showIgnoreEditor = false; changed() }
                                catch { editorError = compareText(OperationFailure.message(error, repository: repository.url)) }
                            }
                        }.disabled(mutationBusy || isBusy)
                    }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
                }.controlSize(.small).padding(20).frame(width: 650, height: 500)
            }
    }
    private var displayedExpansion: Set<String> {
        nodesRepositoryPath == repository.url.path ? expandedPaths : []
    }
    private var treeExpansion: Binding<Set<String>> {
        Binding(get: { displayedExpansion }, set: { expandedPaths = $0 })
    }
    private var treeSelection: Binding<Set<String>> {
        Binding(get: {
            nodesRepositoryPath == repository.url.path && WorkspaceTreeSelection.resolve(selectedTreePaths, changedPaths: changedPaths) == selection.wrappedValue
                ? selectedTreePaths : selection.wrappedValue
        }, set: {
            selectedTreePaths = $0
            selection.wrappedValue = WorkspaceTreeSelection.resolve($0, changedPaths: changedPaths)
        })
    }
    private var displayedNodes: [WorkspaceFileNode] {
        guard nodesRepositoryPath == repository.url.path else {
            return WorkspaceTreeCache.shared.nodes(for: repository.url.path) ?? []
        }
        return nodes.isEmpty && loading ? WorkspaceTreeCache.shared.nodes(for: repository.url.path) ?? nodes : nodes
    }
    private var filteredNodes: [WorkspaceFileNode] {
        guard let visiblePaths else { return displayedNodes }
        func filtered(_ node: WorkspaceFileNode) -> WorkspaceFileNode? {
            if !node.isDirectory { return visiblePaths.contains(node.path) ? node : nil }
            let children = node.children.compactMap(filtered)
            return children.isEmpty ? nil : WorkspaceFileNode(path: node.path, isDirectory: true, children: children)
        }
        return displayedNodes.compactMap(filtered)
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
        guard !isBusy, !mutationBusy, permitsMutation() else { return }
        mutationBusy = true; setBusy(true)
        Task { defer { mutationBusy = false; setBusy(false) }; do { try await action(); saveTrash(); error = nil; changed() } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) } }
    }
    private var trashKey: String { "RayGit.TrashRecords." + repository.url.standardizedFileURL.path }
    private func loadTrash() { if let data = UserDefaults.standard.data(forKey: trashKey), let records = try? JSONDecoder().decode([TrashedRepositoryFile].self, from: data) { trashed = records.filter { FileManager.default.fileExists(atPath: $0.trashURL.path) }; saveTrash() } }
    private func saveTrash() { if let data = try? JSONEncoder().encode(trashed) { UserDefaults.standard.set(data, forKey: trashKey) } }
    private func changed() { NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url) }
    private func loadIgnored() {
        let owner = stateID
        Task {
            do {
                let paths = try await repository.ignoredWorkspacePaths()
                guard owner == stateID, stateRepositoryPath == repository.url.path else { return }
                ignored = paths; showIgnored = true
            } catch {
                guard owner == stateID, stateRepositoryPath == repository.url.path else { return }
                self.error = compareText(OperationFailure.message(error, repository: repository.url))
            }
        }
    }
    private func scheduleReload() {
        let owner = stateID
        Task { await reload(stateID: owner) }
    }
    private func reload(stateID owner: UUID) async {
        guard owner == stateID, stateRepositoryPath == repository.url.path else { return }
        let id = UUID()
        reloadID = id
        loading = true
        defer { if reloadID == id { loading = false } }
        do {
            let result = try await repository.workspaceTree()
            guard !Task.isCancelled, reloadID == id, stateID == owner, stateRepositoryPath == repository.url.path else { return }
            WorkspaceTreeCache.shared.store(result, for: repository.url.path)
            nodes = result; nodesRepositoryPath = repository.url.path; error = nil
        } catch {
            guard !Task.isCancelled, reloadID == id, stateID == owner, stateRepositoryPath == repository.url.path else { return }
            self.error = compareText(OperationFailure.message(error, repository: repository.url))
        }
    }
}
struct WorkspaceTreeRow: Identifiable {
    let path: String
    let isDirectory: Bool
    let depth: Int
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum WorkspaceTreeRows {
    static func flatten(_ nodes: [WorkspaceFileNode], expanded: Set<String>) -> [WorkspaceTreeRow] {
        var rows: [WorkspaceTreeRow] = []
        func append(_ nodes: [WorkspaceFileNode], depth: Int) {
            for node in nodes {
                rows.append(WorkspaceTreeRow(path: node.path, isDirectory: node.isDirectory, depth: depth))
                if node.isDirectory, expanded.contains(node.path) { append(node.children, depth: depth + 1) }
            }
        }
        append(nodes, depth: 0)
        return rows
    }
}

/// Expand directories to changed descendants. Preserve an unmatched path so a
/// clean or empty directory never becomes an empty/global toolbar selection.
enum WorkspaceTreeSelection {
    static func resolve(_ paths: Set<String>, changedPaths: Set<String>) -> Set<String> {
        guard !paths.isSubset(of: changedPaths) else { return paths }
        var resolved = paths
        // Visit each changed file's ancestors once instead of rescanning all files per selected clean row.
        for changed in changedPaths {
            var ancestor = changed[...]
            while let slash = ancestor.lastIndex(of: "/") {
                ancestor = ancestor[..<slash]
                let path = String(ancestor)
                if paths.contains(path), !changedPaths.contains(path) {
                    resolved.remove(path)
                    resolved.insert(changed)
                }
            }
        }
        return resolved
    }
}

@MainActor
final class WorkspaceTreeCache {
    static let shared = WorkspaceTreeCache()
    private var entries: [(path: String, nodes: [WorkspaceFileNode], count: Int)] = []
    func nodes(for path: String) -> [WorkspaceFileNode]? {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.nodes
    }
    func store(_ nodes: [WorkspaceFileNode], for path: String) {
        func count(_ nodes: [WorkspaceFileNode]) -> Int { nodes.reduce(0) { $0 + 1 + count($1.children) } }
        let nodeCount = count(nodes)
        entries.removeAll { $0.path == path }
        guard nodeCount <= 50_000 else { return }
        entries.append((path, nodes, nodeCount))
        while entries.count > 32 || entries.reduce(0, { $0 + $1.count }) > 50_000 { entries.removeFirst() }
    }
}
