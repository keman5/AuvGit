import AppKit

/// Real controls in a dedicated display rail; no glyphs enter the document.
final class ComparisonActionRail: NSView {
    struct Entry {
        let text: NSTextView
        let range: NSRange
        var sourceText: NSTextView? = nil
        var sourceRange: NSRange? = nil
        var insertionLine: Int? = nil
        var sourceInsertionLine: Int? = nil
        var tint: NSColor? = nil
        let title: String
        var deletesContent = false
        let action: () -> Void
    }
    weak var scroll: NSScrollView?
    weak var oppositeRail: ComparisonActionRail?
    var pointsRight = true
    var color: NSColor = .systemBlue
    private var entries: [Entry] = []
    private var buttons: [NSButton] = []
    private var connectors: [(NSBezierPath, NSColor)] = []
    override var isFlipped: Bool { true }
    func setEntries(_ value: [Entry]) {
        entries = value
        let previous = buttons
        previous.dropFirst(value.count).forEach { $0.removeFromSuperview() }
        buttons = value.enumerated().map { index, entry in
            let button = previous.indices.contains(index) ? previous[index] : NSButton(title: "", target: self, action: #selector(accept(_:)))
            let font = entry.sourceText?.font ?? entry.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
            button.image = NSImage(systemSymbolName: entry.deletesContent ? "xmark" : pointsRight ? "chevron.right.2" : "chevron.left.2", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: max(8, font.pointSize - 3), weight: .regular))
            button.tag = index
            button.isBordered = false
            button.contentTintColor = DiffVisualStyle.actionColor
            button.toolTip = entry.title
            button.setAccessibilityLabel(entry.title)
            if button.superview == nil { addSubview(button) }
            return button
        }
        refresh()
    }
    @objc private func accept(_ button: NSButton) {
        guard entries.indices.contains(button.tag) else { return }
        entries[button.tag].action()
    }
    /// Read existing TextKit geometry; drawing must not lay out an offscreen document.
    static func documentRect(_ range: NSRange, in text: NSTextView, insertionLine: Int? = nil) -> NSRect? {
        guard let layout = text.layoutManager else { return nil }
        let length = (text.string as NSString).length
        let location = min(range.location, length)
        // UTF-16 EOF alone cannot distinguish insertion before or after the final empty line.
        if range.length == 0, location == length, let insertionLine, let text = text as? ComparisonTextView {
            guard location == 0 || location - 1 < layout.firstUnlaidCharacterIndex() else { return nil }
            return NSRect(x: 0, y: text.missingChangeY(at: insertionLine), width: 1, height: 0)
        }
        let inset = text.textContainerInset.height
        if range.length == 0 || location == length {
            guard location > 0 else {
                let top = text is ComparisonTextView ? ComparisonEditorMetrics.textInset.height : inset
                return NSRect(x: 0, y: top, width: 1, height: 0)
            }
            guard location - 1 < layout.firstUnlaidCharacterIndex() else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: location - 1)
            let bottom = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY
            return NSRect(x: 0, y: bottom + inset, width: 1, height: 0)
        }
        let lastCharacter = min(max(location, NSMaxRange(range) - 1), length - 1)
        guard lastCharacter < layout.firstUnlaidCharacterIndex() else { return nil }
        let first = layout.glyphIndexForCharacter(at: location)
        let top = layout.lineFragmentUsedRect(forGlyphAt: first, effectiveRange: nil).minY + inset
        let last = layout.glyphIndexForCharacter(at: lastCharacter)
        let bottom = layout.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY + inset
        return NSRect(x: 0, y: top, width: 1, height: bottom - top)
    }
    static func connectorPath(left: NSRect, right: NSRect, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let edge = min(6, width / 8)
        let middle = width / 2
        path.move(to: NSPoint(x: 0, y: left.minY))
        path.line(to: NSPoint(x: edge, y: left.minY))
        path.curve(to: NSPoint(x: width - edge, y: right.minY), controlPoint1: NSPoint(x: middle, y: left.minY), controlPoint2: NSPoint(x: middle, y: right.minY))
        path.line(to: NSPoint(x: width, y: right.minY))
        path.line(to: NSPoint(x: width, y: right.maxY))
        path.line(to: NSPoint(x: width - edge, y: right.maxY))
        path.curve(to: NSPoint(x: edge, y: left.maxY), controlPoint1: NSPoint(x: middle, y: right.maxY), controlPoint2: NSPoint(x: middle, y: left.maxY))
        path.line(to: NSPoint(x: 0, y: left.maxY))
        path.close()
        return path
    }
    func refresh() {
        connectors.removeAll(keepingCapacity: true)
        for (entry, button) in zip(entries, buttons) {
            guard let document = Self.documentRect(entry.range, in: entry.text, insertionLine: entry.insertionLine) else { button.isHidden = true; continue }
            let rect = convert(document, from: entry.text)
            var source = rect
            if let sourceText = entry.sourceText, let sourceRange = entry.sourceRange {
                guard let document = Self.documentRect(sourceRange, in: sourceText, insertionLine: entry.sourceInsertionLine) else { button.isHidden = true; continue }
                source = convert(document, from: sourceText)
            }
            let tint = entry.tint ?? (entry.deletesContent ? NSColor.systemRed : color)
            // Both editable panes clip the same bridge instead of drawing mirrored curves.
            let bridge = oppositeRail.flatMap { $0.bounds.width > 0 ? bounds.union(convert($0.bounds, from: $0)) : nil } ?? bounds
            let path = Self.connectorPath(left: pointsRight ? source : rect, right: pointsRight ? rect : source, width: bridge.width)
            path.transform(using: AffineTransform(translationByX: bridge.minX, byY: 0))
            connectors.append((path, tint))
            var host = self
            if !entry.deletesContent, let oppositeRail, oppositeRail.bounds.width > 0,
               entry.range.length > 0 || oppositeRail.bounds.width >= ComparisonEditorMetrics.actionRailWidth { host = oppositeRail }
            if button.superview !== host { host.addSubview(button) }
            let anchor = host.convert(entry.deletesContent ? rect : source, from: self)
            let top = anchor.minY
            let visible = NSRect(x: 0, y: top, width: host.bounds.width, height: max(1, anchor.height)).intersection(host.bounds)
            let buttonWidth = ComparisonEditorMetrics.actionButtonWidth
            let font = entry.sourceText?.font ?? entry.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
            let buttonHeight = ceil((entry.sourceText ?? entry.text).layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height)
            let halfHeight = buttonHeight / 2
            button.isHidden = visible.isEmpty || host.bounds.width < buttonWidth
            // Keep a tall block's control usable while only part of it is in view.
            let center = min(max(anchor.midY, halfHeight), max(halfHeight, host.bounds.height - halfHeight))
            let onLeft = entry.deletesContent ? !pointsRight : pointsRight
            // Two editable copies also offer copying an insertion; keep its arrow beside, not over, ×.
            let inset = !entry.deletesContent && entry.range.length == 0 && host !== self ? buttonWidth : 0
            let x = onLeft ? 2 + inset : max(0, host.bounds.width - buttonWidth - 2 - inset)
            button.frame = NSRect(x: x, y: center - halfHeight, width: buttonWidth, height: buttonHeight)
        }
        needsDisplay = true
    }
    override func layout() { super.layout(); refresh() }
    override func draw(_ dirtyRect: NSRect) {
        DiffVisualStyle.actionBackgroundColor.setFill()
        dirtyRect.fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        for (path, tint) in connectors {
            guard path.bounds.intersects(dirtyRect) else { continue }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DiffVisualStyle.lineBackground(tint, dark: dark).setFill()
            path.fill()
            tint.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
