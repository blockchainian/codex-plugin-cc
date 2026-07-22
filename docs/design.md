# Parallel Codex Execution Workflow — Design

Status: revised per review decisions (2026-07-22).

## Problem

We do "many-at-once" backend work: a batch of independent tasks that can run in
parallel. The prior setup used Claude Code as a live orchestrator driving Codex,
and it was slow. Root cause, confirmed by profiling: **Claude was on the
execution critical path**. Two ways this happened:

1. **Model-driven orchestration.** The Claude main loop decided each next step
   conversationally, so every hop was a full main-loop turn.
2. **Claude Code Workflow wrapping Codex.** When we tried the Workflow harness,
   each `agent()` task was a Claude subagent that *shelled out to Codex*. Every
   task then paid Claude's latency **plus** Codex's latency, stacked, N times.
   In the recorded attempt (2026-07-18) the wrapper was also lifecycle-fatal:
   all four tasks died within two minutes when their ephemeral agent worktrees
   were cleaned up under the still-running codex jobs.

Both are the same mistake: keeping Claude resident across the execution window.
Measured on the 2026-07-20→22 sessions: codex tasks run 7–27 minutes each (not
seconds), and the real tax is the orchestrator staying on-path around them — in
the one batch run, dispatch was serialized over 30 minutes of brief-writing,
every task wakeup cost a full max-effort main-loop turn (79 requests and 33
minutes of model wall during an 80-minute task phase), and the session
/compact'd twice mid-run. Codex's parallelism never reaches the wall clock, and
progress is invisible to the human, who ends up polling the orchestrator ("are
you done?").

### Latency facts that drive the design
- Main-loop turns pay an **effort-floor** cost as pre-first-token latency:
  median time-to-first-token measured 2026-07-20→22 was ~4s at high effort, ~7s
  at xhigh, and 13–27s at max.
- Big orchestrator context taxes twice: decode slows toward ~40% by >450k
  tokens (week-scale data; flat up to ~400k in this window), and growth forces
  mid-run /compacts (177s + 110s observed in one orchestration morning). The
  context grows every time the orchestrator reads a worker's output back in.
- Model wall time is bought in ~9s quanta per request.

## Core principle

**Take Claude off the execution path. git + the filesystem are the coordination
bus, not Claude's context.** Claude plans once, up front, and never re-enters
the loop: execution, merge, push, and review are Codex + git + script. Claude
never ingests worker transcripts, so its context stays tiny and under the 300k
wall no matter how many tasks run.

## Pipeline

```
1. Plan          — Claude (one turn): write spec.md + tasks.txt
2. Execute       — Codex ×N in parallel worktrees: task → check → task branch (bounded retries)
3. Merge & Push  — task branches → feature worktree/branch; conflicts resolved here; push
4. Review        — Codex reviews the feature branch as one PR; merge to base on green
```

### 1. Plan (Claude, one turn)

Decided: Claude plans. Decomposition is the one step that trades on reasoning
depth rather than speed, and task independence — which the whole pipeline
assumes — is produced here, not checked at runtime.

- Decompose the goal into N **independent, self-contained** tasks.
- **Conflict avoidance is the planner's responsibility.** Partition along file
  boundaries so no two tasks edit the same file. When overlap is genuinely
  unavoidable, record it in `spec.md` (which tasks, which files) so the merge
  phase expects those conflicts. There is no runtime pre-flight check.
- Write a shared `spec.md` (architecture, constraints, patterns, out-of-scope,
  known overlaps).
- Write `tasks.txt`: **one task per line, each line a pointer, not the whole
  brief.** Example line:
  `implement task 3 per spec.md §3; run auth tests, must be green`
- Codex reads `spec.md` itself; we do not duplicate the spec across N lines.

### 2. Execute (Codex ×N, parallel, no Claude) — `execute.sh`

The engine's first half. Responsibilities:
- Read `tasks.txt`.
- Maintain a **worktree pool** sized to concurrency (see Parameters) so parallel
  tasks never write the same tree. (Shared-tree parallel writers = data race;
  rejected.) Pool size = concurrency, **not** task count — a task grabs a free
  worktree, does its task, commits to a per-task branch, releases the worktree
  for the next queued task. Worktrees are created on demand during execution
  and live only until the merge phase completes; nothing persists across runs.
- Run tasks concurrently (`xargs -P` or equivalent).
- Per task: `codex exec "<line>"` → run the per-task **check** → if green,
  commit its branch. If red, **bounded retry**: re-invoke Codex in the same
  worktree with the failing check output appended to the prompt, up to
  `retries` times. A task that hangs past a per-task timeout or finishes with
  no diff counts as red — both happened in the 2026-07-22 run (one resume hung,
  one died at 0s on sandbox scope). On exhaustion, mark the task FAILED (no
  commit), exclude it
  from the merge, and report it in the run summary and the PR body.

### 3. Merge & Push (script + Codex, no Claude)

The engine's second half.
- Create the **feature worktree/branch** from `base`.
- Merge green task branches into the feature branch one at a time. Clean merges
  are the expected case — the planner made tasks file-disjoint.
- On conflict (expected only where `spec.md` flagged an overlap): resolve at
  merge — `codex exec` in the feature worktree with the conflict and `spec.md`
  as context.
- After the last merge, run `check` once on the feature branch: conflict
  resolutions are code that no task gate covered.
- Delete task worktrees and task branches, push the feature branch, open **one
  PR** against `base`.

### 4. Review (Codex, one PR)

- Codex reviews the feature-branch PR on GitHub; merge to `base` on green.
- **No Claude review step.** Correctness rests on three deterministic-ish
  gates: each task's own check, the post-merge check on the integrated branch,
  and Codex's GitHub review — not a single model's judgment used as a gate.

## Parameters (this must be generic and reusable across sessions)

Nothing project-specific is baked in. Per invocation:
- `tasks`       — the work list / spec pointers
- `base`        — branch to integrate into
- `feature`     — integration branch name (must not already exist)
- `check`       — per-task verify command (`yarn test`, `cargo test`, …)
- `concurrency` — default = CPU count, overridable
- `retries`     — per-task retry budget on a red check (default 2)
- `timeout`     — per-codex-invocation seconds; a task past it counts as red
  (default 2400 — the longest measured task was 27m)
- `setup`       — optional command run once per created worktree (deps
  provisioning; the codex sandbox has no network for `yarn install`)

## Packaging (implemented 2026-07-22)
- **Generic script** = the repo-agnostic engine
  `skills/execute/execute.sh (this repo)`: Execute plus Merge & Push —
  parallel Codex + worktree pool + per-task check + task merge — driven
  entirely by the params above. Verified by
  `skills/execute/tests/test-execute.sh` (stubbed codex; covers
  pass/retry/hang/no-diff/conflict/cleanup/push) plus a live `codex exec`
  smoke run.
- **Skill** = `skills/execute/SKILL.md`: the Claude bookend —
  write spec+tasks, launch the script in the background, request the review.
- **Review mechanism** (decided 2026-07-22): the engine runs local
  `codex exec review --base <base>` on the integrated diff itself (fast,
  CLI-native; findings land in the run logs), then comments `@codex review` on
  the PR as a bonus for the codex GitHub app. codex-cli rejects combining
  `--base` with custom review instructions — review focus lives in spec.md.
- **Artifact locations**: Claude (not codex) authors `spec.md` + `tasks.txt`,
  stored at `specs/<date>-<feature>/` on the base branch; codex reads them
  from each task worktree. Engine takes `--spec` to reference them in prompts.
- **Existing-PR delivery** (`--onto-base`): when the base branch already has
  an open PR (several features accumulating on one branch), the engine pushes
  `feature:base` (fast-forward; rejects if base moved mid-run) so the existing
  PR updates instead of opening a new one, then deletes the feature
  worktree/branch.

## Rejected alternatives (do not re-propose without new reasoning)
- **Claude Code Workflow with Codex-in-each-agent** — double-wraps every task
  (Claude latency + Codex latency ×N). This was the original slow design.
- **Claude adversarial review as the final gate** — removed. Reliability of a
  single-model correctness review is unknown/weak; a shallow review is *worse*
  than none because it launders bad code as "reviewed." Correctness pushed to
  deterministic tests + Codex GitHub review instead.
- **Shared worktree across tasks** — data race on file writes.
- **One worktree per task** — unnecessary; pool sized to concurrency suffices.
- **One PR per task** — review fragments into N small diffs and the integrated
  result is never reviewed or tested as a whole; `base` takes N separate merge
  events. One feature PR reviews the integrated diff; failed tasks stay
  isolated anyway because they are excluded at merge.
- **Persistent worktree pool across runs** — standing cleanup discipline bought
  for a spin-up cost that is already small; worktrees live only from first use
  to end of merge.
- **Codex as planner (zero-Claude pipeline)** — decomposition and conflict
  avoidance are the reasoning-depth step; this is the one Claude turn the
  pipeline keeps, deliberately.
