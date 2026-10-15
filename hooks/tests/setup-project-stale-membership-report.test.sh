#!/usr/bin/env bash
#
# Regression test for #488 — atelier-setup-project report_stale_workspace_members().
# A workspace member whose path is NOT registered but whose git origin equals
# this project's origin is reported (warn) with the exact fix command; the
# report never edits workspaces.json.
#
# Strategy: extract report_stale_workspace_members() and drive it with a stubbed
# warn() against a temp registry + temp git repos with fake origin URLs.
#
# Run:  hooks/tests/setup-project-stale-membership-report.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

awk '/^report_stale_workspace_members\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "  FAIL: could not extract report_stale_workspace_members()"; exit 1; }
# shellcheck disable=SC1090
source "$TMP/fn.sh"

WARNS=()
warn() { WARNS+=("$*"); }
all_warn() { printf '%s\n' ${WARNS[@]+"${WARNS[@]}"}; }

export ATELIER_CONFIG_DIR="$TMP/config"
mkdir -p "$ATELIER_CONFIG_DIR"
CONFIG_FILE="$ATELIER_CONFIG_DIR/projects.json"
WSF="$ATELIER_CONFIG_DIR/workspaces.json"

mkrepo() { # <name> <origin-url>
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  [ -n "$2" ] && git -C "$d" remote add origin "$2"
  return 0
}

NEW="$TMP/new"; OLD="$TMP/old"; OTHER="$TMP/other"; NOREMOTE="$TMP/noremote"
mkrepo new  https://github.com/AkaLab-Tech/demo.git
mkrepo old  git@github.com:akalab-tech/demo            # same repo, ssh spelling, different case
mkrepo other https://github.com/AkaLab-Tech/different.git
mkrepo noremote ""
PROJECT="$NEW"

jq -n --arg n "$NEW" '{projects: {($n): {name:"new"}}}' > "$CONFIG_FILE"
write_ws() { # members JSON array
  jq -n --argjson m "$1" '{workspaces: {ws1: {root:"/r/ws1", createdAt:"T1", members:$m}}}' > "$WSF"
}

# ---------- case 1: unregistered same-origin member is reported ----------
write_ws "$(jq -n --arg n "$NEW" --arg o "$OLD" '[{token:"app",path:$o},{token:"cur",path:$n}]')"
before="$(cat "$WSF")"
WARNS=()
report_stale_workspace_members; rc=$?
out="$(all_warn)"
[ "$rc" -eq 0 ] && pass "returns 0" || fail "returned $rc"
case "$out" in *"workspace 'ws1' lists member 'app' at $OLD, an unregistered checkout of this project's remote"*)
  pass "names workspace, member token and old path" ;; *) fail "report line wrong: $out" ;; esac
case "$out" in *"fix: re-run /atelier:setup-workspace with the corrected --members (this project at $NEW), --root /r/ws1 and --force"*)
  pass "prints the exact setup-workspace fix with this project's path and the workspace root" ;;
  *) fail "fix line wrong: $out" ;; esac
case "$out" in *"or drop the grouping: atelier-remove-workspace ws1"*) pass "prints atelier-remove-workspace ws1" ;;
  *) fail "no remove-workspace alternative: $out" ;; esac
[ "${#WARNS[@]}" -eq 3 ] && pass "exactly 3 warn lines (only the stale member; current member not reported)" || fail "warn count ${#WARNS[@]}: $out"
[ "$before" = "$(cat "$WSF")" ] && pass "workspaces.json byte-identical (report-only)" || fail "workspaces.json modified"

# ---------- case 2: member registered -> silent ----------
jq -n --arg n "$NEW" --arg o "$OLD" '{projects: {($n): {}, ($o): {}}}' > "$CONFIG_FILE"
WARNS=()
report_stale_workspace_members
[ "${#WARNS[@]}" -eq 0 ] && pass "registered member at the same origin stays silent" || fail "warned for registered member: $(all_warn)"

# ---------- case 3: different origin / no origin / missing dir -> silent ----------
jq -n --arg n "$NEW" '{projects: {($n): {}}}' > "$CONFIG_FILE"
write_ws "$(jq -n --arg o "$OTHER" --arg r "$NOREMOTE" --arg g "$TMP/gone" \
  '[{token:"o",path:$o},{token:"r",path:$r},{token:"g",path:$g}]')"
WARNS=()
report_stale_workspace_members
[ "${#WARNS[@]}" -eq 0 ] && pass "different origin, no origin and missing-dir members stay silent" || fail "false positive: $(all_warn)"

# ---------- case 4: missing / invalid workspaces.json -> silent, untouched ----------
rm -f "$WSF"
WARNS=()
report_stale_workspace_members; rc=$?
[ "$rc" -eq 0 ] && [ "${#WARNS[@]}" -eq 0 ] && [ ! -e "$WSF" ] \
  && pass "missing workspaces.json: silent, not created" || fail "missing workspaces.json: rc=$rc warns=$(all_warn)"
printf '{ nope' > "$WSF"
WARNS=()
report_stale_workspace_members; rc=$?
[ "$rc" -eq 0 ] && [ "${#WARNS[@]}" -eq 0 ] && [ "$(cat "$WSF")" = '{ nope' ] \
  && pass "invalid workspaces.json: silent, untouched" || fail "invalid workspaces.json: rc=$rc warns=$(all_warn)"

# ---------- case 5: the real script wires the report into step_record_setup ----------
awk '/^step_record_setup\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" | grep -q '^  report_stale_workspace_members$' \
  && pass "step_record_setup calls report_stale_workspace_members" || fail "step_record_setup does not call the report"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project stale membership report (#488): all assertions passed."
  exit 0
else
  echo "setup-project stale membership report (#488): $fails assertion(s) failed."
  exit 1
fi
