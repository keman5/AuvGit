# Segmented Remote Authentication Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let users retry failed network operations with an access token or app password, an account password, or a custom SSH private key, and safely migrate an HTTPS remote to SSH after SSH authentication succeeds.

**Architecture:** Keep HTTPS secrets and SSH key material in the existing `NetworkCredential` and `RemoteCredentialStore` boundary. Add a presentation-only authentication method to the sheet, plus a GitCore SSH migration plan that derives a stable SSH URL from the effective HTTPS remote, verifies access without changing configuration, then updates the exact fetch or push URL that Git resolved before retrying the operation.

**Tech Stack:** Swift 6, SwiftUI, Security.framework, Git CLI, XCTest, Swift Package Manager.

---

### Task 1: Model segmented methods and SSH URL conversion

**Files:**
- Modify: `Sources/GitCore/RemoteAuthentication.swift`
- Modify: `Sources/AuvGit/RemoteAuthenticationSheet.swift`
- Test: `Tests/GitCoreTests/RemoteAuthenticationTests.swift`
- Test: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Add failing tests for the default HTTPS token method, separate password mode, SSH form validation, safe HTTPS-to-SSH URL conversion, custom SSH port, and invalid input.
2. Run `swift test --build-system native --filter RemoteAuthenticationTests` and `swift test --build-system native --filter NetworkAuthenticationPolicyTests`; confirm the new tests fail because the method and migration APIs do not exist.
3. Add `RemoteAuthenticationMethod`, make the draft produce HTTPS credentials for token/password and SSH credentials for private-key mode, and add a pure HTTPS-to-SSH endpoint conversion API.
4. Re-run both focused test classes and confirm they pass.

### Task 2: Verify before permanently changing the remote

**Files:**
- Modify: `Sources/GitCore/RemoteAuthentication.swift`
- Test: `Tests/GitCoreTests/RemoteAuthenticationTests.swift`

1. Add failing tests that resolve whether the active operation uses `remote.<name>.url` or `remote.<name>.pushurl`, reject a stale migration plan, leave configuration unchanged when verification fails, and update the correct URL after verification succeeds.
2. Run the focused GitCore tests and confirm failure for the missing migration behavior.
3. Implement a migration plan, read-only `ls-remote` verification using the selected SSH credential, and guarded application with `git remote set-url`.
4. Re-run the focused tests and confirm they pass.

### Task 3: Build the segmented authentication sheet

**Files:**
- Modify: `Sources/AuvGit/RemoteAuthenticationSheet.swift`
- Modify: `Sources/AuvGitLocalization/Resources/en.lproj/Network.strings`
- Modify: `Sources/AuvGitLocalization/Resources/ja.lproj/Network.strings`
- Modify: `Sources/AuvGitLocalization/Resources/zh-Hans.lproj/Network.strings`
- Modify: `Sources/AuvGitLocalization/Resources/zh-Hant.lproj/Network.strings`
- Test: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Render a segmented picker with access token/app password as the HTTPS default, account password, and SSH private key.
2. Keep username and secret values method-local so switching segments cannot expose or reuse a password as an SSH passphrase.
3. Show SSH username, port, private-key chooser, and optional passphrase; explain that a successful SSH check changes the remote before retry.
4. Save successful credentials automatically using the existing Keychain/security-bookmark store.
5. Run focused UI-model tests and localization validation.

### Task 4: Integrate migration into every retry path

**Files:**
- Modify: `Sources/AuvGit/RemoteAuthenticationSheet.swift`
- Modify: `Sources/AuvGit/MainWindow.swift`
- Modify: `Sources/AuvGit/NetworkOperationsView.swift`
- Test: `Tests/AuvGitTests/NetworkAuthenticationPolicyTests.swift`

1. Add a coordinator preparation step that scopes the selected key, verifies SSH access, applies the guarded migration, and only then executes the existing retry callback.
2. Route toolbar push, network-sheet push/preview, fetch/pull, and guarded force-push retries through that preparation step.
3. Persist credentials only after authentication preparation or the network operation succeeds; never save a rejected secret.
4. Keep the authentication sheet open with an actionable error when verification fails.

### Task 5: Verify locally

**Files:**
- Verify all modified authentication and localization files.

1. Run focused authentication tests.
2. Run `swift test --build-system native`.
3. Run `python3 scripts/check-localizations.py`.
4. Run `git diff --check`.
5. Run `./scripts/build-app.sh` locally and inspect the final diff without staging or committing test files.
