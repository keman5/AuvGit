import XCTest
@testable import GitCore

final class ComparisonAlignmentTests: XCTestCase {
    func testInsertionAndWrappedRowsPreserveFollowingAnchor() {
        let alignment = ComparisonAlignment(texts: ["a\n尾🙂\nz", "a\nx\ny\n尾🙂\nz"])
        let padding = alignment.padding(lineHeights: [[10, 30, 10], [10, 10, 10, 10, 10]])
        XCTAssertEqual(padding.after[0][0], 20)
        XCTAssertEqual(padding.after[1][3], 20)
        XCTAssertEqual(padding.after[0].reduce(50, +), padding.after[1].reduce(50, +))
    }
    func testConflictSidesBeginAtMarkerAndFollowingContextMatches() {
        let draft = "head\n<<<<<<< ours\nold\n=======\nnew\nmore\n>>>>>>> theirs\ntail"
        let alignment = ComparisonAlignment(texts: ["head\nold\ntail", draft, "head\nnew\nmore\ntail"], baseline: 1, conflictBlocks: ConflictDraft.blocks(in: draft))
        XCTAssertEqual(alignment.bands, [[0..<1, 0..<1, 0..<1], [1..<2, 1..<7, 1..<3], [2..<3, 7..<8, 3..<4]])
        let padding = alignment.padding(lineHeights: [[10,10,10], Array(repeating: 10, count: 8), [10,10,10,10]])
        XCTAssertEqual(padding.after[0][1], 50)
        XCTAssertEqual(padding.after[2][2], 40)
    }
    func testThreeWayPreservesEachPairwiseAnchorAndSimilarReplacement() {
        let unicode = String(repeating: "长行🙂abcdef", count: 20)
        let head = "anchor\nremoved\nold middle\n" + unicode + "\nend"
        let index = "anchor\ninserted one\ninserted two\nremoved\nold middle\n" + unicode + "\nend"
        let result = "prefix\nanchor\nnew middle\nnew middle two\n" + unicode + " edited\nend"
        let alignment = ComparisonAlignment(texts: [head, result, index])
        let row = alignment.bands.first { $0[0].contains(3) }!
        XCTAssertEqual(row[1], 4..<5)
        XCTAssertEqual(row[2], 5..<6)
        for pane in 0..<3 {
            XCTAssertEqual(alignment.bands.flatMap { Array($0[pane]) }, Array(0..<([head,result,index][pane].components(separatedBy: "\n").count)))
        }
    }
    func testExactThreePaneFixtureUnicodeRow() {
        let long = String(repeating: "Unicode 中文 😀 café e\u{0301} — ", count: 24)
        let head = ["first original", "anchor A", "repeat", "repeat", "repeat", "anchor B", "middle original", long, "anchor C", "end original"].joined(separator: "\n") + "\n"
        let index = ["first index insert", "first original", "anchor A", "repeat", "repeat", "anchor B", "middle index 1", "middle index 2", long, "anchor C"].joined(separator: "\n") + "\n"
        let result = ["first worktree insert 1", "first worktree insert 2", "first original", "anchor A", "repeat", "repeat", "repeat", "repeat", "anchor B", "middle worktree", long + String(repeating: "result wrap extension ", count: 10), "anchor C", "end worktree 1", "end worktree 2"].joined(separator: "\n") + "\n"
        let alignment = ComparisonAlignment(texts: [head, result, index])
        XCTAssertEqual(alignment.bands.first { $0[0].contains(7) }, [7..<8, 10..<11, 8..<9])
        XCTAssertEqual(alignment.bands.first { $0[0].contains(8) }, [8..<9, 11..<12, 9..<10])
    }
    func testEmptySideAndLeadingGap() {
        let alignment = ComparisonAlignment(texts: ["tail", "first\nsecond\ntail"])
        let padding = alignment.padding(lineHeights: [[10], [10,10,10]])
        XCTAssertEqual(padding.before[0], 20)
        let empty = ComparisonAlignment(texts: ["", "one\ntwo\n"]).padding(lineHeights: [[10], [10,10,10]])
        XCTAssertEqual(empty.after[0][0] + empty.before[0], 20)
    }
}

