import Foundation
import CryptoKit

public enum CommitAvatarIdentity {
    /// Only GitHub's actual noreply email formats imply a GitHub account.
    public static func githubLogin(email: String) -> String? {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "users.noreply.github.com" else { return nil }
        let local = parts[0].split(separator: "+", omittingEmptySubsequences: false)
        let login: String
        if local.count == 2 {
            guard !local[0].isEmpty, local[0].unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else { return nil }
            login = String(local[1])
        } else if local.count == 1 { login = String(local[0]) }
        else { return nil }
        guard !login.isEmpty, login.count <= 39, !login.hasPrefix("-"), !login.hasSuffix("-"), !login.contains("--"),
              login.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" }) else { return nil }
        return login
    }
    public static func url(email: String, size: Int = 80) -> URL? {
        if let login = githubLogin(email: email) { return URL(string: "https://github.com/\(login).png?size=\(size)") }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil else { return nil }
        let hash = Insecure.MD5.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?d=404&s=\(size)")
    }
}
