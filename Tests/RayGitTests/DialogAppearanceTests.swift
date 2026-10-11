import AppKit
import SwiftUI
import XCTest
@testable import RayGit

@MainActor
final class DialogAppearanceTests: XCTestCase {
    func testSheetUsesSharedRadiusWithoutSystemModalFrame() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled, .docModalWindow, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        DialogAppearance.style(window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.docModalWindow))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.canBecomeKey)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotEqual(window.standardWindowButton(button)?.isHidden, false)
        }
        XCTAssertEqual(window.contentView?.superview?.layer?.cornerRadius, 8)
        XCTAssertEqual(window.contentView?.superview?.layer?.masksToBounds, true)
        XCTAssertFalse(window.isOpaque)
    }

    func testMainWindowClipsTheFrameContainingTheSheetDimmer() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = EightPointFrameView(content: NSView())
        XCTAssertEqual(window.contentView?.superview?.layer?.cornerRadius, 8)
        XCTAssertEqual(window.contentView?.superview?.layer?.masksToBounds, true)
    }
    func testAlertDefaultSkipsDisabledActionsAndPrefersCancelToDestructive() {
        let disabledSave = RayGitAlertButton("Save").disabled(true)
        let discard = RayGitAlertButton("Discard", role: .destructive)
        let cancel = RayGitAlertButton("Cancel", role: .cancel)
        XCTAssertEqual(DialogAppearance.defaultButtonIndex([disabledSave, discard, cancel]), 2)
        XCTAssertEqual(DialogAppearance.defaultButtonIndex([discard, RayGitAlertButton("Save"), cancel]), 1)
        XCTAssertNil(DialogAppearance.defaultButtonIndex([disabledSave, cancel.disabled(true)]))
    }

    func testDefaultButtonHighlightDoesNotReplaceDraftEditorFocus() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let editor = NSTextView(frame: NSRect(x: 10, y: 60, width: 300, height: 100))
        editor.string = "Unfinished draft"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: nil, action: nil)
        save.keyEquivalent = "\r"
        content.addSubview(editor); content.addSubview(cancel); content.addSubview(save)
        window.contentView = content
        window.makeFirstResponder(editor)
        DialogAppearance.style(window)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(window.defaultButtonCell === save.cell)
        XCTAssertEqual(editor.string, "Unfinished draft")
        save.isEnabled = false
        DialogAppearance.configureDefaultButton(in: window)
        XCTAssertTrue(window.defaultButtonCell === cancel.cell)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testSheetClipsContentAndOuterFrameAtMainWindowRadius() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        DialogAppearance.style(window)
        for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
            XCTAssertEqual(view.layer?.cornerRadius, RayGitStyle.windowCornerRadius)
            XCTAssertEqual(view.layer?.masksToBounds, true)
        }
    }

    private final class SheetModel: ObservableObject {
        @Published var presented = false
        @Published var draft = "Unfinished draft"
        @Published var showError = false
        var confirmations = 0
        var dismissals = 0
    }
    private struct RealSheetFixture: View {
        @ObservedObject var model: SheetModel
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .rayGitSheet(isPresented: $model.presented, onDismiss: { model.dismissals += 1 }) {
                    RealSheetContent(model: model)
                }
        }
    }

    private struct RealSheetContent: View {
        @ObservedObject var model: SheetModel
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            VStack {
                StableTextField("Draft", text: $model.draft, initialFocus: true)
                KeyViewProxy(label: "Cancel", keyEquivalent: "\u{1b}") { dismiss() }
                if model.showError { Text("Authentication requires another credential.").frame(height: 70) }
                KeyViewProxy(label: "Continue", prominent: true) { model.confirmations += 1 }
            }.padding(24).frame(width: 360, height: model.showError ? 250 : 180).background(Color.white)
        }
    }

    func testRealSwiftUISheetUsesSharedOuterSilhouetteAndNativeDismissal() throws {
        let app = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await verifyRealSheet() } catch { failure = error }
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: false)
            }
        }
        // Key-window activation and Return dispatch require AppKit's real event
        // loop; XCTest's async scheduler alone leaves NSApp inactive/non-running.
        app.run()
        if let failure { throw failure }
    }

    private func activateFixture(_ window: NSWindow) async throws {
        let app = NSApplication.shared
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            app.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(50))
        } while !app.isActive && ContinuousClock.now < deadline
        XCTAssertTrue(app.isActive, "Real-window keyboard/pixel gates require an active fixture host")
        _ = try XCTUnwrap(app.isActive ? window : nil)
    }

    private func verifyRealSheet() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let model = SheetModel()
        let host = NSHostingView(rootView: RealSheetFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        try await activateFixture(window)
        model.presented = true
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.sheetParent === window)
        XCTAssertTrue(sheet.canBecomeKey)
        let visible = DialogAppearance.visibleWindow(for: sheet)
        XCTAssertFalse(visible === sheet)
        XCTAssertTrue(visible.canBecomeKey)
        print("REAL_SHEET_KEY active=\(app.isActive) policy=\(app.activationPolicy().rawValue) running=\(app.isRunning) visibleKey=\(visible.isKeyWindow) anchorKey=\(sheet.isKeyWindow) parentKey=\(window.isKeyWindow) appKey=\(String(describing: app.keyWindow)) panel=\(visible)")
        XCTAssertTrue(visible.isKeyWindow)
        XCTAssertFalse(visible.styleMask.contains(.titled))
        XCTAssertEqual(visible.animationBehavior, .none)
        XCTAssertEqual(sheet.animationBehavior, .none)
        XCTAssertEqual(sheet.alphaValue, 0)
        XCTAssertNotNil(visible.defaultButtonCell)
        XCTAssertEqual(model.draft, "Unfinished draft")

        // Capture the real WindowServer silhouette; layer.cornerRadius alone did
        // not catch the system sheet mask that rounded 28 pt off our corners.
        if ProcessInfo.processInfo.environment["RAYGIT_DIALOG_CAPTURE"] == "1" {
            let output = URL(fileURLWithPath: "/tmp/raygit-real-sheet-corner-test.png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let frame = visible.frame
            let region = "\(Int(frame.minX)),\(Int(screenTop - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
            capture.arguments = ["-x", "-o", "-R", region, output.path]
            capture.standardOutput = Pipe(); capture.standardError = Pipe()
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0, "Real-sheet capture requires the current test host's Screen Recording permission")
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: output)))
            let scale = visible.backingScaleFactor
            XCTAssertEqual(CGFloat(image.pixelsWide), visible.frame.width * scale, accuracy: 1)
            XCTAssertEqual(CGFloat(image.pixelsHigh), visible.frame.height * scale, accuracy: 1)
            print("REAL_SHEET_CAPTURE frame=\(visible.frame) scale=\(scale) pixels=\(image.pixelsWide)x\(image.pixelsHigh)")
            let x = Int((RayGitStyle.windowCornerRadius + 2) * scale)
            let y = max(1, Int(scale))
            let topEdge = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(topEdge.redComponent, 0.95)
            XCTAssertGreaterThan(topEdge.greenComponent, 0.95)
            XCTAssertGreaterThan(topEdge.blueComponent, 0.95,
                                 "At 10 pt from the side the white 8 pt sheet must reach the top edge")
            let outside = try XCTUnwrap(image.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(outside.redComponent, 0.95, "The screenshot must include the sheet's transparent corner over its dimmed parent")
        }
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        NSApplication.shared.sendEvent(tab)
        XCTAssertTrue(visible.firstResponder is NSView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        // Return inside a text editor belongs to that editor. Verify the dialog
        // default from the window responder after ending the active edit.
        XCTAssertTrue(visible.makeFirstResponder(visible))
        NSApplication.shared.sendEvent(enter)
        XCTAssertEqual(model.confirmations, 1)
        let originalHeight = visible.frame.height
        model.showError = true
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(visible.frame.height, originalHeight + 50)
        XCTAssertEqual(visible.frame, sheet.frame)

        // Escape travels through the moved content and its original SwiftUI
        // Environment dismiss action, rather than mutating the binding directly.
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApplication.shared.sendEvent(escape)
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(visible.isVisible)
        XCTAssertFalse(model.presented)
        XCTAssertEqual(model.dismissals, 1)
        XCTAssertEqual(model.draft, "Unfinished draft")
        try await activateFixture(window)
        model.presented = true
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
        let reopenedAnchor = try XCTUnwrap(window.attachedSheet)
        let reopened = DialogAppearance.visibleWindow(for: reopenedAnchor)
        XCTAssertFalse(reopened === visible)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertTrue(reopened.isKeyWindow)
        model.presented = false
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(reopened.isVisible)
        XCTAssertEqual(model.dismissals, 2)
    }

    func testOversizedSheetFrameIsBoundedOnOffsetDisplay() {
        let visible = NSRect(x: -1440, y: 40, width: 1440, height: 860)
        let frame = DialogAppearance.boundedFrame(NSRect(x: -1500, y: -2000, width: 3000, height: 12000), visibleFrame: visible)
        XCTAssertTrue(visible.insetBy(dx: 16, dy: 16).contains(frame))
        XCTAssertEqual(frame.width, 1408)
        XCTAssertEqual(frame.height, 828)
    }

    private final class LongAlertModel: ObservableObject {
        @Published var presented = false
        @Published var lineCount = 1
        var confirmations = 0
    }
    private struct LongAlertFixture: View {
        @ObservedObject var model: LongAlertModel
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .rayGitAlert("Discard workspace changes", isPresented: $model.presented) {
                    RayGitAlertButton("Cancel", role: .cancel)
                    RayGitAlertButton("Continue") { model.confirmations += 1 }
                } message: {
                    Text((0..<model.lineCount).map { "file-\($0).txt" }.joined(separator: "\n"))
                }
        }
    }

    func testLongAlertMessagesScrollWhileActionsStayVisibleAndKeyboardReachable() throws {
        let app = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await verifyLongAlerts() } catch { failure = error }
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: false)
            }
        }
        app.run()
        if let failure { throw failure }
    }

    private func verifyLongAlerts() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let model = LongAlertModel()
        let host = NSHostingView(rootView: LongAlertFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        for lines in [1, 81, 1000] {
            try await activateFixture(window)
            model.lineCount = lines
            model.presented = true
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
            let anchor = try XCTUnwrap(window.attachedSheet)
            let visible = DialogAppearance.visibleWindow(for: anchor)
            let content = try XCTUnwrap(visible.contentView)
            XCTAssertLessThan(visible.frame.height, lines == 1 ? 200 : 520)
            let screen = try XCTUnwrap(window.screen).visibleFrame
            XCTAssertTrue(screen.insetBy(dx: 16, dy: 16).contains(visible.frame))
            XCTAssertTrue(visible.isKeyWindow)
            func keyViews(_ view: NSView) -> [NSView] {
                (view.canBecomeKeyView ? [view] : []) + view.subviews.flatMap(keyViews)
            }
            let actions = keyViews(content)
            XCTAssertGreaterThanOrEqual(actions.count, 2)
            for action in actions {
                XCTAssertTrue(content.bounds.contains(action.convert(action.bounds, to: content)),
                              "Keyboard actions must remain inside the visible panel for \(lines) lines")
            }
            XCTAssertTrue(visible.makeFirstResponder(visible))
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            app.sendEvent(enter)
            for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(visible.isVisible)
        }
        XCTAssertEqual(model.confirmations, 3)
    }

    func testFileListSummaryListsAtMostTwentyFiles() {
        let twenty = (0..<20).map { "file-\($0).txt" }
        XCTAssertEqual(DialogAppearance.fileListSummary(twenty), twenty.joined(separator: "\n"))
        XCTAssertEqual(DialogAppearance.fileListSummary([]), "")
        let large = twenty + ["file-20.txt"]
        XCTAssertEqual(DialogAppearance.fileListSummary(large), interactionText("File Count Summary", 21))
        XCTAssertFalse(DialogAppearance.fileListSummary(large).contains("file-0.txt"))
        XCTAssertFalse(DialogAppearance.fileListSummary(large).contains("\n"))
    }

    func testNativeFrameIsHiddenBeforeShellInstallation() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = DialogFrameStyle.FrameView()
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertEqual(window.animationBehavior, .none)
    }

}
