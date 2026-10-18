import XCTest
import AppKit
@testable import AuvGit

@MainActor
final class ComparisonActionRailTests: XCTestCase {
    func testEditablePanesShareOneContinuousBridgeForAddAndDelete() async throws {
        _ = NSApplication.shared
        let short = "head\ntail\n"
        let long = "head\ninserted one\ninserted two\ninserted three\ntail\n"
        for (source, target, addition) in [(short, long, true), (long, short, false)] {
            let editor = ComparisonEditor(columns: [
                .init(id: "copy", title: "Copy", text: source, isEditable: true, message: nil, preservesUndo: true),
                .init(id: "worktree", title: "Worktree", text: target, isEditable: true, message: nil, preservesUndo: true)
            ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
                changeNavigation: 0, onEdit: { _, _ in })
            let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300)); split.isVertical = true
            let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
            let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = split; window.appearance = NSAppearance(named: .aqua)
            defer { window.close() }
            split.resetDistribution()
            for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(1)) }
            let rails = split.subviews.flatMap { $0.subviews.compactMap { $0 as? ComparisonActionRail } }.filter { $0.bounds.width > 0 }
            XCTAssertEqual(rails.count, 2)
            let left = try XCTUnwrap(rails.first), right = try XCTUnwrap(rails.last)
            XCTAssertTrue(left.oppositeRail === right); XCTAssertTrue(right.oppositeRail === left)
            XCTAssertEqual(left.bounds.width + right.bounds.width, ComparisonEditorMetrics.actionRailWidth, accuracy: 0.01)
            let controls = rails.flatMap { $0.subviews.compactMap { $0 as? NSButton } }
            XCTAssertEqual(controls.count, 2)
            if controls.count == 2 {
                let frames = controls.map { split.convert($0.bounds, from: $0) }
                XCTAssertTrue(frames[0].intersection(frames[1]).isEmpty, "Copy insertion and delete must have separate hit areas")
                for button in controls {
                    let point = split.superview!.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    let hit = split.hitTest(point)
                    XCTAssertTrue(hit === button, "Hit \(String(describing: hit)); control \(button.frame), hidden \(button.isHiddenOrHasHiddenAncestor), split \(split.frame)")
                }
            }
            for rail in rails {
                for button in rail.subviews.compactMap({ $0 as? NSButton }) {
                    XCTAssertEqual(button.contentTintColor, DiffVisualStyle.actionColor,
                        "Copy and delete controls remain neutral regardless of the change color")
                    button.isHidden = true
                }
            }
            let bitmap = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
            split.cacheDisplay(in: split.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / split.bounds.width
            let leftX = Int((split.convert(left.bounds, from: left).maxX - 2) * scale)
            let rightX = Int((split.convert(right.bounds, from: right).minX + 2) * scale)
            var joinedRows = 0
            // The curved border crosses these sample columns at different rows. Compare its interior.
            let margin = Int(4 * scale)
            for y in margin..<(bitmap.pixelsHigh - margin) {
                let a = try XCTUnwrap(bitmap.colorAt(x: leftX, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(bitmap.colorAt(x: rightX, y: y)?.usingColorSpace(.deviceRGB))
                let aTint = addition ? a.greenComponent - a.redComponent : a.redComponent - a.greenComponent
                let bTint = addition ? b.greenComponent - b.redComponent : b.redComponent - b.greenComponent
                let interior = [leftX, rightX].allSatisfy { x in
                    [-margin, margin].allSatisfy { dy in
                        guard let color = bitmap.colorAt(x: x, y: y + dy)?.usingColorSpace(.deviceRGB) else { return false }
                        return (addition ? color.greenComponent - color.redComponent : color.redComponent - color.greenComponent) > 0.015
                    }
                }
                if aTint > 0.015 && bTint > 0.015 && interior {
                    joinedRows += 1
                    XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.04)
                    XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.04)
                }
            }
            XCTAssertGreaterThan(joinedRows, 5, "The same colored band must meet at both sides of the divider")
        }
    }
    func testThreeColumnGapsShareOnlyTwoButtonWidths() async throws {
        _ = NSApplication.shared
        for conflicts in [false, true] {
            let editor = ComparisonEditor(columns: [
                .init(id: "ours", title: "Left", text: "left\n", isEditable: true, message: nil, preservesUndo: true),
                .init(id: "worktree", title: "Result", text: "<<<<<<< HEAD\nleft\n=======\nright\n>>>>>>> topic\n", isEditable: true, message: nil, preservesUndo: true),
                .init(id: "theirs", title: "Right", text: "right\n", isEditable: true, message: nil, preservesUndo: true)
            ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
                changeNavigation: 0, onEdit: { _, _ in }, resolver: conflicts ? ComparisonResolverState() : nil)
            let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 300)); split.isVertical = true
            let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
            let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = split
            defer { window.close() }
            split.resetDistribution()
            for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(1)) }
            for position in 0..<2 {
                let left = try XCTUnwrap(split.subviews[position].subviews.compactMap { $0 as? ComparisonActionRail }.last)
                let right = try XCTUnwrap(split.subviews[position + 1].subviews.compactMap { $0 as? ComparisonActionRail }.first)
                XCTAssertEqual(left.bounds.width + right.bounds.width, 2 * ComparisonEditorMetrics.actionButtonWidth + 4, accuracy: 0.01)
                for rail in [left, right] {
                    for button in rail.subviews.compactMap({ $0 as? NSButton }) where !button.isHidden {
                        XCTAssertTrue(rail.bounds.contains(button.frame), "Compact rails must retain the whole hit area")
                    }
                }
            }
        }
    }

    func testWholeActionRailUsesNeutralGrayBackgroundInBothAppearances() throws {
        let rail = ComparisonActionRail(frame: NSRect(x: 0, y: 0, width: ComparisonEditorMetrics.actionRailWidth, height: 100))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            rail.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            var expected = DiffVisualStyle.actionBackgroundColor
            rail.effectiveAppearance.performAsCurrentDrawingAppearance { expected = DiffVisualStyle.actionBackgroundColor.usingColorSpace(.deviceRGB)! }
            XCTAssertEqual(expected.redComponent, appearance == .aqua ? 0.93 : 0.16, accuracy: 0.01)
            let bitmap = try XCTUnwrap(rail.bitmapImageRepForCachingDisplay(in: rail.bounds))
            rail.cacheDisplay(in: rail.bounds, to: bitmap)
            for y in [1, bitmap.pixelsHigh / 2, bitmap.pixelsHigh - 2] {
                let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.01)
                XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.01)
                XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.01)
                XCTAssertGreaterThan(color.alphaComponent, 0.99)
            }
        }
    }
    func testReplacementBackgroundKeepsModificationColorInTwoAndThreeColumns() throws {
        _ = NSApplication.shared
        for three in [false, true] {
            var columns = [ComparisonEditorColumn(id: "head", title: "HEAD", text: "old value\ntail\n", isEditable: true, message: nil)]
            if three { columns.append(.init(id: "index", title: "Index", text: "old value\ntail\n", isEditable: true, message: nil)) }
            columns.append(.init(id: "worktree", title: "Result", text: "new value\ntail\n", isEditable: true, message: nil))
            let editor = ComparisonEditor(columns: columns, wrapLines: true, showLineNumbers: true, synchronizeScroll: true,
                search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
            let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300)); split.isVertical = true
            let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
            let texts = split.subviews.flatMap { $0.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ComparisonTextView } }
            XCTAssertEqual(texts.count, columns.count)
            let modification = EditorPreferences.color(UserDefaults.standard.string(forKey: "editor.modificationColor") ?? "", fallback: .systemOrange)
            for text in texts {
                XCTAssertEqual(text.lineBackgrounds[0], DiffVisualStyle.lineBackground(modification, dark: false),
                    "Replacement rows use the same modification color as their connector, independent of +/- signs")
                XCTAssertNil(text.lineBackgrounds[10], "Unchanged lines remain neutral")
            }
        }
    }

    func testConnectorExcludesAlignmentPlaceholderSpacing() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = "one\nnext\n"
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 100
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: 4))
        let layout = try XCTUnwrap(text.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
        let rect = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: 4), in: text))
        XCTAssertLessThan(rect.height, 40, "The source edge covers its real line, not the alignment spacer")
    }
    func testConnectorJoinsUnequalRangesAndInsertionAnchor() {
        let left = NSRect(x: 0, y: -30, width: 1, height: 80)
        let right = NSRect(x: 0, y: 25, width: 1, height: 0)
        let path = ComparisonActionRail.connectorPath(left: left, right: right, width: 24)
        XCTAssertEqual(path.elementCount, 10)
        XCTAssertEqual(path.bounds.minY, -30)
        XCTAssertEqual(path.bounds.maxY, 50)
        XCTAssertEqual(path.bounds.width, 24)
        var points = [NSPoint](repeating: .zero, count: 3)
        let element = points.withUnsafeMutableBufferPointer { path.element(at: 2, associatedPoints: $0.baseAddress!) }
        XCTAssertEqual(element, .cubicCurveTo)
        XCTAssertEqual(points[2], NSPoint(x: 21, y: 25))
    }

    func testWrappedRangeIncludesAllFragmentsAndEmptyRangeIsAnchor() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = String(repeating: "long line ", count: 15) + "\nnext\n"
        let layout = try XCTUnwrap(text.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
        let range = NSRange(location: 0, length: (text.string as NSString).range(of: "\n").location + 1)
        let rect = try XCTUnwrap(ComparisonActionRail.documentRect(range, in: text))
        XCTAssertGreaterThan(rect.height, layout.defaultLineHeight(for: text.font!) * 2)
        let anchor = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: range.length, length: 0), in: text))
        XCTAssertEqual(anchor.height, 0)
        XCTAssertEqual(anchor.minY, rect.maxY, accuracy: 0.01)
    }

    func testInsertionConnectsBeforeAlignmentSpacerIncludingEOF() throws {
        let empty = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), textContainer: nil)
        empty.textContainerInset.height = ComparisonEditorMetrics.textInset.height + 100
        XCTAssertEqual(try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: 0), in: empty)).minY,
            ComparisonEditorMetrics.textInset.height, "A beginning insertion connects before leading alignment padding")
        for value in ["one\nnext\n", "one\n", "one"] {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.string = value
            let range = (value as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 100
            text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
            let layout = try XCTUnwrap(text.layoutManager)
            layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
            let source = try XCTUnwrap(ComparisonActionRail.documentRect(range, in: text))
            let anchor = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: range.length, length: 0), in: text))
            XCTAssertEqual(anchor.minY, source.maxY, accuracy: 0.01, "The empty edge precedes the placeholder, not the following line")
        }
    }

    func testEOFInsertionConnectsAtThePaintedLogicalLineInEveryPane() async throws {
        _ = NSApplication.shared
        for wrap in [false, true] {
            for count in [2, 3] {
                for afterEmptyLine in [false, true] {
                    let source = String(repeating: "wrapped 🙂 content ", count: 20) + "\n"
                    let target = source + (afterEmptyLine ? "\n" : "") + "added\nsecond\n"
                    let editor = ComparisonEditor(columns: (0..<count).map { index in
                        .init(id: "pane\(index)", title: "Pane \(index)", text: index == 1 ? target : source,
                              isEditable: true, message: nil, preservesUndo: true)
                    }, wrapLines: wrap, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
                        changeNavigation: 0, onEdit: { _, _ in })
                    let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800)); split.isVertical = true
                    let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
                    let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = split
                    defer { window.close() }
                    split.resetDistribution()
                    for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(1)) }
                    let texts = split.subviews.compactMap { $0.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ComparisonTextView }.first }
                    let insertionLine = afterEmptyLine ? 2 : 1
                    for index in texts.indices where index != 1 {
                        let text = texts[index]
                        let anchor = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: source.utf16.count, length: 0), in: text, insertionLine: insertionLine))
                        XCTAssertEqual(anchor.minY, text.missingChangeY(at: insertionLine), accuracy: 0.01)
                        let rails = split.subviews[index].subviews.compactMap { $0 as? ComparisonActionRail }
                        let rail = try XCTUnwrap(rails.first { $0.bounds.width > 0 })
                        let point = rail.convert(NSPoint(x: 0, y: anchor.minY), from: text)
                        let bitmap = try XCTUnwrap(rail.bitmapImageRepForCachingDisplay(in: rail.bounds))
                        rail.cacheDisplay(in: rail.bounds, to: bitmap)
                        let scale = CGFloat(bitmap.pixelsWide) / rail.bounds.width
                        let x = index == 0 ? 1 : rail.bounds.width - 1
                        let colors = (-1...1).compactMap { dy in
                            bitmap.colorAt(x: Int(x * scale), y: Int(point.y * scale) + dy)?.usingColorSpace(.deviceRGB)
                        }
                        XCTAssertTrue(colors.contains { abs($0.greenComponent - $0.redComponent) > 0.05 },
                            "The rendered connector must meet the insertion marker, wrap=\(wrap), panes=\(count), afterEmpty=\(afterEmptyLine), pane=\(index)")
                    }
                }
            }
        }
    }

    private final class FlippedRoot: NSView { override var isFlipped: Bool { true } }
    func testArrowStaysBesideSourceBlockInsteadOfMiddleOfResult() throws {
        let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        let source = NSTextView(frame: NSRect(x: 0, y: 60, width: 300, height: 300))
        let target = NSTextView(frame: NSRect(x: 400, y: 60, width: 300, height: 300))
        source.string = "our\n"; target.string = "marker\nour\nseparator\nother\nend\n"
        let rail = ComparisonActionRail(frame: NSRect(x: 330, y: 0, width: 56, height: 400))
        for view in [source, target, rail] { root.addSubview(view) }
        for text in [source, target] { text.layoutManager!.ensureLayout(for: text.textContainer!) }
        for right in [true, false] {
            rail.pointsRight = right
            rail.setEntries([.init(text: target, range: NSRange(location: 0, length: target.string.utf16.count),
                sourceText: source, sourceRange: NSRange(location: 0, length: source.string.utf16.count), title: "Apply", action: {})])
            let button = try XCTUnwrap(rail.subviews.first as? NSButton)
            let rect = rail.convert(try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: source.string.utf16.count), in: source)), from: source)
            XCTAssertEqual(button.frame.midY, rect.midY, accuracy: 0.01)
            XCTAssertEqual(button.frame.minX, right ? 2 : 34)
        }
    }

    func testCopyAndDeleteUseSourceAndTargetEdgesInBothDirections() throws {
        let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let source = NSTextView(frame: NSRect(x: 0, y: 50, width: 250, height: 300))
        let target = NSTextView(frame: NSRect(x: 500, y: 50, width: 250, height: 300))
        source.string = "source\n"; target.string = "first\nsecond\nthird\n"
        let rail = ComparisonActionRail(frame: NSRect(x: 330, y: 0, width: 56, height: 400))
        let opposite = ComparisonActionRail(frame: NSRect(x: 273, y: 0, width: 56, height: 400))
        for view in [source, target, rail, opposite] { root.addSubview(view) }
        for text in [source, target] { text.layoutManager!.ensureLayout(for: text.textContainer!) }
        var clicks = 0
        for paired in [false, true] {
            rail.oppositeRail = paired ? opposite : nil
            for right in [true, false] {
                rail.pointsRight = right
                opposite.frame.origin.x = right ? 273 : 387
                for deletes in [false, true] {
                    rail.setEntries([.init(text: target, range: NSRange(location: 0, length: target.string.utf16.count),
                        sourceText: source, sourceRange: NSRange(location: 0, length: source.string.utf16.count),
                        title: "Apply", deletesContent: deletes, action: { clicks += 1 })])
                    let host = paired && !deletes ? opposite : rail
                    let button = try XCTUnwrap(host.subviews.first as? NSButton)
                    XCTAssertEqual(button.frame.minX, (deletes ? !right : right) ? 2 : 34)
                    let anchorText = deletes ? target : source
                    let anchor = host.convert(try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: anchorText.string.utf16.count), in: anchorText)), from: anchorText)
                    XCTAssertEqual(button.frame.midY, anchor.midY, accuracy: 0.01)
                    XCTAssertFalse(button.isBordered)
                    XCTAssertNil(button.layer?.backgroundColor)
                    button.performClick(nil)
                }
            }
        }
        XCTAssertEqual(clicks, 8)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                let color = DiffVisualStyle.actionColor.usingColorSpace(.deviceRGB)!
                XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.001)
                XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.001)
                XCTAssertGreaterThan(color.redComponent, 0.3)
                XCTAssertLessThan(color.redComponent, 0.8)
            }
        }
    }

    func testGutterSignsRenderForEveryEditorFontSizeWithoutTextFallback() throws {
        for size in 9...32 {
            let font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
            XCTAssertGreaterThanOrEqual(ComparisonEditorMetrics.signWidth(codeFont: font), CGFloat(size) / 2)
            for addition in [true, false] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill()
                NSColor.red.setStroke()
                for _ in 0..<50 { ComparisonEditorMetrics.signPath(addition: addition, center: NSPoint(x: 32, y: 32), codeSize: CGFloat(size)).stroke() }
                NSGraphicsContext.restoreGraphicsState()
                let center = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32))
                XCTAssertLessThan(center.greenComponent, 0.2)
                let vertical = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32 - max(2, Int(Double(size) * 0.18))))
                XCTAssertEqual(vertical.greenComponent < 0.8, addition, "Only + has a vertical stroke")
            }
        }
    }

    func testRepeatedNativeRepaintWithUnicodeChangesAndResizing() async throws {
        let original = (0..<180).map { "row \($0) 中文 🙂 العربية" }.joined(separator: "\n") + "\n"
        let changed = original.replacingOccurrences(of: "row 40", with: "changed 40\nadded\nadded again")
        let editor = ComparisonEditor(columns: [
            .init(id: "head", title: "HEAD", text: original, isEditable: false, message: nil),
            .init(id: "worktree", title: "Result", text: changed, isEditable: true, message: nil, preservesUndo: true)
        ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in }, scrollsToFirstChangeOnOpen: true)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split
        defer { window.close() }
        split.resetDistribution()
        for index in 0..<24 {
            split.setFrameSize(NSSize(width: index % 2 == 0 ? 900 : 620, height: 300))
            split.layoutSubtreeIfNeeded(); coordinator.alignDisplay()
            coordinator.navigateChange(forward: index % 2 == 0)
            let image = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
            split.cacheDisplay(in: split.bounds, to: image)
            try await Task.sleep(for: .milliseconds(1))
        }
        let texts = split.subviews.flatMap { $0.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView } }
        XCTAssertEqual(texts.map(\.string), [original, changed], "Repainting must not alter either file")
    }

    func testAlignmentPlaceholderDoesNotPaintAsChangedOrCurrentLineInGutter() async throws {
        let editor = ComparisonEditor(columns: [
            .init(id: "head", title: "HEAD", text: "old\ntail\n", isEditable: false, message: nil),
            .init(id: "worktree", title: "Result", text: "new\nnew 2\nnew 3\nnew 4\nnew 5\ntail\n", isEditable: true, message: nil, preservesUndo: true)
        ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in })
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        split.resetDistribution()
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(1)) }
        let pane = try XCTUnwrap(split.subviews.first)
        let text = try XCTUnwrap(pane.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ComparisonTextView }.first)
        let row = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: 4), in: text))
        let gutter = try XCTUnwrap(pane.subviews.first { NSStringFromClass(type(of: $0)).contains("LineGutter") })
        let image = try XCTUnwrap(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
        gutter.cacheDisplay(in: gutter.bounds, to: image)
        let scale = CGFloat(image.pixelsHigh) / gutter.bounds.height
        let normal = try XCTUnwrap(image.colorAt(x: 3, y: Int((row.maxY + 8) * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(abs(normal.redComponent - normal.greenComponent), 0.01, "Alignment padding must retain its neutral background")
        XCTAssertLessThan(abs(normal.blueComponent - normal.greenComponent), 0.01)
        let line = try XCTUnwrap(image.colorAt(x: 3, y: Int((row.minY + 2) * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(line.redComponent - line.greenComponent, 0.015, "The real deleted row stays highlighted")
        text.highlightCurrentLine = false
        let textImage = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
        text.cacheDisplay(in: text.bounds, to: textImage)
        let textScale = CGFloat(textImage.pixelsHigh) / text.bounds.height
        let empty = try XCTUnwrap(textImage.colorAt(x: textImage.pixelsWide - 8, y: Int((row.maxY + 8) * textScale))?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(empty.redComponent, empty.greenComponent, accuracy: 0.01)
        let filled = try XCTUnwrap(textImage.colorAt(x: textImage.pixelsWide - 8, y: Int(row.midY * textScale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(filled.redComponent - filled.greenComponent, 0.015, "Change backgrounds extend across the whole real row")
    }
}
