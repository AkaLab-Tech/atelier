#!/usr/bin/env bash
#
# Test for scripts/atelier-dispatch-denial (#457) — the local record of denied
# task-orchestrator / planner dispatches. Drives the real helper against a
# temporary ATELIER_STATE_DIR; no network, never touches the real state dir.
#
# Asserted:
#   D1 — record writes valid JSONL + a prompt copy whose sha256 matches
#   D2 — prompt copy is 0600, its dir 0700, the log 0600
#   D3 — missing --tag / --task (and other required args) exit non-zero
#   D4 — outcome links back by --ref; unknown ref / bad choice exit 2
#   D5 — report renders a table; filters by --since and --project
#   D6 — prompt_form classification (file-pointer vs inline); refs are unique
#   D8 — outcome --choice auto-reissue stored and reported; invalid choice still dies
#   D9 — --prompt-file - reads the prompt from stdin (byte-identical 0600 copy, true
#        sha256/lines/form); empty stdin exits 2 with no log line or copy
#   D7 — optional --hook stored as "hook" (null when absent); report renders it
#
# Run:  hooks/tests/dispatch-denial-log.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HELPER="$REPO_ROOT/scripts/atelier-dispatch-denial"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
export ATELIER_STATE_DIR="$TMP/state"
export HOME="$TMP/home"; mkdir -p "$HOME"
LOG="$ATELIER_STATE_DIR/dispatch-denials.jsonl"
COPIES="$ATELIER_STATE_DIR/dispatch-denials"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected '$3', got '$2'"; fi; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

printf 'Brief line 1\nBrief line 2\nBrief line 3\nBrief line 4\n' > "$TMP/inline.md"
printf 'Read /tmp/brief.md and follow it\n' > "$TMP/pointer.md"

rec() { # <project-root> <task> <tag> <prompt-file> [extra args...]
  local proj="$1" task="$2" tag="$3" pf="$4"; shift 4
  bash "$HELPER" record --project "$proj" --command next-task --agent task-orchestrator \
    --task "$task" --tag "$tag" --attempt 1 --prompt-file "$pf" "$@"
}

# --- D1 / D2 ----------------------------------------------------------------
REF1="$(rec /w/alpha '#457' '[Auto-Mode Bypass]' "$TMP/inline.md" --session-role worker --prior-denials-in-session 2)"
eq "D1: record exits 0 and prints a compact UTC ref" "$(printf '%s' "$REF1" | grep -Ec '^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$')" "1"
eq "D1: log has exactly one line" "$(wc -l < "$LOG" | tr -d ' ')" "1"
if jq -e . "$LOG" >/dev/null 2>&1; then pass "D1: log is valid JSON lines"; else fail "D1: log is not valid JSON"; fi
row() { jq -r --arg r "$REF1" "select(.ref == \$r and .type == \"denial\") | $1" "$LOG"; }
eq "D1: project is the root basename" "$(row .project)" "alpha"
eq "D1: project_root kept" "$(row .project_root)" "/w/alpha"
eq "D1: tag verbatim" "$(row .tag)" "[Auto-Mode Bypass]"
eq "D1: task kept" "$(row .task)" "#457"
eq "D1: agent kept" "$(row .agent)" "task-orchestrator"
eq "D1: attempt is a number" "$(row '.attempt|type')" "number"
eq "D1: session_role kept" "$(row .session_role)" "worker"
eq "D1: prior_denials_in_session is 2" "$(row .prior_denials_in_session)" "2"
eq "D1: prompt_lines is 4" "$(row .prompt_lines)" "4"
COPY="$(row .prompt_copy)"
if [ -f "$COPY" ] && cmp -s "$COPY" "$TMP/inline.md"; then pass "D1: prompt copy is byte-identical to the prompt"; else fail "D1: prompt copy missing or different"; fi
eq "D1: logged sha256 matches the sha256 of the copy" "$(row .prompt_sha256)" "$(sha256_of "$COPY")"
eq "D1: logged sha256 matches the sha256 of the original prompt" "$(row .prompt_sha256)" "$(sha256_of "$TMP/inline.md")"
eq "D2: prompt copy mode is 600" "$(mode_of "$COPY")" "600"
eq "D2: copies dir mode is 700" "$(mode_of "$COPIES")" "700"
eq "D2: log mode is 600" "$(mode_of "$LOG")" "600"

# --- D3 ---------------------------------------------------------------------
before="$(wc -l < "$LOG" | tr -d ' ')"
bash "$HELPER" record --project /w/alpha --command next-task --agent task-orchestrator \
  --task '#457' --attempt 1 --prompt-file "$TMP/inline.md" >/dev/null 2>&1
