---
name: execute
description: Execute a planned feature as parallel codex tasks off the Claude critical path — convert the session's plan into spec.md+tasks.txt, launch execute.sh (worktree pool, per-task checks, bounded retries, merge to one feature branch, codex review, push, single PR), then relay the PR. Use when the user wants many-at-once implementation work delegated to codex.
---

# execute — parallel codex execution off the Claude critical path

Claude plans once and never re-enters; git + the filesystem are the
coordination bus. Engine: `${CLAUDE_PLUGIN_ROOT}/skills/execute/execute.sh`.
Design rationale and measured numbers: `${CLAUDE_PLUGIN_ROOT}/docs/design.md`.

## When to use

The handover point of the standard DX: the user researches and plans a feature
with you in Claude Code, then invokes this skill — from there codex delivers
the feature to a pushed branch and PR. Use for **independent, self-contained**
backend tasks codex can execute in parallel. NOT for interactive research/spec
work (keep steering that live), NOT for UI/UX work.

## Phase 1 — Plan handover (you, ONE turn)

The input is the plan already developed in THIS conversation — do not re-plan
or re-ask; convert it. (If invoked with no prior plan, do the research first,
then come back here.)

**You (Claude Code) create spec.md and tasks.txt — codex only reads them.**
Put them where the repo keeps design docs (e.g. `specs/<date>-<feature>/`, or
`docs/`), committed to the base branch so every task worktree carries them.

1. Decompose the plan into N independent tasks. **Partition along file
   boundaries so no two tasks edit the same file** — conflict avoidance is the
   planner's job; there is no runtime check. If overlap is unavoidable, record
   it in spec.md (which tasks, which files) so the merge phase expects it.
2. Write `spec.md` (architecture, constraints, patterns, out-of-scope, known
   overlaps, cross-task invariants). Put invariants into the check command
   where possible: the deterministic gates replace your live review.
3. Write `tasks.txt`: one task per line, each line a **pointer** into the
   spec, not the whole brief
   (`implement task 3 per specs/<date>-<feature>/spec.md §3; run auth tests`).
   Commit both to the base branch.

## Phase 2+3 — Execute, Merge & Push (script, NO Claude)

```
${CLAUDE_PLUGIN_ROOT}/skills/execute/execute.sh \
  --tasks <path>/tasks.txt --base <base> --feature <name> \
  --check "<verify cmd>" --spec <path>/spec.md \
  [--setup "<per-worktree deps cmd>"] [--onto-base] \
  [--concurrency N] [--retries 2] [--timeout 2400] [--no-push]
```

**`--onto-base`** = the base branch already has an open PR (several features
accumulating on one branch). Tasks still integrate on a temp feature branch,
but delivery pushes `feature:base` (fast-forward; rejects safely if base moved
mid-run) so the EXISTING PR updates — no new branch or PR, and the feature
worktree/branch are cleaned up after the push. Without the flag, delivery
pushes the feature branch and opens a new PR against base.

Launch it in the background and END YOUR TURN — do not poll, do not ingest
task logs. Progress lives in files:
- statuses: `<repo>/.git/codex-execute/<feature>/status/task-*.json` + `summary.json`
- logs: `<repo>/.git/codex-execute/<feature>/logs/`

Semantics (all verified by tests/test-execute.sh):
- Worktree pool sized to concurrency at `../.codex-execute-<feature>/w*`;
  created on demand, deleted after merge. Task branches `tasks/<feature>/<n>`.
- Red = check failed OR codex timeout OR codex nonzero exit OR no diff.
  Bounded retry re-invokes codex in the same worktree with the failure tail
  appended.
- Failed tasks: excluded from merge; branch kept only if it has commits.
- Merge: green tasks → feature branch sequentially; conflicts resolved by
  codex in the feature worktree; post-merge `check` must pass or nothing is
  pushed.
- Exit 0 = all green; 2 = partial (some tasks failed, feature green + pushed);
  1 = post-merge check red or push failed (feature worktree left for autopsy).

`--setup` example (codex's sandbox has no network, so provision deps when
creating each worktree): `cp -R ../main-checkout/node_modules node_modules`
(on APFS use `cp -Rc` for a copy-on-write clone).

## Phase 4 — Review (codex, automatic)

The engine runs the review itself — local `codex exec review --base <base>` on
the integrated diff, findings written to
`.git/codex-execute/<feature>/logs/review.md` — then delivers (push + PR or
existing-PR update) and comments `@codex review` as a bonus so the codex
GitHub app also reviews when installed. There is no Claude review step (by
design) and nothing for you to run.

(codex-cli gotcha: `review --base` cannot take custom instructions — review
focus belongs in spec.md, which the reviewer reads from the tree.)

When the run finishes, relay `summary.json`, the review.md findings, and the
PR URL to the user; they merge on green. FAILED tasks are listed in the PR
body — offer to re-plan just those as a new small run (new feature name)
rather than re-entering the loop yourself.

## Cleanup after the PR merges

`git worktree remove ../.codex-execute-<feature>/feature && git branch -d <feature>`
(task worktrees/branches are already gone; `.git/codex-execute/<feature>/` can
be deleted whenever).
