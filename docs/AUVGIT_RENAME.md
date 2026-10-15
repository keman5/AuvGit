# AuvGit rename

The application, Swift package/modules, source and test folders, symbols, localization resources, plugin, scripts, temporary-file prefixes and release artifacts now use AuvGit / auvgit / AUVGIT. The executable is AuvGit, the installed bundle is `/Applications/AuvGit.app`, and the bundle identifier is `dev.auvgit.mac`. The repository checkout path and Git remotes are unchanged.

On first launch, settings are imported from the legacy bundle domain without overwriting existing AuvGit settings. Repository paths and bookmark values are preserved verbatim. Old Keychain service names remain only for credential compatibility; new credentials use AuvGit service names. The installer quits both application identities, verifies the new installation, then moves the legacy application to Trash.

Validation on 2026-10-15:

- Localization parity/static lookup checks: 4 languages, 43 tables, 1,442 keys passed.
- Build/installation shell test and shell syntax checks passed.
- Release build, installation, strict signature and artifact/installed executable comparison passed. The installed AuvGit launched with the prior repository list, active repository and Chinese UI restored; the application menu identifies AuvGit. The legacy application was moved to Trash after successful installation.
- Preferences migration, credential compatibility and localization test suites passed (8 tests).
- Plugin build passed. Plugin tests passed with the Codex host-loader integration excluded; that integration timed out waiting for host initialization when run explicitly.
- Full native run: 625 XCTest cases, 3 skipped, 35 failure records (including 1 unexpected); Swift Testing's 7 tests passed. Failures include comparison placeholders, remote tracking, presentation-cache/refresh assertions, and UI timing/rendering gates. The comparison-placeholder assertion and conflict-layout timing gate also failed on focused recheck. No baseline comparison was performed, so these results do not establish when the failures were introduced.

Logs: `/tmp/auvgit-rename-tests.log`, `/tmp/auvgit-rename-focused-tests.log`, `/tmp/auvgit-plugin-final-tests.log`, `/tmp/auvgit-plugin-recheck.log`, `/tmp/auvgit-rename-build.log`.
