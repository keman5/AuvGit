import AppKit

/// Search is a separate, visible-only drawing layer. Changing a query never
/// clears syntax colours or character-diff attributes in the text system.
enum ComparisonSearchHighlight {
    static func draw(_ matches: [NSRange], in view: NSTextView, dirtyRect: NSRect) {
        guard !matches.isEmpty, let layout = view.layoutManager, let container = view.textContainer else { return }
        let origin = view.textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lower = 0, upper = matches.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(matches[middle]) < visible.location { lower = middle + 1 } else { upper = middle }
        }
        NSColor.systemYellow.withAlphaComponent(0.45).setFill()
        for index in lower..<matches.count {
            let match = matches[index]
            if match.location > NSMaxRange(visible) { break }
            let range = NSIntersectionRange(match, visible)
            guard range.length > 0 else { continue }
            let matchedGlyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: matchedGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rect.offsetBy(dx: origin.x, dy: origin.y).intersection(dirtyRect).fill()
            }
        }
    }
}
