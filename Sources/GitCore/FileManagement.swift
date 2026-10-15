import Foundation

public struct TrashedRepositoryFile: Sendable, Codable {
    public let originalPath: String
    public let trashURL: URL
    let repositoryURL: URL
}
public struct WorkspaceFileNode: Identifiable, Sendable, Codable {
    public let path: String
    public var id: String { path }
    public let isDirectory: Bool
    public let children: [WorkspaceFileNode]
    public init(path: String, isDirectory: Bool, children: [WorkspaceFileNode]) {
        self.path = path; self.isDirectory = isDirectory; self.children = children
    }
}

extension GitRepository {
    private func managedURL(_ path: String, allowMissing: Bool = false) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(""), !parts.contains("."), !parts.contains(".."), !parts.contains(where: { $0.lowercased() == ".git" }), !path.contains("\0") else { throw GitError("Invalid repository file path.") }
        var file = url
        for (index, part) in parts.enumerated() {
            file.appendPathComponent(String(part))
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw GitError("Symbolic links cannot be managed by this operation.") }
            } catch {
                let failure = error as NSError
                if allowMissing && index == parts.count - 1 && failure.domain == NSCocoaErrorDomain && (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) { return file }
                throw error
            }
        }
        return file
    }
    public func renameWorkspaceFile(path: String, destination: String) throws {
        let source = try managedURL(path), target = try managedURL(destination, allowMissing: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw GitError("The destination already exists.") }
        try FileManager.default.moveItem(at: source, to: target)
    }
    public func permanentlyDeleteWorkspaceFile(path: String) throws {
        try FileManager.default.removeItem(at: managedURL(path))
    }
    public func discardWorkspace(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let entries = Dictionary(try await status().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var tracked: [String] = []
        var untracked: [String] = []
        var symlinks: [URL] = []
        for path in Set(paths).sorted() {
            guard let file = entries[path], file.isUnstaged || file.isConflict else { throw GitError("Cannot discard this worktree path: " + path) }
            if file.isUntracked {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(""), !parts.contains("."),
                      !parts.contains(".."), !parts.contains(where: { $0.lowercased() == ".git" }),
                      !path.contains("\0"), let name = parts.last else { throw GitError("Invalid repository file path.") }
                let parent = parts.dropLast().joined(separator: "/")
                let leaf = (parent.isEmpty ? url : try managedURL(parent)).appendingPathComponent(String(name))
                let attributes = try FileManager.default.attributesOfItem(atPath: leaf.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeRegular: untracked.append(path)
                case .typeSymbolicLink: symlinks.append(leaf)
                default: throw GitError("Only regular untracked files and symbolic links can be discarded.")
                }
            } else { tracked.append(path) }
        }
        // Restore tracked worktrees from the index, leaving all staged contents untouched.
        try await discardWorktree(paths: tracked, includeConflicts: true)
        for path in untracked { try permanentlyDeleteWorkspaceFile(path: path) }
        for link in symlinks { try FileManager.default.removeItem(at: link) }
    }
    public func trashWorkspaceFile(path: String) throws -> TrashedRepositoryFile {
        let file = try managedURL(path)
        var result: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &result)
        guard let result else { throw GitError("The system did not return the trash location.") }
        return TrashedRepositoryFile(originalPath: path, trashURL: result as URL, repositoryURL: url)
    }
    public func restoreWorkspaceFile(_ item: TrashedRepositoryFile) throws {
        guard item.repositoryURL.standardizedFileURL == url.standardizedFileURL else { throw GitError("This trash item belongs to a different repository.") }
        let target = try managedURL(item.originalPath, allowMissing: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw GitError("The destination already exists.") }
        try FileManager.default.moveItem(at: item.trashURL, to: target)
    }
    public func ignoredWorkspacePaths() async throws -> [String] {
        let output = try await GitProcess.run(at: url, arguments: ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"])
        return output.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
    }
    public func workspaceTree() async throws -> [WorkspaceFileNode] {
        let output = try await GitProcess.run(at: url, arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        let paths = Set(output.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        return Self.workspaceTree(paths: paths)
    }
    static func workspaceTree(paths: Set<String>) -> [WorkspaceFileNode] {
        var children: [String: Set<String>] = [:]
        var directories: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/")
            var prefix = ""
            for (index, component) in components.enumerated() {
                let name = String(component)
                children[prefix, default: []].insert(name)
                prefix = prefix.isEmpty ? name : prefix + "/" + name
                if index < components.count - 1 { directories.insert(prefix) }
            }
        }
        func nodes(prefix: String) -> [WorkspaceFileNode] {
            (children[prefix] ?? []).sorted().map { name in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let directory = directories.contains(path)
                return WorkspaceFileNode(path: path, isDirectory: directory, children: directory ? nodes(prefix: path) : [])
            }
        }
        return nodes(prefix: "")
    }
    public func ignoreWorkspacePath(_ path: String, directory: Bool) throws {
        _ = try managedURL(path)
        guard !path.contains("\n"), !path.contains("\r") else { throw GitError("Paths containing newlines cannot be represented in .gitignore.") }
        let file = try managedURL(".gitignore", allowMissing: true)
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : Data()
        guard let text = String(data: existing, encoding: .utf8) else { throw GitError("The .gitignore file must use UTF-8.") }
        // Root anchoring and escaping make wildcard characters literal, including trailing spaces.
        var pattern = "/"
        for character in path {
            if "\\*?[]#! ".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        if directory { pattern += "/" }
        if text.split(separator: "\n", omittingEmptySubsequences: false).contains(Substring(pattern)) { return }
        let replacement = text + (!text.isEmpty && !text.hasSuffix("\n") ? "\n" : "") + pattern + "\n"
        try Data(replacement.utf8).write(to: file, options: .atomic)
    }
    public func saveGitignore(text: String, expected: Data?) throws {
        let file = try managedURL(".gitignore", allowMissing: true)
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == expected else { throw GitError("The .gitignore file changed. Reload before saving.") }
        guard !text.contains("\0") else { throw GitError("The .gitignore file must use UTF-8.") }
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}
