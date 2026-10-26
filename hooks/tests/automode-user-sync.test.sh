#!/usr/bin/env bash
#
# Regression test for #456 — scripts/atelier-automode-sync merges atelier's
# managed autoMode.allow entry (templates/automode.user.json) into the
# user-level $ATELIER_CONFIG_DIR/settings.json.
#
#   S1  read-only by default: no write without --apply (exit 1, diff printed)
#   S2  absent file + --apply -> {"autoMode":{"allow":["$defaults", managed]}}
#   S3  operator-shaped fixture: entries/order/other keys preserved, managed appended
#   S4  stale managed entry replaced in place; obsolete managed entry removed
#   S5  no "$defaults" in the operator's array -> none is added
#   S6  idempotent: second --apply is byte-identical, read-only run exits 0
#   S7  invalid JSON / non-array allow -> untouched, rc 0, warning
#   S8  exit codes (2 on missing template / unknown flag), --help
#   S9  no temp files left; real ~/.claude* never touched (scratch HOME)
#   S10 (#633) environment: in-place update, stale dropped, hand-written
#       entries byte-identical, $defaults preserved
#   S11 {{registered_projects}} expansion from projects.json + fixture repos
#   S12 idempotence with a registry; registry change detected as stale
#   S13 read-only default writes nothing
#   S14 template guard: no --admin / --auto / force-push grant in managed allow
#
# Fixtures are synthetic. Hermetic: scratch HOME + ATELIER_CONFIG_DIR.
#
# Run:  hooks/tests/automode-user-sync.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$REPO_ROOT/scripts/atelier-automode-sync"
TEMPLATE="$REPO_ROOT/templates/automode.user.json"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-automode-sync (#456)"

# Expected managed arrays as the sync writes them with no registered project:
# the {{registered_projects}} placeholder renders as NOPROJ.
NOPROJ="(no project registered yet)"
WA="$(jq -c '.autoMode.allow' "$TEMPLATE")"
# shellcheck disable=SC2016  # jq program, not shell
WE="$(jq -c --arg r "$NOPROJ" '.autoMode.environment | map(gsub("\\{\\{registered_projects\\}\\}"; $r))' "$TEMPLATE")"
MANAGED_TXT="$(jq -r '.autoMode.allow[0]' "$TEMPLATE")"
case "$MANAGED_TXT" in '[atelier-managed:gate-runs] '*) pass "template allow[0] starts with the gate-runs marker" ;; *) fail "template entry lacks marker" ;; esac
[ "$(jq -r '.autoMode.allow | length' "$TEMPLATE")" -eq 5 ] && [ "$(jq -r '.autoMode.environment | length' "$TEMPLATE")" -eq 2 ] \
  && pass "template ships 5 managed allow and 2 managed environment entries" || fail "template entry counts changed"

# run <cfg> [args...] — prints combined output, then RC=<n>.
run() {
  local cfg="$1"; shift
  ATELIER_CONFIG_DIR="$cfg" NO_COLOR=1 "$SYNC" "$@" 2>&1
  echo "RC=$?"
}

# S1 --------------------------------------------------------------------
CFG="$TMP/s1"; mkdir -p "$CFG"
printf '{"model":"opus"}\n' > "$CFG/settings.json"
before="$(cat "$CFG/settings.json")"
out="$(run "$CFG")"
[ "$before" = "$(cat "$CFG/settings.json")" ] && pass "S1: no write without --apply" || fail "S1: file changed"
printf '%s' "$out" | grep -q 'RC=1' && pass "S1: read-only run exits 1 (out of sync)" || fail "S1: rc (out: $out)"
printf '%s' "$out" | grep -qF '+ [gate-runs]' && pass "S1: prints the + diff line for gate-runs" || fail "S1: no diff line (out: $out)"
printf '%s' "$out" | grep -q 'Read-only: nothing written' && pass "S1: footer says nothing written" || fail "S1: no footer"
out="$(run "$CFG" --quiet)"
printf '%s' "$out" | grep -q 'Read-only: nothing written' && fail "S1: --quiet still prints footer" || pass "S1: --quiet omits the footer"

