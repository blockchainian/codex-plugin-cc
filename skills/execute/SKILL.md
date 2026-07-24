---
name: "codex:execute"
description: Execute a planned feature as parallel codex workstreams off the Claude critical path — convert the session's plan into spec.md+workstreams.txt, launch execute.sh (worktree pool, per-workstream checks, bounded retries, merge onto the session branch, codex review, push), then relay the result. Use when the user wants many-at-once implementation work delegated to codex.
---

# codex:execute — parallel codex execution off the Claude critical path

Claude plans once and never re-enters; git + the filesystem are the
coordination bus. Engine: `${CLAUDE_PLUGIN_ROOT}/skills/execute/execute.sh`.
Design rationale and measured numbers: `${CLAUDE_PLUGIN_ROOT}/docs/design.md`.

## When to use

The handover point of the standard DX: the user researches and plans a feature
with you in Claude Code, then invokes this skill — from there codex delivers
the feature onto the branch the session is on. Use for **independent,
self-contained** backend workstreams codex can execute in parallel. NOT for
interactive research/spec work (keep steering that live), NOT for UI/UX work.

## Phase 1 — Plan handover (you, ONE turn)

The input is the plan already developed in THIS conversation — do not re-plan
or re-ask; convert it. (If invoked with no prior plan, do the research first,
then come back here.)

**You (Claude Code) create spec.md and workstreams.txt — codex only reads them.**
Put them where the repo keeps design docs (e.g. `specs/<date>-<feature>/`, or
`docs/`), committed to the session branch so every workstream worktree carries
them.

1. Decompose the plan into N independent workstreams. **Partition along file
   boundaries so no two workstreams edit the same file** — conflict avoidance
   is the planner's job; there is no runtime check. If overlap is unavoidable,
   record it in spec.md (which workstreams, which files) so the merge phase
   expects it.
2. Write `spec.md` (architecture, constraints, patterns, out-of-scope, known
   overlaps, cross-workstream invariants). Put invariants into the check
   command where possible: the deterministic gates replace your live review.
3. Write `workstreams.txt`: one workstream per line, each line a **pointer**
   into the spec, not the whole brief
   (`implement workstream 3 per specs/<date>-<feature>/spec.md §3; run auth tests`).
   Commit both to the session branch. The session worktree must be CLEAN when
   the engine starts — the run delivers onto this branch.

## Phase 2+3 — Execute & Merge (script, NO Claude)

```
${CLAUDE_PLUGIN_ROOT}/skills/execute/execute.sh \
  --workstreams <path>/workstreams.txt --feature <run-name> \
  --check "<verify cmd>" --spec <path>/spec.md \
  [--setup "<per-worktree deps cmd>"] \
  [--concurrency N] [--retries 2] [--timeout 2400] [--no-push]
```

Results land on the **session branch, in the session worktree** — the branch
checked out when the run starts (`--base` may name it explicitly and must then
match). `--feature` is just the run name; no branch or worktree is created
for it.

Launch it in the background and END YOUR TURN — do not poll, do not ingest
workstream logs. Progress lives in files:
- statuses: `<repo>/.git/codex-execute/<feature>/status/workstream-*.json` + `summary.json`
- logs: `<repo>/.git/codex-execute/<feature>/logs/`

These workstreams are **self-verifying**: the engine runs `--check` per
workstream and again post-merge, gating on raw exit codes. Never spawn the
`workstream-verifier` agent for a `/codex:execute` run — that agent is for
Claude-subagent workstreams. After the run, your job is only confirming the
check command covered the touched surfaces.

Semantics (all verified by tests/test-execute.sh):
- Worktree pool sized to concurrency at `../.codex-execute-<feature>/w*`,
  branched from the session branch's run-start commit; created on demand,
  fully removed after merge. Workstream branches `workstreams/<feature>/<n>`.
- Red = check failed OR codex timeout OR codex nonzero exit OR no diff.
  Bounded retry re-invokes codex in the same worktree with the failure tail
  appended.
- Failed workstreams: excluded from merge; branch kept only if it has commits.
- Merge: green workstream branches merge DIRECTLY onto the session branch in
  the session worktree (the tree must still be clean and on the same branch);
  conflicts resolved by codex in place; pre-merge HEAD is recorded as
  `refs/codex-execute/<feature>/pre-merge`.
- Post-merge `check` runs on the session branch. RED restores the branch with
  `git reset --keep` to the pre-merge commit and keeps every green workstream
  branch for autopsy — the session worktree ends exactly where it started.
- Exit 0 = all green + delivered; 2 = partial (some workstreams failed,
  session branch green + delivered); 1 = post-merge check red (branch
  restored), merge blocked (dirty/switched worktree), or push failed.

`--setup` example (codex's sandbox has no network, so provision deps when
creating each worktree): `cp -R ../main-checkout/node_modules node_modules`
(on APFS use `cp -Rc` for a copy-on-write clone).

## Phase 4 — Review & deliver (codex, automatic)

The engine reviews locally — `codex exec review --base <pre-merge>` covers
exactly the merged workstream delta, findings written to
`.git/codex-execute/<feature>/logs/review.md` — then pushes the session
branch. If the branch has an open PR it updates and gets an `@codex review`
comment (the GitHub app reviews the whole PR when installed); otherwise a PR
is opened FROM the session branch to the repo's default branch. There is no
Claude review step (by design) and nothing for you to run.

(codex-cli gotcha: `review --base` cannot take custom instructions — review
focus belongs in spec.md, which the reviewer reads from the tree.)

When the run finishes, relay `summary.json`, the review.md findings, and the
PR URL to the user. FAILED workstreams are listed in the PR body — offer to
re-plan just those as a new small run (new run name) rather than re-entering
the loop yourself.

## Cleanup

None on success — workstream worktrees and branches are already gone and the
work is on the session branch. After a red post-merge check, the kept
`workstreams/<feature>/<n>` branches and `refs/codex-execute/<feature>/pre-merge`
can be deleted once the autopsy is done; `.git/codex-execute/<feature>/` can
be deleted whenever.