eq "D3: missing --tag exits 2" "$?" "2"
bash "$HELPER" record --project /w/alpha --command next-task --agent task-orchestrator \
  --tag '[X]' --attempt 1 --prompt-file "$TMP/inline.md" >/dev/null 2>&1
eq "D3: missing --task exits 2" "$?" "2"
bash "$HELPER" record --project /w/alpha --command next-task --agent task-orchestrator \
  --task '#457' --tag '[X]' --attempt 1 --prompt-file "$TMP/nope.md" >/dev/null 2>&1
eq "D3: missing prompt file exits 2" "$?" "2"
bash "$HELPER" record --project /w/alpha --command next-task --agent task-orchestrator \
  --task '#457' --tag '[X]' --attempt 3 --prompt-file "$TMP/inline.md" >/dev/null 2>&1
eq "D3: attempt 3 exits 2" "$?" "2"
eq "D3: failed records append nothing" "$(wc -l < "$LOG" | tr -d ' ')" "$before"

# --- D4 ---------------------------------------------------------------------
bash "$HELPER" outcome --ref "$REF1" --choice redispatch --reissue denied >/dev/null 2>&1
eq "D4: outcome with a known ref exits 0" "$?" "0"
out() { jq -r --arg r "$REF1" "select(.ref == \$r and .type == \"outcome\") | $1" "$LOG"; }
eq "D4: outcome line carries the same ref" "$(out .ref)" "$REF1"
eq "D4: outcome choice" "$(out .choice)" "redispatch"
eq "D4: outcome reissue" "$(out .reissue)" "denied"
bash "$HELPER" outcome --ref 19990101T000000Z --choice held >/dev/null 2>&1
eq "D4: unknown ref exits 2" "$?" "2"
bash "$HELPER" outcome --ref "$REF1" --choice bogus >/dev/null 2>&1
eq "D4: invalid choice exits 2" "$?" "2"
bash "$HELPER" outcome --choice held >/dev/null 2>&1
eq "D4: missing --ref exits 2" "$?" "2"

# --- D6 (before report so beta/pointer rows exist) ---------------------------
REF2="$(rec /w/beta '#9' '[Safety Bypass Flag]' "$TMP/pointer.md")"
eq "D6: one-line 'Read … and follow it' prompt is file-pointer" "$(jq -r --arg r "$REF2" 'select(.ref==$r and .type=="denial") | .prompt_form' "$LOG")" "file-pointer"
eq "D6: multi-line prompt is inline" "$(row .prompt_form)" "inline"
eq "D6: absent --prior-denials-in-session is null" "$(jq -r --arg r "$REF2" 'select(.ref==$r and .type=="denial") | .prior_denials_in_session' "$LOG")" "null"
REF3="$(rec /w/alpha '#10' '[Auto-Mode Bypass]' "$TMP/inline.md")"
if [ "$REF1" != "$REF2" ] && [ "$REF2" != "$REF3" ] && [ "$REF1" != "$REF3" ]; then pass "D6: refs are unique across rapid records"; else fail "D6: duplicate refs: $REF1 $REF2 $REF3"; fi
eq "D6: three distinct prompt copies exist" "$(find "$COPIES" -type f | wc -l | tr -d ' ')" "3"

# --- D5 ---------------------------------------------------------------------
# A hand-written old entry for a third project, to exercise --since.
jq -cn '{type:"denial",ref:"20200101T000000Z",date:"2020-01-01T00:00:00Z",project:"gamma",project_root:"/w/gamma",
  command:"plan-task",agent:"planner",task:"#1",tag:"[Old Tag]",attempt:1,prompt_copy:"",
  prompt_sha256:"0123456789abcdef0123",prompt_lines:2,prompt_form:"inline",session_role:"plan",
  prior_denials_in_session:null}' >> "$LOG"

ALL="$(bash "$HELPER" report)"
eq "D5: report header is a markdown table" "$(printf '%s\n' "$ALL" | sed -n 1p | cut -c1-13)" "| date | proj"
eq "D5: report has a separator row" "$(printf '%s\n' "$ALL" | sed -n 2p | cut -c1-8)" "|---|---"
eq "D5: unfiltered report has 4 data rows" "$(printf '%s\n' "$ALL" | tail -n +3 | grep -c '^|')" "4"
case "$ALL" in *"| alpha | task-orchestrator | #457 | [Auto-Mode Bypass] | 1 |"*"| 2 | redispatch | denied |"*) pass "D5: alpha row shows linked outcome (redispatch / denied)";; *) fail "D5: alpha row lacks outcome: $(printf '%s' "$ALL" | grep '#457')";; esac
case "$(printf '%s\n' "$ALL" | grep '| beta |')" in *"| file-pointer |"*"| - | - |") pass "D5: beta row has no outcome ('-')";; *) fail "D5: beta row unexpected";; esac

