# Pull conflict recovery

Goal: Pull merges diverged history, preserves unresolved conflicts locally, and automatically saves obstructing workspace changes before retrying.

Architecture: GitCore returns a structured pull outcome to both network entry points. Only Git's overwrite refusal permits a stash retry. Existing merge/rebase/conflict states refuse mutation. The auto-stash includes untracked files, is identified by its object ID, and is retained even after restoration. After a clean pull, restore staged/worktree changes; if conflicts remain, expose them through refreshed repository status and an informational dialog.

Implementation:
1. Add real temporary local/bare/peer Git fixtures covering divergence, merge conflicts, workspace conflicts, staged/untracked preservation, existing-conflict refusal, and unrelated network failures.
2. Implement shared pull recovery inside runNetwork, retaining credential/progress scoping.
3. Present outcome dialogs in toolbar and network panel; update pull explanations in all four locales.
4. Run relevant native Swift tests, build locally, replace the installed application and verify the artifact.

No worktree, commit, push, or mutation of the user's repository for testing.