# S2 --------------------------------------------------------------------
CFG="$TMP/s2"
out="$(run "$CFG" --apply)"
printf '%s' "$out" | grep -q 'RC=0' && pass "S2: --apply on absent config dir exits 0" || fail "S2: rc (out: $out)"
want="$(jq -nc --argjson a "$WA" --argjson e "$WE" '{autoMode:{allow:(["$defaults"] + $a),environment:(["$defaults"] + $e)}}')"
[ "$(jq -cS . "$CFG/settings.json" 2>/dev/null)" = "$(printf '%s' "$want" | jq -cS .)" ] \
  && pass "S2: absent file -> [\"\$defaults\", managed...] in both allow and environment" || fail "S2: got $(cat "$CFG/settings.json" 2>&1)"
# existing file without autoMode
CFG="$TMP/s2b"; mkdir -p "$CFG"
printf '{"env":{"K":"v"}}\n' > "$CFG/settings.json"
run "$CFG" --apply >/dev/null
[ "$(jq -cS . "$CFG/settings.json")" = "$(jq -ncS --argjson a "$WA" --argjson e "$WE" '{env:{K:"v"},autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults"]+$e)}}')" ] \
  && pass "S2: file without autoMode gets \$defaults + managed, env untouched" || fail "S2b: got $(cat "$CFG/settings.json")"

# S3 --------------------------------------------------------------------
CFG="$TMP/s3"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{
  "permissions": {"defaultMode": "auto", "allow": ["Bash(ls *)"]},
  "model": "opus",
  "autoMode": {
    "environment": ["Repos live under ~/Work", "Staging is fake-staging.example.test"],
    "soft_deny": ["Never touch ~/Documents"],
    "allow": [
      "Reading files under ~/Work is fine",
      "$defaults",
      "Running linters in ~/Work/demo is fine",
      "Fetching docs from docs.example.test is fine",
      "Rule four, with | a pipe",
      "Rule five"
    ]
  }
}
JSON
cp "$CFG/settings.json" "$TMP/s3.orig"
run "$CFG" --apply >/dev/null
got="$(jq -c '.autoMode.allow' "$CFG/settings.json")"
want="$(jq -c --argjson m "$WA" '.autoMode.allow + $m' "$TMP/s3.orig")"
[ "$got" = "$want" ] && pass "S3: 6 operator entries keep text and order (\$defaults at index 1), 5 managed appended last" || fail "S3: got $got"
got="$(jq -c '.autoMode.environment' "$CFG/settings.json")"
want="$(jq -c --argjson m "$WE" '.autoMode.environment + $m' "$TMP/s3.orig")"
[ "$got" = "$want" ] && pass "S3: 2 hand-written environment entries kept first, 2 managed appended, no \$defaults added" || fail "S3: env got $got"
[ "$(jq -c 'del(.autoMode.allow, .autoMode.environment)' "$CFG/settings.json")" = "$(jq -c 'del(.autoMode.allow, .autoMode.environment)' "$TMP/s3.orig")" ] \
  && pass "S3: soft_deny, permissions, model unchanged" || fail "S3: other keys changed"

# S4 --------------------------------------------------------------------
CFG="$TMP/s4"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{"autoMode":{"allow":["Rule A","[atelier-managed:gate-runs] OLD stale text","$defaults","[atelier-managed:retired-rule] gone now","Rule B"]}}
JSON
out="$(run "$CFG")"
printf '%s' "$out" | grep -qF '~ [gate-runs]' && pass "S4: diff shows ~ for the stale entry" || fail "S4: no ~ line (out: $out)"
printf '%s' "$out" | grep -qF -- '- [retired-rule]' && pass "S4: diff shows - for the retired entry" || fail "S4: no - line (out: $out)"
run "$CFG" --apply >/dev/null
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json")" = "$(jq -nc --argjson m "$WA" '["Rule A",$m[0],"$defaults","Rule B"] + $m[1:]')" ] \
  && pass "S4: stale replaced in place (same position), retired removed, operator entries kept, missing managed appended" || fail "S4: got $(jq -c '.autoMode.allow' "$CFG/settings.json")"

