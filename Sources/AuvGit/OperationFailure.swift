import Foundation
import GitCore
import AuvGitLocalization

enum OperationFailure {
    struct Event: Sendable { let repository: URL?; let message: String }
    static let notification = Notification.Name("AuvGitOperationFailed")
    private static let table = "OperationLog"

    /// Keep the original diagnostic in the log and return a localized summary to the dialog.
    static func message(_ error: Error, repository: URL? = nil) -> String {
        let diagnostic = GitCommandLog.redact(error.localizedDescription)
        if !(error is CancellationError) {
            NotificationCenter.default.post(name: notification, object: Event(repository: repository, message: diagnostic))
        }
        return summary(diagnostic) ?? diagnostic
    }

    static func display(_ diagnostic: String) -> String {
        let safe = GitCommandLog.redact(diagnostic)
        return summary(safe) ?? safe
    }

    static func summary(_ diagnostic: String) -> String? {
        guard !diagnostic.isEmpty else { return nil }
        let language = L10n.language
        func text(_ key: String, _ arguments: [CVarArg] = []) -> String {
            L10n.text(key, table: table, language: language, arguments: arguments)
        }

        var cause = diagnostic
        var prefix = ""
        var suffix = ""
        // Keep the recovery location visible alongside the underlying failure.
        let stashMarker = "\nSaved changes remain in stash "
        if let range = cause.range(of: stashMarker, options: .backwards) {
            let stash = String(cause[range.upperBound...])
            if !stash.isEmpty, !stash.contains(where: \.isNewline) {
                cause = String(cause[..<range.lowerBound])
                suffix = "\n" + text("Saved changes remain in stash %@.", [stash])
            }
        }
        if let match = cause.wholeMatch(of: branchCreated) {
            prefix = text("Branch %@ was created, but checkout failed. Your changes are preserved.", [String(match.1)]) + "\n"
            cause = String(match.2)
        }

        let translated: String?
        if let translation = L10n.translation(cause, table: table, language: language) {
            translated = translation
        } else if let format = formattedError(cause) {
            translated = text(format.key, [format.argument])
        } else {
            translated = GitFailureSummary.message(for: cause, localize: { text($0) })
        }
        if prefix.isEmpty, suffix.isEmpty { return translated }
        return prefix + (translated ?? cause) + suffix
    }

    private static func formattedError(_ diagnostic: String) -> (key: String, argument: String)? {
        for (pattern, key) in formats {
            if let match = diagnostic.wholeMatch(of: pattern), let argument = match[1].substring {
                return (key, String(argument))
            }
        }
        return nil
    }

    private static let branchCreated = #/^Branch created: (.+)\. Could not switch; your changes are preserved\.\n([\s\S]+)$/#
    private static let formats: [(Regex<AnyRegexOutput>, String)] = [
        (Regex(#/^Could not read the remote credential in macOS Keychain \((-?[0-9]+)\)\.$/#), "Could not read the remote credential in macOS Keychain (%@)."),
        (Regex(#/^Could not save the remote credential in macOS Keychain \((-?[0-9]+)\)\.$/#), "Could not save the remote credential in macOS Keychain (%@)."),
        (Regex(#/^Could not delete the remote credential in macOS Keychain \((-?[0-9]+)\)\.$/#), "Could not delete the remote credential in macOS Keychain (%@)."),
        (Regex(#/^Git command failed \((-?[0-9]+)\)\.$/#), "Git command failed (%@)."),
        (Regex(#/^Git operation timed out after ([0-9]+) seconds\.$/#), "Git operation timed out after %@ seconds."),
        (Regex(#/^Cannot start Git: (.+)\.$/#), "Cannot start Git: %@."),
        (Regex(#/^Cannot wait for Git: (.+)\.$/#), "Cannot wait for Git: %@."),
        (Regex(#/^Cannot collect Git exit status: (.+)\.$/#), "Cannot collect Git exit status: %@."),
        (Regex(#/^Cannot discard this worktree path: ([\s\S]+)$/#), "Cannot discard this worktree path: %@"),
        (Regex(#/^External tool template references an unavailable version: (.+)\.$/#), "External tool template references an unavailable version: %@."),
        (Regex(#/^The branch '(.+)' is not fully merged\.$/#), "The branch '%@' is not fully merged."),
        (Regex(#/^Branch switch cancelled; saved changes remain in stash (.+)$/#), "Branch switch cancelled. Saved changes remain in stash %@."),
        (Regex(#/^Missing commit on todo line ([0-9]+)$/#), "Missing commit on todo line %@"),
        (Regex(#/^Unknown or duplicate commit on todo line ([0-9]+)$/#), "Unknown or duplicate commit on todo line %@"),
        (Regex(#/^Unexpected arguments on todo line ([0-9]+)$/#), "Unexpected arguments on todo line %@"),
        (Regex(#/^Unknown rebase instruction on todo line ([0-9]+)$/#), "Unknown rebase instruction on todo line %@"),
    ]
}
