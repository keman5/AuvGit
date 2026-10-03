import SwiftUI
import GitCore

struct TagManagementView: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [ManagedTag] = []
    @State private var selection: String?
    @State private var name = ""
    @State private var revision = "HEAD"
    @State private var annotation = ""
    @State private var signed = false
    @State private var remotes: [String] = []
    @State private var remote = "origin"
    @State private var output = ""
    @State private var pending: TagRequest?
    @State private var reloadID = UUID()
    struct TagRequest: Identifiable {
        let id = UUID()
        let repo: GitRepository
        let name: String
        let remote: String
        let delete: Bool
        let local: Bool
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(workflowText("Tag Management")).font(.title2); Spacer(); Button(workflowText("Close")) { dismiss() }.disabled(store.isBusy) }
            Table(tags, selection: $selection) {
                TableColumn(workflowText("Tag name"), value: \.name)
                TableColumn(workflowText("Commit hash"), value: \.hash)
                TableColumn(workflowText("Annotation"), value: \.message)
            }.frame(minHeight: 180)
            HStack { TextField(workflowText("Tag name"), text: $name); TextField(workflowText("Target revision"), text: $revision) }
            TextField(workflowText("Annotation"), text: $annotation)
            HStack { Toggle(workflowText("Signed tag"), isOn: $signed); Spacer(); Button(workflowText("Create tag")) { create() }.disabled(name.isEmpty || revision.isEmpty) }
            Divider()
            HStack {
                Picker(workflowText("Remote name"), selection: $remote) { ForEach(remotes, id: \.self) { Text($0).tag($0) } }.frame(width: 180)
                Button(workflowText("Fetch tags")) { fetch() }.disabled(remotes.isEmpty)
                Button(workflowText("Preview tag push")) { preview(delete: false) }.disabled(selection == nil || remotes.isEmpty)
                Button(workflowText("Preview remote deletion")) { preview(delete: true) }.disabled(selection == nil || remotes.isEmpty)
                Button(workflowText("Delete local tag")) { if let repo = store.repository, let selected = selection { pending = TagRequest(repo: repo, name: selected, remote: "", delete: true, local: true) } }.disabled(selection == nil)
            }
            ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
        }.disabled(store.isBusy).interactiveDismissDisabled(store.isBusy).padding(20).frame(width: 940, height: 650)
        .task { await reload() }
        .alert(item: $pending) { request in
            Alert(title: Text(workflowText("Confirm repository change")), message: Text(request.name + "\n" + request.remote + "\n" + output), primaryButton: .destructive(Text(workflowText("Continue"))) { publish(request) }, secondaryButton: .cancel(Text(workflowText("Cancel"))))
        }
    }
    private func reload() async {
        guard let repo = store.repository else { return }; let token = UUID(); reloadID = token
        do { let newTags = try await repo.managedTags(); let newRemotes = try await repo.workflowRead(["remote"]).split(separator: "\n").map(String.init); guard reloadID == token, store.repositoryURL == repo.url else { return }; tags = newTags; remotes = newRemotes; if let selection, !tags.contains(where: { $0.name == selection }) { self.selection = nil }; if !remotes.contains(remote) { remote = remotes.first ?? "" } } catch { output = error.localizedDescription }
    }
    private func create() {
        guard let repo = store.repository, !store.isBusy else { return }
        let tag = name, ref = revision, message = annotation, sign = signed
        store.isBusy = true
        Task { do { try await repo.createManagedTag(name: tag, revision: ref, message: message, signed: sign); output = workflowText("Completed") } catch { output = error.localizedDescription }; store.isBusy = false; await reload(); await store.refresh() }
    }
    private func fetch() {
        guard let repo = store.repository, !store.isBusy else { return }; let target = remote
        store.isBusy = true
        Task { do { output = try await repo.fetchTags(remote: target) } catch { output = error.localizedDescription }; store.isBusy = false; await reload(); await store.refresh() }
    }
    private func preview(delete: Bool) {
        guard let repo = store.repository, let selected = selection, !store.isBusy else { return }
        let request = TagRequest(repo: repo, name: selected, remote: remote, delete: delete, local: false)
        store.isBusy = true
        Task { do { output = try await repo.synchronizeTag(name: request.name, remote: request.remote, delete: delete, preview: true); pending = request } catch { output = error.localizedDescription }; store.isBusy = false }
    }
    private func publish(_ request: TagRequest) {
        guard store.repositoryURL == request.repo.url, !store.isBusy else { return }
        store.isBusy = true
        Task { do { if request.local { output = try await request.repo.advancedOperation(.tagDelete, first: request.name, second: "") } else { output = try await request.repo.synchronizeTag(name: request.name, remote: request.remote, delete: request.delete, preview: false) } } catch { output = error.localizedDescription }; store.isBusy = false; await reload(); await store.refresh() }
    }
}
