# codex-plugin-cc

A community extension of the [official codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc)
that delivers a planned feature as **parallel codex tasks, off Claude's
critical path** — from a plan to a pushed branch and PR, with codex reviewing
the result. It ships under the same `codex` plugin name, so the skill joins
the official plugin's `/codex:` namespace as `/codex:execute`.

**The DX:** research and plan a feature with Claude Code, then hand the plan
to `/codex:execute`. Claude converts the plan into `spec.md` +
`tasks.txt` and launches the engine in the background. Codex executes the
tasks in parallel worktrees, each gated by your test command with bounded
retries; green tasks merge into one feature branch (codex resolves conflicts);
a post-merge check gates the push; codex reviews the integrated diff; the
branch is pushed and a PR opened (or an existing PR updated). Claude never
polls, never ingests worker transcripts, and never re-enters the loop.

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
  --tasks specs/my-feature/tasks.txt --base main --feature my-feature \
  --check "yarn test" --spec specs/my-feature/spec.md
```

| Parameter | Meaning | Default |
|---|---|---|
| `--tasks` | work list, one task per line (pointers into the spec) | required |
| `--base` | branch to branch tasks from and integrate onto | required |
| `--feature` | integration branch name (must not exist yet) | required |
| `--check` | per-task verify command, run from the worktree root | required |
| `--spec` | repo-relative path to the shared spec | – |
| `--concurrency` | worktree pool size | CPU count |
| `--retries` | per-task retry budget on red | 2 |
| `--timeout` | per-codex-invocation seconds (past it = red) | 2400 |
| `--setup` | run once per created worktree (deps provisioning) | – |
| `--onto-base` | push `feature:base` so an existing PR for base updates | off |
| `--no-push` | stop after merge + review | off |

Red = check failed, codex timeout, codex error, or no diff produced. Failed
tasks are excluded from the merge and reported in the summary and PR body;
their branches are kept when they contain commits. Exit codes: `0` all green,
`2` partial (some tasks failed; feature green and pushed), `1` post-merge
check red or push failed.

Run state lives under `.git/codex-execute/<feature>/` (per-task status JSON,
logs, `review.md` findings, `summary.json`); worktrees under
`../.codex-execute-<feature>/` exist only for the duration of the run.

## Test

```
skills/execute/tests/test-execute.sh
```

The suite runs the engine against a fixture repo with a stubbed codex CLI
(28 assertions: pass, retry-with-failure-context, hang/timeout, no-diff,
merge-conflict resolution, pool bounds, cleanup, push, both delivery modes).
The engine is additionally verified against the real codex CLI.

## License

MIT
