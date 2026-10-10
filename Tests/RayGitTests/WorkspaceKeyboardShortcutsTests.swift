import AppKit
import XCTest
@testable import RayGit

@MainActor
final class WorkspaceKeyboardShortcutsTests: XCTestCase {
    func testFinderShortcutsStayInFileScopeAndPreserveTextEditing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let region = WorkspaceKeyboardRegion.RegionView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(region)
        let suite = "FinderShortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        region.shortcuts = KeyboardShortcuts(defaults: defaults)
        var fileFocus = true
        var commands: [ShortcutCommand] = []
        region.action = { command in
            guard fileFocus else { return false }
            commands.append(command); return true
        }
        let inputs: [(UInt16, String, NSEvent.ModifierFlags, ShortcutCommand)] = [
            (0, "a", .command, .selectAllFiles), (8, "c", .command, .copyFiles),
            (36, "\n", [], .renameFile), (76, "\u{3}", [], .renameFile), (125, "\u{f701}", .command, .editFile),
            (51, "\u{7f}", .command, .deleteFile), (8, "c", [.command, .option], .copyPath)
        ]
        let editor = NSTextView(frame: region.frame)
        window.contentView!.addSubview(editor)
        for (code, characters, flags, command) in inputs {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.makeFirstResponder(nil)
            fileFocus = true
            XCTAssertNil(region.handle(event))
            XCTAssertEqual(commands.last, command)
            let count = commands.count
            fileFocus = false
            XCTAssertNotNil(region.handle(event))
            XCTAssertEqual(commands.count, count)
            fileFocus = true
            XCTAssertTrue(window.makeFirstResponder(editor))
            XCTAssertNotNil(region.handle(event))
            XCTAssertEqual(commands.count, count)
        }
    }
    func testWorkspaceKeysStayInTheirWindowAndPreserveNativeEditing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let region = WorkspaceKeyboardRegion.RegionView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(region)
        let suite = "WorkspaceKeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); window.orderOut(nil); other.orderOut(nil) }
        region.shortcuts = KeyboardShortcuts(defaults: defaults)
        var commands: [ShortcutCommand] = []
        var menuCommands: [ShortcutCommand] = []
        region.action = { commands.append($0); return $0 == .discard }
        region.menuAction = { menuCommands.append($0); return true }
        func key(_ target: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        }
        XCTAssertNil(region.handle(try key(window)))
        XCTAssertEqual(commands, [.discard])
        XCTAssertNotNil(region.handle(try key(other)))
        let editor = NSTextView(frame: region.frame); window.contentView!.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(region.handle(try key(window)))
        XCTAssertEqual(commands, [.discard])
        region.action = { commands.append($0); return true }
        for command in [ShortcutCommand.activateCommit, .activateFiles, .findObject] {
            let binding = region.shortcuts.binding(command)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: binding.eventModifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(binding.character), charactersIgnoringModifiers: String(binding.character), isARepeat: false, keyCode: 0))
            XCTAssertNil(region.handle(event))
        }
        XCTAssertEqual(commands, [.discard, .activateCommit, .activateFiles, .findObject])
        commands = [.discard]
        window.makeFirstResponder(nil)
        region.isHidden = true
        XCTAssertNotNil(region.handle(try key(window)))
        region.isHidden = false
        NotificationCenter.default.post(name: .rayGitWorkspaceShortcut, object: ShortcutCommand.commit.rawValue, userInfo: ["window": other])
        XCTAssertEqual(commands, [.discard])
        XCTAssertTrue(menuCommands.isEmpty)
        NotificationCenter.default.post(name: .rayGitWorkspaceShortcut, object: ShortcutCommand.commit.rawValue, userInfo: ["window": window])
        XCTAssertEqual(commands, [.discard])
        XCTAssertEqual(menuCommands, [.commit])
        XCTAssertTrue(region.shortcuts.setEnabled(false, for: .discard))
        XCTAssertNotNil(region.handle(try key(window)))
        XCTAssertEqual(commands, [.discard])
        XCTAssertTrue(region.shortcuts.setEnabled(true, for: .discard))
        XCTAssertNil(region.handle(try key(window)))
        XCTAssertEqual(commands, [.discard, .discard])
        XCTAssertFalse(region.shortcuts.set(.init(key: "c", modifiers: 1), for: .copyPath), "Copy Files owns the Finder copy shortcut until disabled")
        XCTAssertTrue(region.shortcuts.setEnabled(false, for: .copyFiles))
        XCTAssertTrue(region.shortcuts.set(.init(key: "c", modifiers: 1), for: .copyPath))
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 0))
        XCTAssertNil(region.handle(copy))
        XCTAssertEqual(commands.last, .copyPath)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(region.handle(copy))
        XCTAssertEqual(commands, [.discard, .discard, .copyPath])
    }
}
