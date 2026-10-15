import Foundation

enum AppBrandMigration {
    // Keep the old domain only as an upgrade source; all new writes use AuvGit.
    static func migrate(defaults: UserDefaults = .standard,
                        legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "dev.raygit.mac")) {
        let marker = "brand.auvgit.migrated"
        guard !defaults.bool(forKey: marker) else { return }
        for (key, value) in legacy ?? [:] {
            let migratedKey = key.replacingOccurrences(of: "RayGit", with: "AuvGit")
                .replacingOccurrences(of: "raygit", with: "auvgit")
                .replacingOccurrences(of: "rayGit", with: "auvGit")
            if defaults.object(forKey: migratedKey) == nil { defaults.set(value, forKey: migratedKey) }
        }
        defaults.set(true, forKey: marker)
    }
}