SINCE="$(bash "$HELPER" report --since 2021-01-01)"
eq "D5: --since drops the 2020 row" "$(printf '%s\n' "$SINCE" | tail -n +3 | grep -c '^|')" "3"
case "$SINCE" in *gamma*) fail "D5: --since still lists gamma";; *) pass "D5: --since output excludes gamma";; esac

PROJ="$(bash "$HELPER" report --project alpha)"
eq "D5: --project alpha keeps 2 rows" "$(printf '%s\n' "$PROJ" | tail -n +3 | grep -c '^|')" "2"
case "$PROJ" in *beta*|*gamma*) fail "D5: --project alpha leaks other projects";; *) pass "D5: --project alpha excludes beta and gamma";; esac

BOTH="$(bash "$HELPER" report --since 2021-01-01 --project gamma)"
eq "D5: --since + --project combine (no rows)" "$(printf '%s\n' "$BOTH" | tail -n +3 | grep -c '^|')" "0"

# Empty state: report still prints the header and exits 0.
EMPTY="$(ATELIER_STATE_DIR="$TMP/empty" bash "$HELPER" report)"
eq "D5: report on missing log prints header only" "$(printf '%s\n' "$EMPTY" | grep -c '^|')" "2"

# --- D7 (#691): --hook ------------------------------------------------------
REF7="$(rec /w/delta '#691' 'hook-changed-input' "$TMP/inline.md" --hook 'context-mode@context-mode')"
eq "D7: --hook stored" "$(jq -r --arg r "$REF7" 'select(.ref==$r and .type=="denial") | .hook' "$LOG")" "context-mode@context-mode"
eq "D7: absent --hook is null" "$(row .hook)" "null"
eq "D7: old record without hook field parses as null" "$(jq -r 'select(.ref=="20200101T000000Z") | .hook' "$LOG")" "null"
REP7="$(bash "$HELPER" report)"
case "$(printf '%s\n' "$REP7" | grep '| delta |')" in *"| hook-changed-input (context-mode@context-mode) |"*) pass "D7: report renders tag with hook";; *) fail "D7: report tag cell wrong";; esac
case "$(printf '%s\n' "$REP7" | grep '| gamma |')" in *"| [Old Tag] | 1 |"*) pass "D7: old record still reports without hook";; *) fail "D7: old record row wrong";; esac
case "$(printf '%s\n' "$REP7" | grep '| alpha | task-orchestrator | #457')" in *"| [Auto-Mode Bypass] | 1 |"*) pass "D7: no-hook row keeps plain tag";; *) fail "D7: no-hook row changed";; esac
# Edge cases: multi-key value, empty value, --hook with an unrelated tag.
REF7M="$(rec /w/epsilon '#691' 'hook-changed-input' "$TMP/inline.md" --hook 'a@x,b@y')"
eq "D7: comma-joined multi-key --hook stored verbatim" "$(jq -r --arg r "$REF7M" 'select(.ref==$r and .type=="denial") | .hook' "$LOG")" "a@x,b@y"
REF7E="$(rec /w/zeta '#691' 'hook-changed-input' "$TMP/inline.md" --hook '')"
eq "D7: empty --hook is stored as null" "$(jq -r --arg r "$REF7E" 'select(.ref==$r and .type=="denial") | .hook' "$LOG")" "null"
REF7T="$(rec /w/eta '#691' '[Safety Bypass Flag]' "$TMP/inline.md" --hook 'c@z')"
eq "D7: --hook kept with a non-hook-changed-input tag" "$(jq -r --arg r "$REF7T" 'select(.ref==$r and .type=="denial") | .hook' "$LOG")" "c@z"
REP7B="$(bash "$HELPER" report)"
case "$(printf '%s\n' "$REP7B" | grep '| epsilon |')" in *"| hook-changed-input (a@x,b@y) |"*) pass "D7: report renders multi-key hook";; *) fail "D7: multi-key report cell wrong";; esac
case "$(printf '%s\n' "$REP7B" | grep '| zeta |')" in *"| hook-changed-input | 1 |"*) pass "D7: empty hook renders bare tag";; *) fail "D7: empty hook row wrong";; esac