# S5 --------------------------------------------------------------------
CFG="$TMP/s5"; mkdir -p "$CFG"
printf '{"autoMode":{"allow":["Only my rule"]}}\n' > "$CFG/settings.json"
run "$CFG" --apply >/dev/null
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json")" = "$(jq -nc --argjson m "$WA" '["Only my rule"] + $m')" ] \
  && pass "S5: no \$defaults added to an array that lacks one" || fail "S5: got $(jq -c '.autoMode.allow' "$CFG/settings.json")"

# S6 --------------------------------------------------------------------
for c in s2 s3 s4 s5; do
  CFG="$TMP/$c"
  cp "$CFG/settings.json" "$TMP/$c.after1"
  out="$(run "$CFG")"
  printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q 'already in sync' \
    && pass "S6/$c: read-only run on synced file exits 0 'already in sync'" || fail "S6/$c: (out: $out)"
  run "$CFG" --apply >/dev/null
  cmp -s "$CFG/settings.json" "$TMP/$c.after1" && pass "S6/$c: second --apply is byte-identical" || fail "S6/$c: file changed on second apply"
done

# S7 --------------------------------------------------------------------
CFG="$TMP/s7"; mkdir -p "$CFG"
printf '{ not json' > "$CFG/settings.json"
out="$(run "$CFG" --apply)"
[ "$(cat "$CFG/settings.json")" = '{ not json' ] && pass "S7: invalid JSON left untouched" || fail "S7: rewritten"
printf '%s' "$out" | grep -q 'not valid JSON' && printf '%s' "$out" | grep -q 'RC=0' \
  && pass "S7: warns and exits 0" || fail "S7: (out: $out)"
CFG="$TMP/s7b"; mkdir -p "$CFG"
printf '{"autoMode":{"allow":"nope"}}\n' > "$CFG/settings.json"
cp "$CFG/settings.json" "$TMP/s7b.orig"
out="$(run "$CFG" --apply)"
cmp -s "$CFG/settings.json" "$TMP/s7b.orig" && printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q 'non-array' \
  && pass "S7: non-array autoMode.allow left untouched, warned, rc 0" || fail "S7b: (out: $out)"

# S8 --------------------------------------------------------------------
out="$(run "$TMP/s8" --template "$TMP/missing.json")"
printf '%s' "$out" | grep -q 'RC=2' && pass "S8: missing template exits 2" || fail "S8: (out: $out)"
printf '{"autoMode":{"allow":"x"}}\n' > "$TMP/badtmpl.json"
out="$(run "$TMP/s8" --template "$TMP/badtmpl.json")"
printf '%s' "$out" | grep -q 'RC=2' && pass "S8: template without allow array exits 2" || fail "S8: (out: $out)"
out="$(run "$TMP/s8" --bogus)"
printf '%s' "$out" | grep -q 'RC=2' && pass "S8: unknown flag exits 2" || fail "S8: (out: $out)"
out="$(run "$TMP/s8" --help)"
printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q -- '--apply' && pass "S8: --help exits 0 and documents --apply" || fail "S8: help (out: $out)"
[ ! -e "$TMP/s8" ] && pass "S8: failed runs create nothing" || fail "S8: created $TMP/s8"
# --config-dir flag and custom template
CFG="$TMP/s8c"
printf '{"autoMode":{"allow":["[atelier-managed:x] custom"]}}\n' > "$TMP/custom.json"
"$SYNC" --apply --template "$TMP/custom.json" --config-dir "$CFG" >/dev/null 2>&1
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json" 2>/dev/null)" = '["$defaults","[atelier-managed:x] custom"]' ] \
  && pass "S8: --config-dir and --template honored" || fail "S8c: got $(cat "$CFG/settings.json" 2>&1)"
[ "$(jq -r '.autoMode | has("environment")' "$CFG/settings.json")" = false ] \
  && pass "S8: template without managed environment entries adds no environment key" || fail "S8c: environment key created"

# S9 --------------------------------------------------------------------
leftover="$(find "$TMP" -name 'settings.json.atelier.*' | head -1)"
[ -z "$leftover" ] && pass "S9: no temp files left behind" || fail "S9: leftover $leftover"
[ -z "$(ls -A "$HOME")" ] && pass "S9: scratch HOME untouched (no ~/.claude*)" || fail "S9: HOME touched: $(ls -A "$HOME")"

