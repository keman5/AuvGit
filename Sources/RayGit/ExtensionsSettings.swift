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
    @State private var shortcutDrafts: [ShortcutCommand: ShortcutBinding] = [:]
    var body: some View {
        Form {
            if page == .all || page == .shortcuts {
            Section(compareText("Keyboard Shortcuts")) {
                ForEach(ShortcutCommand.allCases, id: \.self) { command in shortcut(command) }
                Button(shortcutText("Restore Defaults")) { shortcuts.restoreDefaults(); shortcutDrafts = [:] }
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
        let value = shortcutDrafts[command] ?? shortcuts.binding(command)
        let draft = Binding(get: { shortcutDrafts[command] ?? shortcuts.binding(command) }, set: { saveShortcut($0, command) })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Text(shortcutText(command.title)).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    ShortcutModifiers(modifiers: Binding(get: { draft.wrappedValue.modifiers }, set: { draft.wrappedValue.modifiers = $0 }))
                        .fixedSize(horizontal: true, vertical: false).frame(height: 24)
                    ShortcutRecorder(value: value, label: shortcutText(command.title) + ": " + shortcutText("Key")) { saveShortcut($0, command) }
                        .frame(width: 88, height: 24)
                        .overlay(alignment: .trailing) {
                            Button { var cleared = draft.wrappedValue; cleared.key = ""; cleared.modifiers = 0; draft.wrappedValue = cleared } label: {
                                Image(systemName: "xmark.circle")
                            }.buttonStyle(.plain).frame(width: 20, height: 24).padding(.trailing, 2)
                                .help(shortcutText("Clear Shortcut"))
                                .accessibilityLabel(shortcutText(command.title) + ": " + shortcutText("Clear Shortcut"))
                        }
                }
                Toggle(shortcutText("Enabled"), isOn: Binding(get: { draft.wrappedValue.enabled }, set: { draft.wrappedValue.enabled = $0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).frame(width: 36).padding(.leading, 8)
                    .accessibilityLabel(shortcutText(command.title) + ": " + shortcutText("Enabled"))
            }
            if !shortcuts.isValid(value, for: command) {
                Text(shortcutText("Shortcut conflicts with another enabled action or needs Command/Control."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private func saveShortcut(_ value: ShortcutBinding, _ command: ShortcutCommand) {
        shortcutDrafts[command] = value
        if shortcuts.set(value, for: command) { shortcutDrafts.removeValue(forKey: command) }
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
            await store.cancelBackgroundRepositorySync()
            do { if finish { try await repository.finishGitFlow(kind: selectedKind, name: name, main: main, develop: develop) } else { try await repository.startGitFlow(kind: selectedKind, name: name, main: main, develop: develop) }; message = compareText("Git Flow completed") }
            catch { message = compareText(OperationFailure.message(error, repository: store.repositoryURL)) }
            store.isBusy = false; await store.refresh()
        }
    }
}
