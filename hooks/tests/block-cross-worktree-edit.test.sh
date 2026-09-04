#!/usr/bin/env bash
#
# Regression test for #196a — block-cross-worktree-edit.sh must
# categorically deny a session from editing a sibling task's worktree
# while it already owns a DIFFERENT worktree of the same repository, and
# must NEVER deny a session that owns nothing (or that only owns worktrees
# in a different repository). It must also fail open on every degraded
# path (missing jq, unwritable $ATELIER_CONFIG_DIR, no working `stat`,
# target not inside any git worktree).
#
# Hermetic: drives hooks/block-cross-worktree-edit.sh directly with
# crafted stdin JSON against real throwaway git repos + `git worktree add`
# checkouts under a temp dir. No network. Requires `git` and `jq` (the
# hook's own dependencies).
#
# Run:  hooks/tests/block-cross-worktree-edit.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

# Ambient-env hermeticity guard (#196a review finding 1): the CI failure
# this cycle fixed came from N1/N2 inheriting the DEVELOPER's own
# CLAUDE_CODE_BRIDGE_SESSION_ID instead of the value each section means to
# exercise, which let a clean-env-only assertion pass locally while failing
# under CI's clean env. Fixing only N1/N2 leaves the SAME latent hazard for
# every future section: any block that forgets to set (or deliberately
# unset) this var inherits whatever the invoking shell happens to export.
# Stripping it here, once, for the whole file's own process makes that
# hazard structural rather than a per-section discipline problem — every
# section below either explicitly sets CLAUDE_CODE_BRIDGE_SESSION_ID itself
# (run_hook/run_stop, and the few sections that build a payload by hand) or
# relies on it being genuinely absent (the M/N/R fallback-chain sections),
# and this line guarantees the latter is true regardless of what the
# developer's or CI's own shell happened to export before invoking this
# script.
unset CLAUDE_CODE_BRIDGE_SESSION_ID

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-cross-worktree-edit.sh"
BASH_BIN="$(command -v bash)"

TMP="$(mktemp -d)"
# Canonicalise: macOS `mktemp -d` returns a path under /var/folders/**,
# which is itself a symlink to /private/var/folders/**. The hook
# canonicalises every target path with `pwd -P` before deriving a
# worktree/container id, so this test's own key computations (which
# re-derive the same ids to assert on-disk ownership state directly) must
# start from the same physical path or they'll compute a different key
# than the hook did.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

CFG="$TMP/atelier-config"
mkdir -p "$CFG"

# --- helpers -----------------------------------------------------------

mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  printf 'hi\n' > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -q -m init
}

mk_worktree() {
  local repo="$1" branch="$2" wtpath="$3"
  git -C "$repo" worktree add -q -b "$branch" "$wtpath" >/dev/null 2>&1
}

# Run the hook as Claude Code would: payload = an Edit/Write/MultiEdit/
# NotebookEdit tool call against $file_path. $token drives
# CLAUDE_CODE_BRIDGE_SESSION_ID — this hook's primary session-token
# source (see the hook's own header comment for why). Echoes the exit
# code; hook stderr is captured to $TMP/last_stderr for message
# assertions.
run_hook() {
  local tool="$1" file_path="$2" token="$3" custom_path="${4:-}"
  local field payload rc
  field="file_path"
  [ "$tool" = "NotebookEdit" ] && field="notebook_path"
  payload="$(jq -cn --arg t "$tool" --arg f "$file_path" --arg field "$field" \
    '{tool_name:$t, tool_input: ({} | .[$field]=$f), session_id:("sess-"+$t), transcript_path:("/tmp/does-not-exist-"+$t+".jsonl")}')"
  (
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export CLAUDE_PROJECT_DIR="$TMP/logs"
    export ATELIER_CONFIG_DIR="$CFG"
    export CLAUDE_CODE_BRIDGE_SESSION_ID="$token"
    if [ -n "$custom_path" ]; then
      export PATH="$custom_path"
    fi
    "$BASH_BIN" "$HOOK" <<<"$payload" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  )
  rc=$?
  echo "$rc"
}

assert_block() {
  local desc="$1" tool="$2" file_path="$3" token="$4"
  local code
  code="$(run_hook "$tool" "$file_path" "$token")"
  [ "$code" = "2" ] && pass "$desc → blocked (exit 2)" \
                     || fail "$desc expected exit 2, got $code (stderr: $(cat "$TMP/last_stderr" 2>/dev/null))"
}

assert_allow() {
  local desc="$1" tool="$2" file_path="$3" token="$4" custom_path="${5:-}"
  local code
  code="$(run_hook "$tool" "$file_path" "$token" "$custom_path")"
  [ "$code" = "0" ] && pass "$desc → allowed (exit 0)" \
                     || fail "$desc expected exit 0, got $code (stderr: $(cat "$TMP/last_stderr" 2>/dev/null))"
}

assert_stderr_contains() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$TMP/last_stderr" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc — stderr was: $(cat "$TMP/last_stderr" 2>/dev/null)"
  fi
}

echo "#196a regression — block-cross-worktree-edit categorical worktree-isolation guard"

# Sanity-check the ambient-env guard above actually took effect in THIS
# process before relying on it for every section below.
if [ -z "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}" ]; then
  pass "ambient CLAUDE_CODE_BRIDGE_SESSION_ID stripped for the remainder of this suite (finding 1 guard)"
else
  fail "expected CLAUDE_CODE_BRIDGE_SESSION_ID to be unset after the top-of-file guard, got \"$CLAUDE_CODE_BRIDGE_SESSION_ID\""
fi

# =============================================================================
# SECTION A — baseline ownership rules within one repo (one "container")
# =============================================================================
echo
echo "-- section A: baseline self-claim / same-owner / foreign-but-caller-owns-nothing --"

REPO1="$TMP/repo1"
mk_repo "$REPO1"
WT_A="$TMP/repo1-wt-a"
WT_B="$TMP/repo1-wt-b"
WT_D="$TMP/repo1-wt-d"
mk_worktree "$REPO1" "task/a" "$WT_A"
mk_worktree "$REPO1" "task/b" "$WT_B"
mk_worktree "$REPO1" "task/d" "$WT_D"

# 1. Fresh token, unclaimed worktree A → self-claims, allowed.
assert_allow "token A first write into worktree A (unclaimed)" "Write" "$WT_A/new.txt" "token-A"

# 2. Same token writes into the same worktree again → still allowed.
assert_allow "token A writes into worktree A again (already owner)" "Edit" "$WT_A/f.txt" "token-A"

# 3. Different token (B), worktree A already owned fresh by A, but B owns
#    nothing else yet → allowed (never denied when the caller owns nothing).
assert_allow "token B writes into worktree A (B owns nothing else)" "Write" "$WT_A/other.txt" "token-B"