# S10 -------------------------------------------------------------------
# environment management: in place update, stale dropped, hand-written
# entries byte-identical, $defaults preserved.
CFG="$TMP/s10"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{"autoMode":{"environment":["Hand written one, with \"quotes\" and ünïcode","$defaults","[atelier-managed:trusted-repos] OLD stale trusted text","[atelier-managed:retired-env] gone now","Hand | two"]}}
JSON
cp "$CFG/settings.json" "$TMP/s10.orig"
out="$(run "$CFG")"
cmp -s "$CFG/settings.json" "$TMP/s10.orig" && pass "S10: read-only run leaves the environment fixture untouched" || fail "S10: file changed without --apply"
printf '%s' "$out" | grep -q 'autoMode.environment managed-entry changes' && printf '%s' "$out" | grep -qF '~ [trusted-repos]' \
  && printf '%s' "$out" | grep -qF -- '- [retired-env]' && printf '%s' "$out" | grep -qF '+ [flows]' \
  && pass "S10: environment diff shows ~ stale, - retired, + new" || fail "S10: diff (out: $out)"
run "$CFG" --apply >/dev/null
[ "$(jq -c '.autoMode.environment' "$CFG/settings.json")" = "$(jq -nc --argjson m "$WE" --slurpfile o "$TMP/s10.orig" '[$o[0].autoMode.environment[0], "$defaults", $m[0], $o[0].autoMode.environment[4], $m[1]]')" ] \
  && pass "S10: stale replaced in place, retired dropped, \$defaults kept, missing flows appended" || fail "S10: got $(jq -c '.autoMode.environment' "$CFG/settings.json")"
[ "$(jq -c '.autoMode.environment[0], .autoMode.environment[3]' "$CFG/settings.json")" = "$(jq -c '.autoMode.environment[0], .autoMode.environment[4]' "$TMP/s10.orig")" ] \
  && pass "S10: hand-written environment entries are byte-identical after apply" || fail "S10: hand-written entry changed"
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json")" = "$(jq -nc --argjson m "$WA" '["$defaults"] + $m')" ] \
  && pass "S10: absent allow array created alongside as [\$defaults, managed...]" || fail "S10: allow got $(jq -c '.autoMode.allow' "$CFG/settings.json")"

# S11 -------------------------------------------------------------------
# {{registered_projects}} expansion from projects.json + fixture git repos.
P="$TMP/proj"; mkdir -p "$P"
git init -q "$P/alpha" && git -C "$P/alpha" remote add origin https://github.com/acme/widget.git
git init -q "$P/beta" && git -C "$P/beta" remote add origin git@github.com:acme/gadget.git
git init -q "$P/plain"
CFG="$TMP/s11"; mkdir -p "$CFG"
jq -n --arg a "$P/alpha" --arg b "$P/beta" --arg g "$P/gone" --arg p "$P/plain" '{projects:{($a):{},($b):{},($g):{},($p):{}}}' > "$CFG/projects.json"
run "$CFG" --apply >/dev/null
tr_entry="$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json")"
want_list="$P/alpha (origin acme/widget); $P/beta (origin acme/gadget); $P/gone; $P/plain"
case "$tr_entry" in *"are $want_list. Each is"*) pass "S11: placeholder expands to path (origin owner/name); https and scp remotes parsed, missing path and no-origin repo listed bare" ;; *) fail "S11: entry: $tr_entry" ;; esac
case "$tr_entry" in *'{{'*) fail "S11: unexpanded placeholder left" ;; *) pass "S11: no {{ placeholder left in the written entry" ;; esac
[ "$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:flows]"))' "$CFG/settings.json")" = "$(jq -r '.[1]' <<< "$WE")" ] \
  && pass "S11: entries without the placeholder are written verbatim" || fail "S11: flows entry changed"
# unreadable projects.json -> placeholder text
CFG="$TMP/s11b"; mkdir -p "$CFG"; printf '{ nope' > "$CFG/projects.json"
run "$CFG" --apply >/dev/null
jq -r '.autoMode.environment[1]' "$CFG/settings.json" | grep -qF "are $NOPROJ." \
  && pass "S11: unreadable projects.json -> '$NOPROJ'" || fail "S11b: $(jq -c '.autoMode.environment' "$CFG/settings.json")"

