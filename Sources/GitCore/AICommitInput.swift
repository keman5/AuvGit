import Foundation

public enum AICommitInputError: Error { case exceedsLimit }

public extension GitRepository {
    /// A prefix is used only to detect oversize; partial input is never returned.
    func aiCommitRead(_ arguments: [String], maximumBytes: Int) async throws -> String {
        let limit = min(4_000_000, max(1, maximumBytes))
        let output = try await GitProcess.run(at: url, arguments: arguments, outputPrefixBytes: limit + 1)
        guard output.data.count <= limit else { throw AICommitInputError.exceedsLimit }
        return String(decoding: output.data, as: UTF8.self)
    }
}