#if canImport(AppKit)
import AppKit
extension ComparisonAlignmentTests {
    func testTextKitWrappedGeometryAfterPaddingAndResize() {
        for widths in [[90.0, 180.0], [150.0, 70.0]] {
            let strings = ["頭🙂\na long line that wraps many times at a narrow width\ntail\n", "頭🙂\nshort\ninserted\ntail\n"]
            let views = zip(strings, widths).map { string, width -> NSTextView in
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
                view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                view.string = string
                view.textContainerInset = NSSize(width: 8, height: 8)
                return view
            }
            let starts = strings.map { string in [0] + string.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil } }
            func y(_ index: Int, _ line: Int) -> Double {
                let view = views[index], layout = view.layoutManager!
                layout.ensureLayout(for: view.textContainer!)
                let position = starts[index][line]
                let rect = position == view.string.utf16.count ? layout.extraLineFragmentRect : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
                return rect.minY + view.textContainerInset.height
            }
            let heights = views.indices.map { index in starts[index].indices.map { line in
                line + 1 < starts[index].count ? y(index, line + 1) - y(index, line) : 15
            } }
            let alignment = ComparisonAlignment(texts: strings)
            let padding = alignment.padding(lineHeights: heights)
            for index in views.indices {
                for line in starts[index].indices where padding.after[index][line] > 0 {
                    let start = starts[index][line]
                    let end = line + 1 < starts[index].count ? starts[index][line + 1] : strings[index].utf16.count
                    if end > start {
                        let style = NSMutableParagraphStyle(); style.paragraphSpacing = padding.after[index][line]
                        views[index].textStorage!.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: end - start))
                    }
                }
                views[index].textContainerInset.height += padding.before[index]
            }
            XCTAssertEqual(y(0, 1), y(1, 1), accuracy: 0.1)
            XCTAssertEqual(y(0, 2), y(1, 3), accuracy: 0.1)
            XCTAssertEqual(y(0, 3), y(1, 4), accuracy: 0.1)
            XCTAssertEqual(views.map(\.string), strings)
        }
    }
    func testSameTextViewsKeepWrappedAlignmentThroughRailsResizeAndSizeToFit() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boundary = "abcdefghijklmnopqrstuvwx"
        let unicode = String(repeating: "Unicode 中文 😀 café e\u{0301} — ", count: 8)
        let strings = ["head\n" + boundary + "\n" + unicode + "\ntail\n",
                       "head\n" + boundary + boundary + "\n" + unicode + " extended result\ntail\n",
                       "head\n" + boundary + "\n" + unicode + "\ntail\n"]
        let views = strings.map { string -> NSTextView in
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            view.font = font; view.string = string
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.isVerticallyResizable = true
            view.textContainer!.widthTracksTextView = false
            return view
        }
        let scrolls = views.map { view -> NSScrollView in
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay
            scroll.hasVerticalScroller = true; scroll.documentView = view
            return scroll
        }
        let starts = strings.map { [0] + $0.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil } }
        func y(_ pane: Int, _ line: Int) -> Double {
            let view = views[pane], layout = view.layoutManager!
            layout.ensureLayout(for: view.textContainer!)
            let character = starts[pane][line]
            let rect = character == view.string.utf16.count ? layout.extraLineFragmentRect : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
            return rect.minY + view.textContainerInset.height
        }
        // At this width a viewport-wide container fits the ASCII line, while the
        // real container (viewport minus 16pt inset) requires another fragment.
        let tight = (boundary as NSString).size(withAttributes: [.font: font]).width + 22
        let steps: [(Bool, [CGFloat])] = [(true, [tight, tight, tight]),
                                         (true, [430, 430, 394]),
                                         (true, [340, 170, 280]),
                                         (false, [340, 170, 280]),
                                         (true, [280, 394, 430])]
        for (wrapped, widths) in steps {
            for pane in views.indices {
                let view = views[pane], scroll = scrolls[pane]
                scroll.setFrameSize(NSSize(width: widths[pane], height: 300)); scroll.tile()
                let viewport = scroll.contentView.bounds.size
                view.isHorizontallyResizable = !wrapped
                view.textContainer!.widthTracksTextView = false
                view.textContainerInset.height = 8
                view.textStorage!.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: NSRange(location: 0, length: view.string.utf16.count))
                view.setFrameSize(NSSize(width: viewport.width, height: 300))
                view.textContainer!.containerSize.width = wrapped ? max(1, viewport.width - 16) : .greatestFiniteMagnitude
                view.layoutManager!.ensureLayout(for: view.textContainer!)
            }
            let heights = views.indices.map { pane in starts[pane].indices.map { line in
                line + 1 < starts[pane].count ? y(pane, line + 1) - y(pane, line) : 15
            } }
            let padding = ComparisonAlignment(texts: strings).padding(lineHeights: heights)
            let expectedWidths = views.map { $0.textContainer!.containerSize.width }
            for pane in views.indices {
                let view = views[pane]
                for line in starts[pane].indices where padding.after[pane][line] > 0 {
                    let start = starts[pane][line]
                    let end = line + 1 < starts[pane].count ? starts[pane][line + 1] : view.string.utf16.count
                    guard end > start else { continue }
                    let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = padding.after[pane][line]
                    view.textStorage!.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: end - start))
                }
                view.textContainerInset.height = 8 + padding.before[pane]
                view.layoutManager!.ensureLayout(for: view.textContainer!)
                view.sizeToFit()
                if wrapped { view.setFrameSize(NSSize(width: scrolls[pane].contentView.bounds.width, height: max(300, view.frame.height))) }
                view.layoutManager!.ensureLayout(for: view.textContainer!)
                XCTAssertEqual(view.textContainer!.containerSize.width, expectedWidths[pane])
            }
            XCTAssertEqual(y(0, 3), y(1, 3), accuracy: 0.1)
            XCTAssertEqual(y(0, 3), y(2, 3), accuracy: 0.1)
            XCTAssertEqual(views.map(\.string), strings)
        }
    }

}
#endif
