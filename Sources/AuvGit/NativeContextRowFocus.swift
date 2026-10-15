import AppKit
import SwiftUI

/// A context-menu target is independent of selection and keyboard focus.
@MainActor
final class NativeContextRowFocus {
    private final class Highlight: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private let highlight = Highlight()
    private weak var target: NSView?
    private var row: Int?
    private(set) var highlightedRow: Int?

    func handle(_ event: NSEvent, in window: NSWindow) {
        guard event.window === window else { return }
        let contextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard contextClick else {
            if event.type == .leftMouseDown || event.type == .otherMouseDown
                || (event.type == .keyDown && [48, 53].contains(event.keyCode)) { clear() }
            return
        }
        clear()
        guard let content = window.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return }
        var candidate: NSView? = hit
        while let view = candidate {
            if let table = view as? NSTableView {
                let index = table.row(at: table.convert(event.locationInWindow, from: nil))
                guard index >= 0 else { return }
                target = table; row = index; highlightedRow = index
                apply()
                return
            }
            candidate = view.superview
        }
        // Repository rows are buttons in a ScrollView rather than native rows.
        func marker(in view: NSView) -> ContextRowMarker? {
            guard !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return nil }
            if let marker = view as? ContextRowMarker { return marker }
            // Lazy compactMap followed by first can evaluate a matching subtree
            // twice at every level, making deeply nested SwiftUI rows exponential.
            for child in view.subviews {
                if let found = marker(in: child) { return found }
            }
            return nil
        }
        if let marker = marker(in: content), let host = marker.superview {
            target = marker
            host.addSubview(highlight, positioned: .above, relativeTo: nil)
            apply()
        }
    }

    func apply() {
        guard let target, target.window != nil, !target.isHiddenOrHasHiddenAncestor else { clear(); return }
        let frame: NSRect
        if let table = target as? NSTableView, let row {
            guard row < table.numberOfRows else { clear(); return }
            if highlight.superview !== table { table.addSubview(highlight, positioned: .above, relativeTo: nil) }
            frame = table.rect(ofRow: row)
        } else if let host = target.superview {
            frame = host.convert(target.bounds, from: target)
        } else { clear(); return }
        if highlight.frame != frame {
            highlight.frame = frame
            highlight.needsDisplay = true
        }
    }

    func clear() {
        highlight.removeFromSuperview()
        target = nil; row = nil; highlightedRow = nil
    }
}

final class ContextRowMarker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ContextRowFocusMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> ContextRowMarker { ContextRowMarker() }
    func updateNSView(_ view: ContextRowMarker, context: Context) {}
}

extension View {
    func contextRowFocus() -> some View {
        background(ContextRowFocusMarker().allowsHitTesting(false).accessibilityHidden(true))
    }
}
