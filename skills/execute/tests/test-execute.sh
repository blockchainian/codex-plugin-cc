#!/usr/bin/env bash
# ABOUTME: End-to-end test for execute.sh using a fixture git repo and the stub codex CLI.
# ABOUTME: Covers pass, retry-on-red-check, hang/timeout, no-diff, conflict resolution, cleanup, push.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../execute.sh"
SCRATCH="$(mktemp -d /tmp/codex-execute-test.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

FAILS=0
assert() { # assert <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc  [cmd: $*]"
    FAILS=$((FAILS+1))
  fi
}
assert_eq() { # assert_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1  [expected '$2' got '$3']"
    FAILS=$((FAILS+1))
  fi
}

# ---------- fixture ----------
export STUB_DIR="$SCRATCH/stub"
mkdir -p "$STUB_DIR"
# inject the stub via EXECUTE_CODEX: a single path, immune to PATH quirks (e.g. colons in dir names)
export EXECUTE_CODEX="$HERE/stub-codex/codex"
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pr create") echo "https://github.com/example/app/pull/42" ;;
  "pr comment") ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

FIX="$SCRATCH/repo"
ORIGIN="$SCRATCH/origin.git"
git init -q -b main "$FIX"
git -C "$FIX" config user.email test@test && git -C "$FIX" config user.name test
cat > "$FIX/check.sh" <<'EOF'
#!/bin/sh
for f in a.txt b.txt c.txt; do
  [ -f "$f" ] || continue
  case "$(cat "$f")" in
    ok*) ;;
    *) echo "BAD content in $f"; exit 1 ;;
  esac
done
exit 0
EOF
echo "shared spec for tasks" > "$FIX/spec.md"
cat > "$FIX/tasks.txt" <<'EOF'
TASK-OK write a.txt per spec.md
TASK-FAILONCE write b.txt per spec.md
TASK-HANG never finishes
TASK-NOOP produces no diff
TASK-C1 write c.txt (variant 1)
TASK-C2 write c.txt (variant 2)
EOF
git -C "$FIX" add -A && git -C "$FIX" commit -qm "base"
git init -q --bare "$ORIGIN"
git -C "$FIX" remote add origin "$ORIGIN"
git -C "$FIX" push -q origin main

# ---------- run ----------
set +e
"$ENGINE" --tasks "$FIX/tasks.txt" --base main --feature feat-x \
  --check "sh ./check.sh" --concurrency 2 --retries 1 --timeout 3 \
  --repo "$FIX" > "$SCRATCH/run.log" 2>&1
RC=$?
set -e 2>/dev/null || true

echo "---- engine exit=$RC (log: $SCRATCH/run.log) ----"

# ---------- assertions ----------
assert_eq "exit code 2 (partial: failed tasks, feature green)" 2 "$RC"

WT_ROOT="$(dirname "$FIX")/.codex-execute-feat-x"
FT="$WT_ROOT/feature"

# feature branch content
assert "feature worktree exists" test -d "$FT"
assert_eq "a.txt from task 1" "ok-task1" "$(cat "$FT/a.txt" 2>/dev/null)"
assert_eq "b.txt from task 2 retry" "ok-task2" "$(cat "$FT/b.txt" 2>/dev/null)"
assert_eq "c.txt conflict resolved by codex" "ok-merged" "$(cat "$FT/c.txt" 2>/dev/null)"

# push happened
assert "feature branch pushed to origin" git -C "$ORIGIN" rev-parse --verify refs/heads/feat-x
assert_eq "origin feat-x == local feat-x" \
  "$(git -C "$FIX" rev-parse feat-x)" "$(git -C "$ORIGIN" rev-parse feat-x)"

# retry / attempt counts via stub
count() { wc -l < "$STUB_DIR/calls-$1" 2>/dev/null | tr -d ' ' || echo 0; }
assert_eq "task1 invoked once" 1 "$(count TASK-OK)"
assert_eq "task2 invoked twice (retry with failure context)" 2 "$(count TASK-FAILONCE)"
assert_eq "task3 (hang) invoked retries+1 times" 2 "$(count TASK-HANG)"
assert_eq "task4 (noop) invoked retries+1 times" 2 "$(count TASK-NOOP)"
assert_eq "merge conflict resolved via codex exactly once" 1 "$(count MERGE-RESOLVE)"

# progress output
assert_eq "first attempts omit attempt number" 0 "$(grep -c 'attempt 1' "$SCRATCH/run.log" || true)"
assert "retry start appends attempt number" \
  grep -Eq '\[task 2\] starting \(slot w[12]\) \(attempt 2\)' "$SCRATCH/run.log"
assert "retry pass includes attempt number" grep -q '\[task 2\] PASS (attempt 2)' "$SCRATCH/run.log"
assert "check failure uses concise FAIL output" grep -q '\[task 2\] FAIL (exit 1)' "$SCRATCH/run.log"
assert "summary includes passed and failed tasks" \
  grep -q '^codex:execute: PASS \[1 2 5 6\] FAIL \[3 4\]$' "$SCRATCH/run.log"
assert "successful merge uses uppercase status" \
  grep -q '^codex:execute: \[merge\] task 1 MERGED$' "$SCRATCH/run.log"
