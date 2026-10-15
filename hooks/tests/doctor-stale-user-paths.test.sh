#!/usr/bin/env bash
#
# Regression test for #488 — atelier-doctor check_user_settings_stale_paths().
# Read-only detection of an absolute path in the user-level settings.json that
# is not a registered project but is a checkout of a registered project's
# remote (a moved project). Reports key + index, old path, registered
# successor and the `atelier-automode-sync --replace-path` fix; no false
# positive on `/x/atelier-dev2`-style siblings or registered paths;
# settings.json is never written; one OK line when nothing is stale; SKIP when
# settings.json is missing / invalid.
#
# Strategy: extract check_user_settings_stale_paths() + remote_key() and drive
# them with stubbed push_host / push_fix_manual against temp git repos with
# fake origin URLs. Hermetic: no network.
#
# Run:  hooks/tests/doctor-stale-user-paths.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

for fn in remote_key check_user_settings_stale_paths; do
  awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" {f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" >> "$TMP/fn.sh"
  grep -q "^$fn()" "$TMP/fn.sh" || { echo "  FAIL: could not extract $fn()"; exit 1; }
done
# shellcheck disable=SC1090
source "$TMP/fn.sh"

OK="OKMARK"; WARN="WARNMARK"; SKIP="SKIPMARK"; FAIL="FAILMARK"
HOST_LINES=(); FIX_LINES=()
push_host() { HOST_LINES+=("$1"); }
push_fix_manual() { FIX_LINES+=("$1"); }
all_host() { printf '%s\n' ${HOST_LINES[@]+"${HOST_LINES[@]}"}; }
all_fix()  { printf '%s\n' ${FIX_LINES[@]+"${FIX_LINES[@]}"}; }
reset()    { HOST_LINES=(); FIX_LINES=(); }

export ATELIER_CONFIG_DIR="$TMP/config"
mkdir -p "$ATELIER_CONFIG_DIR"
SETTINGS="$ATELIER_CONFIG_DIR/settings.json"
PF="$ATELIER_CONFIG_DIR/projects.json"

mkrepo() { # <dirname> <origin-url>
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" remote add origin "$2"
}

NEW="$TMP/atelier-dev"          # registered successor
OLD="$TMP/old-atelier"          # stale checkout, same remote (ssh spelling)
SIB="$TMP/atelier-dev2"         # sibling by name prefix, different remote, unregistered
mkrepo atelier-dev  https://github.com/AkaLab-Tech/atelier.git
mkrepo old-atelier  git@github.com:akalab-tech/atelier
mkrepo atelier-dev2 https://github.com/AkaLab-Tech/atelier-two.git
jq -n --arg n "$NEW" '{projects: {($n): {name:"atelier"}}}' > "$PF"

# ---------- case 1: stale path detected ----------
jq -n --arg o "$OLD" --arg n "$NEW" --arg s "$SIB" '{
  model: "x",
  autoMode: {allow: ["unrelated rule", ("Work freely in " + $o + " when asked")], soft_deny: [], environment: []},
  permissions: {allow: ["Bash(ls)", ("Edit(" + $o + "/**)"), ("Edit(" + $n + "/**)"), ("Read(" + $s + "/**)")], deny: [], ask: []}
}' > "$SETTINGS"
before="$(cksum < "$SETTINGS")"
reset
check_user_settings_stale_paths
out="$(all_host)"; fix="$(all_fix)"
case "$out" in *"$WARN user settings autoMode.allow[1] names $OLD, a checkout of github.com/akalab-tech/atelier that is registered at $NEW"*)
  pass "WARN for autoMode.allow[1] names old path, remote key and registered successor" ;;
  *) fail "no autoMode.allow[1] WARN: $out" ;; esac
case "$out" in *"$WARN user settings permissions.allow[1] names $OLD, a checkout of github.com/akalab-tech/atelier that is registered at $NEW"*)
  pass "WARN for permissions.allow[1] (key + index)" ;;
  *) fail "no permissions.allow[1] WARN: $out" ;; esac
[ "${#HOST_LINES[@]}" -eq 2 ] && pass "exactly 2 host lines (registered path, sibling and unrelated rules not flagged)" \
  || fail "expected 2 host lines, got ${#HOST_LINES[@]}: $out"
