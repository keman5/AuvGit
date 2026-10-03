import Foundation

public struct MergePreviewResult: Sendable {
    public let text: String
    public let hasConflicts: Bool
}
public enum MergePreview {
    /// Writes only disposable input files; the returned result is a draft, never a repository mutation.
    public static func create(base: String, ours: String, theirs: String) async throws -> MergePreviewResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, value) in [("base", base), ("ours", ours), ("theirs", theirs)] {
            try Data(value.utf8).write(to: directory.appendingPathComponent(name))
        }
        // merge-file returns the number of conflicts (up to 127), not only 1.
        let result = try await GitProcess.run(at: directory, arguments: ["merge-file", "-p", "--diff3", "-L", "Ours", "-L", "Base", "-L", "Theirs", "ours", "base", "theirs"], allowedCodes: Set(0...127))
        return MergePreviewResult(text: result.text, hasConflicts: result.code != 0)
    }
}
