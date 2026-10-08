import Foundation
import Security
import GitCore

protocol RemoteKeychainClient {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

final class SystemRemoteKeychain: RemoteKeychainClient {
    func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let string = String(data: data, encoding: .utf8) else { throw Self.error("read", status) }
        return string
    }

    func write(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.error("save", update) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw Self.error("save", add) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error("delete", status) }
    }

    private static func error(_ operation: String, _ status: OSStatus) -> GitError {
        GitError("Could not \(operation) the remote credential in macOS Keychain (\(status)).")
    }
}

final class RemoteCredentialStore {
    static let shared = RemoteCredentialStore()
    private let defaults: UserDefaults
    private let keychain: RemoteKeychainClient
    private let httpsService = "com.raygit.remote-auth.https"
    private let sshService = "com.raygit.remote-auth.ssh-passphrase"

    init(defaults: UserDefaults = .standard, keychain: RemoteKeychainClient = SystemRemoteKeychain()) {
        self.defaults = defaults; self.keychain = keychain
    }

    func preferredUsername(for endpoint: RemoteEndpoint) -> String? {
        defaults.string(forKey: preferredKey(endpoint))
    }

    func save(_ credential: NetworkCredential, for endpoint: RemoteEndpoint) throws {
        switch credential {
        case let .https(username, password):
            let identity = endpoint.identity(username: username)
            try keychain.write(password, service: httpsService, account: identity.storageKey)
            defaults.set(username, forKey: preferredKey(endpoint))
        case let .ssh(username, privateKey, passphrase):
            let identity = endpoint.identity(username: username)
            let accessed = privateKey.startAccessingSecurityScopedResource()
            defer { if accessed { privateKey.stopAccessingSecurityScopedResource() } }
            let bookmark = try privateKey.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(privateKey.path, forKey: pathKey(identity))
            defaults.set(bookmark, forKey: bookmarkKey(identity))
            defaults.set(username, forKey: preferredKey(endpoint))
            if let passphrase, !passphrase.isEmpty { try keychain.write(passphrase, service: sshService, account: identity.storageKey) }
            else { try keychain.delete(service: sshService, account: identity.storageKey) }
        }
    }

    func load(for endpoint: RemoteEndpoint, username: String) throws -> NetworkCredential? {
        let identity = endpoint.identity(username: username)
        switch endpoint.transport {
        case .https:
            guard let password = try keychain.read(service: httpsService, account: identity.storageKey) else { return nil }
            return .https(username: username, password: password)
        case .ssh:
            let key: URL?
            if let bookmark = defaults.data(forKey: bookmarkKey(identity)) {
                var stale = false
                key = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            } else if let path = defaults.string(forKey: pathKey(identity)) {
                key = URL(fileURLWithPath: path)
            } else { key = nil }
            guard let key, FileManager.default.fileExists(atPath: key.path) else { return nil }
            let passphrase = try keychain.read(service: sshService, account: identity.storageKey)
            return .ssh(username: username, privateKey: key, passphrase: passphrase)
        }
    }

    func pathKey(_ identity: RemoteCredentialIdentity) -> String { "remoteCredential.ssh.path." + identity.storageKey }
    func bookmarkKey(_ identity: RemoteCredentialIdentity) -> String { "remoteCredential.ssh.bookmark." + identity.storageKey }

    private func preferredKey(_ endpoint: RemoteEndpoint) -> String {
        "remoteCredential.preferred." + endpoint.transport.rawValue + "|" + endpoint.host + "|" + String(endpoint.port)
    }
}
