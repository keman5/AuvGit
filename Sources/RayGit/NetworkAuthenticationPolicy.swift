import Foundation
import GitCore

enum NetworkAuthenticationPolicy {
    static func prompt(for error: Error, endpoint: RemoteEndpoint) -> RemoteEndpoint.Transport? {
        switch GitFailureSummary.key(for: error.localizedDescription) {
        case "Authentication required" where endpoint.transport == .https: return .https
        case "SSH authentication failed" where endpoint.transport == .ssh: return .ssh
        default: return nil
        }
    }
}
