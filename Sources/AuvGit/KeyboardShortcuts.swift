import AppKit
import SwiftUI
import GitCore
import AuvGitLocalization

func shortcutText(_ key: String) -> String { L10n.text(key, table: "KeyboardShortcuts") }

enum ShortcutScope: String, CaseIterable {
    case application, workspace, files, history, branch, stash, comparison
}

enum ShortcutCommand: String, CaseIterable {
    case open, refresh, stage, unstage, commit, viewLog, reset, resetAdvanced, copyHash, copyMessage, createBranch
    case createTag, show, find, refreshAlternate, clone, filterFiles, selectCommittable, selectAllFiles, copyFiles, copyPath, copyRelativePath
    case selectChildCommit, selectParentCommit, showUnversionedFiles, showIgnoredFiles, pull, fetch
    case push, editFile, ignore, renameFile, useCommitMessage
    case discard, deleteFile, stash, applyStash, renameStash, checkout, rebase, renameBranch
    case compareFind, compareFindNext, compareFindPrevious, comparePreviousChange, compareNextChange, compareWrap, compareSave, compareReload
    case activateRepositories, activateBranches, activateFiles, activateChanges, activateHistory, activateCommit, activateOutput, findObject
    case blame, showLogWindow, showChanges
    case compareNextConflict, comparePreviousConflict, compareTakeLeft, compareTakeRight, compareReplace
    case compareCompact, compareLines, compareSync, compareStage

