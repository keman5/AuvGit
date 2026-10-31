import Foundation
import GitCore

/// Captured on the main actor; archive reads and formatting happen on the loader actor.
struct OperationLogSnapshot: Sendable {
    let records: [GitCommandRecord]
    let exitLabel: String
    let expiredMessage: String
    let captureLimitMessage: String
    var identity: [UUID] { records.map(\.id) }
}

struct OperationLogContent: Sendable {
    let text: String
    let pages: [String]
    let complete: Bool

    static func pages(for text: String, limit: Int = 32_768) -> [String] {
        precondition(limit > 0)
        var pages: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            pages.append(String(text[start..<end]))
            start = end
        }
        return pages.isEmpty ? [""] : pages
    }
}

struct OperationLogPreview: Sendable {
    let text: String
    let truncated: Bool
    let fullOutputAvailable: Bool
}

actor OperationLogContentLoader {
    static let shared = OperationLogContentLoader()
    private var cache: [String: OperationLogContent] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let budget = 8 * 1024 * 1024

    /// Bound the combined operation preview, not just each child command.
    func preview(_ snapshot: OperationLogSnapshot, limit: Int = 32_768) throws -> OperationLogPreview {
        precondition(limit > 0)
        var text = "", remaining = limit
        var truncated = snapshot.records.contains(where: \.previewTruncated)
        for record in snapshot.records {
            try Task.checkCancellation()
            var parts = [record.date.formatted(), record.operation, record.directory, record.command]
            if let code = record.exitCode { parts.append(snapshot.exitLabel + ": \(code)") }
            if !record.output.isEmpty { parts.append(record.output) }
            if let error = record.error { parts.append(error) }
            if record.error?.contains("32 MB display limit") == true { parts.append(snapshot.captureLimitMessage) }
            for part in parts {
                let value = text.isEmpty ? part : "\n" + part
                let end = value.index(value.startIndex, offsetBy: remaining, limitedBy: value.endIndex) ?? value.endIndex
                let fragment = value[..<end]
                text.append(contentsOf: fragment)
                remaining -= fragment.count
                if end != value.endIndex { truncated = true }
            }
            if remaining == 0 { truncated = true; break }
        }
        return OperationLogPreview(text: text, truncated: truncated,
            fullOutputAvailable: snapshot.records.allSatisfy(\.fullOutputAvailable))
    }

    func load(_ snapshot: OperationLogSnapshot) throws -> OperationLogContent {
        try Task.checkCancellation()
        let key = snapshot.identity.map(\.uuidString).joined(separator: ",") + snapshot.exitLabel + snapshot.expiredMessage + snapshot.captureLimitMessage
        // Availability is checked even for cached content so expired archives cannot be exported.
        let available = snapshot.records.allSatisfy(\.fullOutputAvailable)
        if available, let cached = cache[key] { return cached }
        var lines: [String] = []
        var complete = true
        for record in snapshot.records {
            try Task.checkCancellation()
            let contents = record.fullContents()
            complete = complete && contents.complete
            lines.append(contentsOf: [record.date.formatted(), record.operation, record.directory, record.command])
            if let code = record.exitCode { lines.append(snapshot.exitLabel + ": \(code)") }
            if !contents.output.isEmpty { lines.append(contents.output) }
            if let error = contents.error { lines.append(error) }
            if !contents.complete { lines.append(snapshot.expiredMessage) }
            if record.error?.contains("32 MB display limit") == true { lines.append(snapshot.captureLimitMessage) }
        }
        try Task.checkCancellation()
        let text = lines.joined(separator: "\n")
        let result = OperationLogContent(text: text, pages: OperationLogContent.pages(for: text), complete: complete)
        // Pages retain their own storage as well as the complete copy/export text.
        let cost = text.utf8.count * 2
        if complete && cost <= budget {
            while bytes + cost > budget || order.count >= 4 {
                let oldest = order.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { bytes -= removed.text.utf8.count * 2 }
            }
            cache[key] = result; order.append(key); bytes += cost
        }
        return result
    }
}
