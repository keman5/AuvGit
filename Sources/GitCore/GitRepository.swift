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
        let output = try await run(["for-each-ref", "--format=%(HEAD)%00%(refname)%00%(symref)%00%(upstream:short)%00%(worktreepath)", "refs/heads", "refs/remotes"])
        return output.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[2].isEmpty else { return nil }
            let remote = parts[1].hasPrefix("refs/remotes/")
            return GitBranch(name: String(parts[1].dropFirst(remote ? 13 : 11)), isCurrent: parts[0] == "*", isRemote: remote,
                             upstream: remote || parts[3].isEmpty ? nil : parts[3], worktreePath: parts[4].isEmpty ? nil : parts[4])
        }
    }
    public func currentBranch() async throws -> String {
        let symbolic = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], allowedCodes: [0, 1])
        if symbolic.code == 0 { return symbolic.text.trimmingCharacters(in: .newlines) }
        return "Detached " + (try await run(["rev-parse", "--short", "HEAD"])).text.trimmingCharacters(in: .newlines)
    }
    public func localUnpushedCommitHashes(limit: Int) async throws -> Set<String>? {
        let upstream = try await run(["rev-parse", "--verify", "@{upstream}"], allowedCodes: [0, 128])
        guard upstream.code == 0 else { return nil }
        guard limit > 0 else { return [] }
        let hash = upstream.text.trimmingCharacters(in: .newlines)
        let output = try await run(["rev-list", "--max-count=" + String(limit), hash + "..HEAD", "--"])
        return Set(output.text.split(separator: "\n").map(String.init))
    }
    /// Query publication independently of the displayed refs, filters and page
    /// size. Remote-tracking refs reflect the most recent fetch or push.
    public func unpublishedCommitHashes(in commits: [GitCommit]) async throws -> Set<String> {
        guard !commits.isEmpty else { return [] }
        let head = try await run(["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
        let revisions = head.code == 0 ? ["HEAD"] : []
        let output = try await run(["rev-list", "--branches"] + revisions + ["--not", "--remotes", "--"])
        return Set(output.text.split(separator: "\n").map(String.init)).intersection(commits.map(\.hash))
    }
    public func worktrees() async throws -> [GitWorktree] {
        GitWorktree.parsePorcelain(try await run(["worktree", "list", "--porcelain", "-z"]).data)
    }
    public func log(limit: Int = 200, skip: Int = 0, search: String = "", path: String? = nil, ref: String? = nil, author: String = "", firstParent: Bool = false, refs: [String]? = nil, stashHashes: [String] = [], includeRecyclable: Bool = false, incomingOnly: Bool = false) async throws -> [GitCommit] {
        if let refs, refs.isEmpty, stashHashes.isEmpty, !includeRecyclable { return [] }
        var args = ["log", "--topo-order", "-z", "--format=%H%x00%P%x00%an%x00%at%x00%s%x00%B%x00%D%x00%ae%x00%cn%x00%ce%x00%ct"]
        if firstParent { args.append("--first-parent") }
        if path == nil { args += ["--max-count=\(max(0,limit))", "--skip=\(max(0,skip))"] }
        if path == nil && !author.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--author=" + author] }
        if path == nil && !search.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--grep=" + search] }
        let head = try await run(["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
        if refs == ["HEAD"], head.code != 0, stashHashes.isEmpty { return [] }
        if ref == "HEAD", refs == nil, head.code != 0, stashHashes.isEmpty { return [] }
        var revisionInput: URL?
        defer { if let revisionInput { try? FileManager.default.removeItem(at: revisionInput) } }
        if incomingOnly {
            if let refs { for value in Set(refs).sorted() { args.append(try await validatedCommit(value)) } }
            else { args.append("--remotes") }
            args += ["--not", "--branches"]
            if head.code == 0 { args.append("HEAD") }
        } else if includeRecyclable || !stashHashes.isEmpty {
            // Enumerate normal history independently so stash index/untracked parents
            // do not enter the log, and first-parent applies only to branch commits.
            var selected = Set(includeRecyclable ? try await recyclableCommitHashes() : [])
            for hash in Set(stashHashes) { selected.insert(try await validatedCommit(hash)) }
            let normalRefs = refs ?? (ref.map { [$0] } ?? [])
            var revisions: [String] = []
            for value in Set(normalRefs).sorted() {
                if value == "HEAD", head.code != 0 { continue }
                revisions.append(try await validatedCommit(value))
            }
            if refs == nil, ref == nil, !stashHashes.isEmpty {
                revisions += ["--exclude=refs/stash", "--all"]
                if head.code == 0 { revisions.append("HEAD") }
            }
            if !revisions.isEmpty {
                let traversal = ["rev-list"] + (firstParent ? ["--first-parent"] : []) + revisions + ["--"]
                selected.formUnion(try await run(traversal).text.split(separator: "\n").map(String.init))
            }
            if selected.isEmpty { return [] }
            let input = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-history-" + UUID().uuidString)
            try Data((selected.sorted().joined(separator: "\n") + "\n").utf8).write(to: input, options: .atomic)
            revisionInput = input
            args += ["--no-walk=sorted", "--stdin"]
        } else if let refs {
            for value in Set(refs).sorted() { args.append(try await validatedCommit(value)) }
        } else if let ref { args.append(try await validatedCommit(ref)) }
        else if path != nil { if head.code == 0 { args.append("HEAD") } }
        else { args.append("--all"); if head.code == 0 { args.append("HEAD") } }
        if let path { try validatePath(path); args += ["--follow", "--", path] }
        else { args.append("--") }
        let output = try await GitProcess.run(at: url, arguments: args, allowedCodes: [0, 128], inputFile: revisionInput)
        if output.code != 0 { if (try await run(["show-ref"], allowedCodes: [0, 1])).code == 1 { return [] }; throw GitError(output.error) }
        let tokens = fields(output.data)
        var result: [GitCommit] = []
        for i in stride(from: 0, to: max(0, tokens.count - 10), by: 11) {
            result.append(GitCommit(hash: tokens[i], parents: tokens[i+1].split(separator: " ").map(String.init), author: tokens[i+2], date: Date(timeIntervalSince1970: Double(tokens[i+3]) ?? 0), subject: tokens[i+4], body: tokens[i+5], refs: tokens[i+6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, authorEmail: tokens[i+7], committer: tokens[i+8], committerEmail: tokens[i+9], committedDate: Date(timeIntervalSince1970: Double(tokens[i+10]) ?? 0)))
        }
        if path != nil {
            // Git's --skip/--grep can skip the rename needed by --follow. Traverse
            // the complete file history before filtering and paginating it.
            let matching = result.filter { (search.isEmpty || $0.body.range(of: search, options: .caseInsensitive) != nil) && (author.isEmpty || $0.author.range(of: author, options: .caseInsensitive) != nil) }
            return Array(matching.dropFirst(max(0, skip)).prefix(max(0, limit)))
        }
        return result
    }
    /// Reflog-retained commits that no ordinary ref or current HEAD can reach.
    /// This is read-only and does not run fsck, prune, or expire reflogs.
    public func recyclableCommitHashes() async throws -> [String] {
        var args = ["rev-list", "--reflog", "--not", "--all"]
        if (try await run(["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])).code == 0 { args.append("HEAD") }
        args.append("--")
        return try await run(args).text.split(separator: "\n").map(String.init)
    }
    /// Full names retain local/remote identity even when their display names collide.
    public func branchesContaining(commit: String) async throws -> [String] {
        let hash = try await validatedCommit(commit)
        return try await run(["for-each-ref", "--contains=" + hash, "--format=%(refname)", "refs/heads", "refs/remotes"]).text.split(separator: "\n").map(String.init)
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
        let selected = Set(paths)
        let originals = entries.filter { selected.contains($0.path) }.compactMap(\.originalPath)
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
        let selected = Set(paths)
        let originals = entries.filter { selected.contains($0.path) }.compactMap(\.originalPath)
        let targets = Array(Set(paths + originals)).sorted()
        let head = try await run(["rev-parse", "--verify", "HEAD"], allowedCodes: [0,128])
        if head.code == 0 { _ = try await run(["reset", "--quiet", "HEAD", "--"] + targets) }
        else { _ = try await run(["rm", "--cached", "--quiet", "--ignore-unmatch", "--"] + targets) }
    }
    public func commit(message: String, amend: Bool = false) async throws { _ = try await run(["commit"] + (amend ? ["--amend"] : []) + (GitRuntimePreferences.shared.commitCleanup == "default" ? [] : ["--cleanup=" + GitRuntimePreferences.shared.commitCleanup]) + ["-m", message]) }
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
    public func discardWorktree(paths: [String], includeConflicts: Bool = false) async throws {
        guard !paths.isEmpty else { return }
        let entries = Dictionary(try await status().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let tracked = Set(fields(try await run(["ls-files", "-z"]).data))
        for path in paths {
            try validatePath(path)
            guard tracked.contains(path), let entry = entries[path], (!entry.isConflict || includeConflicts), !entry.isUntracked,
                  entry.isUnstaged || entry.isConflict else { throw GitError("Cannot discard this worktree path: " + path) }
        }
        let conflicts = Set(paths).filter { entries[$0]?.isConflict == true }.sorted()
        if !conflicts.isEmpty {
            let context = try await resetContext()
            // Unmerged entries have no stage-zero version to restore from the index.
            let headPaths = Set(fields(try await run(["ls-tree", "-r", "--name-only", "-z", context.head, "--"] + conflicts).data))
            let present = conflicts.filter { headPaths.contains($0) }, deleted = conflicts.filter { !headPaths.contains($0) }
            if !present.isEmpty { _ = try await run(["restore", "--source=" + context.head, "--staged", "--worktree", "--"] + present) }
            if !deleted.isEmpty { _ = try await run(["rm", "--force", "--"] + deleted) }
        }
        let ordinary = Set(paths).filter { entries[$0]?.isConflict != true }.sorted()
        if !ordinary.isEmpty { _ = try await run(["restore", "--worktree", "--"] + ordinary) }
    }
    public func renameBranch(oldName: String, newName: String) async throws {
        try await validateBranch(oldName); try await validateBranch(newName)
        _ = try await run(["branch", "-m", "--", oldName, newName])
    }
    public func deleteBranch(name: String, force: Bool = false, expectedHash: String? = nil) async throws {
        try await validateBranch(name)
        let hash = try await validatedCommit("refs/heads/" + name)
        if let expectedHash, hash != expectedHash { throw GitError("Branch changed since deletion was confirmed. Review it before deleting.") }
        do { _ = try await run(["branch", force ? "-D" : "-d", "--", name]) }
        catch let error as GitError {
            if !force, error.message.contains("is not fully merged") { throw BranchDeletionNeedsForce(name: name, hash: hash) }
            throw error
        }
    }
    public func createBranch(name: String, startPoint: String) async throws {
        try await validateBranch(name)
        if startPoint.hasPrefix("refs/remotes/") {
            _ = try await validatedCommit(startPoint)
            _ = try await run(["branch", "--track=direct", "--", name, startPoint])
            return
        }
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
    private func applyCommit(_ revision: String, command: String, mainline: Int?) async throws {
        guard try await status().isEmpty else { throw GitError("A clean worktree and index are required") }
        let hash = try await validatedCommit(revision)
        let parents = try await run(["show", "-s", "--format=%P", hash]).text.split(whereSeparator: { $0.isWhitespace })
        var arguments = [command, "--no-edit"]
        if parents.count > 1 {
            guard let mainline, (1...parents.count).contains(mainline) else { throw GitError("Select a valid mainline parent for the merge commit") }
            arguments += ["--mainline", String(mainline)]
        } else if mainline != nil {
            throw GitError("Mainline parent is only valid for merge commits")
        }
        _ = try await run(arguments + [hash])
    }
    public func cherryPick(hash: String, mainline: Int? = nil) async throws { try await applyCommit(hash, command: "cherry-pick", mainline: mainline) }
    public func revert(hash: String, mainline: Int? = nil) async throws { try await applyCommit(hash, command: "revert", mainline: mainline) }
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

    public func fetch(credential: NetworkCredential? = nil) async throws { _ = try await runNetwork(.fetch, credential: credential, progress: { _ in }) }
    public func pull(credential: NetworkCredential? = nil) async throws { _ = try await runNetwork(.pull, credential: credential, progress: { _ in }) }
    public func push(credential: NetworkCredential? = nil) async throws { _ = try await runNetwork(.push, credential: credential, progress: { _ in }) }
    public func stashes() async throws -> [GitStash] {
        let tokens = fields(try await run(["stash", "list", "-z", "--format=%gd%x00%gs%x00%H%x00%ct"]).data)
        return try stride(from: 0, to: max(0,tokens.count - 3), by: 4).map {
            guard let timestamp = TimeInterval(tokens[$0+3]) else { throw GitError("Invalid stash timestamp") }
            return GitStash(ref: tokens[$0], subject: tokens[$0+1], hash: tokens[$0+2], createdDate: Date(timeIntervalSince1970: timestamp))
        }
    }
    public func stash(message: String) async throws {
        // Stash uses magic pathspecs internally to clean saved untracked files.
        // No user pathspecs are passed here, so inherited literal mode is unnecessary.
        _ = try await GitProcess.run(at: url, arguments: ["stash", "push", "--include-untracked", "-m", message], literalPathspecs: false)
    }
    public func applyStash(ref: String) async throws { _ = try await run(["stash", "apply", ref]) }
}
