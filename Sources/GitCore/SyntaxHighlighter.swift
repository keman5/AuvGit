import Foundation

public enum SyntaxKind: String, Sendable { case keyword, string, comment, number }
public struct SyntaxToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: SyntaxKind
}
public enum SyntaxHighlighter {
    public static func tokens(in text: String, path: String) -> [SyntaxToken] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["swift", "js", "jsx", "ts", "tsx", "go", "py", "json", "sh", "bash", "zsh", "c", "h", "cpp", "rs"].contains(ext), text.utf16.count <= 2_000_000 else { return [] }
        let hashComments = ["py", "sh", "bash", "zsh"].contains(ext)
        let comment = hashComments ? "#[^\\n]*" : "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        let pattern = "(?<comment>" + comment + ")|(?<string>\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')|(?<number>\\b(?:0x[0-9A-Fa-f]+|[0-9]+(?:\\.[0-9]+)?)\\b)|(?<keyword>\\b(?:let|var|func|function|class|struct|enum|import|from|return|if|else|for|while|switch|case|break|continue|guard|public|private|static|try|throw|throws|async|await|const|new|export|default|interface|type|package|defer|go|range|def|lambda|in|with|as|pass|True|False|None|true|false|null|nil|do|done|then|fi)\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).compactMap { match in
            for kind in [SyntaxKind.comment, .string, .number, .keyword] {
                let range = match.range(withName: kind.rawValue)
                if range.location != NSNotFound { return SyntaxToken(range: range, kind: kind) }
            }
            return nil
        }
    }
}
