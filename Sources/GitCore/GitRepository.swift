import Foundation

public actor GitRepository {
    public nonisolated let url: URL
    public init(url: URL) { self.url = url.standardizedFileURL }
    public static func open(_ url: URL) async throws -> GitRepository {
        let result = try await GitProcess.run(at: url, arguments: ["rev-parse", "--show-toplevel"])
        return GitRepository(url: URL(fileURLWithPath: result.text.trimmingCharacters(in: .newlines)))
    }
    private func run(_ args: [String], allowedCodes: Set<Int32> = [0]) async throws -> GitOutput { try await GitProcess.run(at: url, arguments: args, allowedCodes: allowedCodes) }
    private func fields(_ data: Data) -> [String] { data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) } }
    public func status() async throws -> [GitFile] {
        let tokens = fields(try await run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"]).data)
        var result: [GitFile] = [], i = 0
        while i < tokens.count {
            let token = tokens[i]; i += 1
            guard token.utf8.count >= 3 else { continue }
            let status = Array(token.prefix(2)), path = String(token.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C") { if i < tokens.count { original = tokens[i]; i += 1 } }
            result.append(GitFile(path: path, originalPath: original, indexStatus: String(status[0]), worktreeStatus: String(status[1])))
        }
        return result
    }
    public func branches() async throws -> [GitBranch] {
        let output = try await run(["for-each-ref", "--format=%(HEAD)%00%(refname)%00%(symref)", "refs/heads", "refs/remotes"])
        return output.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[2].isEmpty else { return nil }
            let remote = parts[1].hasPrefix("refs/remotes/")
            return GitBranch(name: String(parts[1].dropFirst(remote ? 13 : 11)), isCurrent: parts[0] == "*", isRemote: remote)
        }
    }
    public func currentBranch() async throws -> String {
        let symbolic = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], allowedCodes: [0, 1])
        if symbolic.code == 0 { return symbolic.text.trimmingCharacters(in: .newlines) }
        return "Detached " + (try await run(["rev-parse", "--short", "HEAD"])).text.trimmingCharacters(in: .newlines)
    }
    public func log(limit: Int = 200, skip: Int = 0, search: String = "", path: String? = nil, ref: String? = nil, author: String = "") async throws -> [GitCommit] {
        var args = ["log", "--topo-order", "-z", "--format=%H%x00%P%x00%an%x00%at%x00%s%x00%B%x00%D"]
        if path == nil { args += ["--max-count=\(max(0,limit))", "--skip=\(max(0,skip))"] }
        if path == nil && !author.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--author=" + author] }
        if path == nil && !search.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--grep=" + search] }
        let head = try await run(["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
        if let ref { args.append(try await validatedCommit(ref)) }
        else if path != nil { if head.code == 0 { args.append("HEAD") } }
        else { args.append("--all"); if head.code == 0 { args.append("HEAD") } }
        if let path { try validatePath(path); args += ["--follow", "--", path] }
        else { args.append("--") }
        let output = try await run(args, allowedCodes: [0, 128])
        if output.code != 0 { if (try await run(["show-ref"], allowedCodes: [0, 1])).code == 1 { return [] }; throw GitError(output.error) }
        let tokens = fields(output.data)
        var result: [GitCommit] = []
        for i in stride(from: 0, to: max(0, tokens.count - 6), by: 7) {
            result.append(GitCommit(hash: tokens[i], parents: tokens[i+1].split(separator: " ").map(String.init), author: tokens[i+2], date: Date(timeIntervalSince1970: Double(tokens[i+3]) ?? 0), subject: tokens[i+4], body: tokens[i+5], refs: tokens[i+6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
        }
        if path != nil {
            // Git's --skip/--grep can skip the rename needed by --follow. Traverse
            // the complete file history before filtering and paginating it.
            let matching = result.filter { (search.isEmpty || $0.body.range(of: search, options: .caseInsensitive) != nil) && (author.isEmpty || $0.author.range(of: author, options: .caseInsensitive) != nil) }
            return Array(matching.dropFirst(max(0, skip)).prefix(max(0, limit)))
        }
        return result
    }
    public func commitFiles(hash: String) async throws -> [GitCommitFile] {
        let tokens = fields(try await run(["show", "--format=", "--root", "--first-parent", "--name-status", "-M", "-z", hash, "--"]).data)
        var result: [GitCommitFile] = [], i = 0, seen = Set<String>()
        while i + 1 < tokens.count {
            let status = tokens[i]; i += 1
            guard !status.isEmpty else { continue }
            let first = tokens[i]; i += 1
            let rename = status.hasPrefix("R") || status.hasPrefix("C")
            let path: String
            if rename && i < tokens.count { path = tokens[i]; i += 1 } else { path = first }
            if seen.insert(path).inserted { result.append(GitCommitFile(path: path, status: status, originalPath: rename ? first : nil)) }
        }
        return result
    }
    public func diff(target: DiffTarget, ignoreWhitespace: Bool = false) async throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        if ignoreWhitespace { args.append("--ignore-all-space") }
        switch target {
        case let .worktree(path, untracked):
            if untracked { args += ["--no-index", "--", "/dev/null", path]; return try await run(args, allowedCodes: [0,1]).text }
            args += ["--", path]
        case let .staged(path): args += ["--cached", "--", path]
        case let .commit(hash, path):
            args = ["show", "--format=", "--root", "--first-parent", "--no-ext-diff", "--no-textconv", "--no-color"] + (ignoreWhitespace ? ["--ignore-all-space"] : []) + [hash, "--", path]
        }
        return try await run(args).text
    }
    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let entries = try await status()
        let originals = entries.filter { paths.contains($0.path) }.compactMap(\.originalPath)
        let renameOrigins = Set(entries.compactMap(\.originalPath))
        let tracked = Set(fields(try await run(["ls-files", "-z"]).data))
        let targets = Set(paths + originals).filter { path in
            // Once a rename is staged, its old path is absent from both disk and index.
            !renameOrigins.contains(path) || tracked.contains(path) || (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)) != nil
        }.sorted()
        if !targets.isEmpty { _ = try await run(["add", "--"] + targets) }
    }
    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let entries = try await status()
        let originals = entries.filter { paths.contains($0.path) }.compactMap(\.originalPath)
        let targets = Array(Set(paths + originals)).sorted()
        let head = try await run(["rev-parse", "--verify", "HEAD"], allowedCodes: [0,128])
        if head.code == 0 { _ = try await run(["reset", "--quiet", "HEAD", "--"] + targets) }
        else { _ = try await run(["rm", "--cached", "--quiet", "--ignore-unmatch", "--"] + targets) }
    }
    public func commit(message: String, amend: Bool = false) async throws { _ = try await run(["commit"] + (amend ? ["--amend"] : []) + ["-m", message]) }
    public func checkout(branch: String) async throws { _ = try await run(["switch", "--", branch]) }
    public func createBranch(name: String) async throws { try await validateBranch(name); _ = try await run(["switch", "-c", name]) }
    private func validatedCommit(_ revision: String) async throws -> String {
        guard !revision.isEmpty, !revision.hasPrefix("-"), !revision.contains("\0") else { throw GitError("Invalid revision") }
        return try await run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
    }
    private func validateBranch(_ name: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0") else { throw GitError("Invalid branch name") }
        _ = try await run(["check-ref-format", "refs/heads/" + name])
    }
    private func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".git") else { throw GitError("Invalid repository path") }
        let target = url.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(url.path + "/") else { throw GitError("Path is outside repository") }
        // Resolve the parent, preserving a tracked symlink itself as a valid file.
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = url.resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/") else { throw GitError("Path is outside repository") }
    }
    public func discardWorktree(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let entries = try await status()
        let tracked = Set(fields(try await run(["ls-files", "-z"]).data))
        for path in paths {
            try validatePath(path)
            guard tracked.contains(path), let entry = entries.first(where: { $0.path == path }), !entry.isConflict, !entry.isUntracked, entry.isUnstaged else { throw GitError("Cannot discard this worktree path: " + path) }
        }
        _ = try await run(["restore", "--worktree", "--"] + Set(paths).sorted())
    }
    public func renameBranch(oldName: String, newName: String) async throws {
        try await validateBranch(oldName); try await validateBranch(newName)
        _ = try await run(["branch", "-m", "--", oldName, newName])
    }
    public func deleteBranch(name: String) async throws {
        try await validateBranch(name)
        _ = try await run(["branch", "-d", "--", name])
    }
    public func createBranch(name: String, startPoint: String) async throws {
        try await validateBranch(name)
        let commit = try await validatedCommit(startPoint)
        _ = try await run(["branch", "--", name, commit])
    }
    public func createTag(name: String, commit: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0") else { throw GitError("Invalid tag name") }
        _ = try await run(["check-ref-format", "refs/tags/" + name])
        let hash = try await validatedCommit(commit)
        _ = try await run(["tag", "--", name, hash])
    }
    public func checkoutCommit(hash: String) async throws {
        let commit = try await validatedCommit(hash)
        _ = try await run(["switch", "--detach", commit])
    }
    private func applyCommit(_ revision: String, command: String) async throws {
        guard try await status().isEmpty else { throw GitError("A clean worktree and index are required") }
        let hash = try await validatedCommit(revision)
        let parents = try await run(["show", "-s", "--format=%P", hash]).text.split(whereSeparator: { $0.isWhitespace })
        guard parents.count <= 1 else { throw GitError("Merge commits require a mainline parent and are unsupported") }
        _ = try await run([command, "--no-edit", hash])
    }
    public func cherryPick(hash: String) async throws { try await applyCommit(hash, command: "cherry-pick") }
    public func revert(hash: String) async throws { try await applyCommit(hash, command: "revert") }
    private func validateStash(_ ref: String) async throws {
        guard (try await stashes()).contains(where: { $0.ref == ref }) else { throw GitError("Unknown stash reference") }
    }
    public func dropStash(ref: String) async throws {
        try await validateStash(ref)
        _ = try await run(["stash", "drop", ref])
    }
    public func stashDiff(ref: String) async throws -> String {
        try await validateStash(ref)
        return try await run(["stash", "show", "--patch", "--include-untracked", "--no-ext-diff", "--no-textconv", "--no-color", ref]).text
    }

    public func fetch() async throws { _ = try await run(["fetch", "--all", "--prune"]) }
    public func pull() async throws { _ = try await run(["pull", "--ff-only"]) }
    public func push() async throws { _ = try await run(["push"]) }
    public func stashes() async throws -> [GitStash] {
        let tokens = fields(try await run(["stash", "list", "-z", "--format=%gd%x00%gs"]).data)
        return stride(from: 0, to: max(0,tokens.count - 1), by: 2).map { GitStash(ref: tokens[$0], subject: tokens[$0+1]) }
    }
    public func stash(message: String) async throws { _ = try await run(["stash", "push", "--include-untracked", "-m", message]) }
    public func applyStash(ref: String) async throws { _ = try await run(["stash", "apply", ref]) }
}
