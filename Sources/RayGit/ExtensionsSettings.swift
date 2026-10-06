import SwiftUI
import AppKit
import GitCore

struct ExtensionsSettings: View {
    enum Page { case all, shortcuts, workflow, updates }
    var page: Page = .all
    @ObservedObject var store: RepositoryStore
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @AppStorage("updates.manifest") private var manifestURL = ""
    @State private var kind = GitFlowKind.feature
    @State private var flowName = ""
    @State private var mainBranch = "main"
    @State private var developBranch = "develop"
    @State private var reviewTarget = "main"
    @State private var message = ""
    @State private var update: UpdateManifest?
    @State private var checking = false
    @State private var updateGeneration = 0
    @State private var updateTask: Task<Void, Never>?
    @State private var checkedSource: URL?
    @State private var shortcutError: String?
    var body: some View {
        Form {
            if page == .all || page == .shortcuts {
            Section(compareText("Keyboard Shortcuts")) {
                ForEach(ShortcutCommand.allCases, id: \.self) { command in shortcut(command) }
                Text(shortcutText("Letter shortcuts require Command or Control. Copy and Return keep native text editing."))
                    .font(.caption).foregroundStyle(.secondary)
                if let shortcutError { Text(shortcutError).font(.caption).foregroundStyle(.orange) }
                Button(shortcutText("Restore Defaults")) { shortcuts.restoreDefaults(); shortcutError = nil }
            }
            }
            if page == .all || page == .workflow {
            Section("Git Flow") {
                Picker(compareText("Kind"), selection: $kind) { ForEach(GitFlowKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                field("Name", text: $flowName)
                field("Main Branch", text: $mainBranch)
                field("Develop Branch", text: $developBranch)
                Text(compareText("Finish merges locally and removes only a merged branch. Release and hotfix create a tag named after the branch suffix."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Spacer()
                    Button(compareText("Start Git Flow")) { flow(finish: false) }
                    Button(compareText("Finish Git Flow")) { flow(finish: true) }
                }.disabled(store.repository == nil || store.isBusy || flowName.isEmpty)
            }
            Section(compareText("Pull / Merge Request")) {
                field("Target Branch", text: $reviewTarget)
                HStack {
                    Spacer()
                    Button(compareText("Open Review Page")) {
                        guard let repository = store.repository else { return }
                        Task { do { NSWorkspace.shared.open(try await repository.reviewURL(target: reviewTarget)) } catch { message = compareText(OperationFailure.message(error, repository: store.repositoryURL)) } }
                    }.disabled(store.repository == nil || reviewTarget.isEmpty)
                }
            }
            }
            if page == .all || page == .updates {
            Section(compareText("Updates")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(compareText("Trusted HTTPS Manifest URL"))
                    StableTextField(compareText("Trusted HTTPS Manifest URL"), text: $manifestURL).labelsHidden().textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(compareText("Check for Updates")) { checkUpdates() }.disabled(checking || manifestURL.isEmpty)
                }
                if let checkedSource { Text(checkedSource.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let update {
                    LabeledContent(compareText("Available Version"), value: update.version)
                    if let notes = update.notes { Text(notes).font(.caption).foregroundStyle(.secondary) }
                    HStack { Spacer(); Link(compareText("Download Release"), destination: update.downloadURL) }
                }
            }
            }
            if !message.isEmpty {
                Section(panelText("Results")) { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }.formStyle(.grouped).controlSize(.small)
            .onChange(of: manifestURL) { _, _ in updateGeneration += 1; updateTask?.cancel(); checking = false; update = nil; checkedSource = nil; message = "" }
            .onDisappear { updateGeneration += 1; updateTask?.cancel(); checking = false }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(compareText(title)) {
            StableTextField(compareText(title), text: text).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 280)
        }
    }
    private func shortcut(_ command: ShortcutCommand) -> some View {
        LabeledContent(shortcutText(command.title)) {
            HStack(spacing: 6) {
                ForEach([(1, "⌘"), (2, "⇧"), (4, "⌥"), (8, "⌃")], id: \.0) { bit, symbol in
                    Toggle(symbol, isOn: Binding(get: { shortcuts.binding(command).modifiers & bit != 0 }, set: { enabled in
                        var value = shortcuts.binding(command)
                        if enabled { value.modifiers |= bit } else { value.modifiers &= ~bit }
                        saveShortcut(value, command)
                    })).toggleStyle(.button).accessibilityLabel(shortcutText(command.title) + ": " + shortcutText([1: "Command", 2: "Shift", 4: "Option", 8: "Control"][bit]!)).help(shortcutText([1: "Command", 2: "Shift", 4: "Option", 8: "Control"][bit]!))
                }
                Picker(shortcutText("Key"), selection: Binding(get: { shortcuts.binding(command).key }, set: { key in
                    var value = shortcuts.binding(command); value.key = key; saveShortcut(value, command)
                })) {
                    ForEach(ShortcutBinding.keys, id: \.self) { key in Text(key == "Return" ? shortcutText("Return") : key.uppercased()).tag(key) }
                }.labelsHidden().accessibilityLabel(shortcutText(command.title) + ": " + shortcutText("Key")).frame(width: 90)
            }
        }
    }
    private func saveShortcut(_ value: ShortcutBinding, _ command: ShortcutCommand) {
        shortcutError = shortcuts.set(value, for: command) ? nil : shortcutText("Shortcut conflicts with another action or a macOS command.")
    }
    private func checkUpdates() {
        guard let url = URL(string: manifestURL) else { message = compareText("Invalid update manifest."); return }
        updateGeneration += 1
        let generation = updateGeneration
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        checking = true; update = nil; checkedSource = url; message = ""
        updateTask?.cancel()
        updateTask = Task {
            do {
                let manifest = try await UpdateManifest.fetch(from: url)
                let newer = try UpdateManifest.isNewer(manifest.version, than: installed)
                guard generation == updateGeneration, !Task.isCancelled else { return }
                checking = false
                if newer { update = manifest } else { message = compareText("This installation is up to date.") }
            } catch {
                guard generation == updateGeneration, !Task.isCancelled else { return }
                checking = false; message = compareText(OperationFailure.message(error, repository: store.repositoryURL))
            }
        }
    }
    private func flow(finish: Bool) {
        guard !store.isBusy, let repository = store.repository else { return }
        let selectedKind = kind, name = flowName, main = mainBranch, develop = developBranch
        store.isBusy = true
        Task {
            do { if finish { try await repository.finishGitFlow(kind: selectedKind, name: name, main: main, develop: develop) } else { try await repository.startGitFlow(kind: selectedKind, name: name, main: main, develop: develop) }; message = compareText("Git Flow completed") }
            catch { message = compareText(OperationFailure.message(error, repository: store.repositoryURL)) }
            store.isBusy = false; await store.refresh()
        }
    }
}
