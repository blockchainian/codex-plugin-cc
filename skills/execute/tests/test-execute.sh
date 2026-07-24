#!/usr/bin/env bash
# ABOUTME: End-to-end test for execute.sh using a fixture git repo and the stub codex CLI.
# ABOUTME: Covers pass, retry, hang, no-diff, conflicts, session-branch delivery, restore, guards.
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
  "pr view") [ "${GH_VIEW_OK:-0}" = "1" ] || exit 1 ;;
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
# d and e pass alone but fail combined: drives the post-merge-red scenario
if [ -f d.txt ] && [ -f e.txt ]; then echo "d.txt and e.txt conflict"; exit 1; fi
exit 0
EOF
echo "shared spec for workstreams" > "$FIX/spec.md"
cat > "$FIX/workstreams.txt" <<'EOF'
WS-OK write a.txt per spec.md
WS-FAILONCE write b.txt per spec.md
WS-HANG never finishes
WS-NOOP produces no diff
WS-C1 write c.txt (variant 1)
WS-C2 write c.txt (variant 2)
EOF
git -C "$FIX" add -A && git -C "$FIX" commit -qm "base"
git init -q --bare "$ORIGIN"
git -C "$FIX" remote add origin "$ORIGIN"
git -C "$FIX" push -q origin main

BASE0="$(git -C "$FIX" rev-parse main)"

# ---------- scenario 1: partial run, delivery onto the session branch ----------
set +e
"$ENGINE" --workstreams "$FIX/workstreams.txt" --feature feat-x \
  --check "sh ./check.sh" --concurrency 2 --retries 1 --timeout 3 \
  --repo "$FIX" > "$SCRATCH/run.log" 2>&1
RC=$?
set -e 2>/dev/null || true

echo "---- engine exit=$RC (log: $SCRATCH/run.log) ----"

# ---------- assertions ----------
assert_eq "exit code 2 (partial: failed workstreams, session branch green)" 2 "$RC"

WT_ROOT="$(dirname "$FIX")/.codex-execute-feat-x"

# merged content landed on the session branch, in the session worktree
assert_eq "still on main" "main" "$(git -C "$FIX" symbolic-ref --short HEAD)"
assert_eq "a.txt from workstream 1" "ok-ws1" "$(cat "$FIX/a.txt" 2>/dev/null)"
assert_eq "b.txt from workstream 2 retry" "ok-ws2" "$(cat "$FIX/b.txt" 2>/dev/null)"
assert_eq "c.txt conflict resolved by codex" "ok-merged" "$(cat "$FIX/c.txt" 2>/dev/null)"
assert "merge commits are on main" \
  sh -c "git -C '$FIX' log --oneline main | grep -q 'merge workstream 1'"
assert_eq "pre-merge ref recorded at run-start commit" "$BASE0" \
  "$(git -C "$FIX" rev-parse refs/codex-execute/feat-x/pre-merge 2>/dev/null)"

# push happened: session branch delivered
assert_eq "origin main == local main" \
  "$(git -C "$FIX" rev-parse main)" "$(git -C "$ORIGIN" rev-parse main)"

# retry / attempt counts via stub
count() { wc -l < "$STUB_DIR/calls-$1" 2>/dev/null | tr -d ' ' || echo 0; }
assert_eq "workstream 1 invoked once" 1 "$(count WS-OK)"
assert_eq "workstream 2 invoked twice (retry with failure context)" 2 "$(count WS-FAILONCE)"
assert_eq "workstream 3 (hang) invoked retries+1 times" 2 "$(count WS-HANG)"
assert_eq "workstream 4 (noop) invoked retries+1 times" 2 "$(count WS-NOOP)"
assert_eq "merge conflict resolved via codex exactly once" 1 "$(count MERGE-RESOLVE)"

# progress output
assert_eq "first attempts omit attempt number" 0 "$(grep -c 'attempt 1' "$SCRATCH/run.log" || true)"
assert "retry start appends attempt number" \
  grep -Eq '\[workstream 2\] starting \(slot w[12]\) \(attempt 2\)' "$SCRATCH/run.log"
assert "retry pass includes attempt number" grep -q '\[workstream 2\] PASS (attempt 2)' "$SCRATCH/run.log"
assert "check failure uses concise FAIL output" grep -q '\[workstream 2\] FAIL (exit 1)' "$SCRATCH/run.log"
assert "summary includes passed and failed workstreams" \
  grep -q '^codex:execute: PASS \[1 2 5 6\] FAIL \[3 4\]$' "$SCRATCH/run.log"
