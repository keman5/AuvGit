import Foundation

public struct BlameLine: Identifiable, Sendable {
    public let hash: String
    public let author: String
    public let email: String
    public let date: Date
    public let originalLine: Int
    public let line: Int
    public let code: String
    public var id: Int { line }
}
public struct ReflogEntry: Identifiable, Sendable {
    public let id: Int
    public let hash: String
    public let selector: String
    public let author: String
    public let email: String
    public let date: Date
    public let action: String
}
public extension GitRepository {
    func blameLines(path: String, revision: String = "HEAD") async throws -> [BlameLine] {
        try workflowPath(path)
        let hash = try await workflowRevision(revision)
        return HistoryInspectionParser.blame(try await workflowRead(["blame", "--line-porcelain", hash, "--", path]))
    }
    func reflogEntries() async throws -> [ReflogEntry] {
        HistoryInspectionParser.reflog(try await workflowRead(["reflog", "--all", "--date=unix", "--format=%H%x00%gD%x00%gn%x00%ge%x00%gs"]))
    }
}
public enum HistoryInspectionParser {
    public static func blame(_ text: String) -> [BlameLine] {
        var result: [BlameLine] = []
        var hash = "", author = "", email = "", timestamp: Double = 0, original = 0, line = 0
        for entry in text.components(separatedBy: "\n") {
            if entry.hasPrefix("\t") { result.append(BlameLine(hash: hash, author: author, email: email, date: Date(timeIntervalSince1970: timestamp), originalLine: original, line: line, code: String(entry.dropFirst()))); continue }
            let fields = entry.split(separator: " ")
            if fields.count >= 3, fields[0].count == 40, fields[0].allSatisfy({ $0.isHexDigit }), let a = Int(fields[1]), let b = Int(fields[2]) { hash = String(fields[0]); original = a; line = b }
            else if entry.hasPrefix("author ") { author = String(entry.dropFirst(7)) }
            else if entry.hasPrefix("author-mail ") { email = String(entry.dropFirst(12)).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            else if entry.hasPrefix("author-time ") { timestamp = Double(entry.dropFirst(12)) ?? 0 }
        }
        return result
    }
    public static func reflog(_ text: String) -> [ReflogEntry] {
        text.split(separator: "\n").enumerated().compactMap { index, row in
            let fields = row.split(separator: "\0", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            let selector = fields[1]
            let timestamp = selector.lastIndex(of: "{").flatMap { Double(selector[selector.index(after: $0)...].dropLast()) } ?? 0
            return ReflogEntry(id: index, hash: fields[0], selector: selector, author: fields[2], email: fields[3], date: Date(timeIntervalSince1970: timestamp), action: fields[4])
        }
    }
}
