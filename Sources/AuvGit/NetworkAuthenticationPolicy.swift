import Foundation
import GitCore

enum NetworkAuthenticationPolicy {
    static func tokenValidationMessageKey(_ token: String, endpoint: RemoteEndpoint) -> String? {
        guard endpoint.transport == .https else { return nil }
        if endpoint.host == "github.com", token.hasPrefix("glpat-") { return "gitLabTokenForGitHub" }
        if endpoint.host == "gitlab.com", token.hasPrefix("ghp_") || token.hasPrefix("github_pat_") {
            return "gitHubTokenForGitLab"
        }
        return nil
    }

    static func credentialWasRejected(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("authentication failed") || message.contains("invalid username or token")
            || message.contains("http basic: access denied")
    }

    static func prompt(for error: Error, endpoint: RemoteEndpoint) -> RemoteEndpoint.Transport? {
        switch GitFailureSummary.key(for: error.localizedDescription) {
        case "Authentication required" where endpoint.transport == .https: return .https
        case "SSH authentication failed" where endpoint.transport == .ssh: return .ssh
        default: return nil
        }
    }
}
