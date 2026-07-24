# codex-plugin-cc

A community extension of the [official codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc)
that delivers a planned feature as **parallel codex workstreams, off Claude's
critical path** — from a plan to results on the branch you're working on, with
codex reviewing the result. It ships under the same `codex` plugin name, so
the skill joins the official plugin's `/codex:` namespace as `/codex:execute`.

**The DX:** research and plan a feature with Claude Code, then hand the plan
to `/codex:execute`. Claude converts the plan into `spec.md` +
`workstreams.txt` and launches the engine in the background. Codex executes
the workstreams in parallel worktrees, each gated by your test command with
bounded retries; green workstream branches merge directly onto **the branch
your session is on, in your worktree** (codex resolves conflicts); a
post-merge check gates delivery — red restores your branch exactly to its
pre-merge state; codex reviews the merged delta; your branch is pushed and its
PR updated (or one opened if none exists). Claude never polls, never ingests
worker transcripts, and never re-enters the loop — and when the run is done,
the work is simply on your branch.

Why: profiling hybrid Claude+codex sessions showed the orchestrator burning
~33 minutes of model wall during an 80-minute execution phase — dispatch
serialized, every worker wakeup a full main-loop turn, context compactions
mid-run. Taking Claude off the execution path halved wall-clock on the
measured workload. Full rationale and numbers: [docs/design.md](docs/design.md).

## Install

```
/plugin marketplace add blockchainian/codex-plugin-cc
/plugin install codex@blockchainian
```

(This registers the `blockchainian` marketplace — the same marketplace also
served by [grok-plugin-cc](https://github.com/blockchainian/grok-plugin-cc);
both repos define it identically and list both plugins, so adding either repo
works and a later add simply switches which repo sources it.)

This plugin intentionally shares the `codex` plugin name with the official
plugin. Installing both is supported — installed-plugin identity is
`name@marketplace`, so they coexist as `codex@openai-codex` and
`codex@blockchainian` — but the shared `/codex:` command namespace is not
formally documented behavior; if the combination misbehaves in your setup,
please open an issue.

Requirements: [codex CLI](https://github.com/openai/codex) ≥ 0.144 (logged
in), `git`, `timeout` (coreutils; `brew install coreutils` on macOS), and
optionally `gh` (authenticated) for automatic PR creation.

## Use

In Claude Code, plan a feature in conversation, then:

```
/codex:execute
```

The engine also works standalone, no Claude required:

```
skills/execute/execute.sh \
  --workstreams specs/my-feature/workstreams.txt --feature my-feature \
  --check "yarn test" --spec specs/my-feature/spec.md
```

| Parameter | Meaning | Default |
|---|---|---|
| `--workstreams` | work list, one workstream per line (pointers into the spec) | required |
| `--feature` | run name; namespaces workstream branches and run state | required |
| `--check` | per-workstream verify command, run from the worktree root | required |
| `--base` | session branch to deliver onto; must match the checkout | checked-out branch |
| `--spec` | repo-relative path to the shared spec | – |
| `--concurrency` | worktree pool size | CPU count |
| `--retries` | per-workstream retry budget on red | 2 |
| `--timeout` | per-codex-invocation seconds (past it = red) | 2400 |
| `--setup` | run once per created worktree (deps provisioning) | – |
| `--no-push` | stop after merge + review | off |

The session worktree must be clean when the run starts; results are delivered
by merging onto its branch at the end of the run. Red = check failed, codex
timeout, codex error, or no diff produced. Failed workstreams are excluded
from the merge and reported in the summary and PR body; their branches are
kept when they contain commits. Exit codes: `0` all green + delivered, `2`
partial (some workstreams failed; session branch green and delivered), `1`
post-merge check red (session branch restored to its pre-merge commit; green
workstream branches kept), merge blocked (worktree went dirty or switched
branch mid-run), or push failed.

Run state lives under `.git/codex-execute/<feature>/` (per-workstream status
JSON, logs, `review.md` findings, `summary.json`); worktrees under
`../.codex-execute-<feature>/` exist only for the duration of the run.

## Test

```
skills/execute/tests/test-execute.sh
```

The suite runs the engine against a fixture repo with a stubbed codex CLI
(63 assertions: pass, retry-with-failure-context, hang/timeout, no-diff,
merge-conflict resolution, session-branch delivery, restore-on-red, existing-PR
update, pool bounds, cleanup, guard rails). The engine is additionally
verified against the real codex CLI.

## License

MIT
