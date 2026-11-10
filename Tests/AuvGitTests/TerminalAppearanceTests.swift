import AppKit
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testTerminalAndItsInputSubviewsKeepEditingKeysOutOfWorkspaceShortcuts() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = TerminalSession(directory: FileManager.default.temporaryDirectory).view
        window.contentView!.addSubview(terminal)
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        terminal.addSubview(input)
        let region = WorkspaceKeyboardRegion.RegionView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(region)
        let suite = "TerminalKeys.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        region.shortcuts = KeyboardShortcuts(defaults: defaults)
        var commands: [ShortcutCommand] = []
        region.action = { commands.append($0); return true }
        let keys: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (36, "\r", []), (76, "\u{3}", []), (51, "\u{7f}", []),
            (8, "c", .command), (6, "z", .command), (0, "a", .command),
            (40, "k", .command), (15, "r", .command)
        ]
        for responder in [terminal, input] as [NSView] {
            XCTAssertTrue(window.makeFirstResponder(responder))
            for (code, characters, modifiers) in keys {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                XCTAssertTrue(region.handle(event) === event)
            }
        }
        XCTAssertTrue(commands.isEmpty)
        window.makeFirstResponder(nil)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertNil(region.handle(enter))
        XCTAssertEqual(commands, [.renameFile], "File shortcuts still work after leaving the terminal")
    }

    func testHistoryAcceptedWithRightArrowExecutesWithReturnDespiteFileShortcutScope() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let session = TerminalSession(directory: directory)
        defer { session.stop(immediately: true) }
        session.view.acceptsInput = { true }
        window.contentView!.addSubview(session.view)
        let region = WorkspaceKeyboardRegion.RegionView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(region)
        let suite = "TerminalHistory.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        region.shortcuts = KeyboardShortcuts(defaults: defaults)
        var workspaceCommands: [ShortcutCommand] = []
        // Reproduce a remembered file scope; it must never take terminal input.
        region.action = { workspaceCommands.append($0); return true }
        XCTAssertTrue(window.makeFirstResponder(session.view))
        let config = GitCore.TerminalConfiguration(directory: directory, userShell: "/bin/zsh")
        session.view.startProcess(executable: "/bin/zsh", args: ["-f", "-i"], environment: config.environment, currentDirectory: directory.path)
        XCTAssertTrue(session.view.process.running)
        // Use an isolated ZLE history binding, independent of personal shell plugins/history.
        let setup = "unset HISTFILE; PS1=''; bindkey -e; print -s -- 'printf done > executed'; bindkey '^[[C' up-history; bindkey '^[OC' up-history; printf ready > ready\r"
        session.view.process.send(data: Array(setup.utf8)[...])
        func waitForFile(_ name: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
        try await waitForFile("ready")
        session.view.insertText("printf", replacementRange: NSRange(location: NSNotFound, length: 0))
        for (code, characters) in [(UInt16(124), "\u{f703}"), (36, "\r")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            let delivered = try XCTUnwrap(region.handle(event), "Workspace shortcuts swallowed terminal input")
            session.view.keyDown(with: delivered)
        }
        try await waitForFile("executed")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("executed"), encoding: .utf8), "done")
        XCTAssertTrue(workspaceCommands.isEmpty)
        XCTAssertTrue(window.firstResponder === session.view)
    }

    func testBackgroundProjectDoesNotConsumeTerminalShortcutAndActivationTransfersOwnership() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var backgroundToggles = 0, activeToggles = 0
        let background = TerminalShortcutMonitor.ShortcutView(isActive: false) { backgroundToggles += 1 }
        let active = TerminalShortcutMonitor.ShortcutView { activeToggles += 1 }
        window.contentView!.addSubview(background)
        window.contentView!.addSubview(active)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "`",
            charactersIgnoringModifiers: "`", isARepeat: false, keyCode: 50))
        XCTAssertNotNil(background.handle(event))
        XCTAssertNil(active.handle(event))
        XCTAssertEqual(backgroundToggles, 0)
        XCTAssertEqual(activeToggles, 1)
        background.isActive = true
        active.isActive = false
        XCTAssertNotNil(active.handle(event))
        XCTAssertNil(background.handle(event))
        XCTAssertEqual(backgroundToggles, 1)
        XCTAssertEqual(activeToggles, 1)
    }

    func testTerminalToggleUsesPhysicalGraveKeyWithExactControlModifier() throws {
        func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode))
        }

        XCTAssertTrue(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 50, modifiers: .control, characters: "§")))
        XCTAssertTrue(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 50, modifiers: [.control, .capsLock], characters: "~")))
        XCTAssertFalse(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 50, modifiers: .command, characters: "`")))
        XCTAssertFalse(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 50, modifiers: [.control, .shift], characters: "`")))
        XCTAssertFalse(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 50, modifiers: [.control, .option], characters: "`")))
        XCTAssertFalse(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 50, modifiers: [.control, .command], characters: "`")))
        XCTAssertFalse(TerminalShortcutMonitor.isToggleShortcut(try event(keyCode: 0, modifiers: .control, characters: "`")))
    }

    func testAttachmentAndAppearanceChangesKeepTerminalColorsReadable() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var session: TerminalSession!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            session = TerminalSession(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView!.addSubview(session.view)

        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            let foreground = session.view.nativeForegroundColor.usingColorSpace(.sRGB)!
            let background = session.view.nativeBackgroundColor.usingColorSpace(.sRGB)!
            let terminal = session.view.getTerminal()
            XCTAssertEqual(CGFloat(terminal.foregroundColor.red) / 65535, foreground.redComponent, accuracy: 0.0001)
            XCTAssertEqual(CGFloat(terminal.backgroundColor.red) / 65535, background.redComponent, accuracy: 0.0001)
            if appearance == .darkAqua {
                XCTAssertGreaterThan(foreground.redComponent - background.redComponent, 0.6)
            } else {
                XCTAssertGreaterThan(background.redComponent - foreground.redComponent, 0.6)
            }
        }
    }
}
