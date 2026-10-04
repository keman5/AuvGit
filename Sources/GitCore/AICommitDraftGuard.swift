import Foundation

/// A generated draft is safe to apply only to the exact request context.
public struct AICommitDraftGuard: Sendable {
    public let repository: URL
    public let stagedIdentity: String
    public let originalDraft: String
    public init(repository: URL, stagedIdentity: String, originalDraft: String) {
        self.repository = repository; self.stagedIdentity = stagedIdentity; self.originalDraft = originalDraft
    }
    public func rejection(repository: URL?, stagedIdentity: String, draft: String, isBusy: Bool) -> String? {
        guard repository == self.repository, stagedIdentity == self.stagedIdentity, !isBusy else { return "Repository or staged changes changed" }
        guard draft == originalDraft else { return "Commit draft changed; generated message was discarded" }
        return nil
    }
}
