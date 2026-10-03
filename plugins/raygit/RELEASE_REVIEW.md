# RayGit 0.3.1 review preparation

Status: locally installable package, not submitted or publicly published.

## Implemented interaction

Open the official thread extension “RayGit”. Select a repository. Single click previews a changed file; double click or Enter opens the comparison dialog inside the panel. Edit worktree or index, apply individual diff chunks, undo/redo, search/replace, navigate changes, fold unchanged lines, wrap and sync scrolling. Optional third pane displays HEAD/index/worktree or conflict base/ours/theirs. Save and stage are separate actions.

The public extension API does not document a slot to replace the native top-right Changes card or inject arbitrary top-bar controls. Native placement and desktop-host rendering have not been verified; Edge preview uses the actual MCP SDK/AppBridge but is not Codex itself.

## Review cases

Five positive and three negative cases are included in `plugin.json` at `extensions.com.openai.review.test_cases`. Backend fixture tests and Edge interaction evidence are local rehearsal, not tests against a saved public submission. Only disposable repositories and a temporary local bare remote were mutated by tests.

## Demo recording plan (not a recording)

1. Open RayGit from the Codex thread extension in a disposable repo.
2. Single click a file then double click it; edit and save to worktree.
3. Switch target to index, apply one selected chunk and save; show separate staged/unstaged changes.
4. Show conflict ours/theirs/base, edit the result and explicitly mark resolved.
5. Configure `git status --short`, inspect exact command confirmation, run and show exit code/output. Show a cancellable `sleep 30` command.
6. Make an external edit and demonstrate stale-save rejection and retained draft.

Record the actual Codex host, upload to the publisher's chosen reviewer-accessible destination, then set the real demo URL. Screenshots and this script do not replace a recording.

## Required publishing inputs / external checks

- Intended verified individual or organization; availability countries; whether there is any payment/purchase flow. These have been requested, not yet supplied.
- Real HTTPS website, support, privacy policy and terms URLs covering local repository access and command execution. No invented URLs or legal declarations are present.
- Reviewer-accessible recording URL and actual Codex desktop acceptance.
- Confirm the public directory supports this local stdio/runtime package. Official submission guidance discusses eligible remote HTTPS MCP conversion; uploading a local package does not host it or make local repositories available to cloud servers.
- Complete required identity, scans and legal/policy attestations with the authorized publisher. Submit, await approval, then publish the approved version. No public Codex install URL exists yet.

A separately published Git marketplace is another distribution route if a real public repository/release target is supplied and authorized. The full local marketplace ZIP is already prepared. Do not push the unrelated native RayGit application or the working repository simply to distribute this plugin.

## Sources checked 2026-10-03

- https://developers.openai.com/plugins/build/extensions
- https://developers.openai.com/plugins/build/plugins
- https://developers.openai.com/plugins/deploy/submission

## 0.3 verification boundary

28 local tests pass, including real Codex manifest loading, fresh MCP roots A/B switching, ambiguity handling, PTY cwd/isolation/resize/Ctrl+C/exit. Edge AppBridge validation confirms the new file-table layout, double-click comparison, deferred project switching during an unsaved comparison, restored commit drafts, Cmd+Backquote and terminal pwd. These are development-host tests; actual Codex global/thread entrypoint project switches and shortcut interception still require desktop acceptance. The installed stdio server is checked separately.

## 0.3.1 project selection

The app-server project/list API returned all nine local Codex projects with labels matching the desktop project tool. 29 tests cover project pagination, offline cache, unavailable paths, corrupt preferences and persistence across actual stdio server restarts. The title and picker are merged and no path-entry form remains. Cloud/remote projects are outside this local repository catalog.
