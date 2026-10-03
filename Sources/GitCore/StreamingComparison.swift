import Foundation
import Darwin

public struct StreamingCursor: Equatable, Sendable {
    public let offset: UInt64
    public let line: Int
    public static let start = StreamingCursor(offset: 0, line: 1)
    public init(offset: UInt64, line: Int) { self.offset = offset; self.line = line }
}
public struct StreamingTextPage: Sendable {
    public let text: String
    public let cursor: StreamingCursor
    public let next: StreamingCursor?
    public let totalBytes: UInt64
}
/// A bounded UTF-8 reader. The open descriptor and path metadata must still match the original snapshot.
public actor StreamingTextFile {
    private let url: URL
    private let handle: FileHandle
    private let size: UInt64
    private let modified: Date
    private let inode: UInt64
    private let temporaryDirectory: URL?
    public init(url: URL, temporaryDirectory: URL? = nil) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date,
              let inode = attrs[.systemFileNumber] as? NSNumber else { throw GitError("Only regular files can be streamed.") }
        self.temporaryDirectory = temporaryDirectory
        self.url = url; self.size = size.uint64Value; self.modified = modified; self.inode = inode.uint64Value
        handle = try FileHandle(forReadingFrom: url)
        var descriptor = stat()
        guard fstat(handle.fileDescriptor, &descriptor) == 0, UInt64(descriptor.st_ino) == self.inode, UInt64(descriptor.st_size) == self.size else {
            try? handle.close()
            throw GitError("The file changed while opening the streaming viewer. Reload before continuing.")
        }
    }
    deinit { try? handle.close(); if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
    private func checkSnapshot() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.uint64Value == size,
              attrs[.modificationDate] as? Date == modified,
              (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == inode else {
            throw GitError("The file changed while streaming. Reload the comparison before continuing.")
        }
    }
    public func page(at cursor: StreamingCursor = .start, maximumBytes: Int = 128 * 1024, maximumLines: Int = 500) throws -> StreamingTextPage {
        try checkSnapshot()
        guard cursor.offset <= size else { throw GitError("Invalid streaming page offset.") }
        var offset = cursor.offset
        let cap = min(max(maximumBytes, 4), 1024 * 1024)
        try handle.seek(toOffset: offset)
        var bytes = try handle.read(upToCount: cap + 4) ?? Data()
        if offset == 0 {
            if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { throw GitError("Streaming currently supports UTF-8 text only. UTF-16 files above 32 MB require an external viewer.") }
            if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3); offset += 3 }
        }
        guard !bytes.contains(0) else { throw GitError("Binary content cannot be displayed as streaming text.") }
        var length = min(cap, bytes.count), lineCount = 0
        for (index, byte) in bytes.prefix(length).enumerated() where byte == 10 {
            lineCount += 1
            if lineCount >= max(1, maximumLines) { length = index + 1; break }
        }
        var text: String?
        // A page boundary can fall inside a multi-byte scalar; retry only the trailing 1–3 bytes.
        for trim in 0...3 where length >= trim {
            if let value = String(data: bytes.prefix(length - trim), encoding: .utf8) { length -= trim; text = value; break }
        }
        guard let text, length > 0 || bytes.isEmpty else { throw GitError("Unknown or invalid text encoding; streaming supports UTF-8 only.") }
        let consumed = offset + UInt64(length)
        let nextLine = cursor.line + bytes.prefix(length).filter { $0 == 10 }.count
        try checkSnapshot()
        return StreamingTextPage(text: text, cursor: cursor, next: consumed < size ? StreamingCursor(offset: consumed, line: nextLine) : nil, totalBytes: size)
    }
}
extension GitRepository {
    public func streamingWorktree(path: String) throws -> StreamingTextFile {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }) else { throw GitError("Invalid repository file path.") }
        var file = url
        for part in parts {
            file.appendPathComponent(String(part))
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw GitError("Paths through symbolic links cannot be streamed.") }
        }
        return try StreamingTextFile(url: file)
    }
}

public enum StreamingRevision: String, CaseIterable, Sendable { case worktree, head, index, base, ours, theirs }
extension GitRepository {
    private func streamingBlob(path: String, revision: StreamingRevision) async throws -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }) else { throw GitError("Invalid repository file path.") }
        let listing: GitOutput
        if revision == .head {
            let head = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "HEAD"], allowedCodes: [0, 128])
            if head.code != 0 { return nil }
            let original = try await status().first(where: { $0.path == path })?.originalPath ?? path
            listing = try await GitProcess.run(at: url, arguments: ["ls-tree", "-z", "HEAD", "--", original])
        } else { listing = try await GitProcess.run(at: url, arguments: ["ls-files", "--stage", "-z", "--", path]) }
        let stage = revision == .base ? "1" : revision == .ours ? "2" : revision == .theirs ? "3" : "0"
        for entry in listing.data.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9) else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3 else { continue }
            if revision != .head && fields[2] != stage { continue }
            guard fields[0] == "100644" || fields[0] == "100755" else { throw GitError("Only regular text blobs can be streamed.") }
            let oid = String(revision == .head ? fields[2] : fields[1])
            guard [40, 64].contains(oid.count), oid.allSatisfy({ $0.isHexDigit }) else { throw GitError("Invalid blob identifier.") }
            return oid
        }
        return nil
    }
    public func availableStreamingRevisions(path: String) async throws -> [StreamingRevision] {
        var revisions: [StreamingRevision] = []
        if (try? streamingWorktree(path: path)) != nil { revisions.append(.worktree) }
        for revision in [StreamingRevision.head, .index, .base, .ours, .theirs] {
            if try await streamingBlob(path: path, revision: revision) != nil { revisions.append(revision) }
        }
        return revisions
    }
    public func streamingContent(path: String, revision: StreamingRevision) async throws -> StreamingTextFile {
        if revision == .worktree { return try streamingWorktree(path: path) }
        guard let oid = try await streamingBlob(path: path, revision: revision) else { throw GitError("This revision has no file content.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent("blob")
            // Immutable OID, direct file descriptor stdout: no 32 MB in-memory capture.
            try await GitProcess.runToFile(at: url, arguments: ["cat-file", "blob", oid], outputFile: file)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            return try StreamingTextFile(url: file, temporaryDirectory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
