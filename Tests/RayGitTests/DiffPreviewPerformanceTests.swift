import XCTest
import AppKit
import SwiftUI
import GitCore
@testable import RayGit

@MainActor
final class DiffPreviewPerformanceTests: XCTestCase {
    private func htmlPatch() -> String {
        // Like a bundled landing page: few source lines, with dense markup/CSS/JS.
        let markup = "<span class=\"feature\" data-index=\"123\">Native preview</span>"
        let longest = [12_550, 8_723, 6_365, 2_763, 2_309, 1_521, 1_311, 1_309, 935, 925]
        let lines = (0..<77).map { index in
            let length = longest.indices.contains(index) ? longest[index] : 260
            let prefix = "<section id=\"row-\(index)\">", suffix = "</section>"
            let contentLength = length - prefix.count - suffix.count
            return prefix + String(String(repeating: markup, count: contentLength / markup.count + 1).prefix(contentLength)) + suffix
        }
        return "@@ -0,0 +1,77 @@\n" + lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
    }
    private func surface(_ patch: String, identity: String) -> DiffTextSurface {
        DiffTextSurface(diff: DiffParser.parse(patch), sourceText: patch, languagePath: "index.html", documentIdentity: identity, sideBySide: true, selectedHunk: -1, dark: false, wraps: true, lineNumbers: true, synchronized: true, fontSize: 12, compact: false, searchOptions: ComparisonSearchOptions(), searchStep: 0, matchCount: .constant(0), matchIndex: .constant(0), searchError: .constant(nil), scrollsToFirstChange: false, onFirstScroll: {})
    }
    private func textViews(_ view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap(textViews)
    }
    private func rowOrigins(_ view: NSTextView) -> [CGFloat] {
        guard let layout = view.layoutManager, let container = view.textContainer else { return [] }
        let source = view.string as NSString
        var result: [CGFloat] = [], offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: offset)
            result.append(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
            offset = NSMaxRange(range)
        }
        XCTAssertGreaterThan(layout.usedRect(for: container).height, 900)
        return result
    }
    func testDenseWrappedHTMLColdAndWarmDocumentSwitch() throws {
        _ = NSApplication.shared
        DiffTextSurface.Coordinator.clearDocumentCache()
        defer { DiffTextSurface.Coordinator.clearDocumentCache() }
        let patch: String
        if let path = ProcessInfo.processInfo.environment["RAYGIT_RESPONSE_HTML_PATH"] {
            var lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            patch = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
        } else { patch = htmlPatch() }
        XCTAssertGreaterThan(patch.utf8.count, 50_000)
        let start = ContinuousClock.now
        let host = NSHostingView(rootView: surface(patch, identity: "html"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let cold = start.duration(to: .now)
        let original = textViews(host)
        XCTAssertEqual(original.count, 2)
        guard original.count == 2 else { return }
        let originalAttributes = original.map { NSAttributedString(attributedString: $0.textStorage!) }
        let left = rowOrigins(original[0]), right = rowOrigins(original[1])
        XCTAssertEqual(left.count, 77)
        XCTAssertEqual(left.count, right.count)
        for (a, b) in zip(left, right) { XCTAssertEqual(a, b, accuracy: 0.5, "Wrapped columns must retain exact source-row alignment") }
        let sourceLines = patch.components(separatedBy: "\n").dropFirst().filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
        let renderedLines = original[1].string.components(separatedBy: "\n").prefix(sourceLines.count)
        for (index, pair) in zip(sourceLines, renderedLines).enumerated() {
            let code = String(pair.1.dropFirst(10))
            XCTAssertTrue(code == pair.0, "Source row \(index + 1) must remain complete: expected \(pair.0.utf16.count), rendered \(code.utf16.count) UTF16 units")
        }
        XCTAssertTrue(original[1].string.contains("    77"))
        let repeatStart = ContinuousClock.now
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        let unchanged = repeatStart.duration(to: .now)
        host.rootView = surface("@@ -0,0 +1 @@\n+Other repository\n", identity: "other")
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let warmStart = ContinuousClock.now
        host.rootView = surface(patch, identity: "html")
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let warm = warmStart.duration(to: .now)
        let restored = textViews(host)
        XCTAssertEqual(restored.count, 2)
        for (index, text) in restored.enumerated() where original.indices.contains(index) {
            XCTAssertTrue(text === original[index], "Warm return must reuse TextKit's native laid-out document")
            XCTAssertTrue(text.textStorage!.isEqual(to: originalAttributes[index]), "Line numbers, syntax and character attributes must survive restoration")
        }
        func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        print("DIFF_DENSE_HTML coldMs=\(seconds(cold) * 1000) warmMs=\(seconds(warm) * 1000) unchanged10Ms=\(seconds(unchanged) * 1000) bytes=\(patch.utf8.count)")
        XCTAssertLessThan(seconds(warm), 0.1)
        XCTAssertLessThan(seconds(unchanged), 0.1)
    }

    func testWrappedDocumentRestoresAfterStaticPreviewWithoutHorizontalScroller() {
        _ = NSApplication.shared
        DiffTextSurface.Coordinator.clearDocumentCache()
        defer { DiffTextSurface.Coordinator.clearDocumentCache() }
        let patch = htmlPatch()
        let host = NSHostingView(rootView: AnyView(surface(patch, identity: "html-static")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let original = textViews(host)
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(textViews(host).isEmpty)
        host.rootView = AnyView(surface(patch, identity: "html-static"))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let restored = textViews(host)
        XCTAssertEqual(restored.count, 2)
        guard restored.count == 2 else { return }
        for (index, text) in restored.enumerated() {
            XCTAssertTrue(text === original[index])
            XCTAssertFalse(text.enclosingScrollView!.hasHorizontalScroller)
            XCTAssertFalse(text.isHorizontallyResizable)
            XCTAssertTrue(text.textContainer!.widthTracksTextView)
            XCTAssertEqual(text.textContainer!.containerSize.width, text.enclosingScrollView!.contentSize.width - 16, accuracy: 0.5)
        }
        let left = rowOrigins(restored[0]), right = rowOrigins(restored[1])
        XCTAssertEqual(left.count, 77); XCTAssertEqual(right.count, 77)
        for (a, b) in zip(left, right) { XCTAssertEqual(a, b, accuracy: 0.5) }
    }

    func testDetachedDocumentCanRestoreInNewSurfaceWithoutSharingLiveViews() throws {
        _ = NSApplication.shared
        DiffTextSurface.Coordinator.clearDocumentCache()
        defer { DiffTextSurface.Coordinator.clearDocumentCache() }
        let key = DiffTextSurface.Coordinator.DocumentKey(source: "html", identity: "html", languagePath: "index.html", style: "fixture", split: true, dark: false, lineNumbers: true, fontSize: 12, wraps: true)
        func coordinator() -> DiffTextSurface.Coordinator {
            let value = DiffTextSurface.Coordinator()
            for _ in 0..<2 {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
                scroll.documentView = NSTextView()
                value.scrolls.append(scroll)
            }
            return value
        }
        let first = coordinator()
        XCTAssertFalse(first.activateDocument(key))
        let original = first.scrolls.map { $0.documentView! }
        first.cacheAndDetachActiveDocument()
        XCTAssertTrue(first.scrolls.allSatisfy { $0.documentView == nil })
        let second = coordinator()
        XCTAssertTrue(second.activateDocument(key))
        for (a, b) in zip(original, second.scrolls) { XCTAssertTrue(a === b.documentView) }
        let third = coordinator()
        XCTAssertFalse(third.activateDocument(key), "An active document must never be handed to another surface")
    }
}
