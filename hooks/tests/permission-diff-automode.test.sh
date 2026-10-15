#!/usr/bin/env bash
#
# Regression test for #456 — scripts/atelier-permission-diff covers
# autoMode.* arrays, permissions.additionalDirectories and the scalar modes,
# and describes all 12 env-prefixed gate-run shapes.
#
#   D1 added autoMode.allow entry -> "+" line, description "can do more"
#   D2 removed autoMode.allow entry -> "-" line, "can do less"
#   D3 added soft_deny entry -> "can do less"; removed soft_deny -> "can do more"
#   D4 scalar changes (permissions.defaultMode, autoMode.classifyAllShell) -> CHANGED block old -> new
#   D5 entry containing "|" rendered intact
#   D6 additionalDirectories added/removed
#   D7 the 12 env-prefixed shapes: none shows "(no description)"
#   D8 exit codes 0 (no change) / 1 (changes) / 2 (errors)
#   D9 legacy permissions.allow output keeps the short [allow] tag
#
# Hermetic: temp JSON files, no network.
#
# Run:  hooks/tests/permission-diff-automode.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PD="$REPO_ROOT/scripts/atelier-permission-diff"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-permission-diff autoMode.* / scalars / env shapes (#456)"

# pd <old-json> <new-json> -> output on stdout, rc in PD_RC
pd() {
  printf '%s\n' "$1" > "$TMP/old.json"
  printf '%s\n' "$2" > "$TMP/new.json"
  PD_OUT="$("$PD" --old "$TMP/old.json" --new "$TMP/new.json" --no-color 2>&1)"
  PD_RC=$?
}
has() { printf '%s' "$PD_OUT" | grep -qF -- "$1"; }

# D1
pd '{"autoMode":{"allow":["$defaults"]}}' '{"autoMode":{"allow":["$defaults","[atelier-managed:gate-runs] Running project test scripts is allowed."]}}'
[ "$PD_RC" -eq 1 ] && pass "D1: exit 1 on an added autoMode.allow entry" || fail "D1: rc=$PD_RC"
has '+ [atelier-managed:gate-runs] Running project test scripts is allowed.' && pass "D1: + line carries the exact entry" || fail "D1: no + line (out: $PD_OUT)"
has 'auto-mode classifier rule: gate-runs — the agent can do more' && pass "D1: managed marker id used in the description, 'can do more'" || fail "D1: description (out: $PD_OUT)"
has '[autoMode.allow]' && pass "D1: tagged [autoMode.allow]" || fail "D1: tag (out: $PD_OUT)"
has 'WILL now do these' && pass "D1: rendered in the NEW block" || fail "D1: block"

# D2
pd '{"autoMode":{"allow":["$defaults","Fetching docs from docs.example.test is fine"]}}' '{"autoMode":{"allow":["$defaults"]}}'
[ "$PD_RC" -eq 1 ] && has '- Fetching docs from docs.example.test is fine' && has 'auto-mode classifier rule: Fetching docs from docs.example.test is fine — the agent can do less' \
  && pass "D2: removed autoMode.allow entry -> '-' line, 'can do less'" || fail "D2: (rc=$PD_RC out: $PD_OUT)"
has 'can NO LONGER do these' && pass "D2: rendered in the REMOVED block" || fail "D2: block"

# long entry truncated to 60 chars + ellipsis
long="This is a deliberately long synthetic rule text that exceeds sixty characters by a lot"
pd '{"autoMode":{"allow":[]}}' "$(jq -nc --arg l "$long" '{autoMode:{allow:[$l]}}')"
has "auto-mode classifier rule: ${long:0:60}… — the agent can do more" \
  && pass "D2: unmarked long entry described by its first 60 chars" || fail "D2: long (out: $PD_OUT)"

# D3
pd '{"autoMode":{"soft_deny":[]}}' '{"autoMode":{"soft_deny":["Never push from the sandbox"]}}'
has '[autoMode.soft_deny]' && has 'Never push from the sandbox — the agent can do less' \
  && pass "D3: added soft_deny entry -> 'can do less'" || fail "D3: (out: $PD_OUT)"
pd '{"autoMode":{"soft_deny":["Never push from the sandbox"]}}' '{"autoMode":{"soft_deny":[]}}'
has 'Never push from the sandbox — the agent can do more' \
  && pass "D3: removed soft_deny entry -> 'can do more'" || fail "D3b: (out: $PD_OUT)"
pd '{}' '{"autoMode":{"hard_deny":["Never delete the repo"]}}'
has '[autoMode.hard_deny]' && has 'the agent can do less' && pass "D3: hard_deny added -> 'can do less'" || fail "D3c: (out: $PD_OUT)"
pd '{}' '{"autoMode":{"environment":["Repos live under ~/Work"]}}'
has '[autoMode.environment]' && has 'the agent can do more' && pass "D3: environment added -> 'can do more'" || fail "D3d: (out: $PD_OUT)"
pd '{}' '{"autoMode":{"allow":["$defaults"]}}'
has 'built-in defaults ($defaults)' && pass "D3: \$defaults gets a readable label" || fail "D3e: (out: $PD_OUT)"