assert "successful merge uses uppercase status" \
  grep -q '^codex:execute: \[merge\] workstream 1 MERGED$' "$SCRATCH/run.log"
assert "merge uses concise PASS output" \
  grep -q '^codex:execute: \[merge\] PASS$' "$SCRATCH/run.log"
assert "PR output is concise" \
  grep -q '^codex:execute: PR is https://github.com/example/app/pull/42$' "$SCRATCH/run.log"
assert "GitHub review output is concise" \
  grep -q '^codex:execute: GitHub review requested$' "$SCRATCH/run.log"
assert "console summary uses compact fields" \
  grep -q '^codex:execute: summary: feature=feat-x base=main workstreams=6 pass=4 fail=2 merged=4 post-merge=pass reviewed pushed$' "$SCRATCH/run.log"
assert "review progress uses concise wording" \
  grep -q '^codex:execute: \[review\] merged workstreams vs pre-merge$' "$SCRATCH/run.log"
assert "review result identifies the result file" \
  grep -q '^codex:execute: \[review\] result: .*/logs/review.md$' "$SCRATCH/run.log"
assert "push output omits the branch name" \
  grep -q '^codex:execute: pushed to origin$' "$SCRATCH/run.log"
assert "delivery target announced" \
  grep -q "^codex:execute: delivering onto branch 'main' in $FIX$" "$SCRATCH/run.log"
assert "delivery target precedes logs" \
  awk '/^codex:execute: delivering onto/{d=NR} /^codex:execute: logs:/{l=NR} END {exit !(d && l && d < l)}' "$SCRATCH/run.log"

# worktree pool cleaned up entirely (no feature worktree exists at all)
assert "worktree root fully removed" test ! -e "$WT_ROOT"
assert_eq "git worktree list has no workstream worktrees" 0 \
  "$(git -C "$FIX" worktree list | grep -c "$WT_ROOT" || true)"
L="$(git -C "$FIX" rev-parse --absolute-git-dir)/codex-execute/feat-x/logs"
assert "pool respected concurrency=2 (no w3 created)" test ! -e "$L/w3.create.log"

# merged + clean-failed workstream branches deleted (failed workstreams had no commits)
assert_eq "no workstream branches left" 0 "$(git -C "$FIX" branch --list 'workstreams/feat-x/*' | wc -l | tr -d ' ')"

# status files
ST="$(git -C "$FIX" rev-parse --absolute-git-dir)/codex-execute/feat-x/status"
assert "summary.json exists" test -f "$ST/summary.json"
assert_eq "4 workstreams passed" 4 "$(grep -c '"result": "pass"' "$ST"/workstream-*.json | awk -F: '{s+=$2} END {print s}')"
assert_eq "2 workstreams failed" 2 "$(grep -c '"result": "fail"' "$ST"/workstream-*.json | awk -F: '{s+=$2} END {print s}')"
assert "summary records delivery to main" grep -q '"delivered_to": "main"' "$ST/summary.json"
assert "summary records no restore" grep -q '"restored": false' "$ST/summary.json"

# failed workstreams not on the session branch
assert "no stray files from failed workstreams" test ! -e "$FIX/hang.txt"

# local review ran once and produced findings file
assert_eq "local codex review ran once" 1 "$(count REVIEW)"
assert_eq "review findings captured" "stub review: no findings" "$(cat "$L/review.md" 2>/dev/null)"

# ---------- scenario 2: all green, existing PR for the session branch ----------
# WS-C1 rewrites c.txt (scenario 1 left "ok-merged"), so the workstream has a real diff
printf 'WS-C1 write c.txt (variant 1)\n' > "$FIX/workstreams2.txt"
git -C "$FIX" add workstreams2.txt && git -C "$FIX" commit -qm "workstreams2" && git -C "$FIX" push -q origin main
set +e
GH_VIEW_OK=1 "$ENGINE" --workstreams "$FIX/workstreams2.txt" --base main --feature feat-y \
  --check "sh ./check.sh" --concurrency 1 --retries 0 --timeout 3 \
  --repo "$FIX" > "$SCRATCH/run2.log" 2>&1
RC2=$?
set -e 2>/dev/null || true
echo "---- scenario 2 exit=$RC2 (log: $SCRATCH/run2.log) ----"

assert_eq "all-green run exits 0" 0 "$RC2"
assert "origin main advanced with the new merge" \
  sh -c "git -C '$ORIGIN' log --oneline main | grep -q 'merge workstream 1'"
