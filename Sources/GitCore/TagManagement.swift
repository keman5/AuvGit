import Foundation
public struct ManagedTag: Identifiable, Sendable {
    public let name: String
    public let objectHash: String
    public let commitHash: String?
    public let message: String
    public var id: String { name }
}
public extension GitRepository {
    func managedTags() async throws -> [ManagedTag] {
        let text = try await workflowRead(["for-each-ref", "--format=%(refname:short)%00%(objectname)%00%(objecttype)%00%(contents:subject)", "refs/tags"])
        var tags: [ManagedTag] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { continue }
            let commitHash: String?
            if parts[2] == "commit" { commitHash = parts[1] }
            else if parts[2] == "tag" {
                // Peel the captured immutable object, including nested annotated
                // tags. A blob/tree tag is valid, but has no commit to display.
                let result = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "--end-of-options", parts[1] + "^{commit}"], allowedCodes: [0, 128])
                commitHash = result.code == 0 ? result.text.trimmingCharacters(in: .newlines) : nil
            } else { commitHash = nil }
            tags.append(ManagedTag(name: parts[0], objectHash: parts[1], commitHash: commitHash, message: parts[3]))
        }
        return tags
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
