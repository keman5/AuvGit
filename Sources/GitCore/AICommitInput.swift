import Foundation

public enum AICommitInputError: Error { case exceedsLimit }
public enum AICommitScope: String, CaseIterable, Sendable { case staged, workspace }

public extension GitRepository {
    /// A prefix is used only to detect oversize; partial input is never returned.
    func aiCommitRead(_ arguments: [String], maximumBytes: Int, allowedCodes: Set<Int32> = [0]) async throws -> String {
        let limit = min(4_000_000, max(1, maximumBytes))
        let output = try await GitProcess.run(at: url, arguments: arguments, allowedCodes: allowedCodes, outputPrefixBytes: limit + 1)
        guard output.data.count <= limit else { throw AICommitInputError.exceedsLimit }
        return String(decoding: output.data, as: UTF8.self)
    }

    /// Reads both index and working changes without staging anything. Each section
    /// shares one budget; an oversized input is rejected, never silently truncated.
    func aiCommitInput(scope: AICommitScope, summaryOnly: Bool, maximumBytes: Int) async throws -> String {
        let limit = min(4_000_000, max(1, maximumBytes))
        var result = ""
        func append(_ text: String, label: String) throws {
            guard !text.isEmpty else { return }
            let section = "\n[\(label)]\n" + text
            guard result.utf8.count + section.utf8.count <= limit else { throw AICommitInputError.exceedsLimit }
            result += section
        }
        let common = ["--no-ext-diff", "--no-textconv", "--no-color"]
        for cached in scope == .staged ? [true] : [true, false] {
            let arguments = ["diff"] + (cached ? ["--cached"] : []) + common
            let label = cached ? "Staged changes" : "Unstaged changes"
            if summaryOnly {
                try append(try await aiCommitRead(arguments + ["--name-status", "--no-renames"], maximumBytes: limit - result.utf8.count), label: label)
                try append(try await aiCommitRead(arguments + ["--shortstat", "--no-renames"], maximumBytes: limit - result.utf8.count), label: label + " counts")
            } else {
                try append(try await aiCommitRead(arguments + ["--unified=3"], maximumBytes: limit - result.utf8.count), label: label)
            }
        }
        if scope == .workspace {
            let paths = try await aiCommitRead(["ls-files", "--others", "--exclude-standard", "-z"], maximumBytes: limit)
            for path in paths.split(separator: "\0").map(String.init) {
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)
                let kind = attributes[.type] as? FileAttributeType
                if summaryOnly || (kind != .typeRegular && kind != .typeSymbolicLink) {
                    try append("? " + String(reflecting: path) + "\n", label: "Untracked file")
                } else {
                    let patch = try await aiCommitRead(["diff", "--no-index"] + common + ["--unified=3", "--", "/dev/null", path], maximumBytes: limit - result.utf8.count, allowedCodes: [0, 1])
                    try append(patch.isEmpty ? "? " + String(reflecting: path) + " (empty file)\n" : patch, label: "Untracked file")
                }
            }
        }
        return result
    }
}
