# Accessible Commit Graph Design

## Goal

Redesign the history graph so branch identity, branch state, and commit type remain distinguishable through three independent visual channels: color, stroke pattern, and node shape.

## Information Model

- Color identifies a branch lineage. `main`/`master` uses blue `#378ADD`, `develop` uses cyan `#1D9E75`, remote-only branches use purple `#7F77DD`, and feature branches use coral `#D85A30` followed by pink `#D4537E`, green `#639922`, and gray `#888780` in stable branch-name order.
- Stroke pattern identifies branch state. Long-lived `main`/`master` and `develop` branches are solid. Merged feature branches are dashed. Remote-only or unmerged branches are dotted.
- Node shape identifies commit type. Ordinary commits are filled circles, merge commits are a ring with an inner dot, and remote-only commits are hollow circles. Merge shape takes precedence when both conditions apply.
- `HEAD` adds a separate outer ring without replacing the underlying node shape.

The presentation model derives branch tips from commit decorations and known remote branch names. It walks first-parent ancestry for named lineages and uses deterministic hash-based fallback styles for unnamed topology. This keeps styles stable across pagination and filtering without expanding the Git query into a full repository graph.

## Rendering

`GitCore.CommitGraph` continues to own topology. `HistoryGraphStylePlan` owns presentation semantics for commit hashes, segment lineage hashes, and reference labels.

- Merge edges inherit the style of the merged lineage identified by `CommitGraph.Segment.lineageHash`.
- Curves use rounded cubic Bezier paths.
- Lane spacing is 18 points and row height is 28 points, with a 24-point compact row.
- Each line and node first receives a background-colored halo so crossings remain legible.
- Selected rows retain branch colors; selection changes only the halo background.
- Branch labels use a light fill and border derived from the branch color. Tags always use amber `#BA7517`.
- After the base palette repeats, dash phase variants prevent adjacent lineages from sharing both color and pattern.

## Classification Boundaries

- A local branch is merged when its tip is reachable from a visible `main`, `master`, or `develop` tip.
- A commit is remote-only when it is reachable from a remote tip and not reachable from any local tip.
- If only a partial history is loaded, unresolved frontier hashes retain the style propagated from their visible child.
- Deleted branch names cannot be reconstructed from Git history. Their unnamed side lineages receive deterministic fallback feature styles.

## Testing

- Branch decoration parsing and stable palette assignment.
- Long-lived, merged feature, unmerged, and remote-only stroke selection.
- Ordinary, merge, remote-only, and `HEAD` node semantics.
- Segment lineage style inheritance through forks and merges.
- Stable fallback styles across reordered or paginated inputs.
- Label color rules, including the tag override.
- Layout math for 18-point lanes and 24/28-point rows.
