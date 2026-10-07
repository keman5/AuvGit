import AppKit
import XCTest
@testable import RayGit

@MainActor
final class KeyboardShortcutsTests: XCTestCase {
    func testMigrationCustomizationConflictsPersistenceAndRestore() throws {
        let name = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("b", forKey: "shortcut.stage")
        let shortcuts = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(shortcuts.binding(.stage), .init(key: "b", modifiers: 1))
        XCTAssertEqual(shortcuts.binding(.unstage), .init(key: "b", modifiers: 3))
        XCTAssertFalse(shortcuts.set(.init(key: "a", modifiers: 0), for: .reset))
        XCTAssertFalse(shortcuts.isValid(.init(key: "s", modifiers: 3), for: .reset))
        XCTAssertTrue(shortcuts.isValid(.init(key: "z", modifiers: 3), for: .reset))
        XCTAssertTrue(shortcuts.isValid(.init(key: "a", modifiers: 8), for: .reset))
        XCTAssertFalse(shortcuts.set(shortcuts.binding(.createBranch), for: .reset))
        XCTAssertTrue(shortcuts.set(.init(key: "F8", modifiers: 6), for: .reset))
        let reloaded = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.binding(.reset), .init(key: "F8", modifiers: 6))
        XCTAssertEqual(reloaded.binding(.reset).viewModifiers, [.shift, .option])
        // Swap using a free intermediate chord; reloading validates the final map.
        XCTAssertTrue(shortcuts.set(.init(key: "F9", modifiers: 0), for: .open))
        XCTAssertTrue(shortcuts.set(.init(key: "o", modifiers: 1), for: .refresh))
        XCTAssertTrue(shortcuts.set(.init(key: "F5", modifiers: 0), for: .open))
        let swapped = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(swapped.binding(.open), .init(key: "F5", modifiers: 0))
        XCTAssertEqual(swapped.binding(.refresh), .init(key: "o", modifiers: 1))
        shortcuts.restoreDefaults()
        for command in ShortcutCommand.allCases { XCTAssertEqual(shortcuts.binding(command), command.defaultBinding) }
        let restored = KeyboardShortcuts(defaults: defaults)
        for command in ShortcutCommand.allCases { XCTAssertEqual(restored.binding(command), command.defaultBinding) }
    }
    func testRefreshMigrationAndSavedCollisionRepair() throws {
        let name = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(fresh.binding(.reset), .init(key: "r", modifiers: 1))
        XCTAssertEqual(fresh.binding(.refresh), .init(key: "F5", modifiers: 0))
        XCTAssertFalse(fresh.binding(.refreshAlternate).isAssigned)
        XCTAssertFalse(fresh.set(fresh.binding(.reset), for: .refresh))
        for (key, modifiers) in [("v", 5), ("v", 7), ("g", 3), ("h", 5), ("f", 9)] {
            XCTAssertTrue(fresh.isValid(.init(key: key, modifiers: modifiers), for: .stage))
        }
        // Existing RayGit actions still own their chords in overlapping scopes.
        XCTAssertFalse(fresh.isValid(.init(key: "e", modifiers: 1), for: .stage))
        XCTAssertTrue(fresh.isValid(.init(key: "g", modifiers: 1), for: .stage), "Files and checkout history/branch scopes are disjoint")
        XCTAssertEqual(fresh.binding(.refresh).displayString, "F5")
        defaults.set("r", forKey: "shortcut.refresh")
        defaults.set(Data(#"{"key":"r","modifiers":1}"#.utf8), forKey: "shortcut.binding.refresh")
        defaults.set(try JSONEncoder().encode(ShortcutBinding(key: "F8", modifiers: 6)), forKey: "shortcut.binding.reset")
        let migrated = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(migrated.binding(.refresh), fresh.binding(.refresh))
        XCTAssertEqual(migrated.binding(.reset), .init(key: "F8", modifiers: 6))
        // A custom chord occupying another action's default used to defeat repair.
        defaults.set(try JSONEncoder().encode(ShortcutBinding(key: "t", modifiers: 1)), forKey: "shortcut.binding.open")
        defaults.set(try JSONEncoder().encode(ShortcutBinding(key: "invalid", modifiers: 99)), forKey: "shortcut.binding.commit")
        let repaired = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(repaired.binding(.open), .init(key: "t", modifiers: 1))
        for command in ShortcutCommand.allCases {
            XCTAssertTrue(repaired.isValid(repaired.binding(command), for: command), command.rawValue)
            XCTAssertEqual(KeyboardShortcuts(defaults: defaults).binding(command), repaired.binding(command))
        }
    }

    func testContextualDefaultsSpecialKeysAndUnassignment() throws {
        let name = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let shortcuts = KeyboardShortcuts(defaults: defaults)
        for command in ShortcutCommand.allCases { XCTAssertTrue(shortcuts.isValid(shortcuts.binding(command), for: command), command.rawValue) }
        XCTAssertEqual(shortcuts.binding(.find), shortcuts.binding(.filterFiles))
        XCTAssertEqual(shortcuts.binding(.find), shortcuts.binding(.compareFind))
        XCTAssertEqual(shortcuts.binding(.stash), shortcuts.binding(.compareSave))
        XCTAssertEqual(shortcuts.binding(.reset), shortcuts.binding(.compareReplace))
        XCTAssertEqual(shortcuts.binding(.commit), shortcuts.binding(.compareNextConflict))
        XCTAssertEqual(shortcuts.binding(.comparePreviousChange), .init(key: "F6", modifiers: 2))
        XCTAssertEqual(shortcuts.binding(.compareNextChange), .init(key: "F6", modifiers: 0))
        XCTAssertEqual(shortcuts.binding(.renameFile), shortcuts.binding(.renameBranch))
        XCTAssertEqual(shortcuts.binding(.renameStash), shortcuts.binding(.renameBranch))
        XCTAssertEqual(shortcuts.binding(.findObject), .init(key: "p", modifiers: 1))
        XCTAssertEqual(shortcuts.binding(.activateFiles), .init(key: "3", modifiers: 5))
        XCTAssertFalse(shortcuts.set(shortcuts.binding(.activateFiles), for: .findObject))
        XCTAssertFalse(shortcuts.set(shortcuts.binding(.stage), for: .ignore))
        XCTAssertFalse(shortcuts.set(shortcuts.binding(.find), for: .reset))
        XCTAssertTrue(shortcuts.set(.init(key: "", modifiers: 0), for: .reset))
        let unassigned = shortcuts.binding(.reset)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))
        XCTAssertFalse(unassigned.matches(event))
        XCTAssertFalse(KeyboardShortcuts(defaults: defaults).binding(.reset).isAssigned)
        for (command, code, modifiers) in [(ShortcutCommand.pull, NSPageDownFunctionKey, NSEvent.ModifierFlags.command), (.push, NSPageUpFunctionKey, .command), (.selectChildCommit, NSUpArrowFunctionKey, .option)] {
            let character = String(UnicodeScalar(code)!)
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers.union(.function), timestamp: 0, windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
            XCTAssertTrue(shortcuts.binding(command).matches(key), command.rawValue)
        }
        shortcuts.restoreDefaults()
        for command in ShortcutCommand.allCases { XCTAssertEqual(shortcuts.binding(command), command.defaultBinding) }
    }

    func testDisabledChordReuseReenableAndPersistence() throws {
        let name = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let shortcuts = KeyboardShortcuts(defaults: defaults)
        XCTAssertTrue(shortcuts.setEnabled(false, for: .copyHash))
        let disabled = shortcuts.binding(.copyHash)
        XCTAssertFalse(disabled.isAssigned)
        XCTAssertTrue(disabled.hasAssignedKey)
        XCTAssertEqual(disabled.displayString, "⌘C")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 0))
        XCTAssertFalse(disabled.matches(event))
        XCTAssertTrue(shortcuts.set(.init(key: "c", modifiers: 1), for: .reset))
        XCTAssertTrue(shortcuts.binding(.reset).matches(event))
        XCTAssertFalse(shortcuts.setEnabled(true, for: .copyHash))
        let reloaded = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.binding(.copyHash), disabled)
        XCTAssertEqual(reloaded.binding(.reset), .init(key: "c", modifiers: 1))
        XCTAssertTrue(reloaded.setEnabled(false, for: .reset))
        XCTAssertTrue(reloaded.setEnabled(true, for: .copyHash))
        XCTAssertEqual(reloaded.binding(.copyHash), ShortcutCommand.copyHash.defaultBinding)
        let legacy = try JSONDecoder().decode(ShortcutBinding.self, from: Data(#"{"key":"c","modifiers":1}"#.utf8))
        XCTAssertTrue(legacy.enabled)
        XCTAssertEqual(legacy, ShortcutCommand.copyHash.defaultBinding)
    }

    func testExplicitRefreshOverrideAndCanonicalKeysSurviveReload() throws {
        let name = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let shortcuts = KeyboardShortcuts(defaults: defaults)
        XCTAssertTrue(shortcuts.setEnabled(false, for: .reset))
        XCTAssertTrue(shortcuts.set(.init(key: "R", modifiers: 1), for: .refresh))
        XCTAssertEqual(KeyboardShortcuts(defaults: defaults).binding(.refresh), .init(key: "r", modifiers: 1))
        XCTAssertTrue(shortcuts.setEnabled(false, for: .refresh))
        XCTAssertEqual(KeyboardShortcuts(defaults: defaults).binding(.refresh), .init(key: "r", modifiers: 1, enabled: false))
        XCTAssertTrue(shortcuts.setEnabled(true, for: .refresh))
        XCTAssertEqual(KeyboardShortcuts(defaults: defaults).binding(.refresh), .init(key: "r", modifiers: 1))
        XCTAssertFalse(shortcuts.set(.init(key: "C", modifiers: 1), for: .refresh))
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: Data(#"{"key":"C","modifiers":1}"#.utf8))
        XCTAssertEqual(decoded, ShortcutCommand.copyHash.defaultBinding)
        XCTAssertFalse(ShortcutBinding.supportsKey(String(UnicodeScalar(NSF1FunctionKey)!)))
        XCTAssertFalse(ShortcutBinding.supportsKey("ab"))
        XCTAssertFalse(ShortcutBinding.supportsKey("👩‍💻"))
        XCTAssertTrue(ShortcutBinding.supportsKey("e\u{301}"))
        XCTAssertEqual(ShortcutBinding(key: "e\u{301}", modifiers: 1).character, "e\u{301}")
    }

}
