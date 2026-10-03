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
    @State private var loading = true
    struct TagRequest: Identifiable {
        let id = UUID()
        let repo: GitRepository
        let name: String
        let remote: String
        let delete: Bool
        let local: Bool
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workflowText("Tag Management")).font(.title2.weight(.semibold))
            Group {
                if loading || tags.isEmpty {
                    VStack(spacing: 12) {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "tag").font(.title2).foregroundStyle(.tertiary)
                        }
                        Text(panelText(loading ? "Loading tags…" : "No local tags")).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                } else {
                    Table(tags, selection: $selection) {
                        TableColumn(workflowText("Tag name"), value: \.name).width(min: 130, ideal: 190)
                        TableColumn(workflowText("Commit hash")) { tag in
                            Text(tag.commitHash ?? "—").font(.system(.caption, design: .monospaced)).lineLimit(1)
                        }.width(min: 140, ideal: 190)
                        TableColumn(workflowText("Annotation"), value: \.message)
                    }
                }
            }.frame(minHeight: 150, maxHeight: .infinity)
            GroupBox(workflowText("Create tag")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        field("Tag name", text: $name)
                        field("Target revision", text: $revision)
                        field("Annotation", text: $annotation)
                    }
                    HStack(spacing: 8) {
                        Toggle(workflowText("Signed tag"), isOn: $signed)
                        Spacer()
                        Button(workflowText("Create tag")) { create() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || revision.isEmpty)
                    }
                }.padding(8)
            }
            GroupBox(panelText("Tag synchronization")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(workflowText("Remote name")).font(.callout)
                            if remotes.isEmpty {
                                Text(panelText("No configured remotes")).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Picker(workflowText("Remote name"), selection: $remote) { ForEach(remotes, id: \.self) { Text($0).tag($0) } }
                                    .labelsHidden().fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        Spacer()
                        Button(workflowText("Fetch tags")) { fetch() }.disabled(remotes.isEmpty)
                        Button(workflowText("Preview tag push")) { preview(delete: false) }.disabled(selection == nil || remotes.isEmpty)
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Text(selection ?? panelText("Select a tag to synchronize or delete.")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button(workflowText("Delete local tag"), role: .destructive) {
                            if let repo = store.repository, let selected = selection { pending = TagRequest(repo: repo, name: selected, remote: "", delete: true, local: true) }
                        }.disabled(selection == nil)
                        Button(workflowText("Preview remote deletion"), role: .destructive) { preview(delete: true) }.disabled(selection == nil || remotes.isEmpty)
                    }
                }.padding(8)
            }
            if !output.isEmpty {
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 72)
            }
            Divider()
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(workflowText("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.controlSize(.small).disabled(store.isBusy).interactiveDismissDisabled(store.isBusy).padding(20).frame(width: 940, height: 640)
        .task { await reload() }
        .alert(item: $pending) { request in
            Alert(title: Text(workflowText("Confirm repository change")), message: Text(request.name + "\n" + request.remote + "\n" + output), primaryButton: .destructive(Text(workflowText("Continue"))) { publish(request) }, secondaryButton: .cancel(Text(workflowText("Cancel"))))
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(label)).font(.callout)
            TextField(workflowText(label), text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func reload() async {
        loading = true
        defer { loading = false }
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
