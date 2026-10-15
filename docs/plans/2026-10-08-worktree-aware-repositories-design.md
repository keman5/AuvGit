# Worktree-aware repositories design

## Goal

When AuvGit opens a repository, register its usable linked worktrees as repository projects. When a local branch is already checked out in another worktree, selecting that branch opens the corresponding project instead of attempting `git switch`.

## Design

GitCore will expose a small `GitWorktree` model and parse `git worktree list --porcelain -z`. NUL-delimited porcelain output avoids path and branch-name ambiguity. Entries marked `prunable`, bare entries, and paths that cannot be opened as repositories will not be registered in the application.

`RepositoryStore.performOpen` will keep the explicitly opened repository active, then merge usable linked worktree paths into `openRepositories` and `recentPaths` without duplicates. The store will retain a branch-to-path mapping for the active repository and refresh it when a branch is selected so externally added or removed worktrees are handled.

`RepositoryStore.switchBranch` will first resolve the selected local branch. If it belongs to another usable worktree, it will request opening that repository and return without checking out or stashing. Otherwise it will preserve the existing `BranchSwitch.perform` behavior.

## Failure handling

Failure to enumerate worktrees must not prevent the selected repository from opening. Invalid, bare, or prunable worktree entries are ignored. If a mapped worktree disappears between discovery and selection, AuvGit falls back to the existing branch switch, allowing Git's canonical error to be shown.

## Verification

GitCore tests cover porcelain parsing and real linked-worktree discovery. AuvGit tests cover repository-list merging and branch routing so cross-worktree selection opens the linked project while ordinary branch selection still runs the existing checkout path.
