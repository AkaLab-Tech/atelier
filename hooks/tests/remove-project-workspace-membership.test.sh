#!/usr/bin/env bash
#
# Regression test for #488 — atelier-remove-project drops the workspace
# memberships that reference the removed path (workspaces.json), in default,
# --purge and --unregister-only modes. The membership drop is listed in the
# inventory BEFORE confirmation; other members, other workspaces, `root` and
# `createdAt` are preserved; a workspace left with 0 members is kept and
# `atelier-remove-workspace <slug>` is printed; a missing workspaces.json is
# silent; an invalid one warns and the registry removal is still applied.
#
# Hermetic: ATELIER_CONFIG_DIR + projects live in a temp dir; no network.
#
# Run:  hooks/tests/remove-project-workspace-membership.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-remove-project"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export ATELIER_CONFIG_DIR="$TMP/config"
WS="$ATELIER_CONFIG_DIR/workspaces.json"
PJ="$ATELIER_CONFIG_DIR/projects.json"
mkdir -p "$ATELIER_CONFIG_DIR"

mkproject() {
  local d="$TMP/$1"
  mkdir -p "$d/.claude"
  printf '{"permissions":{}}\n' > "$d/.claude/settings.json"
  printf '{"x":1}\n' > "$d/.atelier.json"
  printf 'ignore-scripts=true\n' > "$d/.npmrc"
  printf '.task-log/\n' > "$d/.gitignore"
  printf '%s' "$d"
}

# seed <A> <B> <C> : registry A,B,C ; workspaces
#   alpha: members a(A), b(B)      root /r/alpha  createdAt T1
#   solo:  members a(A)            root /r/solo   createdAt T2
#   other: members b(B), c(C)      root /r/other  createdAt T3
seed() {
  jq -n --arg a "$1" --arg b "$2" --arg c "$3" \
    '{projects: {($a): {name:"a"}, ($b): {name:"b"}, ($c): {name:"c"}}}' > "$PJ"
  jq -n --arg a "$1" --arg b "$2" --arg c "$3" '{workspaces: {
    alpha: {root:"/r/alpha", createdAt:"T1", members:[{token:"a",path:$a},{token:"b",path:$b}]},
    solo:  {root:"/r/solo",  createdAt:"T2", members:[{token:"a",path:$a}]},
    other: {root:"/r/other", createdAt:"T3", members:[{token:"b",path:$b},{token:"c",path:$c}]}
  }}' > "$WS"
}

wsq() { jq -r "$1" "$WS"; }

check_after() { # label A B  — shared assertions after removing A
  local label="$1" a="$2" b="$3" c="$4"
  [ "$(wsq '[.workspaces.alpha.members[].token]|join(",")')" = "b" ] \
    && pass "$label: alpha keeps only member b" || fail "$label: alpha members: $(wsq '.workspaces.alpha.members')"
  [ "$(wsq '.workspaces.alpha.members[0].path')" = "$b" ] \
    && pass "$label: alpha member b path intact" || fail "$label: alpha member b path changed"
  [ "$(wsq '.workspaces.alpha.root')" = "/r/alpha" ] && [ "$(wsq '.workspaces.alpha.createdAt')" = "T1" ] \
    && pass "$label: alpha root and createdAt preserved" || fail "$label: alpha root/createdAt changed"
  [ "$(wsq '.workspaces.solo.members|length')" = "0" ] \
    && pass "$label: solo kept with 0 members" || fail "$label: solo members: $(wsq '.workspaces.solo')"
  [ "$(wsq '.workspaces.solo.root')" = "/r/solo" ] && [ "$(wsq '.workspaces.solo.createdAt')" = "T2" ] \
    && pass "$label: solo root and createdAt preserved" || fail "$label: solo root/createdAt changed"
  [ "$(wsq '.workspaces.other.members|map(.token)|join(",")')" = "b,c" ] \
    && [ "$(wsq '.workspaces.other.root')" = "/r/other" ] && [ "$(wsq '.workspaces.other.createdAt')" = "T3" ] \
    && pass "$label: unrelated workspace 'other' untouched" || fail "$label: other changed: $(wsq '.workspaces.other')"
  jq -e --arg p "$a" '.projects[$p]' "$PJ" >/dev/null 2>&1 \
    && fail "$label: registry key for A still present" || pass "$label: registry key for A dropped"
  jq -e --arg p "$b" '.projects[$p]' "$PJ" >/dev/null 2>&1 \
    && pass "$label: registry key for B intact" || fail "$label: registry key for B lost"
}

# ---------- case 1: default mode ----------
A="$(mkproject a1)"; B="$(mkproject b1)"; C="$(mkproject c1)"
seed "$A" "$B" "$C"
out="$(bash "$SCRIPT" "$A" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "default: exits 0" || fail "default: exit $rc: $out"
check_after "default" "$A" "$B" "$C"
case "$out" in *"will drop member 'a' from workspace 'alpha'"*"will drop member 'a' from workspace 'solo'"*)
  pass "default: inventory lists both drops" ;; *) fail "default: inventory lacks drops: $out" ;; esac
case "$out" in *"atelier-remove-workspace solo"*) pass "default: prints atelier-remove-workspace solo" ;;
  *) fail "default: no remove-workspace hint for solo: $out" ;; esac
case "$out" in *"atelier-remove-workspace alpha"*|*"atelier-remove-workspace other"*)
  fail "default: remove-workspace hint printed for a non-empty workspace: $out" ;;
  *) pass "default: no hint for workspaces that still have members" ;; esac

