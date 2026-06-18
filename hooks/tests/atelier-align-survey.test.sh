#!/usr/bin/env bash
#
# Test for atelier-align's survey/classification (TASK_017). Drives the real
# helper against a synthetic registry and asserts the per-project `needs` in
# --json, plus the slug filter. Filesystem + jq only.
#
# Run:  hooks/tests/atelier-align-survey.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALIGN="$REPO_ROOT/scripts/atelier-align"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

cfgd() { local d="$1"; mkdir -p "$d/.claude"; echo '{}' > "$d/.claude/settings.json"; printf '{"decisionPolicy":{"default":"%s"}}' "${2:-ask}" > "$d/.atelier.json"; }

# project dirs
cfgd "$TMP/drift"   ask;  printf '# R\n## P1 — Next\n- [ ] x\n'             > "$TMP/drift/ROADMAP.md";   printf '# IP\n' > "$TMP/drift/IN_PROGRESS.md"
cfgd "$TMP/current" auto; printf '# R\n## P1 — Next\n- [ ] x\n'             > "$TMP/current/ROADMAP.md"; printf '# IP\n' > "$TMP/current/IN_PROGRESS.md"
cfgd "$TMP/foreign" auto; printf '# R\n## Backlog\n### TASK-1 Alta\n'       > "$TMP/foreign/ROADMAP.md"; printf '# IP\n' > "$TMP/foreign/IN_PROGRESS.md"
cfgd "$TMP/hml"     auto; printf '# R\n## High Priority\n## Low Priority\n' > "$TMP/hml/ROADMAP.md";     printf '# IP\n' > "$TMP/hml/IN_PROGRESS.md"
mkdir -p "$TMP/partial/.claude"; echo '{}' > "$TMP/partial/.claude/settings.json"   # no .atelier.json
# (missing dir: registered but does not exist)

jq -n --arg d "$TMP/drift" --arg c "$TMP/current" --arg f "$TMP/foreign" --arg h "$TMP/hml" --arg p "$TMP/partial" --arg m "$TMP/gone" '{projects:{
  ($d):{setupVersion:"0.0.1"}, ($c):{setupVersion:"99.0.0"}, ($f):{setupVersion:"0.0.1"},
  ($h):{setupVersion:"0.0.1"}, ($p):{setupVersion:"0.0.1"}, ($m):{setupVersion:"0.0.1"}
}}' > "$CFG/projects.json"
jq -n --arg root "$TMP" --arg f "$TMP/foreign" --arg c "$TMP/current" '{workspaces:{ wt:{name:"wt", root:$root, members:[{path:$f,token:"foreign",role:"member"},{path:$c,token:"current",role:"member"}]} }}' > "$CFG/workspaces.json"

J="$(ATELIER_CONFIG_DIR="$CFG" bash "$ALIGN" --policy auto --json 2>&1)"
needs() { printf '%s' "$J" | jq -r --arg b "$1" '.projects[] | select(.path|endswith("/"+$b)) | .needs | join(",")'; }

[ "$(printf '%s' "$J" | jq -r .installedVersion)" != "null" ] && pass "reports installedVersion" || fail "no installedVersion"
printf '%s' "$(needs drift)"   | grep -q 'resync'          && pass "drift → resync"            || fail "drift needs: $(needs drift)"
[ -z "$(needs current)" ]                                  && pass "current (up-to-date, policy=auto) → no needs" || fail "current needs: $(needs current)"
printf '%s' "$(needs foreign)" | grep -q 'adopt-section5'  && pass "foreign → adopt-section5"   || fail "foreign needs: $(needs foreign)"
printf '%s' "$(needs hml)"     | grep -qv 'adopt-section5' && pass "High/Med/Low → NOT adopt-section5" || fail "hml wrongly flagged: $(needs hml)"
printf '%s' "$(needs hml)"     | grep -q 'resync'          && pass "High/Med/Low → still resync (drift)" || fail "hml needs: $(needs hml)"
printf '%s' "$(needs partial)" | grep -q 'restore'         && pass "partial → restore"         || fail "partial needs: $(needs partial)"
printf '%s' "$(needs gone)"    | grep -q 'unregister'      && pass "missing dir → unregister"  || fail "gone needs: $(needs gone)"

# policy need: drift has policy=ask, --policy auto → should include policy
printf '%s' "$(needs drift)" | grep -q 'policy' && pass "policy≠auto → policy need" || fail "drift missing policy need"

# slug filter: only the workspace's 2 members
JS="$(ATELIER_CONFIG_DIR="$CFG" bash "$ALIGN" wt --json 2>&1)"
[ "$(printf '%s' "$JS" | jq '.projects | length')" = "2" ] && pass "slug filter scopes to workspace members" || fail "slug filter count"

echo ""
if [ "$fails" -eq 0 ]; then echo "atelier-align survey: all assertions passed."; exit 0
else echo "atelier-align survey: $fails assertion(s) failed."; exit 1; fi