assert_eq "origin main == local main after delivery" \
  "$(git -C "$FIX" rev-parse main)" "$(git -C "$ORIGIN" rev-parse main)"
assert "existing PR path comments instead of creating" \
  grep -q '^codex:execute: existing PR updates; GitHub review requested$' "$SCRATCH/run2.log"
assert "feat-y worktree root fully removed" test ! -e "$(dirname "$FIX")/.codex-execute-feat-y"
assert_eq "review also ran for scenario 2" 2 "$(count REVIEW)"
assert "all-green summary only includes passed workstreams" \
  grep -q '^codex:execute: PASS \[1\]$' "$SCRATCH/run2.log"
assert "all-green console summary omits zero values" \
  grep -q '^codex:execute: summary: feature=feat-y base=main workstreams=1 pass=1 merged=1 post-merge=pass reviewed pushed$' "$SCRATCH/run2.log"

# ---------- scenario 3: red post-merge check restores the session branch ----------
printf 'WS-D write d.txt\nWS-E write e.txt\n' > "$FIX/workstreams3.txt"
git -C "$FIX" add workstreams3.txt && git -C "$FIX" commit -qm "workstreams3" && git -C "$FIX" push -q origin main
PRE3="$(git -C "$FIX" rev-parse main)"
ORIGIN3="$(git -C "$ORIGIN" rev-parse main)"
set +e
"$ENGINE" --workstreams "$FIX/workstreams3.txt" --feature feat-z \
  --check "sh ./check.sh" --concurrency 2 --retries 0 --timeout 3 \
  --repo "$FIX" > "$SCRATCH/run3.log" 2>&1
RC3=$?
set -e 2>/dev/null || true
echo "---- scenario 3 exit=$RC3 (log: $SCRATCH/run3.log) ----"

assert_eq "red post-merge exits 1" 1 "$RC3"
assert_eq "session branch restored to pre-merge commit" "$PRE3" "$(git -C "$FIX" rev-parse main)"
assert "restored worktree has no d.txt" test ! -e "$FIX/d.txt"
assert "restored worktree has no e.txt" test ! -e "$FIX/e.txt"
assert_eq "both workstream branches kept for autopsy" 2 \
  "$(git -C "$FIX" branch --list 'workstreams/feat-z/*' | wc -l | tr -d ' ')"
assert "restore is reported" \
  grep -q 'session branch restored' "$SCRATCH/run3.log"
assert "restored summary token present" \
  sh -c "grep -q 'post-merge=fail restored' '$SCRATCH/run3.log'"
assert_eq "origin main untouched by red run" "$ORIGIN3" "$(git -C "$ORIGIN" rev-parse main)"
ST3="$(git -C "$FIX" rev-parse --absolute-git-dir)/codex-execute/feat-z/status"
assert "summary records the restore" grep -q '"restored": true' "$ST3/summary.json"
assert_eq "no review on red post-merge" 2 "$(count REVIEW)"
git -C "$FIX" branch -q -D workstreams/feat-z/1 workstreams/feat-z/2

# ---------- scenario 4: guard rails ----------
echo dirt > "$FIX/dirty.txt"
set +e
"$ENGINE" --workstreams "$FIX/workstreams2.txt" --feature feat-w \
  --check "sh ./check.sh" --repo "$FIX" > "$SCRATCH/run4.log" 2>&1
RC4=$?
set -e 2>/dev/null || true
rm -f "$FIX/dirty.txt"

assert_eq "dirty session worktree is fatal" 1 "$RC4"
assert "dirty guard names the problem" \
  grep -q 'session worktree is dirty' "$SCRATCH/run4.log"
assert_eq "dirty run created no workstream branches" 0 \
  "$(git -C "$FIX" branch --list 'workstreams/feat-w/*' | wc -l | tr -d ' ')"

set +e
"$ENGINE" --workstreams "$FIX/workstreams2.txt" --base other --feature feat-v \
  --check "sh ./check.sh" --repo "$FIX" > "$SCRATCH/run5.log" 2>&1
RC5=$?
set -e 2>/dev/null || true

assert_eq "base/checkout mismatch is fatal" 1 "$RC5"
assert "mismatch guard names both branches" \
  sh -c "grep -q \"repo has 'main' checked out but --base is 'other'\" '$SCRATCH/run5.log'"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$FAILS TEST(S) FAILED"; tail -40 "$SCRATCH/run.log"; echo "-- run3 --"; tail -30 "$SCRATCH/run3.log"; exit 1; fi
