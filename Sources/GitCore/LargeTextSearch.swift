import Foundation

public struct LargeTextSearchOptions: Sendable {
    public let query: String
    public let caseSensitive: Bool
    public let regularExpression: Bool
    public init(query: String, caseSensitive: Bool = false, regularExpression: Bool = false) {
        self.query = query; self.caseSensitive = caseSensitive; self.regularExpression = regularExpression
    }
}
public struct LargeTextSearchHit: Sendable {
    public let cursor: StreamingCursor
    public let range: NSRange
    public let matchOffset: UInt64
    public let matchByteLength: Int
    public func pageLocation(maximumUTF16: Int = Int.max, maximumBytes: Int = Int.max) -> LargeTextSearchLocation {
        let fitsCharacters = NSMaxRange(range) <= maximumUTF16
        let fitsBytes = matchOffset - cursor.offset + UInt64(matchByteLength) <= UInt64(maximumBytes)
        if fitsCharacters && fitsBytes { return LargeTextSearchLocation(cursor: cursor, range: range, firstColumn: 1) }
        return LargeTextSearchLocation(cursor: StreamingCursor(offset: matchOffset, line: cursor.line), range: NSRange(location: 0, length: range.length), firstColumn: range.location + 1)
    }
}
public struct LargeTextSearchLocation: Sendable {
    public let cursor: StreamingCursor
    public let range: NSRange
    public let firstColumn: Int
}
public struct LargeTextSearchResult: Sendable {
    public let hits: [LargeTextSearchHit]
    public let isLimited: Bool
}
/// UTF-8 search is line-oriented, with explicit resource limits instead of silent omissions.
public enum LargeTextSearch {
    public static let maximumLineBytes = 1024 * 1024
    public static let maximumMatches = 10_000
    public static func file(_ url: URL, options: LargeTextSearchOptions) async throws -> LargeTextSearchResult {
        let task = Task.detached { try scanFile(url, options: options) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public static func text(_ value: String, options: LargeTextSearchOptions) async throws -> LargeTextSearchResult {
        let task = Task.detached { () throws -> LargeTextSearchResult in
            let scanner = try Scanner(options)
            let source = value as NSString
            var offset = 0, byteOffset: UInt64 = 0, line = 1
            while offset < source.length {
                try Task.checkCancellation()
                let range = source.lineRange(for: NSRange(location: offset, length: 0))
                let content = source.substring(with: range)
                if try scanner.append(content, cursor: StreamingCursor(offset: byteOffset, line: line)) { return scanner.result(limited: true) }
                byteOffset += UInt64(content.utf8.count); line += 1; offset = NSMaxRange(range)
            }
            return scanner.result(limited: false)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func scanFile(_ url: URL, options: LargeTextSearchOptions) throws -> LargeTextSearchResult {
        let scanner = try Scanner(options)
        if options.query.isEmpty { return scanner.result(limited: false) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data(), offset: UInt64 = 0, line = 1, firstChunk = true
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            if firstChunk { firstChunk = false; if pending.starts(with: [0xef, 0xbb, 0xbf]) { pending.removeFirst(3); offset = 3 } }
            var consumed = pending.startIndex
            while consumed < pending.endIndex, let newline = pending[consumed...].firstIndex(of: 10) {
                try Task.checkCancellation()
                let end = pending.index(after: newline)
                let bytes = pending[consumed..<end]
                guard let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) else { throw GitError("Streaming search requires valid UTF-8 text.") }
                if try scanner.append(text, cursor: StreamingCursor(offset: offset, line: line)) { return scanner.result(limited: true) }
                offset += UInt64(bytes.count); line += 1; consumed = end
            }
            pending.removeSubrange(pending.startIndex..<consumed)
            if pending.count > maximumLineBytes { throw GitError("Streaming search cannot scan a line larger than 1 MiB.") }
        }
        if !pending.isEmpty {
            guard let text = String(data: pending, encoding: .utf8), !pending.contains(0) else { throw GitError("Streaming search requires valid UTF-8 text.") }
            if try scanner.append(text, cursor: StreamingCursor(offset: offset, line: line)) { return scanner.result(limited: true) }
        }
        return scanner.result(limited: false)
    }
    private final class Scanner {
        let expression: NSRegularExpression?
        var hits: [LargeTextSearchHit] = []
        init(_ options: LargeTextSearchOptions) throws {
            guard !options.query.isEmpty else { expression = nil; return }
            let pattern = options.regularExpression ? options.query : NSRegularExpression.escapedPattern(for: options.query)
            expression = try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        }
        func append(_ value: String, cursor: StreamingCursor) throws -> Bool {
            try Task.checkCancellation()
            guard value.utf8.count <= maximumLineBytes else { throw GitError("Streaming search cannot scan a line larger than 1 MiB.") }
            guard let expression else { return false }
            let text = value.hasSuffix("\r\n") ? String(value.dropLast(2)) : value.hasSuffix("\n") ? String(value.dropLast()) : value
            var limited = false
            expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: text.utf16.count)) { match, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard let match else { return }
                if self.hits.count == LargeTextSearch.maximumMatches { limited = true; stop.pointee = true; return }
                let prefix = (text as NSString).substring(to: match.range.location)
                let matchBytes = (text as NSString).substring(with: match.range).utf8.count
                self.hits.append(LargeTextSearchHit(cursor: cursor, range: match.range, matchOffset: cursor.offset + UInt64(prefix.utf8.count), matchByteLength: matchBytes))
            }
            try Task.checkCancellation()
            return limited
        }
        func result(limited: Bool) -> LargeTextSearchResult { LargeTextSearchResult(hits: hits, isLimited: limited) }
    }
}

public enum LargeTextComparison {
    public static func patch(source: String, target: String, ignoreWhitespace: Bool = false) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-large-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Task.detached {
            try Task.checkCancellation(); try Data(source.utf8).write(to: directory.appendingPathComponent("original"))
            try Task.checkCancellation(); try Data(target.utf8).write(to: directory.appendingPathComponent("modified"))
        }
        try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
        return try await GitProcess.run(at: directory, arguments: ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color"] + (ignoreWhitespace ? ["--ignore-all-space"] : []) + ["--", "original", "modified"], allowedCodes: [0, 1]).text
    }
}
