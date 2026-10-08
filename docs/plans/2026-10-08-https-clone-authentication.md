# HTTPS Clone Authentication Implementation Plan

> **For Codex:** Implement this plan in the current checkout with systematic debugging, TDD, and verification-before-completion. Do not create a worktree, delegate, or commit unless the user asks.

**Goal:** Let RayGit collect first-time HTTPS clone credentials in native UI, pass them to Git without exposing secrets in URLs, argv, or logs, and optionally persist successful credentials in macOS Keychain.

**Architecture:** The first clone attempt continues to use existing Git credential helpers. An HTTPS authentication failure reveals username and password/token controls in the clone sheet. A retry creates a mode-0700 temporary helper and mode-0600 credential response, injects only the helper path through command-local Git configuration, and removes the temporary material after Git exits. Adding `osxkeychain` before the one-shot helper lets Git persist successful credentials only when the user opts in.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI/AppKit, Git credential helper protocol, XCTest.

---

### Task 1: One-shot credential transport

**Files:**
- Modify: `Sources/GitCore/RepositoryManagement.swift`
- Test: `Tests/GitCoreTests/RepositoryWorkflowTests.swift`

1. Add a failing test that creates a one-shot HTTPS credential lease, runs `git credential fill`, and verifies the exact username/password response without putting either secret in Git arguments.
2. Run `swift test --build-system native --filter RepositoryWorkflowTests` and confirm the new API is missing.
3. Add validated `HTTPSCredential` input and a temporary credential helper whose directory and files have restrictive permissions.
4. Build command-local helper arguments with `credential.helper=` followed by optional `osxkeychain` and the one-shot helper.
5. Ensure temporary credential files are removed with `defer` after clone completion or failure.
6. Re-run the focused tests and confirm they pass.

### Task 2: Clone authentication presentation

**Files:**
- Create: `Sources/RayGit/CloneAuthentication.swift`
- Modify: `Sources/RayGit/RepositoryTools.swift`
- Test: `Tests/RayGitTests/CloneAuthenticationTests.swift`

1. Add failing policy tests for HTTPS askpass failures, SSH public-key failures, and unrelated clone failures.
2. Implement a small policy that classifies failures and returns stable localization keys without retaining a secret or remote URL.
3. Reveal username, secure password/token, and Keychain opt-in controls only after an HTTPS authentication failure.
4. Retry with `GitRepository.clone(source:destination:credential:)`; keep the form open on failure and clear the token after a successful clone.
5. Show actionable HTTPS and SSH messages while leaving unrelated Git diagnostics intact.
6. Run `swift test --build-system native --filter 'CloneAuthenticationTests|OperationFailureTests'`.

### Task 3: Localization and security regression coverage

**Files:**
- Modify: `Sources/RayGitLocalization/Resources/{en,zh-Hans,zh-Hant,ja}.lproj/Workflow.strings`
- Modify: `Tests/GitCoreTests/GitCommandLogTests.swift` only if a redaction regression is required

1. Add the username, password/token, Keychain opt-in, HTTPS guidance, and SSH guidance strings in all four locales.
2. Run `python3 scripts/check-localizations.py`.
3. Verify `git diff` contains no credential values and `git diff --check` passes.

### Task 4: Full verification and local installation

**Files:**
- Generated: `.artifacts/RayGit.app`
- Generated: `.artifacts/RayGit.dmg`
- Installed: `/Applications/RayGit.app`

1. Run the focused tests, then the full `swift test --build-system native` suite.
2. Run `./scripts/build-app.sh` locally and verify the app signature.
3. Rebuild `.artifacts/RayGit.dmg` and verify its checksum.
4. Replace `/Applications/RayGit.app`, launch it, wait five seconds, and confirm the process remains alive.
5. Confirm the installed executable matches the release build and report the remaining external prerequisite: a valid GitLab PAT or registered SSH public key.
