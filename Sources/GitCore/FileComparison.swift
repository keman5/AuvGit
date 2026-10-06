import Foundation

public struct FileRevisionContent: Sendable {
    public let data: Data?
    public let text: String?
    public let exists: Bool
    public let isBinary: Bool
    public let unavailableReason: String?
    public var gitMode: String? = nil
    public var objectID: String? = nil
    public var byteCount: Int? = nil
    public var canStreamText: Bool = false
    public var characterCount: Int? { text?.count }
    public var exceedsPreviewLimit: Bool { exists && data == nil && (byteCount ?? 0) > FileComparisonLimits.previewBytes }
    public var isEditable: Bool { exists && text != nil && unavailableReason == nil }
}

public struct FileComparisonSnapshot: Sendable {
    public let path: String
    public let head, index, worktree: FileRevisionContent
    public let base, ours, theirs: FileRevisionContent?
    public var status: GitFile? = nil
    public var previewTarget: DiffTarget? = nil
    public var isConflict: Bool { status?.isConflict == true || base != nil || ours != nil || theirs != nil }
    public var requiresStaticPreview: Bool { ["svg", "pdf"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) || [head, index, worktree, base, ours, theirs].compactMap { $0 }.contains { $0.isBinary || $0.exceedsPreviewLimit || ($0.data != nil && $0.text == nil) } }
}

public extension FileComparisonSnapshot {
    /// Maps a full editor snapshot to the index → worktree display patch.
    func worktreeDisplayPatch(fallingBackFrom patch: String, ignoreWhitespace: Bool = false) async throws -> String {
        guard !isConflict else { return patch }
        let preview = FileComparisonSnapshot(path: path, head: index, index: index, worktree: worktree,
                                             base: nil, ours: nil, theirs: nil,
                                             previewTarget: .worktree(path: path, untracked: !index.exists))
        return try await preview.displayPatch(fallingBackFrom: patch, ignoreWhitespace: ignoreWhitespace)
    }
    /// Display-only UTF-8 patch for decoded text that Git classified as binary (e.g. UTF-16).
    /// Never used for staging: original byte snapshots and fresh apply checks remain intact.
    func displayPatch(fallingBackFrom patch: String, ignoreWhitespace: Bool = false) async throws -> String {
        guard !requiresStaticPreview, previewTarget != nil,
              !head.isBinary, !worktree.isBinary,
              !head.exists || head.text != nil, !worktree.exists || worktree.text != nil,
              (patch.contains("Binary files ") || patch.contains("GIT binary patch")),
              DiffParser.parse(patch).isBinary else { return patch }
        return try await LargeTextComparison.patch(source: head.text ?? "", target: worktree.text ?? "", ignoreWhitespace: ignoreWhitespace)
    }
}

public enum FileComparisonLimits { public static let previewBytes = 32 * 1024 * 1024 }
private func hasUTF8TextPrefix(_ data: Data) -> Bool {
    guard !data.contains(0) else { return false }
    for trim in 0...min(3, data.count) {
        if ComparisonTextDecoder.decode(Data(data.dropLast(trim))).text != nil { return true }
    }
    return data.isEmpty
}

