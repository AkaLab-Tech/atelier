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
#   S15 (#633) managed soft_deny: rendered on an absent file, appended after
#       operator soft_deny entries (kept byte-identical), stale replaced
#   S16 (#633) per-project visibility via a stubbed gh: PUBLIC -> public,
#       PRIVATE / INTERNAL -> private, failing / empty gh -> "visibility
#       unknown", gh absent from PATH -> "visibility unknown"
#   S17 (#633) diff prints a category header only for categories with changes
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
# gh is always stubbed (never the real one, never the network): the stub answers
# `gh repo view <owner/name> --json visibility ...` from $GH_STUB_DIR/<owner>__<name>
# (file content = what gh would print) and exits 1 when no such file exists.
GH_STUB_DIR="$TMP/ghstub"; mkdir -p "$GH_STUB_DIR" "$TMP/stubbin"
cat > "$TMP/stubbin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = repo ] && [ "${2:-}" = view ] || exit 2
f="$GH_STUB_DIR/${3//\//__}"
[ -f "$f" ] || exit 1
cat "$f"
STUB
chmod +x "$TMP/stubbin/gh"
export GH_STUB_DIR PATH="$TMP/stubbin:$PATH"
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-automode-sync (#456)"

# Expected managed arrays as the sync writes them with no registered project:
# the {{registered_projects}} placeholder renders as NOPROJ.
NOPROJ="(no project registered yet)"
WA="$(jq -c '.autoMode.allow' "$TEMPLATE")"
WS="$(jq -c '.autoMode.soft_deny' "$TEMPLATE")"
# shellcheck disable=SC2016  # jq program, not shell
WE="$(jq -c --arg r "$NOPROJ" '.autoMode.environment | map(gsub("\\{\\{registered_projects\\}\\}"; $r))' "$TEMPLATE")"
MANAGED_TXT="$(jq -r '.autoMode.allow[0]' "$TEMPLATE")"
case "$MANAGED_TXT" in '[atelier-managed:gate-runs] '*) pass "template allow[0] starts with the gate-runs marker" ;; *) fail "template entry lacks marker" ;; esac
[ "$(jq -r '.autoMode.allow | length' "$TEMPLATE")" -eq 5 ] && [ "$(jq -r '.autoMode.environment | length' "$TEMPLATE")" -eq 2 ] \
  && [ "$(jq -r '.autoMode.soft_deny | length' "$TEMPLATE")" -eq 1 ] \
  && pass "template ships 5 managed allow, 2 managed environment and 1 managed soft_deny entries" || fail "template entry counts changed"
[ "$(jq -r '.autoMode.soft_deny[0] | startswith("[atelier-managed:dispatch-other] ")' "$TEMPLATE")" = true ] \
  && pass "template soft_deny[0] carries the dispatch-other marker" || fail "template soft_deny lacks dispatch-other marker"
jq -e '.autoMode.allow | map(select(startswith("[atelier-managed:merge]")))[0] | test("AtelierReviewer") and test("--match-head-commit")' "$TEMPLATE" >/dev/null \
  && pass "template merge entry names AtelierReviewer and requires --match-head-commit" || fail "template merge entry lacks AtelierReviewer / --match-head-commit"

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
want="$(jq -nc --argjson a "$WA" --argjson e "$WE" --argjson s "$WS" '{autoMode:{allow:(["$defaults"] + $a),environment:(["$defaults"] + $e),soft_deny:(["$defaults"] + $s)}}')"
[ "$(jq -cS . "$CFG/settings.json" 2>/dev/null)" = "$(printf '%s' "$want" | jq -cS .)" ] \
  && pass "S2: absent file -> [\"\$defaults\", managed...] in allow, environment and soft_deny" || fail "S2: got $(cat "$CFG/settings.json" 2>&1)"
