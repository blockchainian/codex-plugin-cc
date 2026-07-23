#!/usr/bin/env bash
# ABOUTME: Parallel codex task engine: runs tasks.txt through codex exec in a worktree pool with
# ABOUTME: per-task checks and bounded retries, then merges task branches onto the session branch.
set -u

usage() {
  cat <<'EOF'
Usage: execute.sh --tasks FILE --feature NAME --check CMD
                    [--base BRANCH] [--concurrency N] [--retries N] [--timeout SECS]
                    [--setup CMD] [--spec PATH] [--repo DIR] [--no-push]

  tasks       one task per line (blank lines and # comments skipped)
  feature     run name; namespaces task branches (tasks/NAME/n) and run state
  check       verify command, run from a worktree root
  base        session branch to deliver onto (default: the branch the repo has
              checked out; when given, it must match the checked-out branch)
  concurrency worktree pool size            (default: CPU count)
  retries     per-task retry budget on red   (default: 2)
  timeout     per-codex-invocation seconds   (default: 2400)
  setup       run once per created task worktree (e.g. deps provisioning)
  spec        repo-relative path to the shared spec (referenced in task and
              merge prompts; e.g. specs/2026-07-22-foo/spec.md)
  repo        repository to operate on       (default: git toplevel of cwd)
  no-push     skip pushing / opening or updating a PR

Tasks run in an isolated worktree pool branched from the session branch's
run-start commit. Green task branches merge DIRECTLY onto the session branch in
the session worktree; the post-merge check runs there, and a red check restores
the branch to its pre-merge state (task branches kept for autopsy). Local codex
review covers the merged task delta; the @codex PR comment covers the whole PR.

Env: EXECUTE_CODEX overrides the codex binary (default: codex).
EOF
  exit 1
}

fatal() { echo "codex:execute: FATAL: $*" >&2; exit 1; }
note()  { echo "codex:execute: $*"; }

# ---------- args ----------
TASKS="" BASE="" FEATURE="" CHECK="" SETUP="" SPEC="" REPO="" PUSH=1
CONCURRENCY="" RETRIES=2 TIMEOUT_S=2400
while [ $# -gt 0 ]; do
  case "$1" in
    --tasks) TASKS="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
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
  REPO="$EXECUTE_REPO"; BASE_SHA="$EXECUTE_BASE_SHA"; FEATURE="$EXECUTE_FEATURE"; CHECK="$EXECUTE_CHECK"
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
    if ! git -C "$REPO" worktree add --detach "$WT" "$BASE_SHA" > "$LOGD/w$SLOT.create.log" 2>&1; then
      sleep 1  # worktree metadata contention with a sibling worker; retry once
      git -C "$REPO" worktree add --detach "$WT" "$BASE_SHA" >> "$LOGD/w$SLOT.create.log" 2>&1 \
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

  git -C "$WT" checkout -q -B "$BR" "$BASE_SHA"
  git -C "$WT" reset -q --hard "$BASE_SHA"
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
    start_attempt=""
    if [ "$a" -gt 1 ]; then
      attempt_prefix="attempt $a "
      attempt_suffix=" (attempt $a)"
      start_attempt=" (attempt $a)"
    fi
    PROMPT="$PREAMBLE"
    if [ "$a" -gt 1 ]; then
      PROMPT="$PREAMBLE

PREVIOUS ATTEMPT FAILED (attempt $((a-1)) of $((RETRIES+1))): $reason
$failctx
Fix it."
    fi
    note "[task $idx] starting (slot w$SLOT)${start_attempt}"
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
    commits="$(git -C "$WT" rev-list --count "$BASE_SHA"..HEAD 2>/dev/null || echo 0)"
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
    note "[task $idx] ${attempt_prefix}FAIL (exit $crc)"
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
  git -C "$WT" reset -q --hard "$BASE_SHA"
  git -C "$WT" clean -qfd
  rmdir "$RUN_DIR/locks/slot-$SLOT"
  exit 0
fi

# ---------- orchestrating mode ----------
[ -n "$TASKS" ] && [ -n "$FEATURE" ] && [ -n "$CHECK" ] || usage
command -v timeout >/dev/null || fatal "timeout(1) not found (brew install coreutils)"
command -v "$CODEX" >/dev/null || fatal "codex binary '$CODEX' not found"
[ -f "$TASKS" ] || fatal "tasks file not found: $TASKS"

if [ -z "$REPO" ]; then REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || fatal "not in a git repo and no --repo"; fi
REPO="$(cd "$REPO" && pwd)"
CUR="$(git -C "$REPO" symbolic-ref --short -q HEAD)" \
  || fatal "repo is on a detached HEAD; check out the branch to deliver onto"
[ -z "$BASE" ] && BASE="$CUR"
[ "$BASE" = "$CUR" ] || fatal "repo has '$CUR' checked out but --base is '$BASE'; check out '$BASE' or drop --base"
[ -z "$(git -C "$REPO" status --porcelain)" ] \
  || fatal "session worktree is dirty; commit or stash before running"
[ -z "$(git -C "$REPO" branch --list "tasks/$FEATURE/*")" ] \
  || fatal "leftover tasks/$FEATURE/* branches exist; delete them or pick a new run name"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

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
note "delivering onto branch '$BASE' in $REPO"
note "logs: $RUN_DIR/logs  status: $RUN_DIR/status"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
export EXECUTE_REPO="$REPO" EXECUTE_BASE_SHA="$BASE_SHA" EXECUTE_FEATURE="$FEATURE" EXECUTE_CHECK="$CHECK"
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
EXECUTION_SUMMARY="PASS [${PASSED# }]"
[ -n "$FAILED" ] && EXECUTION_SUMMARY="$EXECUTION_SUMMARY FAIL [${FAILED# }]"
note "$EXECUTION_SUMMARY"

# ---------- phase: merge (directly onto the session branch) ----------
MERGED=""; MERGE_FAILED=""; POST="skip"; RESTORED=false; MERGE_BLOCKED=""
PRE_MERGE=""
if [ -n "$PASSED" ]; then
  if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    MERGE_BLOCKED="session worktree became dirty during the run"
  elif [ "$(git -C "$REPO" symbolic-ref --short -q HEAD)" != "$BASE" ]; then
    MERGE_BLOCKED="session worktree switched off '$BASE' during the run"
  fi
fi

if [ -n "$MERGE_BLOCKED" ]; then
  note "[merge] BLOCKED: $MERGE_BLOCKED; task branches kept"
elif [ -n "$PASSED" ]; then
  PRE_MERGE="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" update-ref "refs/codex-execute/$FEATURE/pre-merge" "$PRE_MERGE"
  echo "$PRE_MERGE" > "$RUN_DIR/pre-merge.sha"

  for idx in $PASSED; do
    BR="tasks/$FEATURE/$idx"
    if git -C "$REPO" merge -q --no-ff -m "merge task $idx" "$BR" > "$RUN_DIR/logs/merge-$idx.log" 2>&1; then
      MERGED="$MERGED $idx"
      note "[merge] task $idx MERGED"
      continue
    fi
    CONFLICTED="$(git -C "$REPO" diff --name-only --diff-filter=U | tr '\n' ' ')"
    note "[merge] task $idx CONFLICT: $CONFLICTED-> resolving with codex"
    MPROMPT="You are resolving a git merge conflict in this repository. Branch 'tasks/$FEATURE/$idx' is being merged into '$BASE'. Conflicted files: $CONFLICTED
Read ${SPEC:-spec.md at the repo root, if present,} for intent. Resolve every conflict so BOTH sides' intent is preserved, then 'git add' each resolved file. Do not commit, do not push."
    timeout "$TIMEOUT_S" "$CODEX" exec -C "$REPO" -s workspace-write --ephemeral \
      -o "$RUN_DIR/logs/merge-$idx.last" "$MPROMPT" >> "$RUN_DIR/logs/merge-$idx.log" 2>&1
    if [ -z "$(git -C "$REPO" diff --name-only --diff-filter=U)" ] \
       && git -C "$REPO" commit -q --no-edit >> "$RUN_DIR/logs/merge-$idx.log" 2>&1; then
      MERGED="$MERGED $idx"
      note "[merge] task $idx MERGED (conflict resolved)"
    else
      git -C "$REPO" merge --abort >> "$RUN_DIR/logs/merge-$idx.log" 2>&1
      MERGE_FAILED="$MERGE_FAILED $idx"
      note "[merge] task $idx merge FAILED; excluded (branch kept)"
    fi
  done

  # post-merge check (conflict resolutions are code no task gate covered)
  if [ -n "$MERGED" ]; then
    if (cd "$REPO" && eval "$CHECK") > "$RUN_DIR/logs/post-merge-check.log" 2>&1; then
      POST="pass"; note "[merge] PASS"
    else
      POST="fail"
      git -C "$REPO" reset -q --keep "$PRE_MERGE" && RESTORED=true
      note "[merge] post-merge check RED — session branch restored; task branches kept (log: $RUN_DIR/logs/post-merge-check.log)"
    fi
  fi
fi

# ---------- cleanup: task worktrees + merged/empty task branches ----------
s=1
while [ "$s" -le "$CONCURRENCY" ]; do
  [ -d "$WT_ROOT/w$s" ] && git -C "$REPO" worktree remove --force "$WT_ROOT/w$s" >/dev/null 2>&1
  s=$((s+1))
done
rmdir "$WT_ROOT" 2>/dev/null
i=1
while [ "$i" -le "$N" ]; do
  BR="tasks/$FEATURE/$i"
  if git -C "$REPO" rev-parse --verify -q "refs/heads/$BR" >/dev/null; then
    keep=0
    case " $MERGE_FAILED " in *" $i "*) keep=1 ;; esac  # merge-failed: keep for inspection
    case " $FAILED " in *" $i "*)
      [ "$(git -C "$REPO" rev-list --count "$BASE_SHA".."$BR")" != "0" ] && keep=1 ;;
    esac
    if [ "$POST" != "pass" ]; then
      # nothing (or a red result) landed on the session branch — the task
      # branches are the only copy of the work
      case " $PASSED " in *" $i "*) keep=1 ;; esac
    fi
    [ "$keep" = "0" ] && git -C "$REPO" branch -q -D "$BR"
  fi
  i=$((i+1))
done

# ---------- review (local codex review of the merged task delta) ----------
REVIEW="skip"
if [ "$POST" = "pass" ]; then
  note "[review] merged tasks vs pre-merge"
  if timeout "$TIMEOUT_S" "$CODEX" exec -C "$REPO" -o "$RUN_DIR/logs/review.md" \
       review --base "$PRE_MERGE" > "$RUN_DIR/logs/review.log" 2>&1; then
    REVIEW="done"; note "[review] result: $RUN_DIR/logs/review.md"
  else
    REVIEW="failed"; note "[review] codex review failed (see $RUN_DIR/logs/review.log)"
  fi
fi

# ---------- deliver: push the session branch; the PR is FROM it ----------
PUSHED=false; DELIVERED="none"
if [ "$POST" = "pass" ] && [ "$PUSH" = "1" ]; then
  if git -C "$REPO" push -q -u origin "$BASE" > "$RUN_DIR/logs/push.log" 2>&1; then
    PUSHED=true; DELIVERED="$BASE"; note "pushed to origin"
    if gh pr view "$BASE" > "$RUN_DIR/logs/pr.log" 2>&1; then
      if gh pr comment "$BASE" --body "@codex review" >> "$RUN_DIR/logs/pr.log" 2>&1; then
        note "existing PR updates; GitHub review requested"
      else
        note "existing PR updates; @codex comment failed (see $RUN_DIR/logs/pr.log)"
      fi
    else
      BODY="codex:execute run '$FEATURE': $N tasks, passed:[${PASSED# }] failed:[${FAILED# }] merge-failed:[${MERGE_FAILED# }]. Post-merge check: $POST. Codex review: $REVIEW (findings in run logs)."
      if gh pr create --head "$BASE" --title "execute: $FEATURE" --body "$BODY" >> "$RUN_DIR/logs/pr.log" 2>&1; then
        note "PR is $(tail -1 "$RUN_DIR/logs/pr.log")"
        if gh pr comment "$BASE" --body "@codex review" >> "$RUN_DIR/logs/pr.log" 2>&1; then
          note "GitHub review requested"
        else
          note "no @codex comment posted (gh failed); local review already ran"
        fi
      else
        note "no PR created (gh failed, or '$BASE' is the default branch); see $RUN_DIR/logs/pr.log"
      fi
    fi
  else
    note "push failed (see $RUN_DIR/logs/push.log)"
  fi
fi

# ---------- summary ----------
NP=0; NF=0; NM=0; NMF=0
for x in $PASSED; do NP=$((NP+1)); done
for x in $FAILED; do NF=$((NF+1)); done
for x in $MERGED; do NM=$((NM+1)); done
for x in $MERGE_FAILED; do NMF=$((NMF+1)); done
printf '{"feature": "%s", "base": "%s", "tasks": %s, "passed": %s, "failed": %s, "merged": %s, "merge_failed": %s, "post_merge_check": "%s", "review": "%s", "pushed": %s, "delivered_to": "%s", "restored": %s, "merge_blocked": "%s"}\n' \
  "$FEATURE" "$BASE" "$N" "$NP" "$NF" "$NM" "$NMF" "$POST" "$REVIEW" "$PUSHED" "$DELIVERED" "$RESTORED" "$MERGE_BLOCKED" \
  > "$RUN_DIR/status/summary.json"
SUMMARY="feature=$FEATURE base=$BASE tasks=$N"
[ "$NP" -gt 0 ] && SUMMARY="$SUMMARY pass=$NP"
[ "$NF" -gt 0 ] && SUMMARY="$SUMMARY fail=$NF"
[ "$NM" -gt 0 ] && SUMMARY="$SUMMARY merged=$NM"
[ "$NMF" -gt 0 ] && SUMMARY="$SUMMARY merge=fail"
[ -n "$MERGE_BLOCKED" ] && SUMMARY="$SUMMARY merge=blocked"
case "$POST" in
  pass) SUMMARY="$SUMMARY post-merge=pass" ;;
  fail) SUMMARY="$SUMMARY post-merge=fail" ;;
esac
[ "$RESTORED" = "true" ] && SUMMARY="$SUMMARY restored"
case "$REVIEW" in
  done) SUMMARY="$SUMMARY reviewed" ;;
  failed) SUMMARY="$SUMMARY review=failed" ;;
esac
[ "$PUSHED" = "true" ] && SUMMARY="$SUMMARY pushed"
note "summary: $SUMMARY"

if [ -n "$MERGE_BLOCKED" ]; then exit 1; fi
if [ "$POST" = "fail" ]; then exit 1; fi
if [ "$PUSH" = "1" ] && [ "$POST" = "pass" ] && [ "$PUSHED" != "true" ]; then exit 1; fi
if [ -n "$FAILED" ] || [ -n "$MERGE_FAILED" ]; then exit 2; fi
exit 0
