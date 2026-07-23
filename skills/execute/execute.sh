#!/usr/bin/env bash
# ABOUTME: Parallel codex task engine: runs tasks.txt through codex exec in a worktree pool with
# ABOUTME: per-task checks and bounded retries, then merges task branches into one feature branch and pushes.
set -u

usage() {
  cat <<'EOF'
Usage: execute.sh --tasks FILE --base BRANCH --feature NAME --check CMD
                    [--concurrency N] [--retries N] [--timeout SECS]
                    [--setup CMD] [--spec PATH] [--repo DIR]
                    [--onto-base] [--no-push]

  tasks       one task per line (blank lines and # comments skipped)
  base        branch to branch tasks from and merge the feature branch onto
  feature     integration branch name (must not already exist)
  check       per-task verify command, run from the worktree root
  concurrency worktree pool size            (default: CPU count)
  retries     per-task retry budget on red   (default: 2)
  timeout     per-codex-invocation seconds   (default: 2400)
  setup       run once per created worktree  (e.g. deps provisioning)
  spec        repo-relative path to the shared spec (referenced in task and
              merge prompts; e.g. specs/2026-07-22-foo/spec.md)
  repo        repository to operate on       (default: git toplevel of cwd)
  onto-base   deliver onto BASE itself: push feature:BASE (fast-forward) so an
              already-open PR for BASE updates; no new branch/PR is created
  no-push     skip pushing / opening a PR

Env: EXECUTE_CODEX overrides the codex binary (default: codex).
EOF
  exit 1
}

fatal() { echo "codex:execute: FATAL: $*" >&2; exit 1; }
note()  { echo "codex:execute: $*"; }

# ---------- args ----------
TASKS="" BASE="" FEATURE="" CHECK="" SETUP="" SPEC="" REPO="" PUSH=1 ONTO_BASE=0
CONCURRENCY="" RETRIES=2 TIMEOUT_S=2400
while [ $# -gt 0 ]; do
  case "$1" in
    --tasks) TASKS="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --onto-base) ONTO_BASE=1; shift ;;
    --base) BASE="$2"; shift 2 ;;
    --feature) FEATURE="$2"; shift 2 ;;
    --check) CHECK="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --timeout) TIMEOUT_S="$2"; shift 2 ;;
    --setup) SETUP="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    __task) TASK_MODE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

CODEX="${EXECUTE_CODEX:-codex}"

