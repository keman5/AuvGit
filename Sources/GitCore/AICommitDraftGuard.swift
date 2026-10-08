import Foundation

/// Content changes are refreshed by the generator; never overwrite another draft or repository.
public struct AICommitDraftGuard: Sendable {
    public let repository: URL
    public let originalDraft: String
    public init(repository: URL, originalDraft: String) {
        self.repository = repository; self.originalDraft = originalDraft
    }
    public func rejection(repository: URL?, draft: String, isBusy: Bool) -> String? {
        guard repository == self.repository, !isBusy else { return "Repository or staged changes changed" }
        guard draft == originalDraft else { return "Commit draft changed; generated message was discarded" }
        return nil
    }
}
