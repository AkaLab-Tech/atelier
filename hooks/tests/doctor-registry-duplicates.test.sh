#!/usr/bin/env bash
#
# Regression test for #466 — atelier-doctor check_project_registry().
# Offline registry integrity: duplicate remotes (https vs ssh form) are
# flagged naming both paths with the older tip as likely stale; a missing path
# is flagged; a non-git dir stays silent; the fix line carries
# --unregister-only.
#
# Strategy: extract check_project_registry() and drive it with stubbed
# push_host / push_fix_manual against a temp registry + temp git repos.
#
# Run:  hooks/tests/doctor-registry-duplicates.test.sh
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

awk '/^check_project_registry\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "  FAIL: could not extract check_project_registry()"; exit 1; }
# shellcheck disable=SC1090
source "$TMP/fn.sh"

OK="✓"; WARN="!"
HOST_LINES=(); FIX_LINES=()
push_host() { HOST_LINES+=("$1"); }
push_fix_manual() { FIX_LINES+=("$1"); }

export ATELIER_CONFIG_DIR="$TMP/config"
mkdir -p "$ATELIER_CONFIG_DIR"

# mkrepo <name> <origin-url> <epoch>
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" remote add origin "$2"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_AUTHOR_DATE="$3 +0000" GIT_COMMITTER_DATE="$3 +0000" \
    git -C "$d" commit -q --allow-empty -m init
}

register() { # paths...
  jq -n '$ARGS.positional | map({key: ., value: {}}) | {projects: from_entries}' --args "$@" \
    > "$ATELIER_CONFIG_DIR/projects.json"
}

all_host() { printf '%s\n' ${HOST_LINES[@]+"${HOST_LINES[@]}"}; }
all_fix()  { printf '%s\n' ${FIX_LINES[@]+"${FIX_LINES[@]}"}; }
reset()    { HOST_LINES=(); FIX_LINES=(); }

# ---------- case 1: duplicate remote, https vs ssh, older = stale ----------
mkrepo old https://github.com/AkaLab-Tech/atelier.git 1700000000
mkrepo new git@github.com:akalab-tech/atelier 1800000000
register "$TMP/old" "$TMP/new"
reset
check_project_registry
out="$(all_host)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "exactly one host line for the duplicate group" || fail "expected 1 host line, got ${#HOST_LINES[@]}: $out"
case "$out" in *"$WARN"*"registered at 2 paths"*) pass "WARN says registered at 2 paths" ;; *) fail "no WARN/2 paths: $out" ;; esac
case "$out" in *"$TMP/old"*"$TMP/new"*|*"$TMP/new"*"$TMP/old"*) pass "WARN names both paths" ;; *) fail "WARN misses a path: $out" ;; esac
case "$out" in *"likely stale (older tip): $TMP/old") pass "older path marked stale" ;; *) fail "stale marker wrong: $out" ;; esac
fix="$(all_fix)"
case "$fix" in *"atelier-remove-project $TMP/old --unregister-only"*) pass "fix line targets the stale path with --unregister-only" ;; *) fail "fix line wrong: $fix" ;; esac
case "$fix" in *"$TMP/new"*) fail "fix line mentions the newer path: $fix" ;; *) pass "fix line does not touch the newer path" ;; esac

# ---------- case 2: missing path ----------
mkrepo solo https://github.com/AkaLab-Tech/solo.git 1700000000
register "$TMP/solo" "$TMP/gone"
reset
check_project_registry
out="$(all_host)"
case "$out" in *"$WARN registered project path missing on disk: $TMP/gone"*) pass "missing path gets a WARN" ;; *) fail "no missing-path WARN: $out" ;; esac
case "$(all_fix)" in *"atelier-remove-project $TMP/gone --unregister-only"*) pass "missing-path fix uses --unregister-only" ;; *) fail "missing-path fix wrong: $(all_fix)" ;; esac

# ---------- case 3: non-git dir stays silent; all-OK line ----------
mkdir -p "$TMP/plainroot"
register "$TMP/solo" "$TMP/plainroot"
reset
check_project_registry
out="$(all_host)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "non-git dir adds no warning (one line total)" || fail "expected 1 line, got ${#HOST_LINES[@]}: $out"
case "$out" in "$OK project registry consistent (2 registered"*) pass "OK line reports consistent registry" ;; *) fail "no OK line: $out" ;; esac
[ ${#FIX_LINES[@]} -eq 0 ] && pass "no fix lines when consistent" || fail "unexpected fix lines: $(all_fix)"

# ---------- case 4: no registry file -> silent ----------
rm -f "$ATELIER_CONFIG_DIR/projects.json"
reset
check_project_registry
[ ${#HOST_LINES[@]} -eq 0 ] && pass "absent projects.json: silent" || fail "absent projects.json produced: $(all_host)"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor registry duplicates (#466): all assertions passed."
  exit 0
else
  echo "doctor registry duplicates (#466): $fails assertion(s) failed."
  exit 1
fi
