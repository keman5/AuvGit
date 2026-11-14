import AppKit
import SwiftUI
import GitCore
import AuvGitLocalization

func comparisonParityText(_ key: String) -> String { L10n.text(key, table: "ComparisonParity") }

struct ComparisonParityMenu: View {
    @ObservedObject var session: FileCompareSession
    var body: some View {
        Menu {
            Button(comparisonParityText("saveWorktree")) { Task { _ = await session.saveToWorktree() } }
                .disabled(!session.isDirty || session.isBusy)
            Button(comparisonParityText("saveIndex")) { Task { _ = await session.saveIndexDraft() } }
                .disabled(!session.isDirty("index") || session.isHistorical || session.snapshot?.isConflict == true || session.isBusy)
            Divider()
            Toggle(comparisonParityText("ignoreWhitespace"), isOn: $session.ignoreWhitespace)
            Toggle(comparisonParityText("ignoreCase"), isOn: $session.ignoreCase)
            Toggle(comparisonParityText("ignoreEndings"), isOn: $session.ignoreLineEndings)
            Divider()
            Picker(comparisonParityText("language"), selection: $session.languageOverride) {
                Text(comparisonParityText("automatic")).tag("automatic")
                Text(comparisonParityText("plain")).tag("plain")
                Text("Swift").tag("swift"); Text("JavaScript / TypeScript").tag("ts")
                Text("Python").tag("py"); Text("Shell").tag("sh")
                Text("C / C++ / Objective-C").tag("cpp"); Text("Go").tag("go")
                Text("Rust").tag("rs"); Text("Java / Kotlin").tag("java")
                Text("JSON").tag("json"); Text("YAML / TOML").tag("yaml")
                Text("HTML / XML").tag("html"); Text("Ruby").tag("rb")
            }
            Divider()
            Button(comparisonParityText(session.forceCompare ? "endForce" : "forceCompare")) {
                if session.forceCompare { session.cancelForceCompare() } else { session.requestForceCompare() }
            }.disabled(session.preparingForceCompare || session.snapshot == nil)
        } label: { ComparisonToolbarIcon(name: "slider.horizontal.3") }
        .buttonStyle(ComparisonToolbarButtonStyle()).menuIndicator(.hidden).menuStyle(.borderlessButton)
        .help(comparisonParityText("comparisonOptions")).accessibilityLabel(comparisonParityText("comparisonOptions"))
    }
}

@MainActor
enum BaseComparisonPresenter {
    private static var windows: [NSWindowController] = []
    static func show(snapshot: FileComparisonSnapshot, path: String) {
        guard let base = snapshot.base else { return }
        windows.removeAll { $0.window?.isVisible != true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = comparisonParityText("compareBase") + " — " + path
        window.isReleasedWhenClosed = false
        let versions = [("base", comparisonParityText("base"), base), ("ours", compareText("Ours (Stage 2)"), snapshot.ours), ("theirs", compareText("Theirs (Stage 3)"), snapshot.theirs)].compactMap { id, title, content -> ComparisonEditorColumn? in
            guard let content else { return nil }
            return ComparisonEditorColumn(id: id, title: title, text: content.text ?? "", isEditable: false, message: content.unavailableReason, lineEnding: content.data.map { ComparisonTextDecoder.format(of: $0).lineEnding } ?? .lf)
        }
        window.contentView = NSHostingView(rootView: BaseComparisonContent(columns: versions, path: path).nativeFocusRoot())
        let controller = NSWindowController(window: window); windows.append(controller)
        window.center(); controller.showWindow(nil)
    }
}

private struct BaseComparisonContent: View {
    let columns: [ComparisonEditorColumn]
    let path: String
    @State private var search = ComparisonSearchOptions()
    @State private var navigation = 0
    @State private var changes = 0
    @State private var wraps = false
    @State private var rules = ComparisonRules()
    @StateObject private var commands = ComparisonEditingCommands()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(comparisonSearchText("Find"), text: $search.query).frame(width: 220)
                Button(compareText("Previous change")) { changes -= 1 }.disabled(!commands.canNavigatePreviousChange)
                Button(compareText("Next change")) { changes += 1 }.disabled(!commands.canNavigateNextChange)
                Button(comparisonSearchText("Previous match")) { navigation -= 1 }
                Button(comparisonSearchText("Next match")) { navigation += 1 }
                Text("\(commands.searchCurrent)/\(commands.searchTotal)").monospacedDigit()
                Toggle(designCompareText("Wrap"), isOn: $wraps)
                Menu(comparisonParityText("comparisonOptions")) {
                    Toggle(comparisonParityText("ignoreWhitespace"), isOn: $rules.ignoreWhitespace)
                    Toggle(comparisonParityText("ignoreCase"), isOn: $rules.ignoreCase)
                    Toggle(comparisonParityText("ignoreEndings"), isOn: $rules.ignoreLineEndings)
                }
            }.controlSize(.small).padding(10)
            Divider()
            ComparisonEditor(columns: columns, wrapLines: wraps, showLineNumbers: true, synchronizeScroll: true, search: search.query, navigation: navigation, changeNavigation: changes, onEdit: { _, _ in }, languagePath: path, comparisonRules: rules, editingCommands: commands, searchOptions: search)
        }
    }
}