# S12 -------------------------------------------------------------------
# idempotence with registered projects; a registry change is detected as stale.
CFG="$TMP/s11"
cp "$CFG/settings.json" "$TMP/s12.after1"
out="$(run "$CFG")"
printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q 'already in sync' \
  && pass "S12: read-only run after apply exits 0 'already in sync' (rendered placeholder compared)" || fail "S12: (out: $out)"
run "$CFG" --apply >/dev/null
cmp -s "$CFG/settings.json" "$TMP/s12.after1" && pass "S12: second --apply is a byte-identical no-op" || fail "S12: file changed on second apply"
git init -q "$P/delta" && git -C "$P/delta" remote add origin https://github.com/acme/delta.git
jq --arg d "$P/delta" '.projects[$d] = {}' "$CFG/projects.json" > "$CFG/projects.json.new" && mv "$CFG/projects.json.new" "$CFG/projects.json"
out="$(run "$CFG")"
printf '%s' "$out" | grep -q 'RC=1' && printf '%s' "$out" | grep -qF '~ [trusted-repos]' \
  && pass "S12: a newly registered project makes trusted-repos stale (exit 1, ~ line)" || fail "S12: (out: $out)"
cmp -s "$CFG/settings.json" "$TMP/s12.after1" && pass "S12: ...and the read-only run wrote nothing" || fail "S12: read-only run wrote"
run "$CFG" --apply >/dev/null
jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json" | grep -qF "$P/delta (origin acme/delta)" \
  && pass "S12: --apply refreshes trusted-repos with the new project" || fail "S12: new project missing"

# S13 -------------------------------------------------------------------
# read-only default writes nothing, even with a registry and no settings.json.
CFG="$TMP/s13"; mkdir -p "$CFG"; cp "$TMP/s11/projects.json" "$CFG/projects.json"
out="$(run "$CFG")"
[ ! -e "$CFG/settings.json" ] && [ -z "$(find "$CFG" -name 'settings.json*')" ] && printf '%s' "$out" | grep -q 'RC=1' \
  && pass "S13: read-only on absent settings.json creates nothing (rc 1)" || fail "S13: (out: $out)"
printf '%s' "$out" | grep -qF '+ [trusted-repos]' && printf '%s' "$out" | grep -qF '+ [flows]' \
  && pass "S13: read-only run still previews the environment additions" || fail "S13: preview (out: $out)"

# S14 -------------------------------------------------------------------
# narrow-grant guard on the shipped template: no managed allow entry grants
# --admin, --auto or a force push unless it is phrased as a prohibition.
# shellcheck disable=SC2016
GUARD='.autoMode.allow[] | select(
  ((test("--admin")) and (test("[Nn]ever (with )?--admin") | not)) or
  ((test("--auto")) and (test("[Nn]ever with --auto") | not)) or
  ((test("force[- ]push|--force|--force-with-lease|push -f"; "i")) and (test("[Nn]ever[^.]*force"; "i") | not))
) | .[0:70]'
bad="$(jq -r "$GUARD" "$TEMPLATE")"
[ -z "$bad" ] && pass "S14: no template allow entry grants --admin, --auto or a force push" || fail "S14: broad grant: $bad"
jq -e '.autoMode.allow | map(select(startswith("[atelier-managed:merge]")))[0] | test("Never with --admin") and test("never with --auto")' "$TEMPLATE" >/dev/null \
  && pass "S14: merge entry carries the 'Never with --admin' / 'never with --auto' qualifiers" || fail "S14: merge entry lacks qualifiers"
# negative control: the guard flags permissive wording
neg="$(jq -nr '{autoMode:{allow:["[atelier-managed:x] merging with --admin is allowed","[atelier-managed:y] merging with --auto is fine","[atelier-managed:z] a force-push is allowed"]}}' | jq -r "$GUARD" | wc -l | tr -d ' ')"
[ "$neg" -eq 3 ] && pass "S14: guard self-check flags 3/3 permissive fixtures" || fail "S14: guard flagged $neg/3"

echo ""
if [ "$fails" -eq 0 ]; then echo "automode-user-sync: all assertions passed."; exit 0
else echo "automode-user-sync: $fails assertion(s) failed."; exit 1; fi
