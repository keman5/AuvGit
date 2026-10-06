import Foundation
import GitCore

/// Empty is a deliberate empty scope, distinct from an absent saved preference.
struct HistoryBranchScope {
    static func stashRef(_ stash: GitStash) -> String { "$stash:" + stash.hash }
    static func migrate(_ refs: Set<String>, stashes: [GitStash]) -> Set<String> {
        Set(refs.compactMap { ref in
            if ref.hasPrefix("stash@{") { return stashes.first(where: { $0.ref == ref }).map(stashRef) }
            return ref
        })
    }
    static let recyclable = "$recyclable"
    static let allStashes = "$allStashes"
    static let preferenceKey = "history.checkedRefs.v2"
    static let legacyPreferenceKey = "history.checkedRefs.v1"
    static func repositoryKey(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    static func load(repository: URL, defaults: UserDefaults = .standard) -> Set<String>? {
        let key = repositoryKey(repository)
        if let values = defaults.dictionary(forKey: preferenceKey)?[key] as? [String] { return Set(values) }
        if let legacy = defaults.dictionary(forKey: legacyPreferenceKey)?[key] as? [String] { return Set(legacy).union([allStashes]) }
        return nil
    }
    static func save(_ refs: Set<String>, repository: URL, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: preferenceKey) ?? [:]
        values[repositoryKey(repository)] = refs.sorted()
        defaults.set(values, forKey: preferenceKey)
    }
    static func branchRef(_ branch: GitBranch) -> String { (branch.isRemote ? "refs/remotes/" : "refs/heads/") + branch.name }
    static func defaultRefs(branches: [GitBranch], branch: String) -> Set<String> {
        return ["HEAD", allStashes]
    }
    static func isChecked(_ ref: String, in refs: Set<String>) -> Bool {
        refs.contains(ref) || (ref.hasPrefix("$stash:") && refs.contains(allStashes))
    }
    static func setting(_ ref: String, checked: Bool, in refs: Set<String>, stashes: [GitStash]) -> Set<String> {
        var result = refs
        if ref.hasPrefix("$stash:"), result.contains(allStashes) {
            result.remove(allStashes)
            result.formUnion(stashes.map(stashRef))
        }
        if checked { result.insert(ref) } else { result.remove(ref) }
        return result
    }
    static func revisionRefs(_ refs: Set<String>, branches: [GitBranch], stashes: [GitStash]) -> [String] {
        let available = Set(branches.map(branchRef)).union(stashes.map(stashRef)).union(["HEAD"])
        var selected = refs.intersection(available)
        if refs.contains(allStashes) { selected.formUnion(stashes.map(stashRef)) }
        return selected.filter { !$0.hasPrefix("$stash:") }.sorted()
    }
    static func selectedStashHashes(_ refs: Set<String>, stashes: [GitStash]) -> [String] {
        stashes.filter { isChecked(stashRef($0), in: refs) }.map(\.hash)
    }
    static func preservingStashes(in refs: Set<String>, forBranch branch: String) -> Set<String> {
        refs.filter { $0 == allStashes || $0.hasPrefix("$stash:") }.union([branch])
    }
    static func presentationReference(requested: String?, previous: String?, availableBranches: Set<String>) -> String {
        if let requested { return requested }
        if let previous, previous == "HEAD" || availableBranches.contains(previous) { return previous }
        return "HEAD"
    }
    static func preferred(containing refs: [String], branches: [GitBranch]) -> String? {
        if let current = branches.first(where: \.isCurrent), refs.contains(branchRef(current)) { return branchRef(current) }
        return refs.filter { $0.hasPrefix("refs/heads/") }.sorted().first ?? refs.sorted().first
    }
}