# existing file without autoMode
CFG="$TMP/s2b"; mkdir -p "$CFG"
printf '{"env":{"K":"v"}}\n' > "$CFG/settings.json"
run "$CFG" --apply >/dev/null
[ "$(jq -cS . "$CFG/settings.json")" = "$(jq -ncS --argjson a "$WA" --argjson e "$WE" --argjson s "$WS" '{env:{K:"v"},autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults"]+$e),soft_deny:(["$defaults"]+$s)}}')" ] \
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
got="$(jq -c '.autoMode.soft_deny' "$CFG/settings.json")"
want="$(jq -c --argjson m "$WS" '.autoMode.soft_deny + $m' "$TMP/s3.orig")"
[ "$got" = "$want" ] && pass "S3: operator soft_deny entry kept first, managed soft_deny appended" || fail "S3: soft_deny got $got"
[ "$(jq -c 'del(.autoMode.allow, .autoMode.environment, .autoMode.soft_deny)' "$CFG/settings.json")" = "$(jq -c 'del(.autoMode.allow, .autoMode.environment, .autoMode.soft_deny)' "$TMP/s3.orig")" ] \
  && pass "S3: permissions, model unchanged" || fail "S3: other keys changed"

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
printf 'PUBLIC\n' > "$GH_STUB_DIR/acme__widget"
printf 'INTERNAL\n' > "$GH_STUB_DIR/acme__gadget"
CFG="$TMP/s11"; mkdir -p "$CFG"
jq -n --arg a "$P/alpha" --arg b "$P/beta" --arg g "$P/gone" --arg p "$P/plain" '{projects:{($a):{},($b):{},($g):{},($p):{}}}' > "$CFG/projects.json"
run "$CFG" --apply >/dev/null
tr_entry="$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json")"
want_list="$P/alpha (origin acme/widget, public); $P/beta (origin acme/gadget, private); $P/gone; $P/plain"
case "$tr_entry" in *"are $want_list. Each is"*) pass "S11: placeholder expands to path (origin owner/name, visibility); https and scp remotes parsed, missing path and no-origin repo listed bare" ;; *) fail "S11: entry: $tr_entry" ;; esac
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
printf 'PRIVATE\n' > "$GH_STUB_DIR/acme__delta"
jq --arg d "$P/delta" '.projects[$d] = {}' "$CFG/projects.json" > "$CFG/projects.json.new" && mv "$CFG/projects.json.new" "$CFG/projects.json"
out="$(run "$CFG")"
printf '%s' "$out" | grep -q 'RC=1' && printf '%s' "$out" | grep -qF '~ [trusted-repos]' \
  && pass "S12: a newly registered project makes trusted-repos stale (exit 1, ~ line)" || fail "S12: (out: $out)"
cmp -s "$CFG/settings.json" "$TMP/s12.after1" && pass "S12: ...and the read-only run wrote nothing" || fail "S12: read-only run wrote"
run "$CFG" --apply >/dev/null
jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json" | grep -qF "$P/delta (origin acme/delta, private)" \
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

# S15 -------------------------------------------------------------------
# managed soft_deny: stale replaced in place, retired dropped, operator entries kept.
CFG="$TMP/s15"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{"autoMode":{"soft_deny":["Operator deny one","[atelier-managed:dispatch-other] OLD stale text","$defaults","[atelier-managed:retired-deny] gone now","Operator | deny two"]}}
JSON
cp "$CFG/settings.json" "$TMP/s15.orig"
out="$(run "$CFG")"
printf '%s' "$out" | grep -q 'autoMode.soft_deny managed-entry changes' && printf '%s' "$out" | grep -qF '~ [dispatch-other]' \
  && printf '%s' "$out" | grep -qF -- '- [retired-deny]' \
  && pass "S15: soft_deny diff shows ~ stale and - retired" || fail "S15: diff (out: $out)"
cmp -s "$CFG/settings.json" "$TMP/s15.orig" && pass "S15: read-only run leaves soft_deny fixture untouched" || fail "S15: file changed without --apply"
run "$CFG" --apply >/dev/null
[ "$(jq -c '.autoMode.soft_deny' "$CFG/settings.json")" = "$(jq -nc --argjson m "$WS" --slurpfile o "$TMP/s15.orig" '[$o[0].autoMode.soft_deny[0], $m[0], "$defaults", $o[0].autoMode.soft_deny[4]]')" ] \
  && pass "S15: stale managed soft_deny replaced in place, retired dropped, operator entries and \$defaults kept" || fail "S15: got $(jq -c '.autoMode.soft_deny' "$CFG/settings.json")"
# non-array soft_deny is left alone
CFG="$TMP/s15b"; mkdir -p "$CFG"
printf '{"autoMode":{"soft_deny":"nope"}}\n' > "$CFG/settings.json"
cp "$CFG/settings.json" "$TMP/s15b.orig"
out="$(run "$CFG" --apply)"
cmp -s "$CFG/settings.json" "$TMP/s15b.orig" && printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q 'non-array' \
  && pass "S15: non-array soft_deny left untouched, warned, rc 0" || fail "S15b: (out: $out)"

# S16 -------------------------------------------------------------------
# visibility rendering via the stubbed gh.
P16="$TMP/p16"; mkdir -p "$P16"
for n in pub priv intl bad empty; do
  git init -q "$P16/$n" && git -C "$P16/$n" remote add origin "https://github.com/vis/$n.git"