# ---------- worker mode ----------
if [ "${TASK_MODE:-}" != "" ]; then
  # env supplied by the parent
  idx="$TASK_MODE"
  REPO="$EXECUTE_REPO"; BASE="$EXECUTE_BASE"; FEATURE="$EXECUTE_FEATURE"; CHECK="$EXECUTE_CHECK"
  SETUP="$EXECUTE_SETUP"; SPEC="$EXECUTE_SPEC"; RETRIES="$EXECUTE_RETRIES"; TIMEOUT_S="$EXECUTE_TIMEOUT"
  RUN_DIR="$EXECUTE_RUN_DIR"; WT_ROOT="$EXECUTE_WT_ROOT"; CONCURRENCY="$EXECUTE_CONCURRENCY"
  LOGD="$RUN_DIR/logs"
  LINE="$(sed -n "${idx}p" "$RUN_DIR/tasks.txt")"
  BR="tasks/$FEATURE/$idx"

  status() { # status <result> <attempts> <reason>
    printf '{"task": %s, "result": "%s", "attempts": %s, "branch": "%s", "reason": "%s", "line": "%s"}\n' \
      "$idx" "$1" "$2" "$BR" "$3" "$(echo "$LINE" | cut -c1-120 | sed 's/"/\\"/g')" \
      > "$RUN_DIR/status/task-$idx.json"
  }

  # acquire a pool slot
  SLOT=""
  while [ -z "$SLOT" ]; do
    s=1
    while [ "$s" -le "$CONCURRENCY" ]; do
      if mkdir "$RUN_DIR/locks/slot-$s" 2>/dev/null; then SLOT="$s"; break; fi
      s=$((s+1))
    done
    [ -z "$SLOT" ] && sleep 0.3
  done
  WT="$WT_ROOT/w$SLOT"

  if [ ! -d "$WT" ]; then
    if ! git -C "$REPO" worktree add --detach "$WT" "$BASE" > "$LOGD/w$SLOT.create.log" 2>&1; then
      sleep 1  # worktree metadata contention with a sibling worker; retry once
      git -C "$REPO" worktree add --detach "$WT" "$BASE" >> "$LOGD/w$SLOT.create.log" 2>&1 \
        || { status fail 0 "worktree-create-failed"; rmdir "$RUN_DIR/locks/slot-$SLOT"; exit 0; }
    fi
    if [ -n "$SETUP" ]; then
      if ! (cd "$WT" && eval "$SETUP") > "$LOGD/w$SLOT.setup.log" 2>&1; then
        status fail 0 "setup-failed"
        rmdir "$RUN_DIR/locks/slot-$SLOT"
        exit 0
      fi
    fi
  fi

  git -C "$WT" checkout -q -B "$BR" "$BASE"
  git -C "$WT" reset -q --hard "$BASE"
  git -C "$WT" clean -qfd

  SPECHINT=""
  [ -n "$SPEC" ] && SPECHINT=" The shared spec is at $SPEC (repo-relative); read it first."
  PREAMBLE="You are task $idx of a parallel batch run. Work ONLY inside this directory. Do not push, do not switch branches, do not touch other tasks' scopes. The harness runs the check command ($CHECK) and commits for you.$SPECHINT

Task: $LINE"

  result="fail"; reason=""; failctx=""; a=0
  while [ "$a" -lt $((RETRIES+1)) ]; do
    a=$((a+1))
    attempt_prefix=""
    attempt_suffix=""
    if [ "$a" -gt 1 ]; then
      attempt_prefix="attempt $a "
      attempt_suffix=" (attempt $a)"
    fi
    PROMPT="$PREAMBLE"
    if [ "$a" -gt 1 ]; then
      PROMPT="$PREAMBLE

PREVIOUS ATTEMPT FAILED (attempt $((a-1)) of $((RETRIES+1))): $reason
$failctx
Fix it."
    fi
    note "[task $idx] ${attempt_prefix}starting (slot w$SLOT)"
    timeout "$TIMEOUT_S" "$CODEX" exec -C "$WT" -s workspace-write --ephemeral \
      -o "$LOGD/task-$idx-a$a.last" "$PROMPT" > "$LOGD/task-$idx-a$a.codex.log" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      reason="timeout"; failctx="codex hit the ${TIMEOUT_S}s per-invocation timeout"
      note "[task $idx] ${attempt_prefix}red: timeout"; continue
    elif [ "$rc" -ne 0 ]; then
      reason="codex-exit-$rc"; failctx="$(tail -c 3000 "$LOGD/task-$idx-a$a.codex.log")"
      note "[task $idx] ${attempt_prefix}red: codex exited $rc"; continue
    fi
    commits="$(git -C "$WT" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)"
    if [ "$commits" = "0" ] && [ -z "$(git -C "$WT" status --porcelain)" ]; then
      reason="no-diff"; failctx="codex completed but produced no changes"
      note "[task $idx] ${attempt_prefix}red: no diff"; continue
    fi
    (cd "$WT" && eval "$CHECK") > "$LOGD/task-$idx-a$a.check.log" 2>&1
    crc=$?
    if [ "$crc" -eq 0 ]; then
      if [ -n "$(git -C "$WT" status --porcelain)" ]; then
        git -C "$WT" add -A
        git -C "$WT" commit -q -m "task $idx: $(echo "$LINE" | cut -c1-60)"
      fi
      result="pass"; reason="check-green"
      note "[task $idx] PASS${attempt_suffix}"
      break
    fi
    reason="check-failed"; failctx="$(tail -c 3000 "$LOGD/task-$idx-a$a.check.log")"
    note "[task $idx] ${attempt_prefix}red: check failed (exit $crc)"
  done

  if [ "$result" != "pass" ]; then
    # preserve whatever exists on the task branch for inspection
    if [ -n "$(git -C "$WT" status --porcelain)" ]; then
      git -C "$WT" add -A
      git -C "$WT" commit -q -m "FAILED task $idx (kept for inspection): $reason"
    fi
    note "[task $idx] FAILED after $a attempt(s): $reason"
  fi
  status "$result" "$a" "$reason"

  # release the slot with a clean tree
  git -C "$WT" checkout -q --detach
  git -C "$WT" reset -q --hard "$BASE"
  git -C "$WT" clean -qfd
  rmdir "$RUN_DIR/locks/slot-$SLOT"
  exit 0
