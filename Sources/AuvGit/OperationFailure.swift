import Foundation
import GitCore
import AuvGitLocalization

enum OperationFailure {
    struct Event: Sendable { let repository: URL?; let message: String }
    static let notification = Notification.Name("AuvGitOperationFailed")
    /// Keep the original diagnostic in the log and return a localized summary to the dialog.
    static func message(_ error: Error, repository: URL? = nil) -> String {
        let message = GitCommandLog.redact(error.localizedDescription)
        if !(error is CancellationError) {
            NotificationCenter.default.post(name: notification, object: Event(repository: repository, message: message))
        }
        return GitFailureSummary.message(for: message, localize: { L10n.text($0, table: "OperationLog") }) ?? message
    }
}
