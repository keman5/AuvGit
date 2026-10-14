import AppKit

/// Real controls in a dedicated display rail; no glyphs enter the document.
final class ComparisonActionRail: NSView {
    struct Entry {
        let text: NSTextView
        let range: NSRange
        var sourceText: NSTextView? = nil
        var sourceRange: NSRange? = nil
        var tint: NSColor? = nil
        let title: String
        var deletesContent = false
        let action: () -> Void
    }
    weak var scroll: NSScrollView?
    var pointsRight = true
    var color: NSColor = .systemBlue
    private var entries: [Entry] = []
    private var buttons: [NSButton] = []
    private var connectors: [(NSRect, NSRect, NSColor)] = []
    override var isFlipped: Bool { true }
    func setEntries(_ value: [Entry]) {
        entries = value
        buttons.forEach { $0.removeFromSuperview() }
        buttons = value.enumerated().map { index, entry in
            let button = NSButton(title: entry.deletesContent ? "" : pointsRight ? "→" : "←", target: self, action: #selector(accept(_:)))
            if entry.deletesContent { button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil) }
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            let tint = entry.tint ?? (entry.deletesContent ? NSColor.systemRed : color)
            button.contentTintColor = tint
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.borderWidth = 1
            button.layer?.borderColor = tint.withAlphaComponent(0.25).cgColor
            button.layer?.backgroundColor = tint.withAlphaComponent(0.09).cgColor
            button.toolTip = entry.title
            button.setAccessibilityLabel(entry.title)
            addSubview(button)
            return button
        }
        refresh()
    }
    @objc private func accept(_ button: NSButton) {
        guard entries.indices.contains(button.tag) else { return }
        entries[button.tag].action()
    }
    /// Read existing TextKit geometry; drawing must not lay out an offscreen document.
    static func documentRect(_ range: NSRange, in text: NSTextView) -> NSRect? {
        guard let layout = text.layoutManager else { return nil }
        let length = (text.string as NSString).length
        let location = min(range.location, length)
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
            guard let document = Self.documentRect(entry.range, in: entry.text) else { button.isHidden = true; continue }
            let rect = convert(document, from: entry.text)
            var source = rect
            if let sourceText = entry.sourceText, let sourceRange = entry.sourceRange {
                guard let document = Self.documentRect(sourceRange, in: sourceText) else { button.isHidden = true; continue }
                source = convert(document, from: sourceText)
            }
            let tint = entry.tint ?? (entry.deletesContent ? NSColor.systemRed : color)
            connectors.append((pointsRight ? source : rect, pointsRight ? rect : source, tint))
            let anchor = entry.deletesContent ? rect : source
            let top = anchor.minY
            let visible = NSRect(x: 0, y: top, width: bounds.width, height: max(1, anchor.height)).intersection(bounds)
            let buttonWidth = ComparisonEditorMetrics.actionButtonWidth
            let buttonHeight = ComparisonEditorMetrics.actionButtonHeight
            let halfHeight = buttonHeight / 2
            button.isHidden = visible.isEmpty || bounds.width < buttonWidth
            // Keep a tall block's control usable while only part of it is in view.
            let center = min(max(anchor.midY, halfHeight), max(halfHeight, bounds.height - halfHeight))
            let x = pointsRight ? CGFloat(2) : max(0, bounds.width - buttonWidth - 2)
            button.frame = NSRect(x: x, y: center - halfHeight, width: buttonWidth, height: buttonHeight)
        }
        needsDisplay = true
    }
    override func layout() { super.layout(); refresh() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        for (left, right, tint) in connectors {
            let path = Self.connectorPath(left: left, right: right, width: bounds.width)
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
