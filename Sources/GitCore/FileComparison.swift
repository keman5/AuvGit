import Foundation

public struct FileRevisionContent: Sendable {
    public let data: Data?
    public let text: String?
    public let exists: Bool
    public let isBinary: Bool
    public let unavailableReason: String?
    public var isEditable: Bool { exists && text != nil && unavailableReason == nil }
}

public struct FileComparisonSnapshot: Sendable {
    public let path: String
    public let head, index, worktree: FileRevisionContent
    public let base, ours, theirs: FileRevisionContent?
    public var isConflict: Bool { base != nil || ours != nil || theirs != nil }
}

private let comparisonLimit = 2 * 1024 * 1024
private func missingContent() -> FileRevisionContent {
    FileRevisionContent(data: nil, text: nil, exists: false, isBinary: false, unavailableReason: nil)
}
private func decodeContent(_ data: Data, reason: String? = nil) -> FileRevisionContent {
    let decoded = ComparisonTextDecoder.decode(data)
    let binary = decoded.isBinary
    let text = decoded.text
    let mixedEndings = text.map { $0.contains("\r\n") && $0.replacingOccurrences(of: "\r\n", with: "").contains("\n") } ?? false
    return FileRevisionContent(data: data, text: text?.replacingOccurrences(of: "\r\n", with: "\n"), exists: true, isBinary: binary,
        unavailableReason: reason ?? (mixedEndings ? "Files with mixed line endings are read-only." : data.count > comparisonLimit ? "Files larger than 2 MB are read-only." : decoded.readOnlyReason))
}

extension GitRepository {
    private func comparisonURL(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !parts.contains(""), !parts.contains(where: { $0.lowercased() == ".git" }), !path.contains("\0") else { throw GitError("Invalid repository file path.") }
        var current = url
        for part in parts.dropLast() {
            current.appendPathComponent(String(part))
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw GitError("Paths through symbolic links cannot be compared or edited.") }
        }
        return url.appendingPathComponent(path)
    }
    private func diskContent(_ file: URL) throws -> FileRevisionContent {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) { return missingContent() }
            throw error
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: false, unavailableReason: "Symbolic links and non-regular files are read-only.")
        }
        if (attrs[.size] as? NSNumber)?.intValue ?? 0 > 32 * 1024 * 1024 {
            return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: false, unavailableReason: "Files larger than 2 MB are read-only.")
        }
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return decodeContent(try Data(contentsOf: file), reason: permissions & 0o222 == 0 ? "The file is read-only." : nil)
    }
    private func blobContent(_ oid: String, mode: String) async throws -> FileRevisionContent {
        if mode == "160000" || mode == "040000" { return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: false, unavailableReason: "Directories and submodules are read-only.") }
        let size = try await GitProcess.run(at: url, arguments: ["cat-file", "-s", oid])
        if (Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 32 * 1024 * 1024 {
            return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: false, unavailableReason: "Files larger than 2 MB are read-only.")
        }
        return decodeContent(try await GitProcess.run(at: url, arguments: ["cat-file", "blob", oid]).data, reason: mode == "120000" ? "Symbolic links are read-only." : mode == "160000" ? "Submodules are read-only." : nil)
    }
    public func fileComparison(path: String) async throws -> FileComparisonSnapshot {
        let file = try comparisonURL(path)
        let original = try await status().first(where: { $0.path == path })?.originalPath ?? path
        let headCheck = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
        var head = missingContent()
        if headCheck.code == 0 {
            let tree = try await GitProcess.run(at: url, arguments: ["ls-tree", "-z", "HEAD", "--", original])
            if let entry = tree.data.split(separator: 0).first, let tab = entry.firstIndex(of: 9) {
                let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
                if fields.count == 3 { head = try await blobContent(String(fields[2]), mode: String(fields[0])) }
            }
        }
        let listing = try await GitProcess.run(at: url, arguments: ["ls-files", "--stage", "-z", "--", path])
        var stages: [Int: FileRevisionContent] = [:]
        for entry in listing.data.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9), String(decoding: entry[entry.index(after: tab)...], as: UTF8.self) == path else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            if fields.count == 3, let stage = Int(fields[2]) { stages[stage] = try await blobContent(String(fields[1]), mode: String(fields[0])) }
        }
        return FileComparisonSnapshot(path: path, head: head, index: stages[0] ?? missingContent(), worktree: try diskContent(file), base: stages[1], ours: stages[2], theirs: stages[3])
    }
    private func checkedWorktree(_ path: String, expected: FileRevisionContent) throws -> (URL, FileRevisionContent) {
        let file = try comparisonURL(path), current = try diskContent(file)
        guard current.isEditable, expected.isEditable else { throw GitError(current.unavailableReason ?? "Only existing regular UTF-8 files can be edited.") }
        guard current.data == expected.data else { throw GitError("The file changed outside this comparison. Reload before saving or resolving.") }
        return (file, current)
    }
    public func saveWorktree(path: String, text: String, expected: FileRevisionContent) async throws -> FileRevisionContent {
        let (file, current) = try checkedWorktree(path, expected: expected)
        guard !text.contains("\0") else { throw GitError("Binary content cannot be saved by the text editor.") }
        let original = current.data ?? Data()
        let usesCRLF = String(data: original, encoding: .utf8)?.contains("\r\n") == true
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var data = Data((usesCRLF ? normalized.replacingOccurrences(of: "\n", with: "\r\n") : normalized).utf8)
        if original.starts(with: [0xef, 0xbb, 0xbf]) { data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0) }
        guard data.count <= comparisonLimit else { throw GitError("Files larger than 2 MB cannot be saved by the text editor.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try data.write(to: file, options: .atomic)
        if let mode = attrs[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        return try diskContent(file)
    }
    public func markResolved(path: String, expected: FileRevisionContent) async throws {
        let (_, current) = try checkedWorktree(path, expected: expected)
        let markers = current.text?.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix("<<<<<<<") || line.hasPrefix("|||||||") || line == "=======" || line.hasPrefix(">>>>>>>")
        } ?? false
        guard !markers else { throw GitError("Remove the conflict markers before marking this file resolved.") }
        _ = try await GitProcess.run(at: url, arguments: ["add", "--", path])
    }
}