# D4
pd '{"permissions":{"defaultMode":"acceptEdits"}}' '{"permissions":{"defaultMode":"auto"}}'
[ "$PD_RC" -eq 1 ] && has 'CHANGED settings' && has '~ acceptEdits' && has '→ auto' \
  && has 'default permission mode for sessions [permissions.defaultMode]' \
  && pass "D4: defaultMode change -> CHANGED block 'acceptEdits → auto'" || fail "D4: (rc=$PD_RC out: $PD_OUT)"
has '1 changed setting(s)' && pass "D4: impact summary counts the changed setting" || fail "D4: impact (out: $PD_OUT)"
pd '{}' '{"autoMode":{"classifyAllShell":true}}'
has '(unset) → true' && has '[autoMode.classifyAllShell]' && pass "D4: classifyAllShell (unset) → true" || fail "D4b: (out: $PD_OUT)"
pd '{"autoMode":{"classifyAllShell":true}}' '{"autoMode":{"classifyAllShell":true}}'
[ "$PD_RC" -eq 0 ] && pass "D4: identical scalar -> exit 0" || fail "D4c: rc=$PD_RC"

# D5
pd '{}' '{"autoMode":{"allow":["Rule with | a pipe | inside"]}}'
has '+ Rule with | a pipe | inside' && has 'auto-mode classifier rule: Rule with | a pipe | inside — the agent can do more' \
  && pass "D5: entry containing '|' rendered intact with its description" || fail "D5: (out: $PD_OUT)"

# D6
pd '{"permissions":{"additionalDirectories":["/a"]}}' '{"permissions":{"additionalDirectories":["/b"]}}'
has '+ /b' && has '- /a' && has 'extra directory the agent can access — the agent can do more' && has 'directory no longer accessible — the agent can do less' \
  && pass "D6: additionalDirectories added/removed with descriptions" || fail "D6: (out: $PD_OUT)"

# D7: every env-prefixed shape from the shipped template
pd '{"permissions":{"allow":[]}}' "$(jq -c '{permissions:{allow:[.permissions.allow[] | select(test("^Bash\\((PW_CHROME_CHANNEL=chrome|CI=1|CI=true) "))]}}' "$TEMPLATE")"
n_env="$(printf '%s' "$PD_OUT" | grep -c '^  + Bash(\|^  *+ Bash(' || true)"
[ "$n_env" -eq 12 ] && pass "D7: the template carries and the diff lists exactly 12 env-prefixed shapes" || fail "D7: expected 12 + lines, got $n_env (out: $PD_OUT)"
if has '(no description)'; then fail "D7: an env shape shows '(no description)'"; else pass "D7: none of the 12 env shapes shows '(no description)'"; fi
has 'run vitest with CI=1 set' && has 'run playwright tests via pnpm with PW_CHROME_CHANNEL=chrome set' && has "run the project's test scripts with CI=true set" && has 'run tests via pnpm with CI=1 set' \
  && pass "D7: descriptions combine the base command and the env assignment" || fail "D7: descriptions (out: $PD_OUT)"

# D8
pd '{"permissions":{"allow":["Bash(ls *)"]},"autoMode":{"allow":["$defaults"]}}' '{"autoMode":{"allow":["$defaults"]},"permissions":{"allow":["Bash(ls *)"]}}'
[ "$PD_RC" -eq 0 ] && pass "D8: no changes -> exit 0" || fail "D8: rc=$PD_RC (out: $PD_OUT)"
pd '{}' '{}'
[ "$PD_RC" -eq 0 ] && pass "D8: empty objects -> exit 0" || fail "D8: empty rc=$PD_RC"
"$PD" --old "$TMP/nope.json" --new "$TMP/new.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "D8: missing --old file -> exit 2" || fail "D8: missing file rc=$rc"
printf '{ nope' > "$TMP/bad.json"
"$PD" --old "$TMP/bad.json" --new "$TMP/new.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "D8: malformed JSON -> exit 2" || fail "D8: malformed rc=$rc"
"$PD" --new "$TMP/new.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "D8: missing --old flag -> exit 2" || fail "D8: missing flag rc=$rc"

# D9
pd '{"permissions":{"deny":[]}}' '{"permissions":{"deny":["Bash(rm -rf *)"]}}'
has '[deny]' && ! has '[permissions.deny]' && pass "D9: permissions.deny keeps the short [deny] tag" || fail "D9: (out: $PD_OUT)"

echo ""
if [ "$fails" -eq 0 ]; then echo "permission-diff-automode: all assertions passed."; exit 0
else echo "permission-diff-automode: $fails assertion(s) failed."; exit 1; fi