[ "${#FIX_LINES[@]}" -eq 1 ] && pass "one fix line for the repeated OLD=NEW pair" || fail "expected 1 fix line, got ${#FIX_LINES[@]}: $fix"
case "$fix" in "atelier-automode-sync --replace-path $OLD=$NEW"*) pass "fix line is the exact --replace-path command" ;;
  *) fail "fix line wrong: $fix" ;; esac
case "$fix" in *"--apply"*"--apply"*) fail "fix line queues --apply twice" ;; *) pass "fix line previews (apply is gated on operator confirmation)" ;; esac
case "$out" in *"$OK"*) fail "OK line printed alongside warnings: $out" ;; *) pass "no OK line when something is stale" ;; esac
[ "$before" = "$(cksum < "$SETTINGS")" ] && pass "settings.json byte-identical after the check" || fail "settings.json was modified"
ls "$ATELIER_CONFIG_DIR" | grep -q 'settings.json.' && fail "stray file written next to settings.json" || pass "no stray files next to settings.json"

# ---------- case 2: nothing stale -> single OK line ----------
jq -n --arg n "$NEW" --arg s "$SIB" --arg g "$TMP/not-a-repo/x" '{
  autoMode: {allow: [("Work in " + $n)], soft_deny: [("never touch " + $s)], environment: ["relative/path only", ("Bash(cat " + $g + ")")]},
  permissions: {allow: [("Edit(" + $n + "/src/**)")], deny: [], ask: ["Bash(rm -rf /)"]}
}' > "$SETTINGS"
before="$(cksum < "$SETTINGS")"
reset
check_user_settings_stale_paths
out="$(all_host)"
[ "${#HOST_LINES[@]}" -eq 1 ] && case "$out" in "$OK user settings name no stale checkout of a registered project") true ;; *) false ;; esac \
  && pass "single OK line" || fail "expected single OK line: $out"
[ "${#FIX_LINES[@]}" -eq 0 ] && pass "no fix queued" || fail "fix queued: $(all_fix)"
[ "$before" = "$(cksum < "$SETTINGS")" ] && pass "settings.json byte-identical" || fail "settings.json modified"

# ---------- case 3: a sibling that merely shares a name prefix with a registered path ----------
# atelier-dev2 starts with the registered path atelier-dev but is neither
# inside it nor a checkout of its remote, so it must not be flagged.
jq -n --arg s "$SIB" '{permissions: {allow: [("Edit(" + $s + "/**)")]}}' > "$SETTINGS"
reset
check_user_settings_stale_paths
out="$(all_host)"
case "$out" in "$OK"*) pass "name-prefix sibling of a registered path is not flagged" ;; *) fail "false positive on sibling: $out" ;; esac

# ---------- case 4: SKIP on missing / invalid settings.json, no registry ----------
rm -f "$SETTINGS"
reset
check_user_settings_stale_paths
case "$(all_host)" in *"$SKIP"*"missing"*) pass "SKIP when settings.json is missing" ;; *) fail "missing: $(all_host)" ;; esac
[ ! -e "$SETTINGS" ] && pass "missing settings.json not created" || fail "settings.json created"

printf '{ not json' > "$SETTINGS"
reset
check_user_settings_stale_paths
case "$(all_host)" in *"$SKIP"*"not valid JSON"*) pass "SKIP when settings.json is invalid" ;; *) fail "invalid: $(all_host)" ;; esac
[ "$(cat "$SETTINGS")" = '{ not json' ] && pass "invalid settings.json left untouched" || fail "invalid settings.json rewritten"
[ "${#FIX_LINES[@]}" -eq 0 ] && pass "no fix queued on SKIP" || fail "fix queued on SKIP"

jq -n '{permissions: {allow: ["Bash(ls)"]}}' > "$SETTINGS"
rm -f "$PF"
reset
check_user_settings_stale_paths
case "$(all_host)" in *"$SKIP"*"registry"*) pass "SKIP when there is no project registry" ;; *) fail "no registry: $(all_host)" ;; esac

# ---------- case 5: the real doctor runs the check ----------
grep -q '^check_user_settings_stale_paths$' "$SCRIPT" \
  && pass "atelier-doctor main flow calls check_user_settings_stale_paths" || fail "check not wired into atelier-doctor"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor stale user paths (#488): all assertions passed."
  exit 0
else
  echo "doctor stale user paths (#488): $fails assertion(s) failed."
  exit 1
fi
