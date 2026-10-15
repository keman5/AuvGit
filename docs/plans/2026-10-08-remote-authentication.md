# Remote Authentication Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Present native HTTPS or SSH authentication when a Git network operation lacks credentials, securely retry it, and reuse credentials by effective remote endpoint and username.

**Architecture:** GitCore resolves the effective remote, models a normalized credential identity, and accepts an explicit one-operation credential lease. AuvGit owns Keychain/bookmark persistence and the protocol-locked sheet, then retries the exact failed operation. Existing Git helpers and SSH configuration remain the first attempt.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager, Security.framework, Git credential helper protocol, OpenSSH askpass, XCTest.

---

## Constraints

- Use the current checkout; do not create a worktree.
- Preserve all unrelated working-tree changes.
- Keep tests uncommitted unless explicitly requested.
- Never include usernames, passwords, tokens, passphrases, private-key contents, or credential-bearing URLs in command logs or displayed diagnostics.

### Task 1: Remote identity and failure policy

**Files:**
- Create: `Sources/GitCore/RemoteAuthentication.swift`
- Create: `Tests/GitCoreTests/RemoteAuthenticationTests.swift`
- Create: `Sources/AuvGit/NetworkAuthenticationPolicy.swift`
- Create: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Write failing tests for HTTPS, `ssh://`, and SCP-style remotes, default/nondefault ports, explicit usernames, URL rewriting output, and malformed/local remotes.
2. Run `swift test --build-system native --filter 'RemoteAuthenticationTests|NetworkAuthenticationPolicyTests'` and confirm failures are caused by missing APIs.
3. Implement `RemoteEndpoint`, `RemoteCredentialIdentity`, and authentication-failure classification.
4. Resolve the effective remote name and URL with Git commands appropriate to fetch/pull versus push.
5. Re-run the focused tests and keep the implementation free of UI and persistence concerns.

### Task 2: One-operation credential transport

**Files:**
- Modify: `Sources/GitCore/RepositoryManagement.swift`
- Modify: `Sources/GitCore/NetworkOperations.swift`
- Modify: `Sources/GitCore/GitProcess.swift`
- Modify: `Sources/GitCore/GuardedForcePush.swift`
- Test: `Tests/GitCoreTests/RemoteAuthenticationTests.swift`
- Test: `Tests/GitCoreTests/HTTPSCloneCredentialTests.swift`

1. Add failing tests proving endpoint isolation, no secrets in argv, mode-0700/0600 temporary material, SSH key quoting, passphrase askpass behavior, and cleanup.
2. Add an explicit `NetworkCredential` input for HTTPS and SSH.
3. Reuse the existing HTTPS lease and add an SSH lease using command-local `core.sshCommand` plus a temporary askpass helper.
4. Thread the credential through normal network operations, push preparation, force-push preparation, and force-push execution.
5. Run the focused GitCore tests and the existing clone credential security tests.

### Task 3: Keychain and bookmark persistence

**Files:**
- Create: `Sources/AuvGit/RemoteCredentialStore.swift`
- Create: `Tests/AuvGitTests/RemoteCredentialStoreTests.swift`

1. Define a small Keychain client protocol and write failing tests with an in-memory client.
2. Store HTTPS passwords/PATs and SSH passphrases under the AuvGit service using the normalized identity as account.
3. Store the last successful username, private-key path, and security-scoped bookmark as non-secret preferences scoped to the endpoint and username.
4. Persist only after a successful retry; failed and canceled retries must leave prior state unchanged.
5. Run the focused store tests.

### Task 4: Shared authentication sheet

**Files:**
- Create: `Sources/AuvGit/RemoteAuthenticationSheet.swift`
- Modify: `Sources/AuvGitLocalization/Resources/{en,zh-Hans,zh-Hant,ja}.lproj/Network.strings`
- Test: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Add HTTPS and SSH form-state tests before production code.
2. Implement a protocol-locked sheet with username, secure HTTPS secret, private-key chooser, optional secure SSH passphrase, save toggle, redacted error, Cancel, and Retry.
3. Resolve stale bookmarks and preserve security-scoped access for the retry lifetime.
4. Add all strings in four locales and run `python3 scripts/check-localizations.py`.

### Task 5: Network page retry integration

**Files:**
- Modify: `Sources/AuvGit/NetworkOperationsView.swift`
- Test: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Add failing retry-state tests for fetch, pull, push preview, push, and force push.
2. On a recognized first-attempt authentication failure, resolve the endpoint and present the shared sheet.
3. Retry the exact operation with the submitted credential while preserving progress and preview checks.
4. Save credentials only after success, then refresh repository context as today.

### Task 6: Main toolbar retry integration

**Files:**
- Modify: `Sources/AuvGit/MainWindow.swift`
- Modify: `Sources/AuvGit/AuvGitApp.swift` only if shared store state is required
- Test: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Add failing policy tests for toolbar fetch, pull, push, and confirmed force push.
2. Route toolbar network commands through one authentication-aware runner.
3. Preserve pull preflight, push preview, non-fast-forward handling, cancellation, and operation-log behavior.
4. Confirm switching repositories invalidates pending authentication and retry state.

### Task 7: Verification

1. Run focused credential and policy tests.
2. Run `swift test --build-system native`.
3. Run `python3 scripts/check-localizations.py` and `git diff --check`.
4. Inspect the diff for leaked secrets, unsafe shell interpolation, unrelated changes, and credential persistence before success.
5. Run `./scripts/build-app.sh` locally and verify the resulting app bundle. Do not build on a VPS.
