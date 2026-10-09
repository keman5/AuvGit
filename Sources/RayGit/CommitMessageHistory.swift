import Foundation

struct CommitMessageHistory {
    static let limit = 10
    private let defaults: UserDefaults
    private let storageKey = "commitMessageHistory.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func messages(for repositoryURL: URL) -> [String] {
        let values = defaults.dictionary(forKey: storageKey)?[key(for: repositoryURL)] as? [String] ?? []
        var seen = Set<String>()
        return Array(values.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }.prefix(Self.limit))
    }

    func record(_ message: String, for repositoryURL: URL) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var histories = defaults.dictionary(forKey: storageKey) ?? [:]
        let repositoryKey = key(for: repositoryURL)
        let updated = [message] + messages(for: repositoryURL).filter { $0 != message }
        histories[repositoryKey] = Array(updated.prefix(Self.limit))
        defaults.set(histories, forKey: storageKey)
    }

    func clear(for repositoryURL: URL) {
        var histories = defaults.dictionary(forKey: storageKey) ?? [:]
        histories.removeValue(forKey: key(for: repositoryURL))
        if histories.isEmpty { defaults.removeObject(forKey: storageKey) }
        else { defaults.set(histories, forKey: storageKey) }
    }

    private func key(for repositoryURL: URL) -> String {
        repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
