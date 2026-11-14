import AppKit
import SwiftUI
import GitCore
import AuvGitLocalization

func graphFeatureText(_ key: String) -> String { L10n.text(key, table: "HistoryGraphFeatures") }

enum HistoryIdentityMode: String, CaseIterable {
    case author, committer
    func name(_ commit: GitCommit) -> String { self == .author ? commit.author : commit.committer }
    func email(_ commit: GitCommit) -> String { self == .author ? commit.authorEmail : commit.committerEmail }
    func text(_ commit: GitCommit, names: Bool, emails: Bool) -> String {
        let name = name(commit), email = email(commit)
        return [names ? name : "", emails && !email.isEmpty ? (names ? "<\(email)>" : email) : ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum HistoryGraphDragSource: Codable, Equatable, Sendable {
    case commits([String]), localBranch(String), head
    var operations: [HistoryGraphDropOperation] {
        switch self {
        case .commits: [.cherryPick, .rebase]
        case .localBranch: [.moveBranch, .rebase]
        case .head: [.reset, .rebase]
        }
    }
    var label: String {
        switch self {
        case .commits(let ids): ids.map { String($0.prefix(8)) }.joined(separator: ", ")
        case .localBranch(let name): name
        case .head: "HEAD"
        }
    }
}

enum HistoryGraphDropOperation: String, Codable, CaseIterable, Sendable {
    case cherryPick, rebase, moveBranch, reset
    var title: String { graphFeatureText(rawValue) }
}
struct HistoryGraphDropRequest: Equatable, Sendable {
    let source: HistoryGraphDragSource
    let targetCommitID: String
    var operation: HistoryGraphDropOperation
    var expectedHeadCommitID: String? = nil
    var expectedSourceCommitID: String? = nil
    var repositoryIdentity: UUID? = nil
    var sourceIsCurrentBranch: Bool = false
    var isContiguousHeadRange: Bool = false
}
struct HistoryGraphDragPayload: Codable {
    let source: HistoryGraphDragSource
    let generation: UUID?
    static let pasteboardType = NSPasteboard.PasteboardType("com.auvgit.history.graph-operation")
}

/// Hides only ancestry exclusive to an individually collapsed merge side. Shared
/// first-parent ancestry, referenced tips and selections stay visible.
enum HistoryMergeCollapse {
    struct Projection {
        let commits: [GitCommit]
        let hiddenCounts: [String: Int]
    }
    static func project(_ commits: [GitCommit], collapsed: Set<String>, preserving: Set<String>) -> Projection {
        guard !collapsed.isEmpty else { return Projection(commits: commits, hiddenCounts: [:]) }
        let byHash = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0) })
        func reachable(_ roots: [String]) -> Set<String> {
            var pending = roots, seen = Set<String>()
            while let hash = pending.popLast() {
                guard seen.insert(hash).inserted else { continue }
                pending.append(contentsOf: byHash[hash].map { $0.graphParents ?? $0.parents } ?? [])
            }
            return seen
        }
        var hidden = Set<String>(), counts: [String: Int] = [:]
        for commit in commits where collapsed.contains(commit.hash) && commit.parents.count > 1 {
            let topology = commit.graphParents ?? commit.parents
            let first = reachable(Array(topology.prefix(1)))
            let sides = reachable(Array(topology.dropFirst())).subtracting(first)
            let removable = sides.filter { !preserving.contains($0) && (byHash[$0]?.refs.isEmpty ?? true) && !collapsed.contains($0) }
            hidden.formUnion(removable)
            counts[commit.hash] = removable.count
        }
        func visibleParents(_ parents: [String]) -> [String] {
            var pending = parents.reversed().map { $0 }, seen = Set<String>(), result: [String] = []
            while let hash = pending.popLast() {
                guard seen.insert(hash).inserted else { continue }
                if hidden.contains(hash) { pending.append(contentsOf: (byHash[hash].map { $0.graphParents ?? $0.parents } ?? []).reversed()) }
                else { result.append(hash) }
            }
            return result
        }
        let projected = commits.filter { !hidden.contains($0.hash) }.map { commit in
            GitCommit(hash: commit.hash, parents: commit.parents, author: commit.author, date: commit.date,
                subject: commit.subject, body: commit.body, refs: commit.refs, authorEmail: commit.authorEmail,
                committer: commit.committer, committerEmail: commit.committerEmail, committedDate: commit.committedDate,
                signatureStatus: commit.signatureStatus, graphParents: visibleParents(commit.graphParents ?? commit.parents))
        }
        return Projection(commits: projected, hiddenCounts: counts)
    }
}

