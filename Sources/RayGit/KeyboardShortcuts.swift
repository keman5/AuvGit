import AppKit
import SwiftUI
import GitCore
import RayGitLocalization

func shortcutText(_ key: String) -> String { L10n.text(key, table: "KeyboardShortcuts") }

enum ShortcutCommand: String, CaseIterable {
    case open, refresh, stage, unstage, commit, viewLog, reset, resetAdvanced, copyHash, createBranch, createTag, show, find, refreshAlternate
    var title: String {
        switch self {
        case .open: return "Open Repository"
        case .refresh: return "Refresh Repository"
        case .stage: return "Stage"
        case .unstage: return "Unstage"
        case .commit: return "Commit"
        case .viewLog: return "View Log"
        case .reset: return "Hard Reset"
        case .resetAdvanced: return "Advanced Reset"
        case .copyHash: return "Copy Commit Hash"
        case .createBranch: return "Create Branch"
        case .createTag: return "Create Tag"
        case .show: return "Commit Details"
        case .find: return "Filter Commits"
        case .refreshAlternate: return "Refresh Repository (Alternate)"
        }
    }
    var historyAction: HistoryAction? {
        switch self {
        case .viewLog: return .viewLog
        case .reset: return .reset
        case .resetAdvanced: return .resetAdvanced
        case .copyHash: return .copyHash
        case .createBranch: return .createBranch
        case .createTag: return .createTag
        case .show: return .show
        default: return nil
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .open: return .init(key: "o", modifiers: 1)
        case .refresh: return .init(key: "r", modifiers: 5)
        case .reset: return .init(key: "r", modifiers: 1)
        case .stage: return .init(key: "t", modifiers: 1)
        case .unstage: return .init(key: "t", modifiers: 3)
        case .commit: return .init(key: "k", modifiers: 1)
        case .viewLog: return .init(key: "l", modifiers: 1)
        case .resetAdvanced: return .init(key: "r", modifiers: 3)
        case .copyHash: return .init(key: "c", modifiers: 1)
        case .createBranch: return .init(key: "F7", modifiers: 0)
        case .createTag: return .init(key: "F7", modifiers: 2)
        case .show: return .init(key: "Return", modifiers: 0)
        case .find: return .init(key: "f", modifiers: 1)
        case .refreshAlternate: return .init(key: "F5", modifiers: 0)
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: String
    // Command, Shift, Option, Control; stable preference encoding independent of AppKit.
    var modifiers: Int
    static let keys = Array("abcdefghijklmnopqrstuvwxyz").map(String.init) + (1...12).map { "F\($0)" } + ["Return"]
    var displayString: String {
        [(8, "⌃"), (4, "⌥"), (2, "⇧"), (1, "⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            + (key == "Return" ? "↩" : key.uppercased())
    }
    var character: Character {
        if key == "Return" { return "\r" }
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
        event.charactersIgnoringModifiers?.lowercased() == String(character).lowercased()
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
        // Cmd+R used to refresh and reset; keep it exclusively for reset.
        if binding(.refresh) == ShortcutCommand.reset.defaultBinding { bindings[.refresh] = ShortcutCommand.refresh.defaultBinding }
        // Preserve valid swaps and customized bindings before repairing collisions.
        let commands = [ShortcutCommand.reset] + ShortcutCommand.allCases.filter { $0 != .reset && binding($0) != $0.defaultBinding }
            + ShortcutCommand.allCases.filter { $0 != .reset && binding($0) == $0.defaultBinding }
        var used: [ShortcutBinding] = []
        var repair: [ShortcutCommand] = []
        for command in commands {
            let value = binding(command)
            if isAllowed(value, for: command), !used.contains(value) { used.append(value) }
            else { repair.append(command) }
        }
        for command in repair {
            let candidates = [command.defaultBinding] + Array("abcdefghijklmnopqrstuvwxyz").map { ShortcutBinding(key: String($0), modifiers: 5) }
            let value = candidates.first { isAllowed($0, for: command) && !used.contains($0) }!
            bindings[command] = value; used.append(value)
        }
    }
    func binding(_ command: ShortcutCommand) -> ShortcutBinding {
        if let binding = bindings[command] { return binding }
        return command.defaultBinding
    }
    private func isAllowed(_ value: ShortcutBinding, for command: ShortcutCommand) -> Bool {
        guard ShortcutBinding.keys.contains(value.key), (0...15).contains(value.modifiers) else { return false }
        if value.key.count == 1 {
            guard value.modifiers & (1 | 8) != 0 else { return false }
            if value.modifiers == 1, Set("qwhmcvxzafseg".map(String.init)).contains(value.key) {
                guard (command == .copyHash && value.key == "c") || (command == .find && value.key == "f") else { return false }
            }
        }
        if value.modifiers == 3, ["s", "z", "g", "q"].contains(value.key) { return false }
        if value.modifiers == 8, Set("aebfnphdkltouvyw".map(String.init)).contains(value.key) { return false }
        if value.key == "Return" && value.modifiers == 0 && command != .show { return false }
        if value.modifiers == 5, ["h", "m", "w", "c", "v", "f", "d"].contains(value.key) { return false }
        if value.modifiers == 7, ["v", "q"].contains(value.key) { return false }
        if value.modifiers == 9, ["f", "q"].contains(value.key) { return false }
        return true
    }
    func isValid(_ value: ShortcutBinding, for command: ShortcutCommand) -> Bool {
        isAllowed(value, for: command) && !ShortcutCommand.allCases.contains { $0 != command && binding($0) == value }
    }
    @discardableResult func set(_ value: ShortcutBinding, for command: ShortcutCommand) -> Bool {
        guard isValid(value, for: command), let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: "shortcut.binding.\(command.rawValue)")
        bindings[command] = value
        return true
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
        return keyboardShortcut(KeyEquivalent(value.character), modifiers: value.viewModifiers)
    }
}