fi

# ---------- orchestrating mode ----------
[ -n "$TASKS" ] && [ -n "$BASE" ] && [ -n "$FEATURE" ] && [ -n "$CHECK" ] || usage
command -v timeout >/dev/null || fatal "timeout(1) not found (brew install coreutils)"
command -v "$CODEX" >/dev/null || fatal "codex binary '$CODEX' not found"
[ -f "$TASKS" ] || fatal "tasks file not found: $TASKS"

if [ -z "$REPO" ]; then REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || fatal "not in a git repo and no --repo"; fi
REPO="$(cd "$REPO" && pwd)"
git -C "$REPO" rev-parse --verify -q "$BASE" >/dev/null || fatal "base branch '$BASE' not found"
git -C "$REPO" rev-parse --verify -q "refs/heads/$FEATURE" >/dev/null \
  && fatal "feature branch '$FEATURE' already exists; pick a new name or delete it"

if [ -z "$CONCURRENCY" ]; then
  CONCURRENCY="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null | head -1 )"
  [ -n "$CONCURRENCY" ] || CONCURRENCY=4
fi

GITDIR="$(git -C "$REPO" rev-parse --absolute-git-dir)"
RUN_DIR="$GITDIR/codex-execute/$FEATURE"
WT_ROOT="$(dirname "$REPO")/.codex-execute-$FEATURE"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/status" "$RUN_DIR/locks" "$WT_ROOT"

grep -v '^[[:space:]]*$' "$TASKS" | grep -v '^[[:space:]]*#' > "$RUN_DIR/tasks.txt"
N="$(wc -l < "$RUN_DIR/tasks.txt" | tr -d ' ')"
[ "$N" -gt 0 ] || fatal "no tasks in $TASKS"
[ "$CONCURRENCY" -gt "$N" ] && CONCURRENCY="$N"

note "feature=$FEATURE base=$BASE tasks=$N pool=$CONCURRENCY retries=$RETRIES timeout=${TIMEOUT_S}s"
note "logs: $RUN_DIR/logs  status: $RUN_DIR/status"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
export EXECUTE_REPO="$REPO" EXECUTE_BASE="$BASE" EXECUTE_FEATURE="$FEATURE" EXECUTE_CHECK="$CHECK"
export EXECUTE_SETUP="$SETUP" EXECUTE_SPEC="$SPEC" EXECUTE_RETRIES="$RETRIES" EXECUTE_TIMEOUT="$TIMEOUT_S"
export EXECUTE_RUN_DIR="$RUN_DIR" EXECUTE_WT_ROOT="$WT_ROOT" EXECUTE_CONCURRENCY="$CONCURRENCY"
export EXECUTE_CODEX="$CODEX"

# ---------- phase: execute ----------
seq 1 "$N" | xargs -n1 -P "$CONCURRENCY" "$SELF" __task

PASSED=""; FAILED=""
i=1
while [ "$i" -le "$N" ]; do
  if grep -q '"result": "pass"' "$RUN_DIR/status/task-$i.json" 2>/dev/null; then
    PASSED="$PASSED $i"
  else
    FAILED="$FAILED $i"
  fi
  i=$((i+1))
