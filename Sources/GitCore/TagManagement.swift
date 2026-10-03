import Foundation
public struct ManagedTag: Identifiable, Sendable {
    public let name: String
    public let hash: String
    public let message: String
    public var id: String { name }
}
public extension GitRepository {
    func managedTags() async throws -> [ManagedTag] {
        let text = try await workflowRead(["for-each-ref", "--format=%(refname:short)%00%(objectname)%00%(contents:subject)", "refs/tags"])
        return text.split(separator: "\n").compactMap { line in let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init); guard parts.count == 3 else { return nil }; return ManagedTag(name: parts[0], hash: parts[1], message: parts[2]) }
    }
    func createManagedTag(name: String, revision: String, message: String, signed: Bool) async throws {
        try await validateManagedTag(name)
        let hash = try await workflowRevision(revision)
        let mode = signed ? ["-s", "-m", message] : message.isEmpty ? [] : ["-a", "-m", message]
        _ = try await workflowRead(["tag"] + mode + ["--", name, hash])
    }
    func validateManagedTag(_ name: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0") else { throw GitError("Invalid tag name") }
        _ = try await workflowRead(["check-ref-format", "refs/tags/" + name])
    }
    func synchronizeTag(name: String, remote: String, delete: Bool, preview: Bool) async throws -> String {
        try await validateManagedTag(name)
        let remotes = try await workflowRead(["remote"]).split(separator: "\n").map(String.init)
        guard remotes.contains(remote) else { throw GitError("Unknown remote") }
        let spec = (delete ? ":" : "refs/tags/" + name + ":") + "refs/tags/" + name
        return try await workflowRead(["push", "--porcelain"] + (preview ? ["--dry-run"] : []) + [remote, spec])
    }
    func fetchTags(remote: String) async throws -> String {
        guard try await workflowRead(["remote"]).split(separator: "\n").contains(Substring(remote)) else { throw GitError("Unknown remote") }
        return try await workflowRead(["fetch", "--tags", remote])
    }
}