    private static let definitions: [Self: (title: String, key: String, modifiers: Int, scopes: Set<ShortcutScope>)] = [
        .activateRepositories: ("Activate Repositories", "1", 5, [.workspace]),
        .activateBranches: ("Activate Branches", "2", 5, [.workspace]),
        .activateFiles: ("Activate Files", "3", 5, [.workspace]),
        .activateChanges: ("Activate Changes", "4", 5, [.workspace]),
        .activateHistory: ("Activate History", "5", 5, [.workspace]),
        .activateCommit: ("Activate Commit", "6", 5, [.workspace]),
        .activateOutput: ("Activate Output", "7", 5, [.workspace]),
        .findObject: ("Find Object", "p", 1, [.workspace]),
        .blame: ("Blame", "l", 5, [.files]),
        .showLogWindow: ("Show Log Window", "n", 3, [.workspace]),
        .showChanges: ("Show Changes", "F4", 0, [.files, .history]),
        .open: ("Open Repository", "o", 1, [.application]),
        .refresh: ("Refresh Repository", "F5", 0, [.workspace, .history]),
        .stage: ("Stage", "t", 1, [.files]),
        .unstage: ("Unstage", "t", 3, [.files]),
        .commit: ("Commit", "k", 1, [.workspace]),
        .viewLog: ("View Log", "l", 1, [.workspace, .history]),
        .reset: ("Hard Reset", "r", 1, [.workspace, .history]),
        .resetAdvanced: ("Advanced Reset", "r", 3, [.workspace, .history]),
        .copyHash: ("Copy Commit Hash", "c", 3, [.history]),
        .copyMessage: ("Copy Commit Message", "c", 1, [.history]),
        .createBranch: ("Create Branch", "F7", 0, [.workspace, .history]),
        .createTag: ("Create Tag", "F7", 2, [.workspace, .history]),
        .show: ("Commit Details", "Return", 0, [.history]),
        .find: ("Filter Commits", "f", 1, [.history]),
        .refreshAlternate: ("Refresh Repository (Alternate)", "", 0, [.workspace, .history]),
        .clone: ("Clone Repository", "o", 3, [.workspace]),
        .filterFiles: ("Filter Files", "f", 1, [.files]),
        .selectCommittable: ("Select Committable Files", "a", 5, [.files]),
        .selectAllFiles: ("Select All Files", "a", 1, [.files]),
        .copyFiles: ("Copy Files", "c", 1, [.files]),
        .copyPath: ("Copy Path", "c", 5, [.files]),
        .copyRelativePath: ("Copy Relative Path", "c", 3, [.files]),
        .selectChildCommit: ("Select Child Commit", "Up", 4, [.history]),
        .selectParentCommit: ("Select Parent Commit", "Down", 4, [.history]),
        .showUnversionedFiles: ("Filter Unversioned Files", "2", 1, [.files]),
        .showIgnoredFiles: ("Show Ignored Files", "3", 1, [.files]),
        .pull: ("Pull", "PageDown", 1, [.workspace]),
        .fetch: ("Fetch", "PageDown", 3, [.workspace]),
        .push: ("Push", "PageUp", 1, [.workspace]),
        .editFile: ("Edit File", "Down", 1, [.files]),
        .ignore: ("Ignore", "i", 1, [.files]),
        .renameFile: ("Move or Rename File", "Return", 0, [.files]),
        .useCommitMessage: ("Use Message for Commit", "k", 3, [.history]),
        .discard: ("Discard", "z", 1, [.files]),
        .deleteFile: ("Delete File", "Backspace", 0, [.files]),
        .stash: ("Stash All", "s", 1, [.workspace]),
        .applyStash: ("Apply Stash", "s", 3, [.workspace, .stash]),
        .renameStash: ("Rename Stash", "F2", 0, [.stash]),
        .checkout: ("Check Out", "g", 1, [.history, .branch]),
        .rebase: ("Rebase", "d", 1, [.history, .branch]),
        .renameBranch: ("Rename Branch", "F2", 0, [.branch]),
        .compareFind: ("Find in Comparison", "f", 1, [.comparison]),
        .compareFindNext: ("Find Next", "g", 1, [.comparison]),
        .compareFindPrevious: ("Find Previous", "g", 3, [.comparison]),
        .comparePreviousChange: ("Previous Change", "F6", 2, [.comparison]),
        .compareNextChange: ("Next Change", "F6", 0, [.comparison]),
        .compareWrap: ("Wrap Lines", "", 0, [.comparison]),
        .compareSave: ("Save Comparison", "s", 1, [.comparison]),
        .compareReload: ("Reload Comparison", "F5", 2, [.comparison]),
        .compareNextConflict: ("Next Conflict", "k", 1, [.comparison]),
        .comparePreviousConflict: ("Previous Conflict", "k", 3, [.comparison]),
        .compareTakeLeft: ("Take Left Block", "Right", 9, [.comparison]),
        .compareTakeRight: ("Take Right Block", "Left", 9, [.comparison]),
        .compareReplace: ("Find and Replace", "r", 1, [.comparison]),
        .compareCompact: ("Compact Comparison", ".", 1, [.comparison]),
        .compareLines: ("Line Numbers", "", 0, [.comparison]),
        .compareSync: ("Synchronize Scrolling", "", 0, [.comparison]),
        .compareStage: ("Stage Comparison", "t", 1, [.comparison]),
    ]
    var title: String { Self.definitions[self]!.title }
    var scopes: Set<ShortcutScope> { Self.definitions[self]!.scopes }
    var worksWhileEditingText: Bool {
        switch self {
        case .activateRepositories, .activateBranches, .activateFiles, .activateChanges, .activateHistory, .activateCommit, .activateOutput,
             .findObject, .refresh, .refreshAlternate, .commit, .viewLog, .showLogWindow, .clone, .createBranch, .createTag,
             .pull, .fetch, .push, .reset, .resetAdvanced: return true
        default: return false
        }
    }
    var defaultBinding: ShortcutBinding {
        let value = Self.definitions[self]!
        return .init(key: value.key, modifiers: value.modifiers)
    }
    func overlaps(_ other: Self) -> Bool {
        if scopes.contains(.application) || other.scopes.contains(.application) { return true }
        let workspaceScopes: Set<ShortcutScope> = [.workspace, .files, .history, .branch, .stash]
        if scopes.contains(.workspace), !other.scopes.isDisjoint(with: workspaceScopes) { return true }
        if other.scopes.contains(.workspace), !scopes.isDisjoint(with: workspaceScopes) { return true }
        return !scopes.isDisjoint(with: other.scopes)
    }
    var historyAction: HistoryAction? {
        switch self {
        case .viewLog: return .viewLog
        case .reset: return .reset
        case .resetAdvanced: return .resetAdvanced
        case .copyHash: return .copyHash
        case .copyMessage: return .copyMessage
        case .createBranch: return .createBranch
        case .createTag: return .createTag
        case .show: return .show
        case .checkout: return .checkout
        case .rebase: return .rebase
        case .useCommitMessage: return .useCommitMessage
        default: return nil
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: String
    // Command, Shift, Option, Control; stable preference encoding independent of AppKit.
    var modifiers: Int
    static let keys = [""] + Array("abcdefghijklmnopqrstuvwxyz0123456789-.").map(String.init) + (1...20).map { "F\($0)" } + ["Return", "Tab", "Space", "Delete", "Backspace", "Up", "Down", "Left", "Right", "PageUp", "PageDown", "Home", "End"]
    var enabled: Bool
    init(key: String, modifiers: Int, enabled: Bool = true) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
        self.enabled = enabled
    }
    private enum CodingKeys: String, CodingKey { case key, modifiers, enabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try values.decode(String.self, forKey: .key)
        key = decodedKey.count == 1 ? decodedKey.lowercased() : decodedKey
        modifiers = try values.decode(Int.self, forKey: .modifiers)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
    static func supportsKey(_ key: String) -> Bool {
        keys.contains(key) || (key.count == 1 && key.lowercased().count == 1 && key.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) && !(0xF700...0xF8FF).contains($0.value)
        })
    }
    var hasAssignedKey: Bool { !key.isEmpty }
    var isAssigned: Bool { enabled && hasAssignedKey }
    var displayString: String {
        guard hasAssignedKey else { return shortcutText("Unassigned") }
        return [(8, "⌃"), (4, "⌥"), (2, "⇧"), (1, "⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            + (["Return": "↩", "Tab": "⇥", "Space": "␣", "Delete": "⌦", "Backspace": "⌫", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "PageUp": "⇞", "PageDown": "⇟", "Home": "↖", "End": "↘"][key] ?? key.uppercased())
    }
    var character: Character {
        if key == "Return" { return "\r" }
        if key == "Tab" { return "\t" }
        if key == "Space" { return " " }
        if key == "Delete" { return Character(UnicodeScalar(NSDeleteFunctionKey)!) }
        if key == "Backspace" { return "\u{7f}" }
        let special: [String: Int] = ["Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey, "Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey, "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey]
        if let code = special[key] { return Character(UnicodeScalar(code)!) }
        if key.hasPrefix("F"), let number = Int(key.dropFirst()) { return Character(UnicodeScalar(NSF1FunctionKey + number - 1)!) }
        return key.first ?? "\0"
    }
    var eventModifiers: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        for (bit, flag) in [(1, NSEvent.ModifierFlags.command), (2, .shift), (4, .option), (8, .control)] where modifiers & bit != 0 { value.insert(flag) }
        return value
    }
    var viewModifiers: EventModifiers {
        var value: EventModifiers = []
        for (bit, flag) in [(1, EventModifiers.command), (2, .shift), (4, .option), (8, .control)] where modifiers & bit != 0 { value.insert(flag) }
        return value
    }
    func matches(_ event: NSEvent) -> Bool {
        isAssigned && ((key == "Return" && [36, 76].contains(event.keyCode)) || event.charactersIgnoringModifiers?.lowercased() == String(character).lowercased())
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == eventModifiers
    }
}

final class KeyboardShortcuts: ObservableObject {
    static let shared = KeyboardShortcuts()
    @Published private(set) var bindings: [ShortcutCommand: ShortcutBinding] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacy = ShortcutRules.normalized(["open", "refresh", "stage", "commit"].map { defaults.string(forKey: "shortcut.\($0)") ?? "" })
        for (index, command) in [ShortcutCommand.open, .refresh, .stage, .commit].enumerated() {
            bindings[command] = .init(key: legacy[index], modifiers: 1)
        }
        bindings[.unstage] = .init(key: legacy[2], modifiers: 3)
        for command in ShortcutCommand.allCases {
            if let data = defaults.data(forKey: "shortcut.binding.\(command.rawValue)"),
               let value = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
                bindings[command] = value
            }
        }
        if !defaults.bool(forKey: "shortcut.deleteFile.backspaceMigrated") {
            if binding(.deleteFile) == .init(key: "Backspace", modifiers: 1) {
                bindings[.deleteFile] = ShortcutCommand.deleteFile.defaultBinding
                defaults.set(try? JSONEncoder().encode(ShortcutCommand.deleteFile.defaultBinding), forKey: "shortcut.binding.deleteFile")
            }
            defaults.set(true, forKey: "shortcut.deleteFile.backspaceMigrated")
        }
        if binding(.copyHash) == .init(key: "c", modifiers: 1) {
            bindings[.copyHash] = ShortcutCommand.copyHash.defaultBinding
        }
        // Only migrate legacy payloads; enabled-aware preferences are deliberate assignments.
        let refreshData = defaults.data(forKey: "shortcut.binding.refresh")
        let refreshPayload = refreshData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if refreshPayload?["enabled"] == nil, [.init(key: "r", modifiers: 1), .init(key: "r", modifiers: 5)].contains(binding(.refresh)) {
            bindings[.refresh] = ShortcutCommand.refresh.defaultBinding
        }
        if binding(.refreshAlternate) == binding(.refresh) { bindings[.refreshAlternate] = .init(key: "", modifiers: 0) }
        // Preserve saved custom chords first; collisions are contextual, not global.
        let commands = ShortcutCommand.allCases.filter { binding($0) != $0.defaultBinding }
            + ShortcutCommand.allCases.filter { binding($0) == $0.defaultBinding }
        var accepted: [ShortcutCommand] = []
        for command in commands {
            let value = binding(command)
            if !isAllowed(value, for: command) || (value.isAssigned && accepted.contains(where: { command.overlaps($0) && binding($0) == value })) {
                let candidate = command.defaultBinding
                let available = !candidate.isAssigned || !accepted.contains { command.overlaps($0) && binding($0) == candidate }
                bindings[command] = available ? candidate : .init(key: "", modifiers: 0)
            }
            accepted.append(command)
        }
    }
    func binding(_ command: ShortcutCommand) -> ShortcutBinding {
        if let binding = bindings[command] { return binding }
        return command.defaultBinding
    }
    private func isAllowed(_ value: ShortcutBinding, for command: ShortcutCommand) -> Bool {
        guard ShortcutBinding.supportsKey(value.key), (0...15).contains(value.modifiers) else { return false }
        if !value.hasAssignedKey { return value.modifiers == 0 }
        if (value.key.count == 1 || ["Tab", "Space"].contains(value.key)) && value.modifiers & (1 | 8) == 0 { return false }
        return true
    }
    func isValid(_ value: ShortcutBinding, for command: ShortcutCommand) -> Bool {
        isAllowed(value, for: command) && (!value.isAssigned || !ShortcutCommand.allCases.contains { $0 != command && command.overlaps($0) && binding($0) == value })
    }
    @discardableResult func set(_ value: ShortcutBinding, for command: ShortcutCommand) -> Bool {
        let value = ShortcutBinding(key: value.key, modifiers: value.modifiers, enabled: value.enabled)
        guard isValid(value, for: command), let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: "shortcut.binding.\(command.rawValue)")
        bindings[command] = value
        return true
    }
    @discardableResult func setEnabled(_ enabled: Bool, for command: ShortcutCommand) -> Bool {
        var value = binding(command)
        value.enabled = enabled
        return set(value, for: command)
    }
    func restoreDefaults() {
        for command in ShortcutCommand.allCases { defaults.removeObject(forKey: "shortcut.binding.\(command.rawValue)") }
        for (index, command) in [ShortcutCommand.open, .refresh, .stage, .commit].enumerated() { defaults.set(ShortcutRules.defaults[index], forKey: "shortcut.\(command.rawValue)") }
        bindings = [:]
    }
}

extension View {
    func configuredShortcut(_ command: ShortcutCommand, using shortcuts: KeyboardShortcuts) -> some View {
        let value = shortcuts.binding(command)
        return keyboardShortcut(value.isAssigned ? KeyboardShortcut(KeyEquivalent(value.character), modifiers: value.viewModifiers) : nil)
    }
}