done
note "execute done: passed:[${PASSED# }] failed:[${FAILED# }]"

# ---------- phase: merge ----------
FT="$WT_ROOT/feature"
git -C "$REPO" worktree add -q "$FT" -b "$FEATURE" "$BASE" || fatal "cannot create feature worktree"

MERGED=""; MERGE_FAILED=""
for idx in $PASSED; do
  BR="tasks/$FEATURE/$idx"
  if git -C "$FT" merge -q --no-ff -m "merge task $idx" "$BR" > "$RUN_DIR/logs/merge-$idx.log" 2>&1; then
    MERGED="$MERGED $idx"
    note "[merge] task $idx merged clean"
    continue
  fi
  CONFLICTED="$(git -C "$FT" diff --name-only --diff-filter=U | tr '\n' ' ')"
  note "[merge] task $idx CONFLICT: $CONFLICTED-> resolving with codex"
  MPROMPT="You are resolving a git merge conflict in this repository. Branch 'tasks/$FEATURE/$idx' is being merged into '$FEATURE'. Conflicted files: $CONFLICTED
Read ${SPEC:-spec.md at the repo root, if present,} for intent. Resolve every conflict so BOTH sides' intent is preserved, then 'git add' each resolved file. Do not commit, do not push."
  timeout "$TIMEOUT_S" "$CODEX" exec -C "$FT" -s workspace-write --ephemeral \
    -o "$RUN_DIR/logs/merge-$idx.last" "$MPROMPT" >> "$RUN_DIR/logs/merge-$idx.log" 2>&1
  if [ -z "$(git -C "$FT" diff --name-only --diff-filter=U)" ] \
     && git -C "$FT" commit -q --no-edit >> "$RUN_DIR/logs/merge-$idx.log" 2>&1; then
    MERGED="$MERGED $idx"
    note "[merge] task $idx merged (conflict resolved)"
  else
    git -C "$FT" merge --abort >> "$RUN_DIR/logs/merge-$idx.log" 2>&1
    MERGE_FAILED="$MERGE_FAILED $idx"
    note "[merge] task $idx merge FAILED; excluded (branch kept)"
  fi
done

# post-merge check (conflict resolutions are code no task gate covered)
POST="skip"
if [ -n "$MERGED" ]; then
  if (cd "$FT" && eval "$CHECK") > "$RUN_DIR/logs/post-merge-check.log" 2>&1; then
    POST="pass"; note "[merge] post-merge check green"
  else
    POST="fail"; note "[merge] post-merge check RED (log: $RUN_DIR/logs/post-merge-check.log)"
  fi
fi

# ---------- cleanup: task worktrees + merged/empty task branches ----------
s=1
while [ "$s" -le "$CONCURRENCY" ]; do
  [ -d "$WT_ROOT/w$s" ] && git -C "$REPO" worktree remove --force "$WT_ROOT/w$s" >/dev/null 2>&1
  s=$((s+1))
done
i=1
while [ "$i" -le "$N" ]; do
  BR="tasks/$FEATURE/$i"
  if git -C "$REPO" rev-parse --verify -q "refs/heads/$BR" >/dev/null; then
    keep=0
    case " $MERGE_FAILED " in *" $i "*) keep=1 ;; esac  # merge-failed: keep for inspection
    case " $FAILED " in *" $i "*)
      [ "$(git -C "$REPO" rev-list --count "$BASE".."$BR")" != "0" ] && keep=1 ;;
    esac
    [ "$keep" = "0" ] && git -C "$REPO" branch -q -D "$BR"
  fi
  i=$((i+1))
done

# ---------- review (local codex review of the integrated diff) ----------
REVIEW="skip"
if [ "$POST" = "pass" ]; then
  note "[review] running codex review of $FEATURE vs $BASE"
  if timeout "$TIMEOUT_S" "$CODEX" exec -C "$FT" -o "$RUN_DIR/logs/review.md" \
       review --base "$BASE" > "$RUN_DIR/logs/review.log" 2>&1; then
    REVIEW="done"; note "[review] findings: $RUN_DIR/logs/review.md"
  else
    REVIEW="failed"; note "[review] codex review failed (see $RUN_DIR/logs/review.log)"
  fi
