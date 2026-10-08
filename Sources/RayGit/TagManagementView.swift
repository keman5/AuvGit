import SwiftUI
import GitCore
import AppKit

struct TagManagementView: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [ManagedTag] = []
    @State private var selection: String?
    @State private var name = ""
    @State private var revision = "HEAD"
    @State private var annotation = ""
    @State private var tagKind = "lightweight"
    @State private var showCreate = false
    @State private var query = ""
    @State private var typeFilter = "all"
    @State private var tagTypes: [String: String] = [:]
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
    private var filteredTags: [ManagedTag] {
        tags.filter { tag in
            let matchesType = typeFilter == "all" || tagTypes[tag.name] == typeFilter
            return matchesType && (query.isEmpty || [tag.name, tag.commitHash ?? "", tag.message].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                DesignPageHeading(title: workflowText("Tag Management"), subtitle: designText("View and manage repository Git tags"))
                Button { showCreate = true } label: { Label(workflowText("Create tag"), systemImage: "plus") }.buttonStyle(.borderedProminent)
                Button { fetch() } label: { Label(workflowText("Fetch tags"), systemImage: "arrow.down.to.line") }.disabled(remotes.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    DesignActionChip(title: designText("Local tags") + "  \(tags.count)")
                    Picker(designText("Tag type"), selection: $typeFilter) {
                        Text(designText("All types")).tag("all")
                        Text(designText("Lightweight")).tag("commit")
                        Text(designText("Annotated")).tag("tag")
                    }.frame(width: 170)
                    Spacer()
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        StableTextField(designText("Search tags, annotations or commits"), text: $query, rounded: false)
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }.padding(8).frame(width: 300).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                }
                Group {
                    if loading || tags.isEmpty || filteredTags.isEmpty {
                        VStack(spacing: 12) {
                            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "tag").font(.system(size: 27)).foregroundStyle(.tertiary) }
                            Text(loading ? panelText("Loading tags…") : tags.isEmpty ? panelText("No local tags") : designText("No matching tags")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(filteredTags, selection: $selection) {
                            TableColumn(workflowText("Tag name")) { tag in
                                Label(tag.name, systemImage: "tag").font(.system(size: 13, weight: .medium))
                            }.width(min: 140, ideal: 180)
                            TableColumn(designText("Tag type")) { tag in
                                if let type = tagTypes[tag.name] {
                                    DesignActionChip(title: designText(type == "tag" ? "Annotated" : type == "commit" ? "Lightweight" : "Other"), color: type == "tag" ? .blue : .secondary)
                                }
                            }.width(110)
                            TableColumn(workflowText("Commit hash")) { tag in
                                HStack(spacing: 8) {
                                    Text(tag.commitHash.map { String($0.prefix(10)) } ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    if let hash = tag.commitHash {
                                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hash, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                                            .buttonStyle(.plain).foregroundStyle(.secondary).help(designText("Copy commit hash"))
                                    }
                                }
                            }.width(min: 150, ideal: 180)
                            TableColumn(workflowText("Annotation"), value: \.message)
                        }
                    }
                }.frame(minHeight: 230, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                DesignCard {
                    HStack(spacing: 12) {
                        if remotes.isEmpty {
                            Text(panelText("No configured remotes")).foregroundStyle(.secondary)
                        } else {
                            Picker(workflowText("Remote name"), selection: $remote) { ForEach(remotes, id: \.self) { Text($0).tag($0) } }.frame(width: 200)
                        }
                        Spacer()
                        Button { preview(delete: false) } label: { Label(workflowText("Preview tag push"), systemImage: "square.and.arrow.up") }.disabled(selection == nil || remotes.isEmpty)
                        Button(workflowText("Delete local tag"), role: .destructive) {
                            if let repo = store.repository, let selected = selection { pending = TagRequest(repo: repo, name: selected, remote: "", delete: true, local: true) }
                        }.disabled(selection == nil)
                        Button(workflowText("Preview remote deletion"), role: .destructive) { preview(delete: true) }.disabled(selection == nil || remotes.isEmpty)
                    }
                    Text(selection ?? panelText("Select a tag to synchronize or delete.")).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                if !output.isEmpty {
                    ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 72)
                }
            }.padding(22)
            Divider()
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                Button(workflowText("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 14)
        }.tint(.blue).background(Color(nsColor: .windowBackgroundColor)).disabled(store.isBusy).interactiveDismissDisabled(store.isBusy).frame(width: 1020, height: 700)
        .task { await reload() }
        .rayGitSheet(isPresented: $showCreate) { createSheet }
        .rayGitAlert(item: $pending) { request in
            RayGitAlert(title: workflowText("Confirm repository change"), message: request.name + "\n" + request.remote + "\n" + output, buttons: [
                RayGitAlertButton(workflowText("Cancel"), role: .cancel),
                RayGitAlertButton(workflowText("Continue"), role: .destructive) { publish(request) }
            ])
        }
    }
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            DesignPageHeading(title: workflowText("Create tag"), subtitle: designText("Point a new tag at a repository revision"), icon: "tag")
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText("Tag name")).font(.callout)
                StableTextField(workflowText("Tag name"), text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText("Target revision")).font(.callout)
                StableTextField(workflowText("Target revision"), text: $revision).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(designText("Tag type")).font(.callout)
                Picker(designText("Tag type"), selection: $tagKind) {
                    Text(designText("Lightweight")).tag("lightweight")
                    Text(designText("Annotated")).tag("annotated")
                    Text(workflowText("Signed tag")).tag("signed")
                }.labelsHidden().pickerStyle(.radioGroup).frame(maxWidth: .infinity, alignment: .leading)
            }
            if tagKind != "lightweight" {
                Text(workflowText("Annotation")).font(.system(size: 13, weight: .medium))
                TextEditor(text: $annotation).font(.system(size: 13)).frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
            }
            if !output.isEmpty { Text(output).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
            Divider()
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                Button(workflowText("Cancel")) { showCreate = false }.keyboardShortcut(.cancelAction)
                Button(workflowText("Create tag")) { create() }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || revision.isEmpty || (tagKind != "lightweight" && annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.frame(maxWidth: .infinity)
        }.padding(22).frame(width: 360).disabled(store.isBusy).interactiveDismissDisabled(store.isBusy)
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(label)).font(.callout)
            StableTextField(workflowText(label), text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func reload() async {
        loading = true
        defer { loading = false }
        guard let repo = store.repository else { return }; let token = UUID(); reloadID = token
        do { let newTags = try await repo.managedTags(); let newRemotes = try await repo.workflowRead(["remote"]).split(separator: "\n").map(String.init); let types = try await repo.workflowRead(["for-each-ref", "--format=%(refname:short)%00%(objecttype)", "refs/tags"]); guard reloadID == token, store.repositoryURL == repo.url else { return }; tags = newTags; tagTypes = Dictionary(uniqueKeysWithValues: types.split(separator: "\n").compactMap { line in let fields = line.split(separator: "\0").map(String.init); return fields.count == 2 ? (fields[0], fields[1]) : nil }); remotes = newRemotes; if let selection, !tags.contains(where: { $0.name == selection }) { self.selection = nil }; if !remotes.contains(remote) { remote = remotes.first ?? "" } } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }
    }
    private func create() {
        guard let repo = store.repository, !store.isBusy else { return }
        let tag = name, ref = revision, message = tagKind == "lightweight" ? "" : annotation, sign = tagKind == "signed"
        store.isBusy = true
        Task { do { try await repo.createManagedTag(name: tag, revision: ref, message: message, signed: sign); output = workflowText("Completed"); showCreate = false; name = ""; annotation = "" } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }; store.isBusy = false; await reload(); await store.refresh() }
    }
    private func fetch() {
        guard let repo = store.repository, !store.isBusy else { return }; let target = remote
        store.isBusy = true
        Task { do { output = try await repo.fetchTags(remote: target) } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }; store.isBusy = false; await reload(); await store.refresh() }
    }
    private func preview(delete: Bool) {
        guard let repo = store.repository, let selected = selection, !store.isBusy else { return }
        let request = TagRequest(repo: repo, name: selected, remote: remote, delete: delete, local: false)
        store.isBusy = true
        Task { do { output = try await repo.synchronizeTag(name: request.name, remote: request.remote, delete: delete, preview: true); pending = request } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }; store.isBusy = false }
    }
    private func publish(_ request: TagRequest) {
        guard store.repositoryURL == request.repo.url, !store.isBusy else { return }
        store.isBusy = true
        Task { do { if request.local { output = try await request.repo.advancedOperation(.tagDelete, first: request.name, second: "") } else { output = try await request.repo.synchronizeTag(name: request.name, remote: request.remote, delete: request.delete, preview: false) } } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }; store.isBusy = false; await reload(); await store.refresh() }
    }
}
