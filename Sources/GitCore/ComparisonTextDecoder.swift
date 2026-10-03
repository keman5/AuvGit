import Foundation

public struct DecodedComparisonText: Sendable {
    public let text: String?
    public let isBinary: Bool
    public let readOnlyReason: String?
}
public enum ComparisonTextDecoder {
    public static func decode(_ data: Data) -> DecodedComparisonText {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            let encoding: String.Encoding = data.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian : .utf16BigEndian
            let text = String(data: data.dropFirst(2), encoding: encoding)
            return DecodedComparisonText(text: text, isBinary: text == nil, readOnlyReason: "UTF-16 text is read-only; saving requires an explicit encoding conversion.")
        }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
        let binary = bytes.contains(0)
        let text = binary ? nil : String(data: bytes, encoding: .utf8)
        return DecodedComparisonText(text: text, isBinary: binary, readOnlyReason: binary ? "Binary files are read-only." : text == nil ? "Unknown text encoding is read-only." : nil)
    }
}

public struct TextPage: Sendable {
    public let text: String
    public let firstLine: Int
    public let hasNext: Bool
}
public enum TextPager {
    /// Scans UTF-16 line boundaries without allocating an array for every line of the file.
    public static func page(_ text: String, index: Int, linesPerPage: Int = 500) -> TextPage {
        let ns = text as NSString
        let pageSize = max(1, linesPerPage), startLine = max(0, index) * pageSize
        var position = 0, line = 0, start = 0
        while position < ns.length, line < startLine {
            let range = ns.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(range); line += 1
        }
        start = position
        while position < ns.length, line < startLine + pageSize {
            position = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0))); line += 1
        }
        return TextPage(text: ns.substring(with: NSRange(location: start, length: position - start)), firstLine: startLine + 1, hasNext: position < ns.length)
    }
}
