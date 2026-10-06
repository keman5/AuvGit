import SwiftUI
import GitCore
import RayGitLocalization

func compareExtra(_ key: String) -> String { L10n.text(key, table: "CompareExtras") }

struct ComparisonExtrasMenu: View {
    @ObservedObject var session: FileCompareSession
    @State private var showEncoding = false
    @State private var showRename = false
    @State private var restore: FileRevisionContent?
    @State private var restoreName = ""
    @State private var confirmRestore = false
    @State private var confirmDelete = false
    @State private var confirmExternal = false
    private var versions: [(String, FileRevisionContent)] {
        guard let snapshot = session.snapshot else { return [] }
        return [("HEAD", snapshot.head), (compareExtra("index"), snapshot.index), (compareExtra("base"), snapshot.base), (compareExtra("ours"), snapshot.ours), (compareExtra("theirs"), snapshot.theirs)].compactMap { name, value in
            guard let value, value.exists, value.data != nil, value.gitMode?.hasPrefix("100") == true else { return nil }
            return (name, value)
        }
    }
    var body: some View {
        Menu {
            if session.pendingExternalResult != nil { Button(compareExtra("applyExternalResult")) { confirmExternal = true }.disabled(!session.canEdit) }
            Button(compareExtra("encoding")) { showEncoding = true }.disabled(session.savedWorktree?.data == nil || session.savedWorktree?.isBinary == true)
            Button(compareExtra("establishRename")) { showRename = true }.disabled(session.latestSnapshot?.index.exists != false || !session.canEdit || session.isDirty)
            Menu(compareExtra(session.snapshot?.isConflict == true ? "restoreResolve" : "restoreVersion")) {
                ForEach(versions, id: \.0) { name, version in Button(name) { restore = version; restoreName = name; confirmRestore = true } }
            }.disabled(session.isDirty)
            Button(compareExtra(session.snapshot?.isConflict == true ? "deleteResolve" : "deleteFile"), role: .destructive) { confirmDelete = true }.disabled(session.isDirty)
        } label: { ComparisonToolbarIcon(name: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22, height: 24).help(compareExtra("more")).disabled(session.isBusy || session.snapshot == nil)
        .sheet(isPresented: $showEncoding) { EncodingConversionSheet(session: session) }
        .sheet(isPresented: $showRename) { RenameIdentitySheet(session: session) }
        .alert(compareExtra("applyExternalResult"), isPresented: $confirmExternal) {
            Button(compareExtra("cancel"), role: .cancel) {}
            Button(compareExtra("apply")) { if let result = session.pendingExternalResult { session.draft = result; session.pendingExternalResult = nil } }
        } message: { Text(compareExtra("externalResultHelp")) }
        .alert(compareExtra("restoreVersion"), isPresented: $confirmRestore) {
            Button(compareExtra("cancel"), role: .cancel) {}
            Button(compareExtra("apply")) { if let restore { mutate { snapshot in try await session.repository.restoreComparedVersion(path: session.path, source: restore, expected: snapshot, resolve: session.snapshot?.isConflict == true) } } }
        } message: { Text(restoreName + "\n" + compareExtra("restoreHelp")) }
        .alert(compareExtra("deleteFile"), isPresented: $confirmDelete) {
            Button(compareExtra("cancel"), role: .cancel) {}
            Button(compareExtra("apply"), role: .destructive) { mutate { snapshot in try await session.repository.deleteComparedFile(path: session.path, expected: snapshot, resolve: session.snapshot?.isConflict == true) } }
        } message: { Text(compareExtra("deleteHelp")) }
    }
    private func mutate(_ body: @escaping (FileComparisonSnapshot) async throws -> Void) {
        guard let snapshot = session.latestSnapshot, !session.isBusy, !session.isDirty else { return }
        session.isBusy = true
        Task { @MainActor in
            do { try await body(snapshot); try await session.refreshExpectations(replacingDraft: true); NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: session.repository.url); session.isBusy = false }
            catch { session.error = compareExtra(OperationFailure.message(error, repository: session.repository.url)); session.isBusy = false }
        }
    }
}

