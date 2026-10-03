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
        let patch: String
        if !unstage && !file.index.exists && file.worktree.isEditable {
            patch = try await GitProcess.run(at: url, arguments: ["diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", path], allowedCodes: [0, 1]).text
        } else { patch = try await GitProcess.run(at: url, arguments: args).text }
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
        else if original != nil && (unstage || !file.index.exists) { reason = "Renamed files must be staged or unstaged as a whole." }
        else if (file.index.exists && !file.index.isEditable) || ((unstage ? file.head : file.worktree).exists && !(unstage ? file.head : file.worktree).isEditable) { reason = "Only UTF-8 text supports partial staging." }
        else { reason = nil }
        return PartialStagingSnapshot(file: file, unstage: unstage, hunks: hunks, unavailableReason: reason, header: header.joined(separator: "\n"))
    }
    public func applyPartialStaging(_ expected: PartialStagingSnapshot, selectedLines: Set<Int>) async throws {
        if let reason = expected.unavailableReason { throw GitError(reason) }
        let current = try await fileComparison(path: expected.file.path)
        guard current.index.data == expected.file.index.data, current.worktree.data == expected.file.worktree.data, current.head.data == expected.file.head.data, !current.isConflict else { throw GitError("The index or working tree changed. Reload before partial staging.") }
        var pieces: [String] = []
        var retainedOriginalLines = false
        var offset = 0
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
                    if !chosen { newCount += 1; retainedOriginalLines = true }
                } else if line.text.hasPrefix(" ") { keptPrevious = true; lines.append(line.text); oldCount += 1; newCount += 1 }
                else if line.text.hasPrefix("\\ No newline") && keptPrevious { lines.append(line.text) }
            }
            let ranges = hunk.header.split(separator: " ")
            guard ranges.count >= 3 else { throw GitError("Invalid patch hunk.") }
            let oldStart = Int(ranges[1].dropFirst().split(separator: ",")[0]) ?? 0
            let newStart = newCount == 0 ? max(0, oldStart + offset - 1) : oldCount == 0 && oldStart == 0 ? 1 : max(0, oldStart + offset)
            pieces.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + lines.joined(separator: "\n"))
            offset += newCount - oldCount
        }
        guard !pieces.isEmpty else { throw GitError("Select at least one changed line.") }
        var header = expected.header.split(separator: "\n").filter { !$0.hasPrefix("old mode ") && !$0.hasPrefix("new mode ") }.joined(separator: "\n")
        if header.contains("deleted file mode ") && retainedOriginalLines {
            let headerLines = header.split(separator: "\n").map(String.init)
            guard let original = headerLines.first(where: { $0.hasPrefix("--- ") }) else { throw GitError("Invalid patch hunk.") }
            let destination = original.replacingOccurrences(of: "--- a/", with: "+++ b/").replacingOccurrences(of: "--- \"a/", with: "+++ \"b/")
            header = headerLines.filter { !$0.hasPrefix("deleted file mode ") && !$0.hasPrefix("index ") }.map { $0 == "+++ /dev/null" ? destination : $0 }.joined(separator: "\n")
        }
        let patch = header + "\n" + pieces.joined(separator: "\n") + "\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".patch")
        try Data(patch.utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await GitProcess.run(at: url, arguments: ["apply", "--cached", "--recount", "--whitespace=nowarn", temp.path])
    }
    public func saveIndex(path: String, text: String, expected: FileRevisionContent) async throws {
        let current = try await fileComparison(path: path)
        guard !current.isConflict, current.index.isEditable, current.index.data == expected.data else { throw GitError("The index changed. Reload before saving to the index.") }
        guard !text.contains("\0"), text.utf8.count <= 2 * 1024 * 1024 else { throw GitError("Only UTF-8 text up to 2 MB can be saved to the index.") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var data = Data(normalized.utf8)
        if String(data: expected.data ?? Data(), encoding: .utf8)?.contains("\r\n") == true { data = Data(normalized.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
        if expected.data?.starts(with: [0xef, 0xbb, 0xbf]) == true { data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        let oid = try await GitProcess.run(at: url, arguments: ["hash-object", "-w", "--", temp.path]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = try await GitProcess.run(at: url, arguments: ["ls-files", "--stage", "--", path]).text
        guard let mode = listing.split(separator: " ").first else { throw GitError("Index entry is missing.") }
        _ = try await GitProcess.run(at: url, arguments: ["update-index", "--cacheinfo", String(mode), oid, path])
    }
}
