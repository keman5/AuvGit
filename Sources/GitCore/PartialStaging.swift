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
    public func partialStaging(path: String, unstage: Bool, snapshot: FileComparisonSnapshot? = nil) async throws -> PartialStagingSnapshot {
        if let snapshot, snapshot.path != path { throw GitError("Comparison snapshot does not match the requested path.") }
        let file: FileComparisonSnapshot
        if let snapshot { file = snapshot } else { file = try await fileComparison(path: path) }
        let args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color"] + (unstage ? ["--cached", "-R"] : []) + ["--", path]
        let original = file.status?.originalPath
        let patch: String
        if unstage, original != nil, file.index.exists, let before = file.index.data, let after = file.head.data {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try before.write(to: directory.appendingPathComponent("before")); try after.write(to: directory.appendingPathComponent("after"))
            let raw = try await GitProcess.run(at: directory, arguments: ["diff", "--no-index", "--no-color", "--", "before", "after"], allowedCodes: [0, 1]).text
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\"" }
            if let range = raw.range(of: "@@ ") {
                let oldName = quote("a/" + path), newName = quote("b/" + path)
                let metadata = ["diff --git \(oldName) \(newName)", "--- \(oldName)", "+++ \(newName)"]
                patch = metadata.joined(separator: "\n") + "\n" + String(raw[range.lowerBound...])
            }
            else { patch = "" }
        } else if !unstage && !file.index.exists && file.worktree.isEditable {
            patch = try await GitProcess.run(at: url, arguments: ["diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", path], allowedCodes: [0, 1]).text
        } else { patch = try await GitProcess.run(at: url, arguments: args).text }
        var header: [String] = [], hunks: [StagingHunk] = [], body: [StagingLine] = [], hunkHeader = "", lineID = 0
        func finish() { if !hunkHeader.isEmpty { hunks.append(StagingHunk(id: hunks.count, header: hunkHeader, lines: body)) } }
        for line in patch.components(separatedBy: "\n").dropLast() {
            if line.hasPrefix("@@ ") { finish(); hunkHeader = line; body = [] }
            else if hunkHeader.isEmpty { header.append(line) }
            else { body.append(StagingLine(id: lineID, text: line)); lineID += 1 }
        }
        finish()
        let reason: String?
        if file.isConflict { reason = "Resolve conflicts before partial staging." }
        else if original != nil && !file.index.exists { reason = "Prepare the rename identity before partially staging its content." }
        else if [file.index.data, (unstage ? file.head : file.worktree).data].compactMap({ $0 }).contains(where: { ComparisonTextDecoder.format(of: $0).encoding == .utf16LE || ComparisonTextDecoder.format(of: $0).encoding == .utf16BE }) { reason = "Convert UTF-16 to UTF-8 before partial staging; whole-file staging preserves UTF-16." }
        else if (file.index.exists && !file.index.isEditable) || ((unstage ? file.head : file.worktree).exists && !(unstage ? file.head : file.worktree).isEditable) { reason = "Only UTF-8 text supports partial staging." }
        else { reason = nil }
        return PartialStagingSnapshot(file: file, unstage: unstage, hunks: hunks, unavailableReason: reason, header: header.joined(separator: "\n"))
    }
    public func applyPartialStaging(_ expected: PartialStagingSnapshot, selectedLines: Set<Int>) async throws {
        if let reason = expected.unavailableReason { throw GitError(reason) }
        let current = try await fileComparison(path: expected.file.path)
        guard current.index.data == expected.file.index.data, current.worktree.data == expected.file.worktree.data, current.head.data == expected.file.head.data, current.index.gitMode == expected.file.index.gitMode, current.worktree.gitMode == expected.file.worktree.gitMode, current.head.objectID == expected.file.head.objectID, !current.isConflict else { throw GitError("The index or working tree changed. Reload before partial staging.") }
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
            let destination = "+++ " + original.dropFirst(4)
            header = headerLines.filter { !$0.hasPrefix("deleted file mode ") && !$0.hasPrefix("index ") }.map { $0 == "+++ /dev/null" ? destination : $0 }.joined(separator: "\n")
        }
        let patch = header + "\n" + pieces.joined(separator: "\n") + "\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".patch")
        try Data(patch.utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await GitProcess.run(at: url, arguments: ["apply", "--cached", "--recount", "--whitespace=nowarn", temp.path])
    }
    public func saveIndex(path: String, text: String, expected: FileRevisionContent, format: ComparisonTextFormat? = nil) async throws {
        let current = try await fileComparison(path: path)
        guard !current.isConflict, (current.index.isEditable || (format != nil && current.index.reinterpreting(as: format!.encoding).isEditable)), current.index.data == expected.data, current.index.gitMode == expected.gitMode else { throw GitError("The index changed. Reload before saving to the index.") }
        guard !text.contains("\0") else { throw GitError("Only UTF-8 text up to 2 MB can be saved to the index.") }
        let data = try ComparisonTextDecoder.encode(text, format: format ?? ComparisonTextDecoder.format(of: expected.data ?? Data()))
        guard data.count <= 2 * 1024 * 1024 else { throw GitError("Files larger than 2 MB cannot be saved by the text editor.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        let oid = try await GitProcess.run(at: url, arguments: ["hash-object", "-w", "--", temp.path]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = try await GitProcess.run(at: url, arguments: ["ls-files", "--stage", "--", path]).text
        guard let mode = listing.split(separator: " ").first else { throw GitError("Index entry is missing.") }
        let verified = try await fileComparison(path: path)
        guard verified.index.data == expected.data, verified.index.gitMode == expected.gitMode, verified.index.objectID == expected.objectID, !verified.isConflict else { throw GitError("The index changed. Reload before saving to the index.") }
        _ = try await GitProcess.run(at: url, arguments: ["update-index", "--cacheinfo", String(mode), oid, path])
    }
}

extension GitRepository {
    /// Stage only rename identity using the old index bytes; worktree content remains untouched.
    public func prepareRenameIdentity(path: String, originalPath: String, expected: FileComparisonSnapshot) async throws {
        guard path != originalPath else { throw GitError("Choose a different original path.") }
        let current = try await fileComparison(path: path), original = try await fileComparison(path: originalPath)
        guard !current.isConflict, !original.isConflict, !current.index.exists, current.worktree.isEditable,
              current.worktree.data == expected.worktree.data, current.worktree.gitMode == expected.worktree.gitMode,
              !original.worktree.exists, original.index.isEditable, let oid = original.index.objectID, let mode = original.index.gitMode else { throw GitError("Choose a missing tracked original file and an unchanged new regular file.") }
        _ = try await GitProcess.run(at: url, arguments: ["update-index", "--add", "--cacheinfo", mode, oid, path, "--force-remove", "--", originalPath])
    }
}
