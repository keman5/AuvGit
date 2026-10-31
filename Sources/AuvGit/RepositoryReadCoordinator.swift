import Foundation
import GitCore

/// Shares only live work. Completed reads are removed before their consumers resume.
@MainActor
final class RepositoryReadCoordinator {
    static let shared = RepositoryReadCoordinator()
    private let statuses = InFlightReadPool<String, [GitFile]>()
    private let changes = InFlightReadPool<ChangeKey, RepositoryChangeState>()
    private let syncs = InFlightReadPool<String, String?>()

    private struct ChangeKey: Hashable {
        let repository: String
        let files: [GitFile]
    }
    private func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func status(repository: GitRepository) async throws -> [GitFile] {
        try await statuses.value(for: key(repository.url)) {
            try await GitCommandLog.$suppressRoutineReads.withValue(true) { try await repository.status() }
        }
    }
    func changeState(repository: GitRepository, files: [GitFile]) async throws -> RepositoryChangeState {
        try await changes.value(for: ChangeKey(repository: key(repository.url), files: files)) {
            try await GitCommandLog.$suppressRoutineReads.withValue(true) { try await repository.changeState(files: files) }
        }
    }
    func syncCounts(repository: GitRepository) async -> String? {
        try? await syncs.value(for: key(repository.url)) {
            try await GitCommandLog.$suppressRoutineReads.withValue(true) {
                try await repository.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
            }
        }
    }
    func invalidate(repository: URL) {
        let path = key(repository)
        statuses.cancel { $0 == path }
        changes.cancel { $0.repository == path }
        syncs.cancel { $0 == path }
    }
}

/// Each consumer owns a continuation, so cancelling one returns promptly without
/// disrupting other consumers. The final cancellation tears down the worker.
@MainActor
final class InFlightReadPool<Key: Hashable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var entries: [Key: Entry] = [:]
    var pendingConsumerCount: Int { entries.values.reduce(0) { $0 + $1.waiters.count } }

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var entry = entries[key] {
                    entry.waiters[waiter] = continuation
                    entries[key] = entry
                } else {
                    let id = UUID()
                    entries[key] = Entry(id: id, task: nil, waiters: [waiter: continuation])
                    let task = Task {
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        finish(key, id: id, result: result)
                    }
                    entries[key]?.task = task
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(waiter, for: key) }
        }
    }
    private func finish(_ key: Key, id: UUID, result: Result<Value, Error>) {
        guard let entry = entries[key], entry.id == id else { return }
        entries.removeValue(forKey: key)
        for continuation in entry.waiters.values { continuation.resume(with: result) }
    }
    private func cancelWaiter(_ waiter: UUID, for key: Key) {
        guard var entry = entries[key], let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        if entry.waiters.isEmpty {
            entries.removeValue(forKey: key)
            entry.task?.cancel()
        } else { entries[key] = entry }
        continuation.resume(throwing: CancellationError())
    }
    func cancel(where matches: (Key) -> Bool) {
        for key in entries.keys.filter(matches) {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.task?.cancel()
            for continuation in entry.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
    }
}