private let comparisonLimit = 2 * 1024 * 1024
private func missingContent() -> FileRevisionContent {
    FileRevisionContent(data: nil, text: nil, exists: false, isBinary: false, unavailableReason: nil)
}
private func decodeContent(_ data: Data, reason: String? = nil) -> FileRevisionContent {
    let decoded = ComparisonTextDecoder.decode(data)
    let binary = decoded.isBinary
    let text = decoded.text
    var hasCRLF = false, hasLF = false, hasCR = false, previousCR = false
    if let text {
        for byte in text.utf8 {
            if previousCR { if byte == 10 { hasCRLF = true } else { hasCR = true } }
            if byte == 10 && !previousCR { hasLF = true }
            previousCR = byte == 13
        }
        if previousCR { hasCR = true }
    }
    let mixedEndings = [hasCRLF, hasLF, hasCR].filter { $0 }.count > 1
    let normalized = (hasCRLF || hasCR) ? text?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
    return FileRevisionContent(data: data, text: normalized, exists: true, isBinary: binary,
        unavailableReason: reason ?? (mixedEndings ? "Files with mixed line endings are read-only." : data.count > comparisonLimit ? "Files larger than 2 MB are read-only." : decoded.readOnlyReason), byteCount: data.count)
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
        let byteCount = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if byteCount > FileComparisonLimits.previewBytes {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let sample = try handle.read(upToCount: 4096) ?? Data()
            let streamable = hasUTF8TextPrefix(sample)
            return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: !streamable, unavailableReason: "File exceeds preview limit.", byteCount: byteCount, canStreamText: streamable)
        }
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: FileComparisonLimits.previewBytes + 1) ?? Data()
        guard data.count <= FileComparisonLimits.previewBytes else {
            return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: !hasUTF8TextPrefix(Data(data.prefix(4096))), unavailableReason: "File exceeds preview limit.", byteCount: max(byteCount, data.count), canStreamText: hasUTF8TextPrefix(Data(data.prefix(4096))))
        }
        var content = decodeContent(data, reason: permissions & 0o222 == 0 ? "The file is read-only." : nil)
        content.gitMode = permissions & 0o111 != 0 ? "100755" : "100644"
        return content
    }
    private nonisolated func blobContent(_ oid: String, mode: String) async throws -> FileRevisionContent {
        if mode == "160000" || mode == "040000" { return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: false, unavailableReason: "Directories and submodules are read-only.", gitMode: mode, objectID: oid) }
        let size = try await GitProcess.run(at: url, arguments: ["cat-file", "-s", oid])
        let byteCount = Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if byteCount > FileComparisonLimits.previewBytes {
            let sample = try await blobPrefix(oid)
            let streamable = hasUTF8TextPrefix(sample)
            return FileRevisionContent(data: nil, text: nil, exists: true, isBinary: !streamable, unavailableReason: "File exceeds preview limit.", gitMode: mode, objectID: oid, byteCount: byteCount, canStreamText: streamable)
        }
        var content = decodeContent(try await GitProcess.run(at: url, arguments: ["cat-file", "blob", oid]).data, reason: mode == "120000" ? "Symbolic links are read-only." : mode == "160000" ? "Submodules are read-only." : nil)
        content.gitMode = mode; content.objectID = oid
        return content
    }
    private nonisolated func blobPrefix(_ oid: String) async throws -> Data {
        return try await GitCommandLog.$suppressRoutineReads.withValue(true) {
            try await GitProcess.run(at: url, arguments: ["cat-file", "blob", oid], timeout: 5, outputPrefixBytes: 4096).data
        }
    }
    public func fileComparison(path: String) async throws -> FileComparisonSnapshot {
        let file = try comparisonURL(path)
        async let statusRead = status()
        async let headRead = GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
        async let indexRead = GitProcess.run(at: url, arguments: ["ls-files", "--stage", "-z", "--", path])
        let fileStatus = try await statusRead.first(where: { $0.path == path })
        let original = fileStatus?.originalPath ?? path
        let headCheck = try await headRead
        var versions: [Int: (oid: String, mode: String)] = [:]
        if headCheck.code == 0 {
            let tree = try await GitProcess.run(at: url, arguments: ["ls-tree", "-z", headCheck.text.trimmingCharacters(in: .whitespacesAndNewlines), "--", original])
            if let entry = tree.data.split(separator: 0).first, let tab = entry.firstIndex(of: 9) {
                let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
                if fields.count == 3 { versions[-1] = (String(fields[2]), String(fields[0])) }
            }
        }
        let listing = try await indexRead
        for entry in listing.data.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9), String(decoding: entry[entry.index(after: tab)...], as: UTF8.self) == path else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            if fields.count == 3, let stage = Int(fields[2]) { versions[stage] = (String(fields[1]), String(fields[0])) }
        }
        // HEAD and index commonly point at the same immutable blob. Read/decode it once.
        let unique = Dictionary(versions.values.map { ($0.mode + ":" + $0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        let content = try await withThrowingTaskGroup(of: (String, FileRevisionContent).self) { group in
            for (key, version) in unique { group.addTask { (key, try await self.blobContent(version.oid, mode: version.mode)) } }
            var result: [String: FileRevisionContent] = [:]
            for try await (key, value) in group { result[key] = value }
            return result
        }
        func revision(_ stage: Int) -> FileRevisionContent? { versions[stage].flatMap { content[$0.mode + ":" + $0.oid] } }
        return FileComparisonSnapshot(path: path, head: revision(-1) ?? missingContent(), index: revision(0) ?? missingContent(), worktree: try diskContent(file), base: revision(1), ours: revision(2), theirs: revision(3), status: fileStatus)
    }

    public func comparisonPreview(target: DiffTarget) async throws -> FileComparisonSnapshot {
        switch target {
        case let .worktree(path, _):
            let file = try comparisonURL(path)
            let original = try await indexComparisonContent(path: path)
            return FileComparisonSnapshot(path: path, head: original, index: original, worktree: try diskContent(file), base: nil, ours: nil, theirs: nil, previewTarget: target)
        case let .staged(path):
            _ = try comparisonURL(path)
            let original = try await status().first(where: { $0.path == path })?.originalPath ?? path
            let headCheck = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
            let left = headCheck.code == 0 ? try await treeComparisonContent(revision: "HEAD", path: original) : missingContent()
            let right = try await indexComparisonContent(path: path)
            return FileComparisonSnapshot(path: path, head: left, index: left, worktree: right, base: nil, ours: nil, theirs: nil, previewTarget: target)
        case let .commit(hash, path):
            _ = try comparisonURL(path)
            let revision = try await workflowRevision(hash)
            let parent = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", revision + "^"], allowedCodes: [0, 128])
            let original = try await commitFiles(hash: revision).first(where: { $0.path == path })?.originalPath ?? path
            let left = parent.code == 0 ? try await treeComparisonContent(revision: parent.text.trimmingCharacters(in: .whitespacesAndNewlines), path: original) : missingContent()
            let right = try await treeComparisonContent(revision: revision, path: path)
            return FileComparisonSnapshot(path: path, head: left, index: left, worktree: right, base: nil, ours: nil, theirs: nil, previewTarget: target)
        }
    }
    private func indexComparisonContent(path: String) async throws -> FileRevisionContent {
        let listing = try await GitProcess.run(at: url, arguments: ["ls-files", "--stage", "-z", "--", path])
        for entry in listing.data.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9) else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            if fields.count == 3, fields[2] == "0" { return try await blobContent(String(fields[1]), mode: String(fields[0])) }
        }
        return missingContent()
    }
    private func treeComparisonContent(revision: String, path: String) async throws -> FileRevisionContent {
        let tree = try await GitProcess.run(at: url, arguments: ["ls-tree", "-z", revision, "--", path])
        guard let entry = tree.data.split(separator: 0).first, let tab = entry.firstIndex(of: 9) else { return missingContent() }
        let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 3 else { return missingContent() }
        return try await blobContent(String(fields[2]), mode: String(fields[0]))
    }
    private func checkedWorktree(_ path: String, expected: FileRevisionContent, encoding: ComparisonEncoding? = nil) throws -> (URL, FileRevisionContent) {
        let file = try comparisonURL(path), current = try diskContent(file)
        let explicitlyDecoded = encoding.flatMap { selected in current.data.flatMap { ComparisonTextDecoder.decode($0, as: selected) } }
        guard (current.isEditable && expected.isEditable) || (encoding != nil && explicitlyDecoded != nil && current.data != nil && !current.isBinary && current.gitMode?.hasPrefix("100") == true && current.unavailableReason != "The file is read-only." && current.data!.count <= comparisonLimit) else { throw GitError(current.unavailableReason ?? "Only existing regular UTF-8 files can be edited.") }
        guard current.data == expected.data else { throw GitError("The file changed outside this comparison. Reload before saving or resolving.") }
        return (file, current)
    }
    public func saveWorktree(path: String, text: String, expected: FileRevisionContent, format: ComparisonTextFormat? = nil) async throws -> FileRevisionContent {
        let (file, current) = try checkedWorktree(path, expected: expected, encoding: format?.encoding)
        guard !text.contains("\0") else { throw GitError("Binary content cannot be saved by the text editor.") }
        let data = try ComparisonTextDecoder.encode(text, format: format ?? ComparisonTextDecoder.format(of: current.data ?? Data()))
        guard data.count <= comparisonLimit else { throw GitError("Files larger than 2 MB cannot be saved by the text editor.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try data.write(to: file, options: .atomic)
        if let mode = attrs[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        let saved = try diskContent(file)
        return format.map { saved.reinterpreting(as: $0.encoding) } ?? saved
    }
    public func markResolved(path: String, expected: FileRevisionContent, encoding: ComparisonEncoding? = nil) async throws {
        let (_, raw) = try checkedWorktree(path, expected: expected, encoding: encoding)
        let current = encoding.map { raw.reinterpreting(as: $0) } ?? raw
        let markers = current.text.map { ConflictDraft.hasConflictMarkers(in: $0) } ?? false
        guard !markers else { throw GitError("Remove the conflict markers before marking this file resolved.") }
        _ = try await GitProcess.run(at: url, arguments: ["add", "--", path])
    }
}

extension GitRepository {
    public func convertWorktree(path: String, text: String, format: ComparisonTextFormat, expected: FileRevisionContent) async throws -> FileRevisionContent {
        let file = try comparisonURL(path), current = try diskContent(file)
        guard current.exists, !current.isBinary, current.data == expected.data, current.data != nil, current.unavailableReason != "The file is read-only." else { throw GitError("The file changed or cannot be converted. Reload before continuing.") }
        let data = try ComparisonTextDecoder.encode(text, format: format)
        guard data.count <= comparisonLimit else { throw GitError("Files larger than 2 MB cannot be saved by the text editor.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try data.write(to: file, options: .atomic)
        if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        return try diskContent(file).reinterpreting(as: format.encoding)
    }
    /// Restores a missing regular file or chooses a conflict revision, after validating every snapshot stage.
    public func restoreComparedVersion(path: String, source: FileRevisionContent, expected: FileComparisonSnapshot, resolve: Bool) async throws {
        let current = try await fileComparison(path: path)
        guard comparisonIdentity(current.worktree, expected.worktree), comparisonIdentity(current.head, expected.head), comparisonIdentity(current.index, expected.index), comparisonIdentity(current.base, expected.base), comparisonIdentity(current.ours, expected.ours), comparisonIdentity(current.theirs, expected.theirs) else { throw GitError("The file or conflict changed. Reload before continuing.") }
        let file = try comparisonURL(path)
        guard !current.worktree.exists || current.worktree.data != nil, source.exists, let data = source.data, source.gitMode?.hasPrefix("100") == true else { throw GitError("Only a regular file revision can be restored.") }
        if resolve, let text = source.text, ConflictDraft.hasConflictMarkers(in: text) { throw GitError("Remove the conflict markers before marking this file resolved.") }
        let mode = source.gitMode == "100755" ? 0o755 : 0o644
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        if resolve { _ = try await GitProcess.run(at: url, arguments: ["add", "--", path]) }
    }
    public func deleteComparedFile(path: String, expected: FileComparisonSnapshot, resolve: Bool) async throws {
        let current = try await fileComparison(path: path)
        guard comparisonIdentity(current.worktree, expected.worktree), comparisonIdentity(current.head, expected.head), comparisonIdentity(current.index, expected.index), comparisonIdentity(current.base, expected.base), comparisonIdentity(current.ours, expected.ours), comparisonIdentity(current.theirs, expected.theirs) else { throw GitError("The file or conflict changed. Reload before continuing.") }
        let file = try comparisonURL(path)
        guard !current.worktree.exists || current.worktree.data != nil else { throw GitError("Only regular files can be removed by this comparison.") }
        if current.worktree.exists { try FileManager.default.removeItem(at: file) }
        if resolve { _ = try await GitProcess.run(at: url, arguments: ["add", "--", path]) }
    }
}

private func comparisonIdentity(_ a: FileRevisionContent?, _ b: FileRevisionContent?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.exists == b.exists && a.data == b.data && a.gitMode == b.gitMode && a.objectID == b.objectID
}
extension FileRevisionContent {
    public func reinterpreting(as encoding: ComparisonEncoding) -> FileRevisionContent {
        guard let data, !isBinary, let text = ComparisonTextDecoder.decode(data, as: encoding) else { return self }
        let reason = ["Unknown text encoding is read-only.", "Invalid UTF-16 text is read-only."].contains(unavailableReason ?? "") ? nil : unavailableReason
        return FileRevisionContent(data: data, text: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), exists: exists, isBinary: false, unavailableReason: reason, gitMode: gitMode, objectID: objectID)
    }
}
