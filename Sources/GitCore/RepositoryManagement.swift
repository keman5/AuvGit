import Foundation
import Darwin

public extension GitRepository {
    static func initialize(at directory: URL) async throws -> GitRepository {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: directory, arguments: ["init"])
        return try await open(directory)
    }
    static func clone(source: String, destination: URL) async throws -> GitRepository {
        guard !source.isEmpty, !source.hasPrefix("-"), !source.contains("\0") else { throw GitError("Invalid clone source") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: destination.deletingLastPathComponent(), arguments: ["clone", "--", source, destination.path])
        return try await open(destination)
    }
    func workflowRevision(_ value: String) async throws -> String {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0") else { throw GitError("Invalid revision") }
        return try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "--end-of-options", value + "^{commit}"]).text.trimmingCharacters(in: .newlines)
    }
    func workflowRead(_ arguments: [String]) async throws -> String { try await GitProcess.run(at: url, arguments: arguments).text }
    func setUpstream(branch: String, remoteBranch: String?) async throws {
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\0"), !branch.contains("\n") else { throw GitError("Invalid branch") }
        var args = ["branch"]
        if let remoteBranch {
            guard remoteBranch.hasPrefix("refs/remotes/"), !remoteBranch.contains("\0"), !remoteBranch.contains("\n") else { throw GitError("Invalid remote branch") }
            args.append("--set-upstream-to=" + remoteBranch)
        } else { args.append("--unset-upstream") }
        _ = try await GitProcess.run(at: url, arguments: args + ["--", branch])
    }
    func stopTracking(remoteBranch: String) async throws {
        let output = try await workflowRead(["for-each-ref", "--format=%(refname:short)%09%(upstream)", "refs/heads/"])
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 2, fields[1] == remoteBranch { try await setUpstream(branch: String(fields[0]), remoteBranch: nil) }
        }
    }
    func compareReferences(_ left: String, _ right: String) async throws -> String {
        let a = try await workflowRevision(left), b = try await workflowRevision(right)
        return try await workflowRead(["diff", "--no-ext-diff", "--no-textconv", "--no-color", a, b, "--"])
    }
    func reflogText() async throws -> String { try await workflowRead(["reflog", "--date=iso", "--all"]) }
    func blameText(path: String, revision: String) async throws -> String {
        try workflowPath(path)
        let hash = try await workflowRevision(revision)
        return try await workflowRead(["blame", "--date=iso", hash, "--", path])
    }
    func interactiveRebase(onto: String, plan: String) async throws -> String {
        let base = try await workflowRevision(onto), head = try await workflowRevision("HEAD")
        var messages: [Int: String] = [:]
        for (index, line) in plan.components(separatedBy: "\n").enumerated() {
            let fields = line.split(separator: " ", maxSplits: 2)
            if fields.count == 3, ["reword", "r"].contains(String(fields[0])) { messages[index] = String(fields[2]) }
        }
        return try await executeRebase(plan: RebasePlan(base: base, head: head, todo: plan), editedTodo: plan, messages: messages, allowExec: false)
    }
    private func workflowShellPath(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    func rebaseToolsDirectory() async throws -> URL {
        let path = try await workflowRead(["rev-parse", "--git-path", "raygit-rebase-tools"]).trimmingCharacters(in: .newlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
    }
    func cleanupRebaseToolsIfFinished() async {
        guard let path = try? await workflowRead(["rev-parse", "--git-path", "rebase-merge"]).trimmingCharacters(in: .newlines) else { return }
        let active = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
        if !FileManager.default.fileExists(atPath: active.path), let directory = try? await rebaseToolsDirectory() { try? FileManager.default.removeItem(at: directory) }
    }
    func renameStash(reference: String, message: String) async throws -> String {
        guard !message.isEmpty, !message.contains("\0"), !message.contains("\n"), !message.contains("\r"), reference.hasPrefix("stash@{"), reference.hasSuffix("}"), let index = Int(reference.dropFirst(7).dropLast()), index >= 0 else { throw GitError("Invalid stash reference or message") }
        let refPath = try await workflowRead(["rev-parse", "--git-path", "refs/stash"]).trimmingCharacters(in: .newlines)
        let logPath = try await workflowRead(["rev-parse", "--git-path", "logs/refs/stash"]).trimmingCharacters(in: .newlines)
        func resolved(_ path: String) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path) }
        let lock = resolved(refPath + ".lock")
        let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitError("Stash reference is locked by another Git operation") }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: lock) }
        let log = resolved(logPath)
        let data = try Data(contentsOf: log)
        guard let text = String(data: data, encoding: .utf8) else { throw GitError("Stash reflog is not UTF-8") }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard index < lines.count else { throw GitError("Unknown stash reference") }
        let position = lines.count - 1 - index
        guard let tab = lines[position].firstIndex(of: "\t") else { throw GitError("Invalid stash reflog") }
        lines[position] = String(lines[position][...tab]) + message
        // Only a reflog message changes: OIDs, order, identity and timestamps stay intact.
        // Holding refs/stash.lock prevents Git reference writers during atomic replacement.
        guard try Data(contentsOf: log) == data else { throw GitError("Stash reflog changed while renaming; retry") }
        let permissions = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: log.path) }
        return "Renamed " + reference
    }
    func workflowPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else { throw GitError("Invalid repository path") }
        let target = url.appendingPathComponent(path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: target.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw GitError("Symbolic link paths are not supported by this operation") }
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = url.resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/") else { throw GitError("Path is outside repository") }
    }
    func advancedOperation(_ operation: RepositoryWorkflow, first: String, second: String) async throws -> String {
        func name(_ value: String) throws { guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0"), !value.contains("\n") else { throw GitError("Invalid name") } }
        var args: [String]
        switch operation {
        case .rebasePlan:
            return try await generatedRebasePlan(onto: first).todo
        case .interactiveRebase: return try await interactiveRebase(onto: first, plan: second)
        case .stashRename: return try await renameStash(reference: first, message: second)
        case .compare: return try await compareReferences(first, second)
        case .reflog: return try await reflogText()
        case .blame: return try await blameText(path: first, revision: second.isEmpty ? "HEAD" : second)
        case .remoteList: args = ["remote", "-v"]
        case .remoteAdd: try name(first); try name(second); args = ["remote", "add", first, second]
        case .remoteRemove: try name(first); args = ["remote", "remove", first]
        case .upstream: try name(first); args = ["branch", "--set-upstream-to=" + first]
        case .trackingBranch: try name(first); try name(second); args = ["switch", "--track", "-c", first, second]
        case .tags: args = ["tag", "-n99"]
        case .tagDelete: try name(first); args = ["tag", "-d", "--", first]
        case .annotatedTag: try name(first); args = ["tag", "-a", first, "-m", second]
        case .aheadBehind: args = ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]
        case .pushPreview: args = ["push", "--dry-run", "--porcelain"]
        case .forcePush: args = ["push", "--force-with-lease"]
        case .merge: args = ["merge", "--no-edit", try await workflowRevision(first)]
        case .resetSoft, .resetMixed, .resetHard: return try await reset(to: first, mode: operation == .resetSoft ? .soft : operation == .resetMixed ? .mixed : .hard)
        case .mergeContinue: args = ["-c", "core.editor=true", "merge", "--continue"]
        case .mergeAbort: args = ["merge", "--abort"]
        case .rebaseContinue:
            let editor = try await rebaseToolsDirectory().appendingPathComponent("message-editor")
            let result = try await workflowRead(["-c", "core.editor=" + (FileManager.default.fileExists(atPath: editor.path) ? workflowShellPath(editor.path) : "true"), "rebase", "--continue"])
            await cleanupRebaseToolsIfFinished(); return result
        case .rebaseAbort:
            let result = try await workflowRead(["rebase", "--abort"]); await cleanupRebaseToolsIfFinished(); return result
        case .cherryContinue: args = ["-c", "core.editor=true", "cherry-pick", "--continue"]
        case .cherryAbort: args = ["cherry-pick", "--abort"]
        case .revertContinue: args = ["-c", "core.editor=true", "revert", "--continue"]
        case .revertAbort: args = ["revert", "--abort"]
        case .partialStash: let paths = first.split(separator: "\n").map(String.init); guard !paths.isEmpty else { throw GitError("Select at least one path") }; for path in paths { try workflowPath(path) }; args = ["stash", "push", "--include-untracked", "-m", second, "--"] + paths
        case .submodules: args = ["submodule", "status", "--recursive"]
        case .submoduleUpdate: args = ["submodule", "update", "--init", "--recursive"]
        case .submoduleAdd: try name(first); try workflowPath(second); args = ["submodule", "add", "--", first, second]
        case .lfsStatus: args = ["lfs", "status"]
        case .lfsInstall: args = ["lfs", "install", "--local"]
        case .lfsTrack: try name(first); args = ["lfs", "track", "--", first]
        case .flowStart: try name(first); _ = try await workflowRead(["check-ref-format", "refs/heads/feature/" + first]); args = ["switch", "-c", "feature/" + first, try await workflowRevision(second.isEmpty ? "develop" : second)]
        case .commitTemplate: try name(first); args = ["config", "--local", "commit.template", first]
        case .signingKey: args = ["config", "--local", "user.signingkey", first]
        case .signingEnable: guard ["true", "false"].contains(first) else { throw GitError("Use true or false") }; args = ["config", "--local", "commit.gpgsign", first]
        }
        return try await workflowRead(args)
    }
}
public enum RepositoryWorkflow: String, CaseIterable, Identifiable, Sendable {
    case rebasePlan, interactiveRebase, stashRename, compare, reflog, blame, remoteList, remoteAdd, remoteRemove, upstream, trackingBranch, tags, tagDelete, annotatedTag, aheadBehind, pushPreview, forcePush, merge, resetSoft, resetMixed, resetHard, mergeContinue, mergeAbort, rebaseContinue, rebaseAbort, cherryContinue, cherryAbort, revertContinue, revertAbort, partialStash, submodules, submoduleUpdate, submoduleAdd, lfsStatus, lfsInstall, lfsTrack, flowStart, commitTemplate, signingKey, signingEnable
    public var id: String { rawValue }
    public var writes: Bool { ![Self.rebasePlan, .compare, .reflog, .blame, .remoteList, .tags, .aheadBehind, .pushPreview, .submodules, .lfsStatus].contains(self) }
}

public enum GitResetMode: String, CaseIterable, Sendable { case mixed, soft, hard, keep, merge }
public struct GitResetContext: Equatable, Sendable {
    public let repositoryURL: URL
    public let head: String
    public let reference: String
}
public extension GitRepository {
    func resetContext() async throws -> GitResetContext {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            let path = try await workflowRead(["rev-parse", "--git-path", marker]).trimmingCharacters(in: .newlines)
            let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw GitError("Finish or abort the active Git operation before resetting") }
        }
        return GitResetContext(repositoryURL: url.standardizedFileURL, head: try await workflowRevision("HEAD"), reference: try await workflowRead(["rev-parse", "--symbolic-full-name", "HEAD"]).trimmingCharacters(in: .newlines))
    }
    func reset(to revision: String, mode: GitResetMode, expected: GitResetContext? = nil) async throws -> String {
        let hash = try await workflowRevision(revision)
        let current = try await resetContext()
        guard expected == nil || expected == current else { throw GitError("Repository or HEAD changed. Reopen the reset confirmation.") }
        return try await workflowRead(["reset", "--" + mode.rawValue, hash, "--"])
    }
}
