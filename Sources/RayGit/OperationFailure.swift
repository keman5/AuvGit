import Foundation
import GitCore

enum OperationFailure {
    struct Event: Sendable { let repository: URL?; let message: String }
    static let notification = Notification.Name("RayGitOperationFailed")
    /// Retains the existing local message while bridging user-visible failures to the footer.
    static func message(_ error: Error, repository: URL? = nil) -> String {
        let message = GitCommandLog.redact(error.localizedDescription)
        if !(error is CancellationError) {
            NotificationCenter.default.post(name: notification, object: Event(repository: repository, message: message))
        }
        return message
    }
}
