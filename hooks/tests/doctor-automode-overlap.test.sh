#!/usr/bin/env bash
#
# Regression test for #646 — atelier-doctor check_automode_handwritten_overlap().
#
#   D1 verbatim duplicate of a managed entry body        -> WARN "duplicates the managed entry <id>"
#   D2 case / whitespace variant of the managed body     -> same duplicate WARN
#   O1 overlap, managed id present in the same array     -> WARN "overlaps the managed entry <id> (both cover "<sig>")"
#   O2 same hand-written text, managed id absent         -> no warning, OK line
#   O3 managed id present only in a different array      -> no warning
#   O4 per-id signatures (merge, dispatch, gate-runs, catalog-pin, trusted-repos)
#   N1 unrelated entries, "$defaults", "### " headers    -> no warning, OK line
#   Q1 settings.json invalid / absent / no autoMode      -> quiet (no output at all, or OK only for no autoMode)
#   R1 settings.json byte-identical after every run
#   R2 push_fix_auto never called; one push_fix_manual per finding
#
# Hermetic: the function is extracted from scripts/atelier-doctor and run with
# push_* stubs against fixtures in a scratch ATELIER_CONFIG_DIR. No network.
#
# Run:  hooks/tests/doctor-automode-overlap.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

FN_FILE="$TMP/fn.sh"
awk '/^check_automode_handwritten_overlap\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" > "$FN_FILE"
grep -q 'check_automode_handwritten_overlap()' "$FN_FILE" || { echo "  FAIL: could not extract check_automode_handwritten_overlap from $DOCTOR"; exit 1; }
# shellcheck disable=SC1090
source "$FN_FILE"

HOST_OUT="$TMP/host_out"; AUTO_OUT="$TMP/auto_out"; MANUAL_OUT="$TMP/manual_out"
push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_auto()   { printf '%s\n' "$*" >> "$AUTO_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$MANUAL_OUT"; }
export OK="OKMARK" WARN="WARNMARK" SKIP="SKIPMARK" FAIL="FAILMARK"

# run <name> <settings-json|NONE>; runs the check and asserts R1/R2.
run() {
  rm -f "$HOST_OUT" "$AUTO_OUT" "$MANUAL_OUT"; touch "$HOST_OUT" "$MANUAL_OUT"
  ATELIER_CONFIG_DIR="$TMP/$1"; mkdir -p "$ATELIER_CONFIG_DIR"
  if [ "$2" != NONE ]; then
    printf '%s\n' "$2" > "$ATELIER_CONFIG_DIR/settings.json"
    cp "$ATELIER_CONFIG_DIR/settings.json" "$TMP/$1.orig"
  fi
  check_automode_handwritten_overlap
  if [ "$2" != NONE ]; then
    cmp -s "$ATELIER_CONFIG_DIR/settings.json" "$TMP/$1.orig" \
      && [ -z "$(find "$ATELIER_CONFIG_DIR" -name 'settings.json.*')" ] \
      && pass "R1/$1: settings.json byte-identical, no temp files" || fail "R1/$1: file changed or temp left"
  else
    [ ! -e "$ATELIER_CONFIG_DIR/settings.json" ] && pass "R1/$1: settings.json not created" || fail "R1/$1: file created"
  fi
  [ ! -s "$AUTO_OUT" ] && pass "R2/$1: no push_fix_auto registered" || fail "R2/$1: auto fix registered: $(cat "$AUTO_OUT")"
}
warns() { grep -c '^WARNMARK' "$HOST_OUT"; }
fixes() { grep -c . "$MANUAL_OUT"; }

echo "atelier-doctor check_automode_handwritten_overlap (#646)"

