import Foundation
import GitCore

enum CloneAuthentication {
    enum Failure: Equatable {
        case httpsCredentials
        case sshKey
        case other(String)
    }

    static func classify(source: String, error: Error) -> Failure {
        let message = GitCommandLog.redact(error.localizedDescription)
        let key = GitFailureSummary.key(for: message)
        let scheme = URLComponents(string: source.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        if scheme == "https", key == "Authentication required" { return .httpsCredentials }
        if key == "SSH authentication failed" { return .sshKey }
        switch message {
        case "HTTPS username and password or token must be non-empty single-line values.",
             "HTTPS credentials require a valid HTTPS clone URL.",
             "HTTPS credentials can only be used with an HTTPS clone URL.",
             "Cannot create the temporary HTTPS credential response.",
             "Cannot create the temporary HTTPS credential helper.":
            return .other(workflowText(message))
        default: return .other(message)
        }
    }
}
