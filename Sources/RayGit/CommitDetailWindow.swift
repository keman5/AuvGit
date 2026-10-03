import AppKit
import SwiftUI
import GitCore
import RayGitLocalization

@MainActor
enum CommitDetailPresenter {
    private static var controllers: [UUID: CommitDetailWindowController] = [:]
    static func show(commit: GitCommit, repository: GitRepository) {
        let id = UUID()
        let controller = CommitDetailWindowController(commit: commit, repository: repository) {
            controllers.removeValue(forKey: id)
        }
        controllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class CommitDetailWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    init(commit: GitCommit, repository: GitRepository, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = commit.shortHash + " — " + commit.subject
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CommitDetailView(commit: commit, repository: repository))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct CommitDetailView: View {
    let commit: GitCommit
    let repository: GitRepository
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    @State private var files: [GitCommitFile] = []
    @State private var selection: String?
    @State private var diff = ""
    @State private var loadingFiles = true
    @State private var loadingDiff = false
    @State private var filesError: String?
    @State private var diffError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(commit.hash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button(historyActionText("copyHash")) { copy(commit.hash) }
                    Button(historyActionText("copyMessage")) { copy(commit.body.isEmpty ? commit.subject : commit.body) }
                }
                HStack {
                    Text(commit.author).textSelection(.enabled)
                    Spacer()
                    Text(commit.date, format: .dateTime.year().month().day().hour().minute().second().locale(L10n.locale)).foregroundStyle(.secondary)
                }.font(.caption)
                ScrollView { Text(commit.body.isEmpty ? commit.subject : commit.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 130)
            }.padding(12)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(historyActionText("files")).font(.headline).padding(10)
                    Divider()
                    if loadingFiles { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let filesError { Text(filesError).foregroundStyle(.red).textSelection(.enabled).padding() }
                    else if files.isEmpty { Text(historyActionText("noFiles")).foregroundStyle(.secondary).padding() }
                    else {
                        List(files, selection: $selection) { file in
                            HStack(spacing: 8) {
                                Text(file.status).font(.system(.caption, design: .monospaced))
                                Text(file.path).font(.system(size: 12)).lineLimit(2)
                            }.tag(file.path).help(file.originalPath.map { $0 + " → " + file.path } ?? file.path)
                        }.listStyle(.plain)
                    }
                }.frame(minWidth: 180, idealWidth: 250, maxWidth: 330)
                VStack(spacing: 0) {
                    if let diffError { Text(diffError).foregroundStyle(.red).textSelection(.enabled).padding() }
                    DiffPane(text: diff, title: selection ?? historyActionText("show"), isLoading: loadingDiff)
                }.frame(minWidth: 420)
            }
        }.environment(\.locale, L10n.locale).id(language)
            .task {
                loadingFiles = true
                do {
                    let result = try await repository.commitFiles(hash: commit.hash)
                    guard !Task.isCancelled else { return }
                    files = result; selection = result.first?.path; filesError = nil
                } catch { if !Task.isCancelled { filesError = error.localizedDescription } }
                loadingFiles = false
            }
            .task(id: selection) {
                diff = ""; diffError = nil; loadingDiff = false
                guard let path = selection else { return }
                loadingDiff = true
                do {
                    let result = try await repository.diff(target: .commit(hash: commit.hash, path: path))
                    guard !Task.isCancelled, selection == path else { return }
                    diff = result
                } catch {
                    guard !Task.isCancelled, selection == path else { return }
                    diffError = error.localizedDescription
                }
                loadingDiff = false
            }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