# D1: verbatim duplicate
run d1 "$(jq -nc '{autoMode:{allow:["$defaults","[atelier-managed:gate-runs] Run pnpm test is allowed","Run pnpm test is allowed"]}}')"
grep -q '^WARNMARK user settings autoMode.allow\[2\] duplicates the managed entry gate-runs' "$HOST_OUT" \
  && [ "$(warns)" -eq 1 ] && [ "$(fixes)" -eq 1 ] && grep -q 'autoMode.allow\[2\]' "$MANUAL_OUT" \
  && ! grep -q 'overlaps' "$HOST_OUT" \
  && pass "D1: verbatim duplicate -> one duplicate WARN at index 2 + one manual fix" || fail "D1: (host: $(cat "$HOST_OUT") manual: $(cat "$MANUAL_OUT"))"

# D2: case / whitespace variant, in soft_deny
run d2 "$(jq -nc '{autoMode:{soft_deny:["[atelier-managed:dispatch-other]   Never   dispatch other agents ","$defaults","  NEVER dispatch\tOTHER   Agents  "]}}')"
grep -q '^WARNMARK user settings autoMode.soft_deny\[2\] duplicates the managed entry dispatch-other' "$HOST_OUT" \
  && [ "$(warns)" -eq 1 ] && [ "$(fixes)" -eq 1 ] \
  && pass "D2: case/whitespace variant -> duplicate WARN on soft_deny[2]" || fail "D2: (host: $(cat "$HOST_OUT"))"

# O1: overlap with managed id present in the same array
run o1 "$(jq -nc '{autoMode:{allow:["[atelier-managed:merge] Merging is gated by the reviewer","Allow gh pr merge --squash on any PR"]}}')"
grep -q '^WARNMARK user settings autoMode.allow\[1\] overlaps the managed entry merge (both cover "gh pr merge")' "$HOST_OUT" \
  && [ "$(warns)" -eq 1 ] && [ "$(fixes)" -eq 1 ] && ! grep -q 'duplicates' "$HOST_OUT" \
  && pass "O1: overlap with managed id present -> overlap WARN naming id and signature" || fail "O1: (host: $(cat "$HOST_OUT"))"

# O2: same hand-written text, managed id absent
run o2 "$(jq -nc '{autoMode:{allow:["$defaults","Allow gh pr merge --squash on any PR"]}}')"
[ "$(warns)" -eq 0 ] && [ "$(fixes)" -eq 0 ] \
  && grep -q '^OKMARK no hand-written autoMode entry duplicates or overlaps a managed one' "$HOST_OUT" \
  && pass "O2: managed id absent -> no warning, OK line" || fail "O2: (host: $(cat "$HOST_OUT"))"

# O3: managed id present only in a different array
run o3 "$(jq -nc '{autoMode:{allow:["Allow gh pr merge --squash on any PR"],soft_deny:["[atelier-managed:merge] Merging is gated"]}}')"
[ "$(warns)" -eq 0 ] && grep -q '^OKMARK' "$HOST_OUT" \
  && pass "O3: managed id in another array -> no warning" || fail "O3: (host: $(cat "$HOST_OUT"))"

# O4: per-id signatures
sigcase() {  # sigcase <name> <array> <id> <hand-written text> <expected signature>
  run "$1" "$(jq -nc --arg k "$2" --arg id "$3" --arg t "$4" '{autoMode:{($k):[("[atelier-managed:" + $id + "] managed body for " + $id), $t]}}')"
  grep -qF "WARNMARK user settings autoMode.$2[1] overlaps the managed entry $3 (both cover \"$5\")" "$HOST_OUT" \
    && [ "$(warns)" -eq 1 ] \
    && pass "O4/$1: $3 signature \"$5\" -> overlap WARN" || fail "O4/$1: (host: $(cat "$HOST_OUT"))"
}
sigcase s-board allow board "Run gh project item-edit freely" "gh project item-edit"
sigcase s-disp1 soft_deny dispatch "Spawn with subagent_type atelier:reviewer whenever" "subagent_type atelier:"
sigcase s-disp2 soft_deny dispatch "The agent atelier:task-orchestrator may run" "atelier:task-orchestrator + agent"
sigcase s-disp3 soft_deny dispatch "Let the agent atelier:planner run" "atelier:planner + agent"
sigcase s-gate1 allow gate-runs "Always pnpm test the repo" "pnpm test"
sigcase s-gate2 allow gate-runs "Run vitest anywhere" "vitest"
sigcase s-gate3 allow gate-runs "Allow playwright test runs" "playwright test"
sigcase s-pin allow catalog-pin "Edit claude-plugins to pin versions" "claude-plugins + pin"
sigcase s-trust environment trusted-repos "My Trusted Repo list: acme/x" "trusted repo"