assert "merge uses concise PASS output" \
  grep -q '^codex:execute: \[merge\] PASS$' "$SCRATCH/run.log"
assert "PR output is concise" \
  grep -q '^codex:execute: PR is https://github.com/example/app/pull/42$' "$SCRATCH/run.log"
assert "GitHub review output is concise" \
  grep -q '^codex:execute: GitHub review requested$' "$SCRATCH/run.log"
assert "console summary uses compact fields" \
  grep -q '^codex:execute: summary: feature=feat-x base=main tasks=6 pass=4 fail=2 merged=4 post-merge=pass reviewed pushed$' "$SCRATCH/run.log"
assert "review progress uses concise wording" \
  grep -q '^codex:execute: \[review\] feat-x vs main$' "$SCRATCH/run.log"
assert "review result identifies the result file" \
  grep -q '^codex:execute: \[review\] result: .*/logs/review.md$' "$SCRATCH/run.log"
assert "push output omits the feature name" \
  grep -q '^codex:execute: pushed to origin$' "$SCRATCH/run.log"
assert "worktree output uses concise label" \
  grep -q "^codex:execute: worktree: $FT$" "$SCRATCH/run.log"
assert "worktree output precedes logs" \
  awk '/^codex:execute: worktree:/{worktree=NR} /^codex:execute: logs:/{logs=NR} END {exit !(worktree && logs && worktree < logs)}' "$SCRATCH/run.log"
assert_eq "review result is not repeated at the end" 0 \
  "$(grep -c '^codex:execute: review result:' "$SCRATCH/run.log" || true)"

# task worktrees cleaned, feature worktree kept
assert "task worktree w1 removed" test ! -e "$WT_ROOT/w1"
assert "task worktree w2 removed" test ! -e "$WT_ROOT/w2"
assert_eq "git worktree list has no task worktrees" 0 \
  "$(git -C "$FIX" worktree list | grep -c "$WT_ROOT/w" || true)"

# merged + clean-failed task branches deleted (failed tasks had no commits)
assert_eq "no task branches left" 0 "$(git -C "$FIX" branch --list 'tasks/feat-x/*' | wc -l | tr -d ' ')"

# status files
ST="$(git -C "$FIX" rev-parse --absolute-git-dir)/codex-execute/feat-x/status"
assert "summary.json exists" test -f "$ST/summary.json"
assert_eq "4 tasks passed" 4 "$(grep -c '"result": "pass"' "$ST"/task-*.json | awk -F: '{s+=$2} END {print s}')"
assert_eq "2 tasks failed" 2 "$(grep -c '"result": "fail"' "$ST"/task-*.json | awk -F: '{s+=$2} END {print s}')"

# failed tasks not in feature branch
assert "no stray files from failed tasks" test ! -e "$FT/hang.txt"

# concurrency: only w1/w2 ever created (pool of 2 for 6 tasks)
assert_eq "worktree pool respected concurrency=2" 0 "$(ls -d "$WT_ROOT"/w3 2>/dev/null | wc -l | tr -d ' ')"

# local review ran once and produced findings file
L="$(git -C "$FIX" rev-parse --absolute-git-dir)/codex-execute/feat-x/logs"
assert_eq "local codex review ran once" 1 "$(count REVIEW)"
assert_eq "review findings captured" "stub review: no findings" "$(cat "$L/review.md" 2>/dev/null)"

# ---------- scenario 2: --onto-base (existing-PR branch mode) ----------
printf 'TASK-OK write a.txt per spec.md\n' > "$FIX/tasks2.txt"
set +e
"$ENGINE" --tasks "$FIX/tasks2.txt" --base main --feature feat-y \
  --check "sh ./check.sh" --concurrency 1 --retries 0 --timeout 3 \
  --onto-base --repo "$FIX" > "$SCRATCH/run2.log" 2>&1
RC2=$?
set -e 2>/dev/null || true
echo "---- scenario 2 exit=$RC2 (log: $SCRATCH/run2.log) ----"

assert_eq "onto-base run exits 0 (all green)" 0 "$RC2"
assert "origin main advanced with task merge" \
  sh -c "git -C '$ORIGIN' log --oneline main | grep -q 'merge task 1'"
assert "no feat-y branch on origin" \
  sh -c "! git -C '$ORIGIN' rev-parse --verify -q refs/heads/feat-y"
assert "local feat-y branch deleted after delivery" \
  sh -c "! git -C '$FIX' rev-parse --verify -q refs/heads/feat-y"
assert "feat-y worktree root fully removed" test ! -e "$(dirname "$FIX")/.codex-execute-feat-y"
assert_eq "review also ran for onto-base run" 2 "$(count REVIEW)"
assert "all-green summary only includes passed tasks" \
  grep -q '^codex:execute: PASS \[1\]$' "$SCRATCH/run2.log"
assert "all-green console summary omits zero values" \
  grep -q '^codex:execute: summary: feature=feat-y base=main tasks=1 pass=1 merged=1 post-merge=pass reviewed pushed$' "$SCRATCH/run2.log"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$FAILS TEST(S) FAILED"; tail -40 "$SCRATCH/run.log"; echo "-- run2 --"; tail -30 "$SCRATCH/run2.log"; exit 1; fi
