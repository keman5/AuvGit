import Foundation

public enum ComparisonEncoding: String, CaseIterable, Sendable { case utf8, utf8BOM, utf16LE, utf16BE, latin1 }
public enum ComparisonLineEnding: String, CaseIterable, Sendable { case lf, crlf, cr }
public struct ComparisonTextFormat: Equatable, Sendable {
    public let encoding: ComparisonEncoding
    public let lineEnding: ComparisonLineEnding
    public init(encoding: ComparisonEncoding, lineEnding: ComparisonLineEnding) { self.encoding = encoding; self.lineEnding = lineEnding }
}
public struct DecodedComparisonText: Sendable {
    public let text: String?
    public let isBinary: Bool
    public let readOnlyReason: String?
}
public enum ComparisonTextDecoder {
    public static func format(of data: Data, encoding selectedEncoding: ComparisonEncoding? = nil) -> ComparisonTextFormat {
        let encoding: ComparisonEncoding = selectedEncoding ?? (data.starts(with: [0xff, 0xfe]) ? .utf16LE : data.starts(with: [0xfe, 0xff]) ? .utf16BE : data.starts(with: [0xef, 0xbb, 0xbf]) ? .utf8BOM : .utf8)
        let text = selectedEncoding.flatMap { decode(data, as: $0) } ?? decode(data).text ?? ""
        let ending: ComparisonLineEnding = text.contains("\r\n") ? .crlf : text.contains("\r") ? .cr : .lf
        return ComparisonTextFormat(encoding: encoding, lineEnding: ending)
    }
    public static func decode(_ data: Data, as encoding: ComparisonEncoding) -> String? {
        guard !data.contains(0) || encoding == .utf16LE || encoding == .utf16BE else { return nil }
        let bytes = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? Data(data.dropFirst(2)) : data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
        if encoding == .utf16LE || encoding == .utf16BE {
            guard bytes.count % 2 == 0 else { return nil }
            let values = Array(bytes)
            var index = 0
            func unit(_ index: Int) -> UInt16 { encoding == .utf16LE ? UInt16(values[index]) | UInt16(values[index + 1]) << 8 : UInt16(values[index]) << 8 | UInt16(values[index + 1]) }
            while index < values.count {
                let value = unit(index)
                if (0xD800...0xDBFF).contains(value) {
                    guard index + 3 < values.count, (0xDC00...0xDFFF).contains(unit(index + 2)) else { return nil }
                    index += 4
                } else {
                    guard !(0xDC00...0xDFFF).contains(value) else { return nil }
                    index += 2
                }
            }
        }
        let swiftEncoding: String.Encoding = encoding == .utf16LE ? .utf16LittleEndian : encoding == .utf16BE ? .utf16BigEndian : encoding == .latin1 ? .isoLatin1 : .utf8
        guard let text = String(data: bytes, encoding: swiftEncoding), !text.contains("\0") else { return nil }
        return text
    }
    public static func encode(_ text: String, format: ComparisonTextFormat) throws -> Data {
        guard !text.contains("\0") else { throw GitError("Binary content cannot be saved by the text editor.") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let value = format.lineEnding == .crlf ? normalized.replacingOccurrences(of: "\n", with: "\r\n") : format.lineEnding == .cr ? normalized.replacingOccurrences(of: "\n", with: "\r") : normalized
        let encoding: String.Encoding = format.encoding == .utf16LE ? .utf16LittleEndian : format.encoding == .utf16BE ? .utf16BigEndian : format.encoding == .latin1 ? .isoLatin1 : .utf8
        guard var data = value.data(using: encoding, allowLossyConversion: false) else { throw GitError("The selected encoding cannot represent every character.") }
        switch format.encoding { case .utf8BOM: data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0); case .utf16LE: data.insert(contentsOf: [0xff, 0xfe], at: 0); case .utf16BE: data.insert(contentsOf: [0xfe, 0xff], at: 0); default: break }
        return data
    }
    public static func decode(_ data: Data) -> DecodedComparisonText {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            let encoding: ComparisonEncoding = data.starts(with: [0xff, 0xfe]) ? .utf16LE : .utf16BE
            let text = decode(data, as: encoding)
            let binary = text == nil || text?.contains("\0") == true
            return DecodedComparisonText(text: binary ? nil : text, isBinary: binary, readOnlyReason: text == nil ? "Invalid UTF-16 text is read-only." : binary ? "Binary files are read-only." : nil)
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
        let pageSize = max(1, linesPerPage), wanted = max(0, index)
        var position = 0, firstLine = 1, pageStart = 0, pageFirstLine = 1
        for current in 0...wanted {
            pageStart = position; pageFirstLine = firstLine
            let cap = min(ns.length, position + 100_000)
            var lines = 0
            while position < cap, lines < pageSize {
                let end = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0)))
                if end > cap {
                    position = cap
                    // Never split a surrogate pair at the page boundary.
                    if position < ns.length, position > pageStart, (0xDC00...0xDFFF).contains(ns.character(at: position)) { position -= 1 }
                    break
                }
                position = end; lines += 1; firstLine += 1
            }
            if current == wanted { break }
            if position == ns.length { return TextPage(text: "", firstLine: firstLine, hasNext: false) }
        }
        return TextPage(text: ns.substring(with: NSRange(location: pageStart, length: position - pageStart)), firstLine: pageFirstLine, hasNext: position < ns.length)
    }
}