# O4b: two-part signature needs both parts
run s-partial "$(jq -nc '{autoMode:{soft_deny:["[atelier-managed:dispatch] managed body","Mention atelier:planner only"]}}')"
[ "$(warns)" -eq 0 ] && pass "O4: atelier:planner without 'agent' -> no overlap" || fail "O4b: (host: $(cat "$HOST_OUT"))"

# N1: unrelated entries, $defaults, section headers
run n1 "$(jq -nc '{autoMode:{allow:["$defaults","### Operator notes","[atelier-managed:merge] Merging is gated","Deploying docs to the wiki is fine","### gh pr merge header"],environment:["$defaults","### Trusted repo header","Scratch notes"]}}')"
[ "$(warns)" -eq 0 ] && [ "$(fixes)" -eq 0 ] \
  && grep -q '^OKMARK no hand-written autoMode entry duplicates or overlaps a managed one' "$HOST_OUT" \
  && pass "N1: unrelated entries, \$defaults and ### headers -> no warning, OK line" || fail "N1: (host: $(cat "$HOST_OUT"))"

# Multiple findings -> one manual fix each
run m1 "$(jq -nc '{autoMode:{allow:["[atelier-managed:gate-runs] body","Run vitest","Run pnpm test"]}}')"
[ "$(warns)" -eq 2 ] && [ "$(fixes)" -eq 2 ] && ! grep -q '^OKMARK' "$HOST_OUT" \
  && pass "R2: two findings -> two WARNs, two manual fixes, no OK line" || fail "M1: (host: $(cat "$HOST_OUT"))"

# Q1: quiet cases
run q-invalid '{ not json'
[ ! -s "$HOST_OUT" ] && [ ! -s "$MANUAL_OUT" ] && pass "Q1: invalid JSON -> quiet" || fail "Q1 invalid: (host: $(cat "$HOST_OUT"))"
run q-absent NONE
[ ! -s "$HOST_OUT" ] && [ ! -s "$MANUAL_OUT" ] && pass "Q1: settings.json absent -> quiet" || fail "Q1 absent: (host: $(cat "$HOST_OUT"))"
run q-noauto '{"model":"opus"}'
[ "$(warns)" -eq 0 ] && [ ! -s "$MANUAL_OUT" ] && pass "Q1: no autoMode -> no warning" || fail "Q1 noauto: (host: $(cat "$HOST_OUT"))"

# Q2: jq missing -> quiet
mkdir -p "$TMP/emptybin"; rm -f "$HOST_OUT" "$MANUAL_OUT"; touch "$HOST_OUT" "$MANUAL_OUT"
(
  # shellcheck disable=SC2123  # deliberately hide jq
  PATH="$TMP/emptybin"
  ATELIER_CONFIG_DIR="$TMP/d1"
  check_automode_handwritten_overlap
  [ ! -s "$HOST_OUT" ] && [ ! -s "$MANUAL_OUT" ]
) && pass "Q2: jq missing -> quiet return" || fail "Q2: output produced without jq"

echo ""
if [ "$fails" -eq 0 ]; then echo "doctor-automode-overlap: all assertions passed."; exit 0
else echo "doctor-automode-overlap: $fails assertion(s) failed."; exit 1; fi