done
printf 'PUBLIC\n' > "$GH_STUB_DIR/vis__pub"
printf 'PRIVATE\n' > "$GH_STUB_DIR/vis__priv"
printf 'INTERNAL\n' > "$GH_STUB_DIR/vis__intl"
printf 'WEIRD\n' > "$GH_STUB_DIR/vis__bad"
: > "$GH_STUB_DIR/vis__empty"
CFG="$TMP/s16"; mkdir -p "$CFG"
jq -n --arg d "$P16" '{projects:{($d+"/pub"):{},($d+"/priv"):{},($d+"/intl"):{},($d+"/bad"):{},($d+"/empty"):{}}}' > "$CFG/projects.json"
run "$CFG" --apply >/dev/null
tr_entry="$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json")"
# projects render in sorted-path order
want_list="$P16/bad (origin vis/bad, visibility unknown); $P16/empty (origin vis/empty, visibility unknown); $P16/intl (origin vis/intl, private); $P16/priv (origin vis/priv, private); $P16/pub (origin vis/pub, public)"
case "$tr_entry" in *"are $want_list. Each is"*) pass "S16: PUBLIC -> public, PRIVATE -> private, INTERNAL -> private, unrecognised/empty -> visibility unknown" ;; *) fail "S16: entry: $tr_entry" ;; esac
# gh exits non-zero for every repo (stub files removed)
rm -f "$GH_STUB_DIR"/vis__*
CFG="$TMP/s16b"; mkdir -p "$CFG"; cp "$TMP/s16/projects.json" "$CFG/projects.json"
run "$CFG" --apply >/dev/null
tr_entry="$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json")"
want_list="$P16/bad (origin vis/bad, visibility unknown); $P16/empty (origin vis/empty, visibility unknown); $P16/intl (origin vis/intl, visibility unknown); $P16/priv (origin vis/priv, visibility unknown); $P16/pub (origin vis/pub, visibility unknown)"
case "$tr_entry" in *"are $want_list. Each is"*) pass "S16: failing gh -> every project 'visibility unknown'" ;; *) fail "S16b: entry: $tr_entry" ;; esac
# gh absent from PATH: minimal PATH of symlinks to the tools the helper needs, no gh
NOGH="$TMP/nogh"; mkdir -p "$NOGH"
for t in bash env jq git sed tr cat mktemp mv rm mkdir dirname basename date head sort cmp diff awk grep printf find ls; do
  src="$(PATH="${PATH#"$TMP/stubbin:"}" command -v "$t" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$NOGH/$t"
done
CFG="$TMP/s16c"; mkdir -p "$CFG"; cp "$TMP/s16/projects.json" "$CFG/projects.json"
printf 'PUBLIC\n' > "$GH_STUB_DIR/vis__pub"   # would render public if the stub were reachable
ATELIER_CONFIG_DIR="$CFG" PATH="$NOGH" NO_COLOR=1 "$NOGH/bash" "$SYNC" --apply >/dev/null 2>&1
tr_entry="$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$CFG/settings.json" 2>/dev/null)"
case "$tr_entry" in *"$P16/pub (origin vis/pub, visibility unknown)"*) pass "S16: gh absent from PATH -> 'visibility unknown'" ;; *) fail "S16c: entry: $tr_entry" ;; esac
rm -f "$GH_STUB_DIR"/vis__*
# a project with no origin gets no visibility call at all
case "$(jq -r '.autoMode.environment[] | select(startswith("[atelier-managed:trusted-repos]"))' "$TMP/s11/settings.json")" in
  *"$P/plain."*) pass "S16: project without origin listed bare (no visibility)" ;; *) fail "S16: plain project rendering" ;; esac

# S17 -------------------------------------------------------------------
# a category header is printed only for categories with changes.
CFG="$TMP/s17"; mkdir -p "$CFG"
jq -nc --argjson a "$WA" --argjson e "$WE" --argjson s "$WS" '{autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults"]+$e),soft_deny:(["$defaults","[atelier-managed:dispatch-other] OLD"])}}' > "$CFG/settings.json"
out="$(run "$CFG")"
printf '%s' "$out" | grep -q 'autoMode.soft_deny managed-entry changes' \
  && ! printf '%s' "$out" | grep -q 'autoMode.allow managed-entry changes' \
  && ! printf '%s' "$out" | grep -q 'autoMode.environment managed-entry changes' \
  && pass "S17: only soft_deny stale -> only the soft_deny header" || fail "S17: (out: $out)"
jq -nc --argjson a "$WA" --argjson s "$WS" '{autoMode:{allow:(["$defaults"]+$a),environment:["$defaults","[atelier-managed:flows] OLD"],soft_deny:(["$defaults"]+$s)}}' > "$CFG/settings.json"
out="$(run "$CFG")"
printf '%s' "$out" | grep -q 'autoMode.environment managed-entry changes' \
  && ! printf '%s' "$out" | grep -q 'autoMode.allow managed-entry changes' \
  && ! printf '%s' "$out" | grep -q 'autoMode.soft_deny managed-entry changes' \
  && pass "S17: only environment stale -> only the environment header" || fail "S17b: (out: $out)"

echo ""
if [ "$fails" -eq 0 ]; then echo "automode-user-sync: all assertions passed."; exit 0
else echo "automode-user-sync: $fails assertion(s) failed."; exit 1; fi