# ---------- case 2: --purge ----------
A="$(mkproject a2)"; B="$(mkproject b2)"; C="$(mkproject c2)"
seed "$A" "$B" "$C"
out="$(bash "$SCRIPT" "$A" --purge --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "purge: exits 0" || fail "purge: exit $rc: $out"
check_after "purge" "$A" "$B" "$C"
case "$out" in *"atelier-remove-workspace solo"*) pass "purge: prints atelier-remove-workspace solo" ;;
  *) fail "purge: no remove-workspace hint: $out" ;; esac

# ---------- case 3: --unregister-only ----------
A="$(mkproject a3)"; B="$(mkproject b3)"; C="$(mkproject c3)"
seed "$A" "$B" "$C"
out="$(bash "$SCRIPT" "$A" --unregister-only --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "unregister-only: exits 0" || fail "unregister-only: exit $rc: $out"
check_after "unregister-only" "$A" "$B" "$C"
[ -f "$A/.atelier.json" ] && [ -f "$A/.claude/settings.json" ] \
  && pass "unregister-only: project files still on disk" || fail "unregister-only: project files deleted"
case "$out" in *"atelier-remove-workspace solo"*) pass "unregister-only: prints atelier-remove-workspace solo" ;;
  *) fail "unregister-only: no remove-workspace hint: $out" ;; esac

# ---------- case 4: drop is in the inventory before confirmation ----------
A="$(mkproject a4)"; B="$(mkproject b4)"; C="$(mkproject c4)"
seed "$A" "$B" "$C"
before_ws="$(cat "$WS")"; before_pj="$(cat "$PJ")"
out="$(bash "$SCRIPT" "$A" </dev/null 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "unconfirmed: exits non-zero without --yes on a non-TTY ($rc)" || fail "unconfirmed: exited 0"
case "$out" in *"workspace memberships:"*"will drop member 'a' from workspace 'alpha'"*"will drop member 'a' from workspace 'solo'"*"--yes was not given"*)
  pass "unconfirmed: memberships listed in the inventory before the confirmation gate" ;;
  *) fail "unconfirmed: inventory missing or out of order: $out" ;; esac
[ "$before_ws" = "$(cat "$WS")" ] && [ "$before_pj" = "$(cat "$PJ")" ] \
  && pass "unconfirmed: workspaces.json and projects.json untouched" || fail "unconfirmed: files modified before confirmation"

# ---------- case 5: project with no memberships ----------
A="$(mkproject a5)"; B="$(mkproject b5)"; C="$(mkproject c5)"
seed "$B" "$B" "$C"   # no workspace references A
jq --arg a "$A" '.projects[$a] = {name:"a"}' "$PJ" > "$PJ.n" && mv "$PJ.n" "$PJ"
before_ws="$(cat "$WS")"
out="$(bash "$SCRIPT" "$A" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "no-membership: exits 0" || fail "no-membership: exit $rc: $out"
case "$out" in *"workspace memberships"*|*"atelier-remove-workspace"*) fail "no-membership: mentions workspaces: $out" ;;
  *) pass "no-membership: output silent about workspaces" ;; esac
[ "$before_ws" = "$(cat "$WS")" ] && pass "no-membership: workspaces.json byte-identical" || fail "no-membership: workspaces.json changed"

# ---------- case 6: missing workspaces.json is silent ----------
A="$(mkproject a6)"; B="$(mkproject b6)"; C="$(mkproject c6)"
seed "$A" "$B" "$C"
rm -f "$WS"
out="$(bash "$SCRIPT" "$A" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "missing ws file: exits 0" || fail "missing ws file: exit $rc: $out"
case "$out" in *workspace*|*Workspace*) fail "missing ws file: output mentions workspaces: $out" ;;
  *) pass "missing ws file: silent" ;; esac
[ ! -e "$WS" ] && pass "missing ws file: not created" || fail "missing ws file: workspaces.json was created"
jq -e --arg p "$A" '.projects[$p]' "$PJ" >/dev/null 2>&1 \
  && fail "missing ws file: registry key still present" || pass "missing ws file: registry key dropped"

# ---------- case 7: invalid workspaces.json warns, registry removal still applied ----------
A="$(mkproject a7)"; B="$(mkproject b7)"; C="$(mkproject c7)"
seed "$A" "$B" "$C"
printf '{ not json' > "$WS"
out="$(bash "$SCRIPT" "$A" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "invalid ws file: exits 0" || fail "invalid ws file: exit $rc: $out"
case "$out" in *"workspaces.json is not valid JSON"*) pass "invalid ws file: warns not valid JSON" ;;
  *) fail "invalid ws file: no warning: $out" ;; esac
[ "$(cat "$WS")" = '{ not json' ] && pass "invalid ws file: left byte-identical" || fail "invalid ws file: rewritten"
jq -e --arg p "$A" '.projects[$p]' "$PJ" >/dev/null 2>&1 \
  && fail "invalid ws file: registry key still present" || pass "invalid ws file: registry removal still applied"
jq -e --arg p "$B" '.projects[$p]' "$PJ" >/dev/null 2>&1 \
  && pass "invalid ws file: other registry key intact" || fail "invalid ws file: B lost"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "remove-project workspace membership (#488): all assertions passed."
  exit 0
else
  echo "remove-project workspace membership (#488): $fails assertion(s) failed."
  exit 1
fi
