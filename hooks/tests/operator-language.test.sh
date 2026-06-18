#!/usr/bin/env bash
#
# Test for the operator chat-language feature: atelier-set-language writes
# $ATELIER_CONFIG_DIR/operator.json, and load-operator-rules.sh injects the
# "address the operator in <lang>" directive when it is set (and nothing when not).
#
# Run:  hooks/tests/operator-language.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTER="$REPO_ROOT/scripts/atelier-set-language"
HOOK="$REPO_ROOT/hooks/load-operator-rules.sh"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

set_lang() { ATELIER_CONFIG_DIR="$CFG" bash "$SETTER" "$@" 2>&1; }
hook_out() { CLAUDE_PLUGIN_ROOT="$REPO_ROOT" ATELIER_CONFIG_DIR="$CFG" bash "$HOOK" 2>/dev/null; }

# --- setter: unset -> show ---
printf '%s' "$(set_lang --show)" | grep -q 'unset' && pass "--show reports unset initially" || fail "--show unset"

# --- setter: set + persists ---
set_lang Spanish >/dev/null
[ "$(jq -r '.language' "$CFG/operator.json")" = "Spanish" ] && pass "set writes language" || fail "set did not persist"
printf '%s' "$(set_lang --show)" | grep -q 'Spanish' && pass "--show reports the language" || fail "--show set"

# --- setter: preserves other keys ---
tmp="$(mktemp)"; jq '. + {keep:"me"}' "$CFG/operator.json" > "$tmp" && mv "$tmp" "$CFG/operator.json"
set_lang English >/dev/null
[ "$(jq -r '.language' "$CFG/operator.json")" = "English" ] && [ "$(jq -r '.keep' "$CFG/operator.json")" = "me" ] \
  && pass "set preserves other keys" || fail "set clobbered other keys"

# --- hook: injects directive when set ---
# Capture once (piping the hook directly into `grep -q` trips pipefail via SIGPIPE
# because the hook emits ~26KB and grep -q closes the pipe early).
H_SET="$(hook_out)"
printf '%s' "$H_SET" | grep -q 'Operator chat language' && pass "hook injects directive when set" || fail "hook did not inject"
printf '%s' "$H_SET" | grep -q 'Address the operator in \*\*English\*\*' && pass "directive names the language" || fail "directive missing language"
printf '%s' "$H_SET" | grep -q 'does NOT change `deliverableLanguage`' && pass "directive excludes deliverableLanguage" || fail "directive missing deliverableLanguage carve-out"

# --- setter: clear ---
set_lang --clear >/dev/null
[ "$(jq -r '.language // "GONE"' "$CFG/operator.json")" = "GONE" ] && pass "--clear removes language" || fail "--clear left language"

# --- hook: silent when unset ---
H_UNSET="$(hook_out)"
[ "$(printf '%s' "$H_UNSET" | grep -c 'Operator chat language')" = "0" ] && pass "hook silent when unset" || fail "hook injected with no language"

# --- setter: empty/no arg is an error ---
ATELIER_CONFIG_DIR="$CFG" bash "$SETTER" >/dev/null 2>&1 && fail "no-arg should error" || pass "no-arg errors"

echo ""
if [ "$fails" -eq 0 ]; then echo "operator-language: all assertions passed."; exit 0
else echo "operator-language: $fails assertion(s) failed."; exit 1; fi
