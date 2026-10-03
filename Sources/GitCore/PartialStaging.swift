import Foundation

public struct StagingLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public var isChange: Bool { text.hasPrefix("+") || text.hasPrefix("-") }
}
public struct StagingHunk: Identifiable, Sendable {
    public let id: Int
    public let header: String
    public let lines: [StagingLine]
}
public struct PartialStagingSnapshot: Sendable {
    public let file: FileComparisonSnapshot
    public let unstage: Bool
    public let hunks: [StagingHunk]
    public let unavailableReason: String?
    let header: String
}

extension GitRepository {
    public func partialStaging(path: String, unstage: Bool) async throws -> PartialStagingSnapshot {
        let file = try await fileComparison(path: path)
        let args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color"] + (unstage ? ["--cached", "-R"] : []) + ["--", path]
        let patch = try await GitProcess.run(at: url, arguments: args).text
        var header: [String] = [], hunks: [StagingHunk] = [], body: [StagingLine] = [], hunkHeader = "", lineID = 0
        func finish() { if !hunkHeader.isEmpty { hunks.append(StagingHunk(id: hunks.count, header: hunkHeader, lines: body)) } }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) {
            if line.hasPrefix("@@ ") { finish(); hunkHeader = line; body = [] }
            else if hunkHeader.isEmpty { header.append(line) }
            else { body.append(StagingLine(id: lineID, text: line)); lineID += 1 }
        }
        finish()
        let original = try await status().first { $0.path == path }?.originalPath
        let reason: String?
        if file.isConflict { reason = "Resolve conflicts before partial staging." }
        else if original != nil { reason = "Renamed files must be staged or unstaged as a whole." }
        else if !file.index.exists || !(unstage ? file.head.exists : file.worktree.exists) { reason = "New and deleted files must be staged or unstaged as a whole." }
        else if !file.index.isEditable || !(unstage ? file.head.isEditable : file.worktree.isEditable) { reason = "Only UTF-8 text supports partial staging." }
        else { reason = nil }
        return PartialStagingSnapshot(file: file, unstage: unstage, hunks: hunks, unavailableReason: reason, header: header.joined(separator: "\n"))
    }
    public func applyPartialStaging(_ expected: PartialStagingSnapshot, selectedLines: Set<Int>) async throws {
        if let reason = expected.unavailableReason { throw GitError(reason) }
        let current = try await fileComparison(path: expected.file.path)
        guard current.index.data == expected.file.index.data, current.worktree.data == expected.file.worktree.data, current.head.data == expected.file.head.data, !current.isConflict else { throw GitError("The index or working tree changed. Reload before partial staging.") }
        var pieces: [String] = []
        for hunk in expected.hunks {
            guard hunk.lines.contains(where: { $0.isChange && selectedLines.contains($0.id) }) else { continue }
            var lines: [String] = [], oldCount = 0, newCount = 0, keptPrevious = false
            for line in hunk.lines {
                let chosen = selectedLines.contains(line.id)
                if line.text.hasPrefix("+") {
                    keptPrevious = chosen
                    if chosen { lines.append(line.text); newCount += 1 }
                } else if line.text.hasPrefix("-") {
                    keptPrevious = true
                    lines.append(chosen ? line.text : " " + line.text.dropFirst()); oldCount += 1
                    if !chosen { newCount += 1 }
                } else if line.text.hasPrefix(" ") { keptPrevious = true; lines.append(line.text); oldCount += 1; newCount += 1 }
                else if line.text.hasPrefix("\\ No newline") && keptPrevious { lines.append(line.text) }
            }
            let ranges = hunk.header.split(separator: " ")
            guard ranges.count >= 3 else { throw GitError("Invalid patch hunk.") }
            let oldStart = ranges[1].dropFirst().split(separator: ",")[0]
            // apply uses the original-side position; recount verifies the transformed body.
            pieces.append("@@ -\(oldStart),\(oldCount) +\(oldStart),\(newCount) @@\n" + lines.joined(separator: "\n"))
        }
        guard !pieces.isEmpty else { throw GitError("Select at least one changed line.") }
        let patch = expected.header + "\n" + pieces.joined(separator: "\n") + "\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".patch")
        try Data(patch.utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await GitProcess.run(at: url, arguments: ["apply", "--cached", "--recount", "--whitespace=nowarn", temp.path])
    }
    public func saveIndex(path: String, text: String, expected: FileRevisionContent) async throws {
        let current = try await fileComparison(path: path)
        guard !current.isConflict, current.index.isEditable, current.index.data == expected.data else { throw GitError("The index changed. Reload before saving to the index.") }
        guard !text.contains("\0"), text.utf8.count <= 2 * 1024 * 1024 else { throw GitError("Only UTF-8 text up to 2 MB can be saved to the index.") }
        var data = Data(text.utf8)
        if String(data: expected.data ?? Data(), encoding: .utf8)?.contains("\r\n") == true { data = Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
        if expected.data?.starts(with: [0xef, 0xbb, 0xbf]) == true { data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        let oid = try await GitProcess.run(at: url, arguments: ["hash-object", "-w", "--", temp.path]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = try await GitProcess.run(at: url, arguments: ["ls-files", "--stage", "--", path]).text
        guard let mode = listing.split(separator: " ").first else { throw GitError("Index entry is missing.") }
        _ = try await GitProcess.run(at: url, arguments: ["update-index", "--cacheinfo", String(mode), oid, path])
    }
}
