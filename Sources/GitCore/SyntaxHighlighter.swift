import Foundation

public enum SyntaxKind: String, Sendable { case keyword, string, comment, number }
public struct SyntaxToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: SyntaxKind
}
public enum SyntaxHighlighter {
    private static let hashRegex = makeRegex(comment: "#[^\\n]*")
    private static let slashRegex = makeRegex(comment: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")
    private static let genericRegex = makeRegex(comment: "//[^\\n]*|/\\*[\\s\\S]*?\\*/|#[^\\n]*|<!--[^>]*-->")
    private static func makeRegex(comment: String) -> NSRegularExpression? {
        let pattern = "(?<comment>" + comment + ")|(?<string>\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')|(?<number>\\b(?:0x[0-9A-Fa-f]+|[0-9]+(?:\\.[0-9]+)?)\\b)|(?<keyword>\\b(?:let|var|func|function|class|struct|enum|import|from|return|if|else|for|while|switch|case|break|continue|guard|public|private|protected|static|try|throw|throws|async|await|const|new|export|default|interface|type|package|defer|go|range|def|lambda|in|with|as|pass|True|False|None|true|false|null|nil|do|done|then|fi|namespace|using|void|int|double|float|bool|char|auto|template|typename|include|extends|implements|final|override|fun|val|object|end|module|require|local|self|this)\\b)"
        return try? NSRegularExpression(pattern: pattern)
    }
    public static func tokens(in text: String, path: String) -> [SyntaxToken] {
        guard text.utf16.count <= 2_000_000 else { return [] }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let hashComments = ["py", "sh", "bash", "zsh", "rb", "pl", "r", "yaml", "yml", "toml"].contains(ext)
        let slashComments = ["swift", "js", "jsx", "ts", "tsx", "go", "json", "c", "h", "cpp", "hpp", "cc", "cxx", "rs", "java", "kt", "kts", "cs", "m", "mm", "scala", "dart", "php"].contains(ext)
        // Unknown source extensions and extensionless files still get basic lexical colors.
        guard let regex = hashComments ? hashRegex : slashComments ? slashRegex : genericRegex else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).compactMap { match in
            for kind in [SyntaxKind.comment, .string, .number, .keyword] {
                let range = match.range(withName: kind.rawValue)
                if range.location != NSNotFound { return SyntaxToken(range: range, kind: kind) }
            }
            return nil
        }
    }
}