fi

# ---------- deliver ----------
PUSHED=false; DELIVERED="none"
if [ "$POST" = "pass" ] && [ "$PUSH" = "1" ]; then
  if [ "$ONTO_BASE" = "1" ]; then
    if git -C "$FT" push -q origin "$FEATURE:$BASE" > "$RUN_DIR/logs/push.log" 2>&1; then
      PUSHED=true; DELIVERED="$BASE"
      note "pushed tasks onto origin/$BASE (existing PR for $BASE updates)"
      if gh pr comment "$BASE" --body "@codex review" > "$RUN_DIR/logs/pr.log" 2>&1; then
        note "bonus: codex GitHub app review requested on $BASE's PR"
      else
        note "no @codex comment posted (no open PR for $BASE, or gh failed)"
      fi
      git -C "$REPO" worktree remove --force "$FT" >/dev/null 2>&1
      git -C "$REPO" branch -q -D "$FEATURE"
      rmdir "$WT_ROOT" 2>/dev/null
    else
      note "push onto $BASE failed (base moved during the run?) — see $RUN_DIR/logs/push.log; feature worktree kept"
    fi
  else
    if git -C "$FT" push -q -u origin "$FEATURE" > "$RUN_DIR/logs/push.log" 2>&1; then
      PUSHED=true; DELIVERED="$FEATURE"; note "pushed $FEATURE to origin"
      BODY="codex:execute run: $N tasks, passed:[${PASSED# }] failed:[${FAILED# }] merge-failed:[${MERGE_FAILED# }]. Post-merge check: $POST. Codex review: $REVIEW (findings in run logs).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
      if gh pr create --head "$FEATURE" --base "$BASE" \
           --title "execute: $FEATURE" --body "$BODY" > "$RUN_DIR/logs/pr.log" 2>&1; then
        note "PR opened: $(tail -1 "$RUN_DIR/logs/pr.log")"
        if gh pr comment "$FEATURE" --body "@codex review" >> "$RUN_DIR/logs/pr.log" 2>&1; then
          note "bonus: codex GitHub app review requested (@codex review)"
        else
          note "no @codex comment posted (gh failed); local review already ran"
        fi
      else
        note "gh pr create failed (see $RUN_DIR/logs/pr.log); open the PR manually"
      fi
    else
      note "push failed (see $RUN_DIR/logs/push.log)"
    fi
  fi
fi

# ---------- summary ----------
NP=0; NF=0; NM=0; NMF=0
for x in $PASSED; do NP=$((NP+1)); done
for x in $FAILED; do NF=$((NF+1)); done
for x in $MERGED; do NM=$((NM+1)); done
for x in $MERGE_FAILED; do NMF=$((NMF+1)); done
printf '{"feature": "%s", "base": "%s", "tasks": %s, "passed": %s, "failed": %s, "merged": %s, "merge_failed": %s, "post_merge_check": "%s", "review": "%s", "pushed": %s, "delivered_to": "%s"}\n' \
  "$FEATURE" "$BASE" "$N" "$NP" "$NF" "$NM" "$NMF" "$POST" "$REVIEW" "$PUSHED" "$DELIVERED" \
  > "$RUN_DIR/status/summary.json"
note "summary: $(cat "$RUN_DIR/status/summary.json")"
[ -d "$FT" ] && note "feature worktree: $FT"
[ "$REVIEW" = "done" ] && note "review findings: $RUN_DIR/logs/review.md"

if [ "$POST" = "fail" ]; then exit 1; fi
if [ "$PUSH" = "1" ] && [ "$POST" = "pass" ] && [ "$PUSHED" != "true" ]; then exit 1; fi
if [ -n "$FAILED" ] || [ -n "$MERGE_FAILED" ]; then exit 2; fi
exit 0