# --- D8 (#690): outcome --choice auto-reissue --------------------------------
REF8="$(rec /w/theta '#690' 'hook-changed-input' "$TMP/inline.md" --hook 'c@z' --attempt 1)"
bash "$HELPER" outcome --ref "$REF8" --choice auto-reissue --reissue accepted >/dev/null 2>&1
eq "D8: auto-reissue outcome exits 0" "$?" "0"
eq "D8: auto-reissue choice stored" "$(jq -r --arg r "$REF8" 'select(.ref==$r and .type=="outcome") | .choice' "$LOG")" "auto-reissue"
eq "D8: auto-reissue reissue stored" "$(jq -r --arg r "$REF8" 'select(.ref==$r and .type=="outcome") | .reissue' "$LOG")" "accepted"
REP8="$(bash "$HELPER" report)"
case "$(printf '%s\n' "$REP8" | grep '| theta |')" in *"| auto-reissue | accepted |"*) pass "D8: report shows auto-reissue accepted";; *) fail "D8: report row wrong";; esac
bash "$HELPER" outcome --ref "$REF8" --choice bogus >/dev/null 2>&1
eq "D8: invalid choice still exits 2" "$?" "2"

# --- D9 (#720): --prompt-file - reads stdin ---------------------------------
printf 'Brief A\ngit commit -m "x"\nBrief C\nBrief D\n' > "$TMP/stdin-in.md"
REF9="$(bash "$HELPER" record --project /w/iota --command task-orchestrator --agent implementer \
  --task '#720' --tag hook-changed-input --attempt 1 --prompt-file - < "$TMP/stdin-in.md")"
eq "D9: stdin record exits 0 with a valid ref" "$(printf '%s' "$REF9" | grep -Ec '^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$')" "1"
COPY9="$(jq -r --arg r "$REF9" 'select(.ref==$r and .type=="denial") | .prompt_copy' "$LOG")"
if cmp -s "$TMP/stdin-in.md" "$COPY9"; then pass "D9: copy is byte-identical"; else fail "D9: copy differs from stdin"; fi
eq "D9: sha256 matches input" "$(jq -r --arg r "$REF9" 'select(.ref==$r and .type=="denial") | .prompt_sha256' "$LOG")" "$(sha256_of "$TMP/stdin-in.md")"
eq "D9: prompt_lines" "$(jq -r --arg r "$REF9" 'select(.ref==$r and .type=="denial") | .prompt_lines' "$LOG")" "4"
eq "D9: copy mode 0600" "$(mode_of "$COPY9")" "600"
bash "$HELPER" outcome --ref "$REF9" --choice auto-reissue --reissue accepted >/dev/null 2>&1
eq "D9: outcome on a stdin-recorded ref exits 0" "$?" "0"
eq "D9: outcome choice stored" "$(jq -r --arg r "$REF9" 'select(.ref==$r and .type=="outcome") | .choice' "$LOG")" "auto-reissue"
eq "D9: outcome reissue stored" "$(jq -r --arg r "$REF9" 'select(.ref==$r and .type=="outcome") | .reissue' "$LOG")" "accepted"
REF9B="$(printf 'Read /tmp/brief.md and follow it\n' | bash "$HELPER" record --project /w/iota --command task-orchestrator \
  --agent tester --task '#720' --tag hook-changed-input --attempt 1 --prompt-file -)"
eq "D9: one-line pointer on stdin is file-pointer" "$(jq -r --arg r "$REF9B" 'select(.ref==$r and .type=="denial") | .prompt_form' "$LOG")" "file-pointer"
LINES9="$(wc -l < "$LOG" | tr -d ' ')"; COPIES9="$(find "$COPIES" -type f | wc -l | tr -d ' ')"
bash "$HELPER" record --project /w/iota --command task-orchestrator --agent tester --task '#720' \
  --tag hook-changed-input --attempt 1 --prompt-file - </dev/null >/dev/null 2>&1
eq "D9: empty stdin exits 2" "$?" "2"
eq "D9: empty stdin writes no log line" "$(wc -l < "$LOG" | tr -d ' ')" "$LINES9"
eq "D9: empty stdin leaves no copy" "$(find "$COPIES" -type f | wc -l | tr -d ' ')" "$COPIES9"
bash "$HELPER" record --project /w/iota --command task-orchestrator --agent tester --task '#720' \
  --tag hook-changed-input --attempt 1 --prompt-file "$TMP/does-not-exist" >/dev/null 2>&1
eq "D9: non-existent path still exits 2" "$?" "2"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "dispatch-denial-log: all assertions passed."
  exit 0
else
  echo "dispatch-denial-log: $fails assertion(s) failed."
  exit 1
fi
