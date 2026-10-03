import Foundation
public extension GitRepository {
    func referenceFiles(left: String, right: String) async throws -> [GitCommitFile] {
        let a = try await workflowRevision(left), b = try await workflowRevision(right)
        let output = try await GitProcess.run(at: url, arguments: ["diff", "--name-status", "-M", "-z", a, b, "--"])
        let fields = output.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [GitCommitFile] = [], index = 0
        while index + 1 < fields.count {
            let status = fields[index], first = fields[index + 1]; index += 2
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index < fields.count else { break }
                files.append(GitCommitFile(path: fields[index], status: status, originalPath: first)); index += 1
            } else { files.append(GitCommitFile(path: first, status: status, originalPath: nil)) }
        }
        return files
    }
    func referenceFileDiff(left: String, right: String, file: GitCommitFile) async throws -> String {
        let a = try await workflowRevision(left), b = try await workflowRevision(right)
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        for path in paths { try workflowPath(path) }
        return try await workflowRead(["diff", "--no-ext-diff", "--no-textconv", "--no-color", a, b, "--"] + paths)
    }
}