# Worktree A's ownership must still be token-A after (3) — B's allowed
# pass-through must NOT reassign ownership.
container_common="$(cd "$REPO1" && git rev-parse --git-common-dir)"
case "$container_common" in
  /*) : ;;
  *) container_common="$(cd "$REPO1" && cd "$container_common" && pwd -P)" ;;
esac
enc() { printf '%s' "$1" | cksum | tr -s ' ' '-'; }
key_a="$(enc "$container_common")--$(enc "$WT_A")"
owner_token_a="$(cat "$CFG/state/worktree-owner/$key_a/token" 2>/dev/null || true)"
if [ "$owner_token_a" = "token-A" ]; then
  pass "worktree A ownership still token-A after B's pass-through edit"
else
  fail "worktree A ownership changed unexpectedly (now: $owner_token_a)"
fi

# 4. Token A writes into worktree B (unclaimed) → self-claims B too. A now
#    owns two worktrees (A and B) in this container.
assert_allow "token A first write into worktree B (unclaimed)" "Write" "$WT_B/new.txt" "token-A"

# 5. Token C self-claims worktree D (unclaimed).
assert_allow "token C first write into worktree D (unclaimed)" "Write" "$WT_D/new.txt" "token-C"

# 6. Token A (owns A and B) writes into worktree D (owned fresh by C) →
#    denied — A already owns a different worktree in this same container.
assert_block "token A writes into worktree D (C's, A owns A+B) → cross-worktree deny" \
  "Write" "$WT_D/blocked.txt" "token-A"

# 7. Token E (owns nothing at all) writes into worktree D (owned fresh by
#    C) → allowed — E owns nothing else, so it is never denied.
assert_allow "token E (owns nothing) writes into worktree D (C's)" "Write" "$WT_D/e.txt" "token-E"

# =============================================================================
# SECTION B — cross-container non-interference
# =============================================================================
echo
echo "-- section B: ownership in one repo must not deny edits in a different repo --"

REPO2="$TMP/repo2"
mk_repo "$REPO2"
WT_Z="$TMP/repo2-wt-z"
mk_worktree "$REPO2" "task/z" "$WT_Z"

# Token G self-claims worktree Z in repo2 (fresh, foreign to token-A).
assert_allow "token G first write into worktree Z (repo2, unclaimed)" "Write" "$WT_Z/new.txt" "token-G"

# Token A owns worktree A + B in repo1 only — nothing in repo2 — so its
# write into worktree Z (repo2, owned fresh by G) must still be allowed:
# the "caller already owns a different worktree" condition is scoped to
# the SAME container.
assert_allow "token A (owns only repo1 worktrees) writes into worktree Z (repo2, G's)" \
  "Write" "$WT_Z/cross-container.txt" "token-A"

# =============================================================================
# SECTION C — stale reclaim
# =============================================================================
echo
echo "-- section C: a stale (expired ownerTtlSeconds) claim is reclaimed, not denied --"

REPO3="$TMP/repo3"
mk_repo "$REPO3"
WT_S="$TMP/repo3-wt-s"
mk_worktree "$REPO3" "task/s" "$WT_S"
printf '{"ownerTtlSeconds": 1}\n' > "$WT_S/.atelier.json"

# Token H claims worktree S first.
assert_allow "token H first write into worktree S (ttl=1s)" "Write" "$WT_S/new.txt" "token-H"

# Backdate the claim's token-file mtime far into the past so it reads as
# stale regardless of how fast this test runs. `touch -t` is POSIX/BSD
# and GNU compatible (unlike `-d`), matching the hook's own portability
# constraints.
container3_common="$(cd "$REPO3" && git rev-parse --git-common-dir)"
case "$container3_common" in
  /*) : ;;
  *) container3_common="$(cd "$REPO3" && cd "$container3_common" && pwd -P)" ;;
esac
key_s="$(enc "$container3_common")--$(enc "$WT_S")"
touch -t 202001010000 "$CFG/state/worktree-owner/$key_s/token" 2>/dev/null

# Token I (foreign) writes into worktree S → the stale claim is reclaimed
# atomically (mv -> rm -rf -> mkdir), never denied.
assert_allow "token I writes into worktree S (H's claim is stale) → reclaimed" \
  "Write" "$WT_S/reclaimed.txt" "token-I"

new_owner_s="$(cat "$CFG/state/worktree-owner/$key_s/token" 2>/dev/null || true)"
if [ "$new_owner_s" = "token-I" ]; then
  pass "worktree S ownership transferred to token-I after stale reclaim"
else
  fail "worktree S ownership did not transfer as expected (now: $new_owner_s)"
fi

# =============================================================================
# SECTION D — race: claim dir exists, token file not written yet
# =============================================================================
echo
echo "-- section D: an in-flight claim (dir exists, no token file) is never a foreign owner --"

REPO4="$TMP/repo4"
mk_repo "$REPO4"
WT_R="$TMP/repo4-wt-r"
mk_worktree "$REPO4" "task/r" "$WT_R"

container4_common="$(cd "$REPO4" && git rev-parse --git-common-dir)"
case "$container4_common" in
  /*) : ;;
  *) container4_common="$(cd "$REPO4" && cd "$container4_common" && pwd -P)" ;;
esac
key_r="$(enc "$container4_common")--$(enc "$WT_R")"
mkdir -p "$CFG/state/worktree-owner/$key_r" # claim dir exists, no token file yet

assert_allow "token J writes into worktree R (claim dir exists, no token file)" \
  "Write" "$WT_R/racer.txt" "token-J"

# =============================================================================
# SECTION E — main-checkout edits (unblocker Step 5 / task-orchestrator
# Step 8) must still pass the hook
# =============================================================================
echo
echo "-- section E: main-checkout edit alongside an owned task worktree --"

REPO5="$TMP/repo5"
mk_repo "$REPO5"
WT_TASK="$TMP/repo5-wt-task"
mk_worktree "$REPO5" "task/196a-sim" "$WT_TASK"

# Token K owns the task worktree (as implementer/tester would over the
# course of a chain).
assert_allow "token K writes into its own task worktree" "Edit" "$WT_TASK/f.txt" "token-K"

# unblocker Step 5 / task-orchestrator Step 8 edit ROADMAP.md/IN_PROGRESS.md
# on the MAIN checkout (REPO5 itself) — a different worktree of the same
# container, currently unclaimed — must still be allowed.
assert_allow "token K (owns task worktree) writes into the main checkout (unclaimed)" \
  "Edit" "$REPO5/IN_PROGRESS.md" "token-K"

# =============================================================================
# SECTION F — tool-name matcher coverage
# =============================================================================
echo
echo "-- section F: matcher coverage (Edit/Write/MultiEdit/NotebookEdit vs everything else) --"

REPO6="$TMP/repo6"
mk_repo "$REPO6"
WT_M="$TMP/repo6-wt-m"
mk_worktree "$REPO6" "task/m" "$WT_M"

assert_allow "MultiEdit into a fresh worktree self-claims" "MultiEdit" "$WT_M/multi.txt" "token-M1"
assert_allow "NotebookEdit into a fresh worktree self-claims" "NotebookEdit" "$WT_M/nb.ipynb" "token-M1"

WT_N="$TMP/repo6-wt-n"
mk_worktree "$REPO6" "task/n" "$WT_N"
assert_allow "token M2 self-claims worktree N" "Write" "$WT_N/new.txt" "token-M2"
assert_block "MultiEdit cross-worktree (M1 owns M, writes into N owned by M2)" \
  "MultiEdit" "$WT_N/blocked.txt" "token-M1"

# A non-matching tool (Bash) must never be evaluated by this hook at all,
# regardless of ownership state — always exit 0.
code="$(
  payload="$(jq -cn '{tool_name:"Bash", tool_input:{command:"ls"}}')"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-M1" \
    "$BASH_BIN" "$HOOK" <<<"$payload" >/dev/null 2>&1
  echo $?
)"
[ "$code" = "0" ] && pass "Bash tool call is never evaluated (exit 0)" \
                   || fail "Bash tool call expected exit 0, got $code"

# =============================================================================
# SECTION G — degraded paths: every one exits 0 with a warning
# =============================================================================
echo
echo "-- section G: fail-open degraded paths --"

REPO7="$TMP/repo7"
mk_repo "$REPO7"
WT_G1="$TMP/repo7-wt-g1"
mk_worktree "$REPO7" "task/g1" "$WT_G1"

# G1. jq missing.
BIN_NO_JQ="$TMP/bin-no-jq"
mkdir -p "$BIN_NO_JQ"
for b in git cksum stat date mkdir rm mv dirname cat tr basename sed awk grep head bash env; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN_NO_JQ/$b"
done
assert_allow "jq missing → degrades to allow" "Write" "$WT_G1/new.txt" "token-G1" "$BIN_NO_JQ"
assert_stderr_contains "jq-missing degrade warns on stderr" "jq missing"

# G2. $ATELIER_CONFIG_DIR unwritable (parent is a regular file, not a dir).
BLOCKER_FILE="$TMP/not-a-dir"
: > "$BLOCKER_FILE"
BAD_CFG="$BLOCKER_FILE/sub"
code="$(
  payload="$(jq -cn --arg f "$WT_G1/other.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$BAD_CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-G2" \
    "$BASH_BIN" "$HOOK" <<<"$payload" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code" = "0" ] && pass "unwritable \$ATELIER_CONFIG_DIR → degrades to allow" \
                   || fail "unwritable \$ATELIER_CONFIG_DIR expected exit 0, got $code"
assert_stderr_contains "unwritable-config-dir degrade warns on stderr" "unwritable"

# G3. No working `stat` — needs an existing FOREIGN FRESH claim so the
# hook actually reaches the stat call.
WT_G3="$TMP/repo7-wt-g3"
mk_worktree "$REPO7" "task/g3" "$WT_G3"
assert_allow "token G3-owner claims worktree G3 first" "Write" "$WT_G3/new.txt" "token-G3-owner"

BIN_NO_STAT="$TMP/bin-no-stat"
mkdir -p "$BIN_NO_STAT"
for b in jq git cksum date mkdir rm mv dirname cat tr basename sed awk grep head bash env; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN_NO_STAT/$b"
done
cat > "$BIN_NO_STAT/stat" <<'STATEOF'
#!/bin/sh
exit 1
STATEOF
chmod +x "$BIN_NO_STAT/stat"

assert_allow "no working stat (foreign fresh claim) → degrades to allow" \
  "Write" "$WT_G3/foreign.txt" "token-G3-other" "$BIN_NO_STAT"
assert_stderr_contains "no-working-stat degrade warns on stderr" "stat"

# G4. Target worktree gone — not inside any git worktree at all.
NO_REPO_DIR="$TMP/no-repo-here"
mkdir -p "$NO_REPO_DIR"
code="$(
  payload="$(jq -cn --arg f "$NO_REPO_DIR/f.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-G4" \
    "$BASH_BIN" "$HOOK" <<<"$payload" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code" = "0" ] && pass "target outside any git worktree → degrades to allow" \
                   || fail "target outside any git worktree expected exit 0, got $code"
assert_stderr_contains "worktree-gone degrade warns on stderr" "worktree gone"

# --- shared helper for the sections below -------------------------------

# Container id (git-common-dir, canonicalised) for a repo, matching the
# hook's own resolution exactly (relative git-common-dir joined onto the
# worktree it was resolved from, then canonicalised).
container_dir_of() {
  local repo="$1" c
  c="$(cd "$repo" && git rev-parse --git-common-dir)"
  case "$c" in
    /*) : ;;
    *) c="$(cd "$repo" && cd "$c" && pwd -P)" ;;
  esac
  printf '%s' "$c"
}

# Set a file's mtime to now-minus-N-seconds, portably (BSD `date -r`, then
# GNU `date -d @epoch`) — mirrors the hook's own BSD-then-GNU fallback
# style for `stat`. Never uses a fixed calendar date, since these tests
# need mtimes anchored close to "now" to exercise the TTL boundary.
touch_age() {
  local file="$1" age="$2" now target ts
  now="$(date +%s)"
  target=$((now - age))
  ts="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null)" || \
    ts="$(date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
  [ -n "$ts" ] && touch -t "$ts" "$file" 2>/dev/null
}

# Mirrors the hook's own BSD-then-GNU `_stat_mtime` fallback, for tests
# that assert on mtime deltas directly (section P).
_test_mtime() {
  local f="$1" m
  m="$(stat -f %m "$f" 2>/dev/null)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  m="$(stat -c %Y "$f" 2>/dev/null)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  return 1
}

# =============================================================================
# SECTION H — TTL boundary: just-inside (fresh, still denies) vs
# just-outside (stale, reclaimed) the SAME ownerTtlSeconds window, plus the
# TTL being read from the correct worktree's OWN .atelier.json.
# =============================================================================
echo
echo "-- section H: TTL boundary (just-inside vs just-outside) + correct .atelier.json source --"

REPO8="$TMP/repo8"
mk_repo "$REPO8"
WT8_CALLER="$TMP/repo8-wt-caller"
WT8_TARGET="$TMP/repo8-wt-target"
mk_worktree "$REPO8" "task/8-caller" "$WT8_CALLER"
mk_worktree "$REPO8" "task/8-target" "$WT8_TARGET"
printf '{"ownerTtlSeconds": 30}\n' > "$WT8_TARGET/.atelier.json"

# Token L8 owns a different worktree in the same container.
assert_allow "token L8 claims WT8_CALLER (owns something in this container)" \
  "Write" "$WT8_CALLER/new.txt" "token-L8"
# Token F8 claims the ttl=30 worktree.
assert_allow "token F8 claims WT8_TARGET (ttl=30)" "Write" "$WT8_TARGET/new.txt" "token-F8"

key8="$(enc "$(container_dir_of "$REPO8")")--$(enc "$WT8_TARGET")"
tokfile8="$CFG/state/worktree-owner/$key8/token"

# Just inside the window: age 27s < ttl 30s (margin 3s to absorb exec
# jitter between setting the mtime and the hook computing `now`) — still
# fresh, so L8 (who owns a different worktree here) is denied.
touch_age "$tokfile8" 27
assert_block "L8 writes into WT8_TARGET while F8's claim is fresh (age 27s < ttl 30s)" \
  "Write" "$WT8_TARGET/blocked-fresh.txt" "token-L8"

# Just outside the window: age 33s >= ttl 30s (same 3s margin) — now
# stale, reclaimed rather than denied.
touch_age "$tokfile8" 33
assert_allow "L8 writes into WT8_TARGET once F8's claim ages past ttl (age 33s >= ttl 30s) → reclaimed" \
  "Write" "$WT8_TARGET/reclaimed.txt" "token-L8"
owner8="$(cat "$tokfile8" 2>/dev/null || true)"
if [ "$owner8" = "token-L8" ]; then
  pass "WT8_TARGET ownership transferred to token-L8 after crossing the ttl boundary"
else
  fail "WT8_TARGET ownership did not transfer at the ttl boundary (now: $owner8)"
fi

# --- ttl is read from the TARGET's own .atelier.json, never a decoy at
#     the hook process's cwd ------------------------------------------------

REPO9="$TMP/repo9"
mk_repo "$REPO9"
WT9_CALLER="$TMP/repo9-wt-caller"
WT9_TARGET="$TMP/repo9-wt-target"
mk_worktree "$REPO9" "task/9-caller" "$WT9_CALLER"
mk_worktree "$REPO9" "task/9-target" "$WT9_TARGET"
printf '{"ownerTtlSeconds": 30}\n' > "$WT9_TARGET/.atelier.json"

DECOY_CWD="$TMP/decoy-cwd"
mkdir -p "$DECOY_CWD"
printf '{"ownerTtlSeconds": 1}\n' > "$DECOY_CWD/.atelier.json"

assert_allow "token L9 claims WT9_CALLER" "Write" "$WT9_CALLER/new.txt" "token-L9"
assert_allow "token F9 claims WT9_TARGET (ttl=30)" "Write" "$WT9_TARGET/new.txt" "token-F9"

key9="$(enc "$(container_dir_of "$REPO9")")--$(enc "$WT9_TARGET")"
tokfile9="$CFG/state/worktree-owner/$key9/token"
# age 10s: fresh under the TARGET's real ttl=30, but would read as stale
# (10 >= 1) if the hook ever mistakenly consulted a decoy .atelier.json at
# its own cwd instead of the target worktree's.
touch_age "$tokfile9" 10

payload9="$(jq -cn --arg f "$WT9_TARGET/blocked.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
code9="$(
  cd "$DECOY_CWD" && \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-L9" \
    "$BASH_BIN" "$HOOK" <<<"$payload9" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code9" = "2" ] && pass "ttl read from WT9_TARGET's own .atelier.json, not the hook's cwd (blocked as fresh)" \
                    || fail "expected exit 2 (target's own ttl=30 makes age=10 fresh), got $code9 — decoy cwd .atelier.json may have leaked in"

# --- candidate (the caller's OTHER owned worktree) freshness is judged by
#     THAT worktree's own ttl, not the target's or a hardcoded default ----

REPO10="$TMP/repo10"
mk_repo "$REPO10"
WT10_OTHER="$TMP/repo10-wt-other"   # caller's other claim; short ttl, goes stale fast
WT10_TARGET="$TMP/repo10-wt-target" # default ttl; freshly foreign-owned
mk_worktree "$REPO10" "task/10-other" "$WT10_OTHER"
mk_worktree "$REPO10" "task/10-target" "$WT10_TARGET"
printf '{"ownerTtlSeconds": 1}\n' > "$WT10_OTHER/.atelier.json"

assert_allow "token L10 claims WT10_OTHER (ttl=1)" "Write" "$WT10_OTHER/new.txt" "token-L10"
key10_other="$(enc "$(container_dir_of "$REPO10")")--$(enc "$WT10_OTHER")"
touch_age "$CFG/state/worktree-owner/$key10_other/token" 50 # 50s >= its own ttl=1 → L10's OTHER claim is itself stale now

assert_allow "token F10 claims WT10_TARGET (default ttl, fresh)" "Write" "$WT10_TARGET/new.txt" "token-F10"

assert_allow "L10 writes into WT10_TARGET (F10's, fresh) — allowed because L10's own OTHER claim (WT10_OTHER) is stale per ITS OWN ttl=1, not freshly owned anymore" \
  "Write" "$WT10_TARGET/allowed.txt" "token-L10"

# =============================================================================
# SECTION I — malformed on-disk state: empty token file, malformed/
# non-numeric ownerTtlSeconds
# =============================================================================
echo
echo "-- section I: malformed on-disk state degrades sanely, never crashes --"

REPO11="$TMP/repo11"
mk_repo "$REPO11"
WT11_EMPTY="$TMP/repo11-wt-empty"
mk_worktree "$REPO11" "task/11-empty" "$WT11_EMPTY"
key11_empty="$(enc "$(container_dir_of "$REPO11")")--$(enc "$WT11_EMPTY")"
mkdir -p "$CFG/state/worktree-owner/$key11_empty"
: > "$CFG/state/worktree-owner/$key11_empty/token" # claim dir + token file exist, but empty (corruption, not a race)

assert_allow "empty (corrupt) token file is treated as unowned, never a foreign owner" \
  "Write" "$WT11_EMPTY/new.txt" "token-anyone"

REPO12="$TMP/repo12"
mk_repo "$REPO12"
WT12_CALLER="$TMP/repo12-wt-caller"
WT12_BADJSON="$TMP/repo12-wt-badjson"
mk_worktree "$REPO12" "task/12-caller" "$WT12_CALLER"
mk_worktree "$REPO12" "task/12-badjson" "$WT12_BADJSON"
printf '{ this is not valid json' > "$WT12_BADJSON/.atelier.json"

assert_allow "token L12 claims WT12_CALLER" "Write" "$WT12_CALLER/new.txt" "token-L12"
assert_allow "token F12 claims WT12_BADJSON (malformed .atelier.json)" "Write" "$WT12_BADJSON/new.txt" "token-F12"
key12="$(enc "$(container_dir_of "$REPO12")")--$(enc "$WT12_BADJSON")"
# Fresh (age ~0s): malformed JSON must fall back to the DEFAULT ttl
# (43200s), not crash and not silently treat the claim as stale.
assert_block "malformed .atelier.json falls back to default ttl (claim stays fresh, still denied)" \
  "Write" "$WT12_BADJSON/blocked.txt" "token-L12"
# Far in the past: same malformed config, but old enough to be stale even
# under the (fallback) default ttl — proves the fallback default is a
# real number, not something that make the claim eternally fresh either.
touch -t 202001010000 "$CFG/state/worktree-owner/$key12/token" 2>/dev/null
assert_allow "malformed .atelier.json + very old claim still reclaims via the default ttl fallback" \
  "Write" "$WT12_BADJSON/reclaimed.txt" "token-L12"

REPO13="$TMP/repo13"
mk_repo "$REPO13"
WT13_CALLER="$TMP/repo13-wt-caller"
WT13_BADTTL="$TMP/repo13-wt-badttl"
mk_worktree "$REPO13" "task/13-caller" "$WT13_CALLER"
mk_worktree "$REPO13" "task/13-badttl" "$WT13_BADTTL"
printf '{"ownerTtlSeconds": "soon"}\n' > "$WT13_BADTTL/.atelier.json" # non-numeric

assert_allow "token L13 claims WT13_CALLER" "Write" "$WT13_CALLER/new.txt" "token-L13"
assert_allow "token F13 claims WT13_BADTTL (non-numeric ownerTtlSeconds)" "Write" "$WT13_BADTTL/new.txt" "token-F13"
assert_block "non-numeric ownerTtlSeconds falls back to default ttl (claim stays fresh, denied)" \
  "Write" "$WT13_BADTTL/blocked.txt" "token-L13"

# =============================================================================
# SECTION J — canonicalisation walks up to the nearest EXISTING ancestor
# for not-yet-existing, multi-level-deep Write targets
# =============================================================================
echo
echo "-- section J: deeply-nested not-yet-existing target paths resolve to the right worktree --"

REPO14="$TMP/repo14"
mk_repo "$REPO14"
WT14="$TMP/repo14-wt"
mk_worktree "$REPO14" "task/14" "$WT14"

assert_allow "self-claim via a 3-levels-deep not-yet-existing path" \
  "Write" "$WT14/brand/new/nested/file.txt" "token-N14"
key14="$(enc "$(container_dir_of "$REPO14")")--$(enc "$WT14")"
if [ -d "$CFG/state/worktree-owner/$key14" ]; then
  pass "deep not-yet-existing target resolved to WT14 itself, not some other ancestor"
else
  fail "deep not-yet-existing target did not resolve to the expected worktree key"
fi
# A second, different worktree in the same container, freshly owned by a
# different token — a deep not-yet-existing target under it must still be
# correctly recognised as a DIFFERENT worktree and get the categorical deny.
WT14B="$TMP/repo14-wt-b"
mk_worktree "$REPO14" "task/14b" "$WT14B"
assert_allow "token M14 claims WT14B" "Write" "$WT14B/new.txt" "token-M14"
assert_block "token N14 (owns WT14) writes a deep not-yet-existing path under WT14B (M14's) → denied" \
  "Write" "$WT14B/brand/new/nested/blocked.txt" "token-N14"

# =============================================================================
# SECTION K — paths containing spaces
# =============================================================================
echo
echo "-- section K: worktree paths and filenames containing spaces --"

REPO15="$TMP/repo one five"
mk_repo "$REPO15"
WT15_A="$TMP/repo one five-wt a"
WT15_B="$TMP/repo one five-wt b"
mk_worktree "$REPO15" "task/15-a" "$WT15_A"
mk_worktree "$REPO15" "task/15-b" "$WT15_B"

assert_allow "self-claim into a worktree path with a space, filename with a space" \
  "Write" "$WT15_A/new file.txt" "token-SP1"
assert_allow "token SP2 claims the sibling space-y worktree" \
  "Write" "$WT15_B/new file.txt" "token-SP2"
assert_block "cross-worktree deny still fires correctly across space-containing paths" \
  "Write" "$WT15_B/blocked file.txt" "token-SP1"

# =============================================================================
# SECTION L — concurrency: N parallel first-writers racing one unclaimed
# worktree. Design guarantees every branch here exits 0 regardless of
# interleaving (see the hook's in-flight-race comment) — this asserts that
# in practice, across real parallel processes, exactly one owner ends up
# recorded and no empty/partial claim state is left behind.
# =============================================================================
echo
echo "-- section L: concurrent claims on one unclaimed worktree --"

REPO16="$TMP/repo16"
mk_repo "$REPO16"
WT16="$TMP/repo16-wt"
mk_worktree "$REPO16" "task/16" "$WT16"

RACE_N=6
i=1
while [ "$i" -le "$RACE_N" ]; do
  (
    payload="$(jq -cn --arg f "$WT16/racer-$i.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    CLAUDE_CODE_BRIDGE_SESSION_ID="token-racer-$i" \
      "$BASH_BIN" "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/race-stderr-$i"
    echo $? > "$TMP/race-rc-$i"
  ) &
  i=$((i + 1))
done
wait

race_all_ok=1
i=1
while [ "$i" -le "$RACE_N" ]; do
  rc="$(cat "$TMP/race-rc-$i" 2>/dev/null || echo missing)"
  if [ "$rc" != "0" ]; then
    race_all_ok=0
    fail "racer $i expected exit 0, got $rc (stderr: $(cat "$TMP/race-stderr-$i" 2>/dev/null))"
  fi
  i=$((i + 1))
done
[ "$race_all_ok" -eq 1 ] && pass "all $RACE_N concurrent racers were allowed (exit 0)"

key16="$(enc "$(container_dir_of "$REPO16")")--$(enc "$WT16")"
claimdir16="$CFG/state/worktree-owner/$key16"
if [ -d "$claimdir16" ] && [ -f "$claimdir16/token" ] && [ -s "$claimdir16/token" ]; then
  pass "exactly one claim dir exists for WT16 with a non-empty token file (no empty-owner state left behind)"
else
  fail "WT16 claim state is missing or empty after the race ($claimdir16)"
fi
winner16="$(cat "$claimdir16/token" 2>/dev/null || true)"
case "$winner16" in
  token-racer-*)
    pass "the recorded owner (\"$winner16\") is one of the $RACE_N racers, not a stray value"
    ;;
  *)
    fail "recorded owner \"$winner16\" does not match any racer token"
    ;;
esac
# Only ONE claim directory should exist for this worktree/container pair —
# confirm there's no sibling directory for the same key (would indicate a
# non-atomic claim).
n_claimdirs16="$(find "$CFG/state/worktree-owner" -maxdepth 1 -type d -name "$key16*" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_claimdirs16" = "1" ] && pass "exactly one claim directory exists for WT16's key (atomic mkdir held)" \
                            || fail "expected exactly 1 claim directory for WT16's key, found $n_claimdirs16"

# =============================================================================
# SECTION M — session-token resolution order and the "no stable token"
# path writing NO state at all
# =============================================================================
echo
echo "-- section M: token source order (bridge env > payload.session_id > transcript_path dir > none) --"

REPO17="$TMP/repo17"
mk_repo "$REPO17"
WT17A="$TMP/repo17-wt-a"
WT17B="$TMP/repo17-wt-b"
WT17C="$TMP/repo17-wt-c"
mk_worktree "$REPO17" "task/17-a" "$WT17A"
mk_worktree "$REPO17" "task/17-b" "$WT17B"
mk_worktree "$REPO17" "task/17-c" "$WT17C"

# M1: no CLAUDE_CODE_BRIDGE_SESSION_ID, payload carries session_id → used.
payload_m1="$(jq -cn --arg f "$WT17A/new.txt" --arg sid "sess-fallback-payload" \
  '{tool_name:"Write", tool_input:{file_path:$f}, session_id:$sid}')"
code_m1="$(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload_m1" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_m1" = "0" ] && pass "no bridge env, payload.session_id used as fallback token → allowed" \
                      || fail "expected exit 0, got $code_m1"
key17a="$(enc "$(container_dir_of "$REPO17")")--$(enc "$WT17A")"
owner_m1="$(cat "$CFG/state/worktree-owner/$key17a/token" 2>/dev/null || true)"
[ "$owner_m1" = "sess-fallback-payload" ] && pass "claim recorded under payload.session_id (\"sess-fallback-payload\")" \
                                            || fail "expected owner sess-fallback-payload, got \"$owner_m1\""

# M2: no bridge env, no session_id → falls back to dirname(transcript_path).
TRANSCRIPT_DIR="$TMP/faux-transcripts/abc123"
mkdir -p "$TRANSCRIPT_DIR"
payload_m2="$(jq -cn --arg f "$WT17B/new.txt" --arg tp "$TRANSCRIPT_DIR/session.jsonl" \
  '{tool_name:"Write", tool_input:{file_path:$f}, transcript_path:$tp}')"
code_m2="$(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload_m2" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_m2" = "0" ] && pass "no bridge env, no session_id, transcript_path dir used as fallback token → allowed" \
                      || fail "expected exit 0, got $code_m2"
key17b="$(enc "$(container_dir_of "$REPO17")")--$(enc "$WT17B")"
owner_m2="$(cat "$CFG/state/worktree-owner/$key17b/token" 2>/dev/null || true)"
[ "$owner_m2" = "$TRANSCRIPT_DIR" ] && pass "claim recorded under dirname(transcript_path) (\"$TRANSCRIPT_DIR\")" \
                                      || fail "expected owner \"$TRANSCRIPT_DIR\", got \"$owner_m2\""

# M3: none of bridge env / session_id / transcript_path present → always
# allow, and — since there is no stable identity to claim with — NO state
# is written for this worktree at all.
payload_m3="$(jq -cn --arg f "$WT17C/new.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
code_m3="$(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload_m3" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_m3" = "0" ] && pass "no stable token available anywhere → allowed" \
                      || fail "expected exit 0, got $code_m3"
key17c="$(enc "$(container_dir_of "$REPO17")")--$(enc "$WT17C")"
if [ -d "$CFG/state/worktree-owner/$key17c" ]; then
  fail "no-stable-token path must not write any claim state, but $key17c exists"
else
  pass "no-stable-token path wrote no claim state at all for WT17C"
fi

# =============================================================================
# SECTION N — $ATELIER_CONFIG_DIR unset: default path resolves and works
# normally; when that DEFAULT path is itself unwritable, degrades to allow
# =============================================================================
echo
echo "-- section N: unset \$ATELIER_CONFIG_DIR (default \$HOME/.claude-work) --"

REPO18="$TMP/repo18"
mk_repo "$REPO18"
WT18A="$TMP/repo18-wt-a"
mk_worktree "$REPO18" "task/18-a" "$WT18A"

FAKE_HOME_OK="$TMP/fake-home-ok"
mkdir -p "$FAKE_HOME_OK"
payload_n1="$(jq -cn --arg f "$WT18A/new.txt" --arg sid "sess-n1" '{tool_name:"Write", tool_input:{file_path:$f}, session_id:$sid}')"
code_n1="$(
  unset ATELIER_CONFIG_DIR CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" HOME="$FAKE_HOME_OK" \
    "$BASH_BIN" "$HOOK" <<<"$payload_n1" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_n1" = "0" ] && pass "unset \$ATELIER_CONFIG_DIR + writable \$HOME → claims normally under \$HOME/.claude-work" \
                      || fail "expected exit 0, got $code_n1"
if [ ! -s "$TMP/last_stderr" ]; then
  pass "unset \$ATELIER_CONFIG_DIR with a writable default is NOT a degraded path (no warning printed)"
else
  fail "unexpected stderr for the normal default-path case: $(cat "$TMP/last_stderr")"
fi
[ -d "$FAKE_HOME_OK/.claude-work/state/worktree-owner" ] && pass "claim state written under the default \$HOME/.claude-work" \
                                                           || fail "expected claim state under \$FAKE_HOME_OK/.claude-work"

WT18B="$TMP/repo18-wt-b"
mk_worktree "$REPO18" "task/18-b" "$WT18B"
FAKE_HOME_BAD="$TMP/fake-home-bad"
mkdir -p "$FAKE_HOME_BAD"
: > "$FAKE_HOME_BAD/.claude-work" # regular file where the default state dir needs to be a directory

# Must carry a resolvable token (payload session_id) since the ambient
# bridge var is stripped below — otherwise the hook's "no stable token"
# early-exit (always allow, no stderr) fires before ever attempting the
# state-dir mkdir this case means to exercise.
payload_n2="$(jq -cn --arg f "$WT18B/new.txt" --arg sid "sess-n2" '{tool_name:"Write", tool_input:{file_path:$f}, session_id:$sid}')"
code_n2="$(
  unset ATELIER_CONFIG_DIR CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" HOME="$FAKE_HOME_BAD" \
    "$BASH_BIN" "$HOOK" <<<"$payload_n2" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_n2" = "0" ] && pass "unset \$ATELIER_CONFIG_DIR + unwritable default \$HOME/.claude-work → degrades to allow" \
                      || fail "expected exit 0, got $code_n2"
assert_stderr_contains "unwritable default-path degrade warns on stderr" "unwritable"

# =============================================================================
# SECTION O — explicit unblocker Step 5 / task-orchestrator Step 8
# main-checkout scenarios, including the "owns MULTIPLE task worktrees at
# once" shape a babysit-prs fan-out pass produces
# =============================================================================
echo
echo "-- section O: unblocker Step 5 / task-orchestrator Step 8 main-checkout edits, multi-worktree owner --"

REPO19="$TMP/repo19"
mk_repo "$REPO19"
WT19_TASK1="$TMP/repo19-wt-task1"
WT19_TASK2="$TMP/repo19-wt-task2"
mk_worktree "$REPO19" "task/19-one" "$WT19_TASK1"
mk_worktree "$REPO19" "task/19-two" "$WT19_TASK2"

# A single babysit-prs pass owning TWO task worktrees at once (per the
# hook's own header comment: ownership is per-worktree, not per-session).
assert_allow "babysit token owns task worktree 1" "Write" "$WT19_TASK1/f.txt" "token-BABYSIT"
assert_allow "babysit token owns task worktree 2" "Write" "$WT19_TASK2/f.txt" "token-BABYSIT"

# unblocker Step 5: edit IN_PROGRESS.md on the MAIN worktree (REPO19
# itself) to add the [BLOCKED] marker, while the same session still owns
# both task worktrees above.
assert_allow "unblocker Step 5 — IN_PROGRESS.md edit on the main checkout, while owning 2 task worktrees" \
  "Edit" "$REPO19/IN_PROGRESS.md" "token-BABYSIT"

# task-orchestrator Step 8: the [OVERSIZE] marker edit also lands directly
# on the main checkout's ROADMAP.md — same shape, different file.
assert_allow "task-orchestrator Step 8 — ROADMAP.md [OVERSIZE] marker edit on the main checkout" \
  "Edit" "$REPO19/ROADMAP.md" "token-BABYSIT"

# =============================================================================
# SECTION P — mtime refresh on every accepted self-owned write (review
# finding 2, active-owner half): staleness must track ACTIVITY, not just
# time since the first claim.
# =============================================================================
echo
echo "-- section P: owner's own claim mtime refreshes on each accepted write --"

REPO20="$TMP/repo20"
mk_repo "$REPO20"
WT20="$TMP/repo20-wt"
mk_worktree "$REPO20" "task/20" "$WT20"
printf '{"ownerTtlSeconds": 30}\n' > "$WT20/.atelier.json"

assert_allow "token P20 claims WT20 (ttl=30)" "Write" "$WT20/new.txt" "token-P20"
key20="$(enc "$(container_dir_of "$REPO20")")--$(enc "$WT20")"
tokfile20="$CFG/state/worktree-owner/$key20/token"

# Age the claim to just inside the window, then have the SAME owner write
# again — this must refresh the mtime back to "now" rather than merely
# re-allowing on the stale/foreign-owner branches.
touch_age "$tokfile20" 25
mtime_before="$(_test_mtime "$tokfile20")"
assert_allow "same owner (token-P20) writes again while its own claim is aging" \
  "Write" "$WT20/again.txt" "token-P20"
mtime_after="$(_test_mtime "$tokfile20")"
if [ -n "$mtime_after" ] && [ "$mtime_after" -gt "$mtime_before" ]; then
  pass "owner's own accepted write refreshed the claim's mtime ($mtime_before -> $mtime_after)"
else
  fail "expected the claim mtime to advance past $mtime_before on the owner's own write, got $mtime_after"
fi

# A THIRD party (different token, no other worktree owned) must still be
# freely allowed against a self-refreshed claim — refreshing never denies
# anyone by itself; only the pre-existing cross-worktree rule can.
assert_allow "unrelated token (owns nothing) still allowed against WT20 after the refresh" \
  "Write" "$WT20/third-party.txt" "token-P20-UNRELATED"

# P continued (a): the refresh `touch` is best-effort — a broken/missing
# `touch` binary must never turn the owner's own accepted write into a
# denial or a crash (fail-open on the new refresh path itself).
BIN_NO_TOUCH="$TMP/bin-no-touch"
mkdir -p "$BIN_NO_TOUCH"
for b in jq git cksum stat date mkdir rm mv dirname cat tr basename sed awk grep head bash env; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN_NO_TOUCH/$b"
done
cat > "$BIN_NO_TOUCH/touch" <<'TOUCHEOF'
#!/bin/sh
exit 1
TOUCHEOF
chmod +x "$BIN_NO_TOUCH/touch"

assert_allow "same owner writes again with a broken touch binary — refresh failure never blocks the write" \
  "Write" "$WT20/no-touch-refresh.txt" "token-P20" "$BIN_NO_TOUCH"

# P continued (b): an owner that goes INACTIVE (writes once, then never
# again) must still go stale at the ttl boundary exactly as before the
# refresh existed — the refresh only ever pushes staleness further away
# when writes keep happening; it must never mask a genuinely abandoned claim.
REPO20B="$TMP/repo20b"
mk_repo "$REPO20B"
WT20B_OWNER="$TMP/repo20b-wt-owner"
WT20B_OTHER="$TMP/repo20b-wt-other"
mk_worktree "$REPO20B" "task/20b-owner" "$WT20B_OWNER"
mk_worktree "$REPO20B" "task/20b-other" "$WT20B_OTHER"
printf '{"ownerTtlSeconds": 5}\n' > "$WT20B_OWNER/.atelier.json"

assert_allow "token P20B claims WT20B_OWNER (ttl=5) then goes inactive" \
  "Write" "$WT20B_OWNER/new.txt" "token-P20B"
key20b="$(enc "$(container_dir_of "$REPO20B")")--$(enc "$WT20B_OWNER")"
tokfile20b="$CFG/state/worktree-owner/$key20b/token"

assert_allow "token P20B-CONTENDER claims WT20B_OTHER (a different worktree, same container)" \
  "Write" "$WT20B_OTHER/new.txt" "token-P20B-CONTENDER"

assert_block "contender denied while the inactive owner's claim is still fresh (no writes yet, well under ttl=5)" \
  "Write" "$WT20B_OWNER/blocked.txt" "token-P20B-CONTENDER"

# Age the inactive owner's claim past its own ttl=5 — since it never wrote
# again (no refresh fired), it must go stale exactly as pre-refresh.
touch_age "$tokfile20b" 8
assert_allow "contender's write is allowed once the inactive owner's claim ages past ttl=5 (reclaimed — inactivity was never masked by the refresh)" \
  "Write" "$WT20B_OWNER/reclaimed-after-inactivity.txt" "token-P20B-CONTENDER"

# =============================================================================
# SECTION Q — Stop-event claim release resolves the dead-owner lockout
# (review finding 2, session-ended half). Reviewer's exact repro: R1 claims
# worktree-a, R1's session ends (Stop fires), R2 claims worktree-b, R2
# edits worktree-a -> must be ALLOWED because R1's claim was released on
# Stop, not left to age out via ownerTtlSeconds.
# =============================================================================
echo
echo "-- section Q: Stop hook releases the caller's claims (dead-owner lockout fix) --"

run_stop() {
  local token="$1"
  local payload rc
  payload="$(jq -cn '{hook_event_name:"Stop", session_id:"stop-sess", transcript_path:"/tmp/does-not-exist-stop.jsonl"}')"
  (
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export CLAUDE_PROJECT_DIR="$TMP/logs"
    export ATELIER_CONFIG_DIR="$CFG"
    export CLAUDE_CODE_BRIDGE_SESSION_ID="$token"
    "$BASH_BIN" "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/last_stderr"
  )
  rc=$?
  echo "$rc"
}

REPO21="$TMP/repo21"
mk_repo "$REPO21"
WT21_A="$TMP/repo21-wt-a"
WT21_B="$TMP/repo21-wt-b"
mk_worktree "$REPO21" "task/21-a" "$WT21_A"
mk_worktree "$REPO21" "task/21-b" "$WT21_B"

assert_allow "R1 (token-R1) claims worktree-a" "Write" "$WT21_A/f.txt" "token-R1"

stop_code="$(run_stop "token-R1")"
[ "$stop_code" = "0" ] && pass "Stop hook for R1 exits 0" || fail "Stop hook for R1 expected exit 0, got $stop_code"

key21a="$(enc "$(container_dir_of "$REPO21")")--$(enc "$WT21_A")"
if [ ! -d "$CFG/state/worktree-owner/$key21a" ]; then
  pass "R1's claim on worktree-a was released by the Stop hook"
else
  fail "R1's claim on worktree-a is still present after Stop"
fi

assert_allow "R2 (token-R2) claims worktree-b (unrelated task)" "Write" "$WT21_B/f.txt" "token-R2"

# The reviewer's repro: R2 now edits worktree-a. Before this fix this was a
# false-positive BLOCK against a dead owner; after the Stop-release it must
# be allowed outright (worktree-a is unclaimed again).
assert_allow "R2 edits worktree-a after R1's Stop-released claim — no false-positive lockout" \
  "Write" "$WT21_A/from-r2.txt" "token-R2"

# A Stop event with no matching claims anywhere is a pure no-op.
REPO22="$TMP/repo22"
mk_repo "$REPO22"
stop_noop_code="$(run_stop "token-never-claimed-anything")"
[ "$stop_noop_code" = "0" ] && pass "Stop hook for a token owning nothing is a no-op (exit 0)" \
                             || fail "Stop hook no-op case expected exit 0, got $stop_noop_code"

# A Stop event releases EVERY claim the token holds, not just one worktree
# (mirrors section O's multi-worktree-owner shape).
REPO23="$TMP/repo23"
mk_repo "$REPO23"
WT23_ONE="$TMP/repo23-wt-one"
WT23_TWO="$TMP/repo23-wt-two"
mk_worktree "$REPO23" "task/23-one" "$WT23_ONE"
mk_worktree "$REPO23" "task/23-two" "$WT23_TWO"
assert_allow "token-MULTI claims worktree-one" "Write" "$WT23_ONE/f.txt" "token-MULTI"
assert_allow "token-MULTI claims worktree-two" "Write" "$WT23_TWO/f.txt" "token-MULTI"
run_stop "token-MULTI" >/dev/null
key23one="$(enc "$(container_dir_of "$REPO23")")--$(enc "$WT23_ONE")"
key23two="$(enc "$(container_dir_of "$REPO23")")--$(enc "$WT23_TWO")"
if [ ! -d "$CFG/state/worktree-owner/$key23one" ] && [ ! -d "$CFG/state/worktree-owner/$key23two" ]; then
  pass "Stop released BOTH claims held by the same token in one pass"
else
  fail "Stop left at least one of token-MULTI's claims behind"
fi

# A non-matching token's claim must survive an unrelated Stop event.
REPO24="$TMP/repo24"
mk_repo "$REPO24"
WT24="$TMP/repo24-wt"
mk_worktree "$REPO24" "task/24" "$WT24"
assert_allow "token-SURVIVES claims worktree24" "Write" "$WT24/f.txt" "token-SURVIVES"
run_stop "token-UNRELATED-STOP" >/dev/null
key24="$(enc "$(container_dir_of "$REPO24")")--$(enc "$WT24")"
[ -d "$CFG/state/worktree-owner/$key24" ] && pass "an unrelated token's Stop event never releases someone else's claim" \
                                            || fail "unrelated Stop event incorrectly released token-SURVIVES's claim"

# Q continued (a): Stop is idempotent — firing it twice for the same token
# must not error or misbehave the second time (nothing left to release).
REPO_QI="$TMP/repoQI"
mk_repo "$REPO_QI"
WT_QI="$TMP/repoQI-wt"
mk_worktree "$REPO_QI" "task/qi" "$WT_QI"
assert_allow "token-QI claims WT_QI" "Write" "$WT_QI/f.txt" "token-QI"
stop1_code="$(run_stop "token-QI")"
stop2_code="$(run_stop "token-QI")"
[ "$stop1_code" = "0" ] && [ "$stop2_code" = "0" ] && pass "double Stop for the same token is idempotent (both exit 0)" \
                                                     || fail "double Stop expected 0/0, got $stop1_code/$stop2_code"

# Q continued (b): Stop fails open on its OWN missing dependency (jq) —
# same posture as the PreToolUse path, but never independently verified for
# the Stop branch until now.
stop_payload_jq="$(jq -cn '{hook_event_name:"Stop", session_id:"stop-jq", transcript_path:"/tmp/does-not-exist-jq.jsonl"}')"
code_stop_jq="$(
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  export CLAUDE_PROJECT_DIR="$TMP/logs"
  export ATELIER_CONFIG_DIR="$CFG"
  export CLAUDE_CODE_BRIDGE_SESSION_ID="token-stop-jq"
  export PATH="$BIN_NO_JQ"
  "$BASH_BIN" "$HOOK" <<<"$stop_payload_jq" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_stop_jq" = "0" ] && pass "Stop event degrades to allow when jq is missing" \
                           || fail "Stop event with jq missing expected exit 0, got $code_stop_jq"
assert_stderr_contains "Stop jq-missing degrade warns on stderr" "jq missing"

# Q continued (c): Stop with NO state dir at all yet (never created by any
# prior claim) is a clean no-op, not an error.
FRESH_CFG_Q="$TMP/fresh-cfg-q"
mkdir -p "$FRESH_CFG_Q"
stop_payload_fresh="$(jq -cn '{hook_event_name:"Stop", session_id:"stop-fresh"}')"
code_stop_fresh="$(
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  export CLAUDE_PROJECT_DIR="$TMP/logs"
  export ATELIER_CONFIG_DIR="$FRESH_CFG_Q"
  export CLAUDE_CODE_BRIDGE_SESSION_ID="token-never-owned-anything"
  "$BASH_BIN" "$HOOK" <<<"$stop_payload_fresh" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_stop_fresh" = "0" ] && pass "Stop event with no state/worktree-owner dir at all is a clean no-op" \
                              || fail "Stop with no state dir expected exit 0, got $code_stop_fresh"

# Q continued (d): a malformed (empty) token file inside a claim dir must
# not be released (it can never match a real caller token) and must not
# crash Stop — same corruption shape as section I, exercised here on Stop.
REPO_QM="$TMP/repoQM"
mk_repo "$REPO_QM"
WT_QM="$TMP/repoQM-wt"
mk_worktree "$REPO_QM" "task/qm" "$WT_QM"
key_qm="$(enc "$(container_dir_of "$REPO_QM")")--$(enc "$WT_QM")"
mkdir -p "$CFG/state/worktree-owner/$key_qm"
: > "$CFG/state/worktree-owner/$key_qm/token" # empty/corrupt — never a valid match
stop_qm_code="$(run_stop "token-anyone")"
[ "$stop_qm_code" = "0" ] && pass "Stop with a malformed (empty) token file in a claim dir does not crash" \
                           || fail "Stop with malformed token file expected exit 0, got $stop_qm_code"
[ -d "$CFG/state/worktree-owner/$key_qm" ] && pass "malformed token file's claim dir is left untouched (never falsely matched/released)" \
                                             || fail "malformed token file's claim dir was unexpectedly removed"

# Q continued (e): Stop degrades to a clean no-op (never errors, never
# denies — there's no deny path on Stop at all) when the state dir exists
# but is not writable (rm -rf of a claim entry fails).
REPO_QU="$TMP/repoQU"
mk_repo "$REPO_QU"
WT_QU="$TMP/repoQU-wt"
mk_worktree "$REPO_QU" "task/qu" "$WT_QU"
assert_allow "token-QU claims WT_QU" "Write" "$WT_QU/f.txt" "token-QU"
STATE_DIR_Q="$CFG/state/worktree-owner"
chmod 555 "$STATE_DIR_Q" 2>/dev/null
stop_qu_code="$(run_stop "token-QU")"
chmod 755 "$STATE_DIR_Q" 2>/dev/null # restore immediately — later sections need write access
[ "$stop_qu_code" = "0" ] && pass "Stop still exits 0 when the state dir is not writable (claim removal fails silently)" \
                           || fail "Stop with unwritable state dir expected exit 0, got $stop_qu_code"

# =============================================================================
# SECTION R — token_source is logged on every decision (review finding 3):
# the operator must be able to see which resolution tier fired, since
# nothing in this repo sets CLAUDE_CODE_BRIDGE_SESSION_ID by default and the
# payload-session_id fallback silently weakens cross-worktree protection.
# =============================================================================
echo
echo "-- section R: token-source recorded in the hook decision log --"

REPO25="$TMP/repo25"
mk_repo "$REPO25"
WT25="$TMP/repo25-wt"
mk_worktree "$REPO25" "task/25" "$WT25"
LOGDIR25="$TMP/logs25"
mkdir -p "$LOGDIR25"

payload25="$(jq -cn --arg f "$WT25/new.txt" --arg sid "sess-25" '{tool_name:"Write", tool_input:{file_path:$f}, session_id:$sid}')"
(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$LOGDIR25" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload25" >/dev/null 2>/dev/null
)
if grep -q 'token-source: payload-session-id' "$LOGDIR25/.task-log/hook-decisions.jsonl" 2>/dev/null; then
  pass "log_decision records token-source: payload-session-id when the bridge env is absent"
else
  fail "expected a hook-decisions.jsonl line recording token-source: payload-session-id under $LOGDIR25"
fi

# R continued (a): the transcript-parent-dir fallback source is logged too
# (third of the four token_source values, mirroring section M2's scenario).
REPO25T="$TMP/repo25t"
mk_repo "$REPO25T"
WT25T="$TMP/repo25t-wt"
mk_worktree "$REPO25T" "task/25t" "$WT25T"
LOGDIR25T="$TMP/logs25t"
mkdir -p "$LOGDIR25T"
TRANSCRIPT_DIR25T="$TMP/faux-transcripts-25t/xyz"
mkdir -p "$TRANSCRIPT_DIR25T"

payload25t="$(jq -cn --arg f "$WT25T/new.txt" --arg tp "$TRANSCRIPT_DIR25T/session.jsonl" \
  '{tool_name:"Write", tool_input:{file_path:$f}, transcript_path:$tp}')"
(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$LOGDIR25T" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload25t" >/dev/null 2>/dev/null
)
if grep -q 'token-source: transcript-parent-dir' "$LOGDIR25T/.task-log/hook-decisions.jsonl" 2>/dev/null; then
  pass "log_decision records token-source: transcript-parent-dir when bridge env and session_id are both absent"
else
  fail "expected a hook-decisions.jsonl line recording token-source: transcript-parent-dir under $LOGDIR25T"
fi

# R continued (b): "none" (no resolvable token at all) is the one value
# that is NEVER logged — the hook exits before reaching any log_decision
# call in that case (nothing was decided about a claim). Confirmed by
# checking a dedicated, otherwise-untouched project log directory.
REPO25N="$TMP/repo25n"
mk_repo "$REPO25N"
WT25N="$TMP/repo25n-wt"
mk_worktree "$REPO25N" "task/25n" "$WT25N"
LOGDIR25N="$TMP/logs25n"
mkdir -p "$LOGDIR25N"
payload25n="$(jq -cn --arg f "$WT25N/new.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$LOGDIR25N" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload25n" >/dev/null 2>/dev/null
)
if [ ! -s "$LOGDIR25N/.task-log/hook-decisions.jsonl" ]; then
  pass "token-source: none is never logged — the hook exits before any log_decision call with no resolvable token"
else
  fail "expected no (or empty) hook-decisions.jsonl under $LOGDIR25N when no token resolves, got: $(cat "$LOGDIR25N/.task-log/hook-decisions.jsonl" 2>/dev/null)"
fi

# R continued (c): the block, reclaim, and Stop-release decisions also
# thread token_source through — not just the claim path asserted above.
# Reused from the shared log ($TMP/logs/.task-log/hook-decisions.jsonl,
# CLAUDE_PROJECT_DIR for every run_hook/run_stop call throughout this whole
# file), which by now contains real examples of all three from sections A
# (block), C/H/I (reclaim) and Q (Stop-release) — all driven via
# run_hook/run_stop, which set CLAUDE_CODE_BRIDGE_SESSION_ID explicitly, so
# every line below is expected to read token-source: bridge-env.
SHARED_LOG="$TMP/logs/.task-log/hook-decisions.jsonl"
if grep -q 'claimed .*(token-source: bridge-env)' "$SHARED_LOG" 2>/dev/null; then
  pass "a claim decision in the shared log records token-source: bridge-env"
else
  fail "expected at least one claim decision logging token-source: bridge-env in $SHARED_LOG"
fi
if grep -q 'owned by a foreign fresh session.*(token-source: bridge-env)' "$SHARED_LOG" 2>/dev/null; then
  pass "a block decision records token-source: bridge-env"
else
  fail "expected at least one block decision logging token-source: bridge-env in $SHARED_LOG"
fi
if grep -q 'reclaimed stale claim.*(token-source: bridge-env)' "$SHARED_LOG" 2>/dev/null; then
  pass "a reclaim decision records token-source: bridge-env"
else
  fail "expected at least one reclaim decision logging token-source: bridge-env in $SHARED_LOG"
fi
if grep -q 'released claim on.*(token-source: bridge-env)' "$SHARED_LOG" 2>/dev/null; then
  pass "a Stop-release decision records token-source: bridge-env"
else
  fail "expected at least one Stop-release decision logging token-source: bridge-env in $SHARED_LOG"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All #196a block-cross-worktree-edit regression checks passed."
  exit 0
else
  echo "$fails #196a block-cross-worktree-edit regression check(s) FAILED."
  exit 1
fi
