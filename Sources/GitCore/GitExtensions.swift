import Foundation

public enum GitFlowKind: String, CaseIterable, Sendable { case feature, release, hotfix }
public enum HostedReview {
    public static func url(remote: String, source: String, target: String) throws -> URL {
        var input = remote
        if remote.hasPrefix("git@"), let colon = remote.firstIndex(of: ":") { input = "https://" + remote[remote.index(remote.startIndex, offsetBy: 4)..<colon] + "/" + remote[remote.index(after: colon)...] }
        guard var parts = URLComponents(string: input), let host = parts.host?.lowercased(), ["github.com", "gitlab.com"].contains(host), ["https", "ssh"].contains(parts.scheme ?? ""), parts.password == nil else { throw GitError("Use a GitHub or GitLab HTTPS/SSH remote.") }
        parts.scheme = "https"; parts.user = nil; parts.password = nil; parts.port = nil; parts.query = nil; parts.fragment = nil
        var path = parts.path
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let segments = path.split(separator: "/")
        guard segments.count >= 2, !segments.contains(".."), !source.isEmpty, !target.isEmpty else { throw GitError("Invalid review branches or remote path.") }
        if host == "github.com" {
            parts.path = path + "/compare/" + target + "..." + source
            parts.queryItems = [URLQueryItem(name: "expand", value: "1")]
        } else {
            parts.path = path + "/-/merge_requests/new"
            parts.queryItems = [URLQueryItem(name: "merge_request[source_branch]", value: source), URLQueryItem(name: "merge_request[target_branch]", value: target)]
        }
        guard let result = parts.url else { throw GitError("Invalid review URL.") }; return result
    }
}
public struct UpdateManifest: Decodable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let notes: String?
    public static func isNewer(_ candidate: String, than installed: String) throws -> Bool {
        func parse(_ value: String) throws -> ([Int], [String]?) {
            let version = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let sections = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let components = sections[0].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }) else { throw GitError("Invalid release version.") }
            var numbers = components.map { Int($0)! }
            while numbers.count < 3 { numbers.append(0) }
            var prerelease: [String]?
            if sections.count == 2 {
                let identifiers = sections[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { throw GitError("Invalid release version.") }
                prerelease = identifiers
            }
            return (numbers, prerelease)
        }
        let candidateVersion = try parse(candidate), installedVersion = try parse(installed)
        for (left, right) in zip(candidateVersion.0, installedVersion.0) where left != right { return left > right }
        switch (candidateVersion.1, installedVersion.1) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let left?, let right?):
            for (a, b) in zip(left, right) where a != b {
                if let ai = Int(a), let bi = Int(b) { return ai > bi }
                if Int(a) != nil { return false }
                if Int(b) != nil { return true }
                return a > b
            }
            return left.count > right.count
        }
    }
    public static func fetch(from url: URL) async throws -> UpdateManifest {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw GitError("The update manifest must use HTTPS.") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https", data.count < 1024 * 1024 else { throw GitError("Update manifest request failed.") }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        guard !manifest.version.isEmpty, manifest.downloadURL.scheme == "https", manifest.downloadURL.host != nil, manifest.downloadURL.user == nil, manifest.downloadURL.password == nil else { throw GitError("Invalid update manifest.") }
        _ = try isNewer(manifest.version, than: "0.0.0")
        return manifest
    }
}
public extension GitRepository {
    func startGitFlow(kind: GitFlowKind, name: String, main: String = "main", develop: String = "develop") async throws {
        guard try await status().isEmpty else { throw GitError("A clean worktree and index are required") }
        for base in [main, develop] { _ = try await GitProcess.run(at: url, arguments: ["check-ref-format", "--branch", base]) }
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitError("Invalid Git Flow name.") }
        let branch = kind.rawValue + "/" + name
        guard main != develop, branch != main, branch != develop else { throw GitError("Git Flow main, develop and task branches must be distinct.") }
        _ = try await GitProcess.run(at: url, arguments: ["check-ref-format", "--branch", branch])
        let base = kind == .hotfix ? main : develop
        _ = try await workflowRevision("refs/heads/" + base)
        _ = try await GitProcess.run(at: url, arguments: ["switch", "-c", branch, base])
    }
    func finishGitFlow(kind: GitFlowKind, name: String, main: String = "main", develop: String = "develop") async throws {
        guard try await status().isEmpty else { throw GitError("A clean worktree and index are required") }
        for base in [main, develop] { _ = try await GitProcess.run(at: url, arguments: ["check-ref-format", "--branch", base]) }
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitError("Invalid Git Flow name.") }
        let branch = kind.rawValue + "/" + name
        guard main != develop, branch != main, branch != develop else { throw GitError("Git Flow main, develop and task branches must be distinct.") }
        guard try await currentBranch() == branch else { throw GitError("Check out the matching Git Flow branch before finishing.") }
        _ = try await workflowRevision("refs/heads/" + develop)
        if kind != .feature {
            _ = try await workflowRevision("refs/heads/" + main)
            _ = try await GitProcess.run(at: url, arguments: ["check-ref-format", "refs/tags/" + name])
            let exists = try await GitProcess.run(at: url, arguments: ["show-ref", "--verify", "--quiet", "refs/tags/" + name], allowedCodes: [0, 1])
            guard exists.code != 0 else { throw GitError("The release tag already exists.") }
            _ = try await GitProcess.run(at: url, arguments: ["switch", main])
            _ = try await GitProcess.run(at: url, arguments: ["merge", "--no-ff", "--no-edit", branch])
            _ = try await GitProcess.run(at: url, arguments: ["tag", name])
        }
        _ = try await GitProcess.run(at: url, arguments: ["switch", develop])
        _ = try await GitProcess.run(at: url, arguments: ["merge", "--no-ff", "--no-edit", branch])
        _ = try await GitProcess.run(at: url, arguments: ["branch", "-d", "--", branch])
    }
    func reviewURL(remote: String = "origin", target: String) async throws -> URL {
        let source = try await currentBranch()
        let address = try await GitProcess.run(at: url, arguments: ["remote", "get-url", "--", remote]).text.trimmingCharacters(in: .newlines)
        return try HostedReview.url(remote: address, source: source, target: target)
    }
}
