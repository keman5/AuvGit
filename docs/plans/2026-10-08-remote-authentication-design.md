# Remote Authentication Design

## Problem

AuvGit disables terminal prompts for every Git child process. Clone has a one-shot HTTPS credential helper, but fetch, pull, push, push preview, and guarded force push do not have an application-owned authentication path. When Git cannot obtain credentials from the existing environment it exits with `terminal prompts disabled`, and AuvGit only displays the error.

Git URL rewriting also means the remote stored in `.git/config` is not necessarily the endpoint Git uses. Authentication must therefore be based on `git remote get-url`, which applies `insteadOf` rules, and on the remote selected by the current branch and operation.

## Behavior

- Run the requested network operation with existing Git helpers and SSH configuration first.
- When the failure is classified as HTTPS or SSH authentication failure, resolve the effective remote endpoint and show a protocol-locked native authentication sheet.
- HTTPS asks for username and password or personal access token.
- SSH asks for username, private-key file, and an optional key passphrase.
- Retry the original operation after submission. Do not change repository remote configuration.
- Persist credentials only after the authenticated Git operation succeeds.
- Reuse saved credentials for repositories that resolve to the same protocol, host, port, and username.
- Keep different usernames isolated. The most recently successful username for an endpoint may be preselected, but it is part of the credential identity rather than a host-wide secret.

## Credential Scope And Storage

`RemoteCredentialIdentity` normalizes the effective endpoint:

- HTTPS: scheme, lowercase host, explicit/default port, username.
- SSH: lowercase host, explicit/default port, username.

HTTPS secrets and optional SSH passphrases are stored as generic passwords in macOS Keychain. Account identifiers contain the normalized protocol, host, port, and username. Private-key paths and security-scoped bookmarks are stored in application preferences under the same non-secret identity.

The UI never reads arbitrary Git credential-helper secrets. It only reads credentials previously saved by AuvGit under its own Keychain service.

## Git Injection

HTTPS retries reuse the existing restrictive temporary credential-helper approach. The helper is scoped to one normalized endpoint and username, and inherited helpers are disabled for the explicit retry.

SSH retries create a temporary askpass lease when a passphrase exists and use a process-local `GIT_SSH_COMMAND` override with the selected key, `IdentitiesOnly=yes`, the resolved port, and host-key checking left enabled. The passphrase is held in a mode-0600 temporary file read by a mode-0700 askpass helper. Secrets never appear in argv, remote URLs, operation output, or command logs. Temporary material and security-scoped access are released on success, failure, or cancellation.

## UI Integration

One reusable `RemoteAuthenticationSheet` serves both the main toolbar and `NetworkOperationsView`. Each owner retains the failed operation and repository identity, presents the sheet, and retries only if the same repository is still active.

The main toolbar uses the same retry behavior for fetch, pull, push, push preview, and guarded force push. The network sheet preserves its existing progress, preview identity, and force-push confirmation behavior.

## Error Handling

- Only recognized authentication failures open the sheet; connection, TLS, proxy, host-key, authorization, and non-fast-forward errors keep their existing handling.
- An inaccessible or stale private-key bookmark keeps the form open and asks the user to choose the key again.
- A failed retry keeps the form open with a redacted diagnostic.
- Canceling the form does not alter Git configuration or saved credentials.

## Verification

Tests cover effective remote parsing, identity normalization, endpoint isolation, Keychain abstraction behavior, temporary HTTPS/SSH helper security, auth-failure classification, persistence only after success, and retry policy. Full Swift tests, localization checks, diff checks, and a local release build complete verification.
