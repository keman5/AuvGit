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
        XCTAssertFalse(shortcuts.set(.init(key: "s", modifiers: 3), for: .reset))
        XCTAssertFalse(shortcuts.set(.init(key: "z", modifiers: 3), for: .reset))
        XCTAssertFalse(shortcuts.set(.init(key: "a", modifiers: 8), for: .reset))
        XCTAssertFalse(shortcuts.set(shortcuts.binding(.createBranch), for: .reset))
        XCTAssertTrue(shortcuts.set(.init(key: "F8", modifiers: 6), for: .reset))
        let reloaded = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.binding(.reset), .init(key: "F8", modifiers: 6))
        XCTAssertEqual(reloaded.binding(.reset).viewModifiers, [.shift, .option])
        // Swap using a free intermediate chord; reloading validates the final map.
        XCTAssertTrue(shortcuts.set(.init(key: "F9", modifiers: 0), for: .open))
        XCTAssertTrue(shortcuts.set(.init(key: "o", modifiers: 1), for: .refresh))
        XCTAssertTrue(shortcuts.set(.init(key: "r", modifiers: 1), for: .open))
        let swapped = KeyboardShortcuts(defaults: defaults)
        XCTAssertEqual(swapped.binding(.open), .init(key: "r", modifiers: 1))
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
        XCTAssertEqual(fresh.binding(.refresh), .init(key: "r", modifiers: 5))
        XCTAssertEqual(fresh.binding(.refreshAlternate), .init(key: "F5", modifiers: 0))
        XCTAssertFalse(fresh.set(fresh.binding(.reset), for: .refresh))
        for modifiers in [5, 7] {
            XCTAssertFalse(fresh.set(.init(key: "v", modifiers: modifiers), for: .stage))
        }
        for (key, modifiers) in [("e", 1), ("g", 1), ("g", 3), ("h", 5), ("m", 5), ("f", 5), ("f", 9), ("d", 5), ("q", 3), ("q", 7), ("q", 9)] {
            XCTAssertFalse(fresh.set(.init(key: key, modifiers: modifiers), for: .stage))
        }
        XCTAssertEqual(fresh.binding(.refresh).displayString, "⌥⌘R")
        defaults.set("r", forKey: "shortcut.refresh")
        defaults.set(try JSONEncoder().encode(ShortcutBinding(key: "r", modifiers: 1)), forKey: "shortcut.binding.refresh")
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

}