private struct EncodingConversionSheet: View {
    @ObservedObject var session: FileCompareSession
    @Environment(\.dismiss) private var dismiss
    @State private var source = ComparisonEncoding.utf8
    @State private var destination = ComparisonEncoding.utf8
    @State private var ending = ComparisonLineEnding.lf
    @State private var error: String?
    @State private var initialized = false
    private var decoded: String? {
        guard let data = session.savedWorktree?.data else { return nil }
        return ComparisonTextDecoder.decode(data, as: source)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(compareExtra("encoding")).font(.headline)
            Text(compareExtra("encodingHelp")).font(.caption).foregroundStyle(.secondary)
            Picker(compareExtra("decodeAs"), selection: $source) { ForEach(ComparisonEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker(compareExtra("saveAs"), selection: $destination) { ForEach(ComparisonEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker(compareExtra("lineEndings"), selection: $ending) { ForEach(ComparisonLineEnding.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
            ScrollView { Text(decoded?.prefix(1000).description ?? compareExtra("cannotDecode")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button(compareExtra("cancel")) { dismiss() }
                Button(compareExtra("viewEncoding")) { session.reinterpret(as: source); dismiss() }.disabled(decoded == nil || session.isDirty)
                Spacer()
                Button(compareExtra("convertSave")) { convert() }.buttonStyle(.borderedProminent).disabled(decoded == nil || session.isBusy || session.isDirty)
            }
        }.controlSize(.small).padding(20).frame(width: 620)
        .onAppear {
            guard !initialized else { return }; initialized = true
            let format = ComparisonTextDecoder.format(of: session.savedWorktree?.data ?? Data())
            source = session.preferredEncoding ?? format.encoding; destination = source; ending = format.lineEnding
        }
    }
    private func convert() {
        guard let expected = session.savedWorktree, let text = decoded else { return }
        session.isBusy = true
        Task { @MainActor in
            do {
                _ = try await session.repository.convertWorktree(path: session.path, text: text, format: ComparisonTextFormat(encoding: destination, lineEnding: ending), expected: expected)
                session.preferredEncoding = destination
                try await session.refreshExpectations(replacingDraft: true, preservingIndexExpectation: true)
                session.isBusy = false
                NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: session.repository.url); dismiss()
            } catch { self.error = compareExtra(OperationFailure.message(error, repository: session.repository.url)); session.isBusy = false }
        }
    }
}

private struct RenameIdentitySheet: View {
    @ObservedObject var session: FileCompareSession
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [String] = []
    @State private var original = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(compareExtra("establishRename")).font(.headline)
            Text(compareExtra("renameHelp")).font(.caption).foregroundStyle(.secondary)
            Picker(compareExtra("originalPath"), selection: $original) { Text(compareExtra("chooseOriginal")).tag(""); ForEach(candidates, id: \.self) { Text($0).tag($0) } }
            Text(session.path).font(.system(.caption, design: .monospaced))
            if let error { Text(error).foregroundStyle(.orange) }
            HStack { Button(compareExtra("cancel")) { dismiss() }; Spacer(); Button(compareExtra("apply")) { apply() }.buttonStyle(.borderedProminent).disabled(original.isEmpty || session.isBusy) }
        }.controlSize(.small).padding(20).frame(width: 620)
        .task { do { candidates = try await session.repository.status().filter { $0.worktreeStatus == "D" && $0.indexStatus != "D" && !$0.isConflict }.map(\.path) } catch { self.error = compareExtra(OperationFailure.message(error, repository: session.repository.url)) } }
    }
    private func apply() {
        guard let expected = session.latestSnapshot else { return }
        session.isBusy = true
        Task { @MainActor in
            do { try await session.repository.prepareRenameIdentity(path: session.path, originalPath: original, expected: expected); try await session.refreshExpectations(); session.isBusy = false; NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: session.repository.url); dismiss() }
            catch { self.error = compareExtra(OperationFailure.message(error, repository: session.repository.url)); session.isBusy = false }
        }
    }
}
