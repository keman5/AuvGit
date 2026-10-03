import Foundation

public extension GitRepository {
    static func initialize(at directory: URL) async throws -> GitRepository {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: directory, arguments: ["init"])
        return try await open(directory)
    }
    static func clone(source: String, destination: URL) async throws -> GitRepository {
        guard !source.isEmpty, !source.hasPrefix("-"), !source.contains("\0") else { throw GitError("Invalid clone source") }
        _ = try await GitProcess.run(at: destination.deletingLastPathComponent(), arguments: ["clone", "--", source, destination.path])
        return try await open(destination)
    }
    func workflowRevision(_ value: String) async throws -> String {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0") else { throw GitError("Invalid revision") }
        return try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "--end-of-options", value + "^{commit}"]).text.trimmingCharacters(in: .newlines)
    }
    func workflowRead(_ arguments: [String]) async throws -> String { try await GitProcess.run(at: url, arguments: arguments).text }
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
    func workflowPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".git") else { throw GitError("Invalid repository path") }
        let parent = url.appendingPathComponent(path).deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = url.resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/") else { throw GitError("Path is outside repository") }
    }
    func advancedOperation(_ operation: RepositoryWorkflow, first: String, second: String) async throws -> String {
        func name(_ value: String) throws { guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0"), !value.contains("\n") else { throw GitError("Invalid name") } }
        var args: [String]
        switch operation {
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
        case .resetSoft, .resetMixed, .resetHard: args = ["reset", operation == .resetSoft ? "--soft" : operation == .resetMixed ? "--mixed" : "--hard", try await workflowRevision(first)]
        case .mergeContinue: args = ["-c", "core.editor=true", "merge", "--continue"]
        case .mergeAbort: args = ["merge", "--abort"]
        case .rebaseContinue: args = ["-c", "core.editor=true", "rebase", "--continue"]
        case .rebaseAbort: args = ["rebase", "--abort"]
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
    case compare, reflog, blame, remoteList, remoteAdd, remoteRemove, upstream, trackingBranch, tags, tagDelete, annotatedTag, aheadBehind, pushPreview, forcePush, merge, resetSoft, resetMixed, resetHard, mergeContinue, mergeAbort, rebaseContinue, rebaseAbort, cherryContinue, cherryAbort, revertContinue, revertAbort, partialStash, submodules, submoduleUpdate, submoduleAdd, lfsStatus, lfsInstall, lfsTrack, flowStart, commitTemplate, signingKey, signingEnable
    public var id: String { rawValue }
    public var writes: Bool { ![Self.compare, .reflog, .blame, .remoteList, .tags, .aheadBehind, .pushPreview, .submodules, .lfsStatus].contains(self) }
}