@MainActor
final class HistoryOverlapCache: ObservableObject {
    @Published private(set) var values: [String: Int] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var cache: [String: [String: Int]] = [:]
    private var scope: UUID?
    private var requestID = UUID()
    func load(selected: String?, commits: [GitCommit], generation: UUID?, enabled: Bool,
              loader: ((String, [String]) async throws -> [String: Int])?) async {
        let requestID = UUID()
        self.requestID = requestID
        if scope != generation { cache.removeAll(); scope = generation }
        values = [:]; error = nil; isLoading = false
        guard enabled, let selected, commits.contains(where: { $0.hash == selected }), let loader else { return }
        // A bounded visible neighborhood keeps analysis responsive for long logs.
        let center = commits.firstIndex { $0.hash == selected } ?? 0
        let start = max(0, min(center - 40, commits.count - 80))
        let candidates = Array(commits.dropFirst(start).prefix(80)).filter { $0.hash != selected }.map(\.hash)
        let key = selected + ":" + candidates.joined(separator: ",")
        if let saved = cache[key] { values = saved; return }
        isLoading = true
        defer { if self.requestID == requestID { isLoading = false } }
        do {
            let result = try await loader(selected, candidates)
            guard !Task.isCancelled, scope == generation, self.requestID == requestID else { return }
            if cache.count >= 16 { cache.removeAll() }
            cache[key] = result; values = result; isLoading = false
        } catch {
            guard !Task.isCancelled, scope == generation, self.requestID == requestID else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }
}

struct HistoryGraphDropPreview: View {
    let initial: HistoryGraphDropRequest
    let confirm: (HistoryGraphDropRequest) -> Void
    let cancel: () -> Void
    @State private var operation: HistoryGraphDropOperation
    init(request: HistoryGraphDropRequest, confirm: @escaping (HistoryGraphDropRequest) -> Void, cancel: @escaping () -> Void) {
        initial = request; self.confirm = confirm; self.cancel = cancel
        _operation = State(initialValue: request.operation)
    }
    private var validationMessage: String? {
        if initial.expectedHeadCommitID == nil { return graphFeatureText("HEAD unavailable") }
        if operation == .rebase, case .commits = initial.source, !initial.isContiguousHeadRange { return graphFeatureText("Rebase requires contiguous HEAD range") }
        if operation == .cherryPick, initial.expectedHeadCommitID != initial.targetCommitID { return graphFeatureText("Cherry-pick requires HEAD target") }
        if operation == .moveBranch, initial.sourceIsCurrentBranch { return graphFeatureText("Use HEAD reset for current branch") }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(graphFeatureText("Operation preview")).font(.headline)
            Text(graphFeatureText("Source") + ": " + initial.source.label).textSelection(.enabled)
            Text(graphFeatureText("Target") + ": " + initial.targetCommitID).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Picker(graphFeatureText("Operation"), selection: $operation) {
                ForEach(initial.source.operations, id: \.self) { Text($0.title).tag($0) }
            }
            Text(graphFeatureText("preview." + operation.rawValue)).font(.callout).foregroundStyle(.secondary)
            if operation == .rebase, case .localBranch = initial.source, !initial.sourceIsCurrentBranch {
                Text(graphFeatureText("Rebase checks out source branch")).font(.callout).foregroundStyle(.secondary)
            }
            if let validationMessage { Text(validationMessage).font(.callout).foregroundStyle(.orange) }
            HStack { Spacer(); Button(graphFeatureText("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(graphFeatureText("Confirm")) { var request = initial; request.operation = operation; confirm(request) }.disabled(validationMessage != nil)
            }
        }.padding(24).frame(width: 500)
    }
}
