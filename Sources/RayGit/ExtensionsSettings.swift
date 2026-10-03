import SwiftUI
import AppKit
import GitCore

struct ExtensionsSettings: View {
    enum Page { case all, shortcuts, workflow, updates }
    var page: Page = .all
    @ObservedObject var store: RepositoryStore
    @AppStorage("shortcut.open") private var openKey = "o"
    @AppStorage("shortcut.refresh") private var refreshKey = "r"
    @AppStorage("shortcut.stage") private var stageKey = "t"
    @AppStorage("shortcut.commit") private var commitKey = "k"
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
    private var keys: [String] { [openKey, refreshKey, stageKey, commitKey] }
    private var validKeys: Bool { keys.allSatisfy { ShortcutRules.isValid($0) } && Set(keys.map { $0.lowercased() }).count == 4 }
    var body: some View {
        Form {
            if page == .all || page == .shortcuts {
            Section(compareText("Keyboard Shortcuts")) {
                shortcut("Open Repository", $openKey)
                shortcut("Refresh", $refreshKey)
                shortcut("Stage", $stageKey)
                shortcut("Commit", $commitKey)
                if let shortcutError { Text(shortcutError).font(.caption).foregroundStyle(.orange) }
                if !validKeys { Text(compareText("Use four distinct single letters; shortcuts use Command.")).font(.caption).foregroundStyle(.orange) }
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
                        Task { do { NSWorkspace.shared.open(try await repository.reviewURL(target: reviewTarget)) } catch { message = compareText(error.localizedDescription) } }
                    }.disabled(store.repository == nil || reviewTarget.isEmpty)
                }
            }
            }
            if page == .all || page == .updates {
            Section(compareText("Updates")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(compareText("Trusted HTTPS Manifest URL"))
                    TextField(compareText("Trusted HTTPS Manifest URL"), text: $manifestURL).labelsHidden().textFieldStyle(.roundedBorder)
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
            .onAppear { repairShortcuts() }
            .onChange(of: manifestURL) { _, _ in updateGeneration += 1; updateTask?.cancel(); checking = false; update = nil; checkedSource = nil; message = "" }
            .onDisappear { updateGeneration += 1; updateTask?.cancel(); checking = false }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(compareText(title)) {
            TextField(compareText(title), text: text).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 280)
        }
    }
    private func shortcut(_ title: String, _ key: Binding<String>) -> some View {
        LabeledContent(compareText(title)) {
            HStack(spacing: 8) {
                Text("⌘").foregroundStyle(.secondary)
                TextField(compareText(title), text: Binding(get: { key.wrappedValue }, set: { new in
                    let value = new.lowercased()
                    let index = ["Open Repository", "Refresh", "Stage", "Commit"].firstIndex(of: title) ?? 0
                    let other = keys.enumerated().filter { $0.offset != index }.map(\.element)
                    if ShortcutRules.isValid(value), !other.map({ $0.lowercased() }).contains(value) { key.wrappedValue = value; shortcutError = nil }
                    else { shortcutError = compareText("Shortcut conflicts with another action or a macOS command.") }
                })).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(width: 44)
            }
        }
    }
    private func repairShortcuts() {
        let repaired = ShortcutRules.normalized(keys)
        openKey = repaired[0]; refreshKey = repaired[1]; stageKey = repaired[2]; commitKey = repaired[3]
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
                checking = false; message = compareText(error.localizedDescription)
            }
        }
    }
    private func flow(finish: Bool) {
        guard !store.isBusy, let repository = store.repository else { return }
        let selectedKind = kind, name = flowName, main = mainBranch, develop = developBranch
        store.isBusy = true
        Task {
            do { if finish { try await repository.finishGitFlow(kind: selectedKind, name: name, main: main, develop: develop) } else { try await repository.startGitFlow(kind: selectedKind, name: name, main: main, develop: develop) }; message = compareText("Git Flow completed") }
            catch { message = compareText(error.localizedDescription) }
            store.isBusy = false; await store.refresh()
        }
    }
}
