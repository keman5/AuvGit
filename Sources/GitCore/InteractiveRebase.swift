import Foundation

public struct RebasePlan: Sendable {
    public let base: String
    public let head: String
    public let todo: String
    public init(base: String, head: String, todo: String) { self.base = base; self.head = head; self.todo = todo }
}
public struct RebaseInstruction: Identifiable, Sendable {
    public let line: Int
    public let command: String
    public let commit: String?
    public let argument: String
    public var id: Int { line }
}
public extension GitRepository {
    func generatedRebasePlan(onto: String) async throws -> RebasePlan {
        guard try await status().isEmpty else { throw GitError("A clean worktree and index are required") }
        for state in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            guard !FileManager.default.fileExists(atPath: try await rebaseGitPath(state).path) else { throw GitError("Finish or abort the existing Git operation before loading a plan") }
        }
        let base = try await workflowRevision(onto), head = try await workflowRevision("HEAD")
        let originalHeadURL = try await rebaseGitPath("ORIG_HEAD")
        let originalHead = try? Data(contentsOf: originalHeadURL)
        // Git prepares ORIG_HEAD before invoking the sequence editor. Restore
        // the pre-existing recovery ref after this deliberately aborted preview.
        defer {
            if let current = try? String(contentsOf: originalHeadURL, encoding: .utf8), current.trimmingCharacters(in: .newlines) == head {
                if let originalHead { try? originalHead.write(to: originalHeadURL, options: .atomic) }
                else { try? FileManager.default.removeItem(at: originalHeadURL) }
            }
        }
        guard try await workflowRead(["rev-list", base + ".." + head]).trimmingCharacters(in: .newlines).isEmpty == false else { throw GitError("No commits to rebase") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let captured = temp.appendingPathComponent("todo"), editor = temp.appendingPathComponent("capture")
        try ("#!/bin/sh\n/bin/cp \"$1\" " + rebaseShellQuote(captured.path) + "\nexit 1\n").write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        let result = try await GitProcess.run(at: url, arguments: ["--no-optional-locks", "-c", "core.abbrev=40", "-c", "rebase.abbreviateCommands=false", "-c", "sequence.editor=" + rebaseShellQuote(editor.path), "rebase", "-i", "--rebase-merges", "--reapply-cherry-picks", "--keep-empty", "--empty=keep", base], allowedCodes: [0, 1, 128])
        guard FileManager.default.fileExists(atPath: captured.path) else { throw GitError(result.error) }
        guard try await workflowRevision("HEAD") == head else { throw GitError("HEAD changed while generating the rebase plan") }
        return RebasePlan(base: base, head: head, todo: try String(contentsOf: captured, encoding: .utf8))
    }
    func validateRebasePlan(base: String, plan: String, allowExec: Bool) async throws -> [RebaseInstruction] {
        guard !plan.contains("\0") else { throw GitError("Invalid rebase plan") }
        let baseHash = try await workflowRevision(base)
        let available = Set(try await workflowRead(["rev-list", baseHash + "..HEAD"]).split(separator: "\n").map(String.init))
        let aliases = ["p":"pick", "r":"reword", "e":"edit", "s":"squash", "f":"fixup", "x":"exec", "b":"break", "d":"drop", "l":"label", "t":"reset", "m":"merge", "u":"update-ref"]
        var seen = Set<String>(), labels = Set<String>(), predecessor = false
        var instructions: [RebaseInstruction] = []
        for (index, raw) in plan.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let allFields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let fields = allFields[0] == "exec" || allFields[0] == "x" ? allFields : Array(allFields.prefix { $0 != "#" })
            let command = aliases[fields[0]] ?? fields[0]
            let argument = String(line.dropFirst(fields[0].count)).trimmingCharacters(in: .whitespaces)
            var commit: String?
            switch command {
            case "pick", "reword", "edit", "drop", "squash", "fixup":
                let offset = command == "fixup" && fields.count > 1 && ["-C", "-c"].contains(fields[1]) ? 2 : 1
                guard fields.count > offset else { throw GitError("Missing commit on todo line \(index + 1)") }
                let hash = try await workflowRevision(fields[offset])
                guard available.contains(hash), seen.insert(hash).inserted else { throw GitError("Unknown or duplicate commit on todo line \(index + 1)") }
                let parents = try await workflowRead(["show", "-s", "--format=%P", hash]).split(separator: " ")
                guard parents.count < 2 || command == "drop" else { throw GitError("Merge commits must use a merge instruction; converting one to pick would flatten topology") }
                if command == "squash" || command == "fixup" { guard predecessor else { throw GitError("Squash/fixup requires a preceding commit on this branch") } }
                if ["pick", "reword", "edit"].contains(command) { predecessor = true }
                commit = hash
            case "label":
                guard fields.count == 2, labels.insert(fields[1]).inserted else { throw GitError("Invalid or duplicate label") }
                _ = try await workflowRead(["check-ref-format", "refs/rewritten/" + fields[1]])
            case "reset":
                if argument != "[new root]" {
                    guard fields.count == 2 else { throw GitError("Reset requires a label or commit") }
                    if !labels.contains(fields[1]) { _ = try await workflowRevision(fields[1]) }
                }
                predecessor = false
            case "merge":
                var offset = 1
                if fields.count > 1 && ["-C", "-c"].contains(fields[1]) {
                    guard fields.count > 3 else { throw GitError("Merge requires a commit and label") }
                    let hash = try await workflowRevision(fields[2]); guard available.contains(hash), seen.insert(hash).inserted else { throw GitError("Unknown or duplicate merge commit") }
                    let parents = try await workflowRead(["show", "-s", "--format=%P", hash]).split(separator: " ")
                    guard parents.count >= 2 else { throw GitError("Merge source must be a merge commit") }
                    commit = hash; offset = 3
                }
                let targets = Array(fields.dropFirst(offset).prefix { !$0.hasPrefix("#") })
                guard !targets.isEmpty, targets.allSatisfy({ labels.contains($0) }) else { throw GitError("Merge requires existing labels") }
                predecessor = true
            case "exec":
                guard allowExec, !argument.isEmpty else { throw GitError("Exec commands require explicit preview and confirmation") }
            case "break", "noop": guard fields.count == 1 else { throw GitError("Unexpected arguments on todo line \(index + 1)") }
            case "update-ref":
                guard fields.count == 2, fields[1].hasPrefix("refs/heads/") else { throw GitError("Update-ref requires a local branch ref") }
                _ = try await workflowRead(["check-ref-format", fields[1]])
            default: throw GitError("Unknown rebase instruction on todo line \(index + 1)")
            }
            instructions.append(RebaseInstruction(line: index, command: command, commit: commit, argument: argument))
        }
        guard seen == available, !available.isEmpty else { throw GitError("Plan must include every original commit exactly once; use drop to remove one") }
        return instructions
    }
    func executeRebase(plan: RebasePlan, editedTodo: String, messages: [Int: String], allowExec: Bool) async throws -> String {
        guard try await status().isEmpty else { throw GitError("A clean worktree and index are required") }
        guard try await workflowRevision("HEAD") == plan.head else { throw GitError("HEAD changed since the plan was loaded; reload it") }
        let instructions = try await validateRebasePlan(base: plan.base, plan: editedTodo, allowExec: allowExec)
        let directory = try await rebaseToolsDirectory()
        // Never overwrite an active editor belonging to an unfinished rebase.
        let state = try await rebaseGitPath("rebase-merge")
        guard !FileManager.default.fileExists(atPath: state.path), !FileManager.default.fileExists(atPath: try await rebaseGitPath("rebase-apply").path) else { throw GitError("A rebase is already in progress") }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var canonical: [String] = []
        for instruction in instructions {
            var argument = instruction.argument
            if let hash = instruction.commit {
                var fields = argument.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                let offset = ["merge", "fixup"].contains(instruction.command) && fields.first.map({ ["-C", "-c"].contains($0) }) == true ? 1 : 0
                fields[offset] = hash
                argument = fields.joined(separator: " ")
            }
            canonical.append(instruction.command + (argument.isEmpty ? "" : " " + argument))
        }
        let todo = directory.appendingPathComponent("todo"), editor = directory.appendingPathComponent("editor")
        try (canonical.joined(separator: "\n") + "\n").write(to: todo, atomically: true, encoding: .utf8)
        try ("#!/bin/sh\n/bin/cp " + rebaseShellQuote(todo.path) + " \"$1\"\n").write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        // done contains executable instructions only. Its line count selects the
        // requested multiline message, including squash and merge -c editors.
        var script = "#!/bin/sh\ndone_file=\"$(/usr/bin/git rev-parse --git-path rebase-merge/done)\"\nstep=\"$(/usr/bin/awk 'NF { n++ } END { print n }' \"$done_file\")\"\ncase \"$step\" in\n"
        for (position, instruction) in instructions.enumerated() {
            let explicit = messages[instruction.line]
            var message = explicit
            if message == nil, instruction.command == "reword", let hash = instruction.commit {
                message = try await workflowRead(["show", "-s", "--format=%B", hash])
            }
            if let message {
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0") else { throw GitError("Commit message must not be empty") }
                let file = directory.appendingPathComponent("message-\(position)")
                try message.write(to: file, atomically: true, encoding: .utf8)
                script += "\(position + 1)) /bin/cp " + rebaseShellQuote(file.path) + " \"$1\" ;;\n"
            }
        }
        script += "*) ;;\nesac\n"
        let messageEditor = directory.appendingPathComponent("message-editor")
        try script.write(to: messageEditor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: messageEditor.path)
        do {
            let result = try await workflowRead(["-c", "core.abbrev=40", "-c", "sequence.editor=" + rebaseShellQuote(editor.path), "-c", "core.editor=" + rebaseShellQuote(messageEditor.path), "rebase", "-i", "--rebase-merges", "--reapply-cherry-picks", "--keep-empty", "--empty=keep", plan.base])
            await cleanupRebaseToolsIfFinished(); return result
        } catch { await cleanupRebaseToolsIfFinished(); throw error }
    }
    private func rebaseShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    func rebaseGitPath(_ path: String) async throws -> URL {
        let value = try await workflowRead(["rev-parse", "--git-path", path]).trimmingCharacters(in: .newlines)
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : url.appendingPathComponent(value)
    }
}
