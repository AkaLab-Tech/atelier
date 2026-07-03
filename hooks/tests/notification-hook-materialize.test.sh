#!/usr/bin/env bash
#
# Regression test for #41 — hooks/sync-notification-hook.sh (merge-safe
# materialize/remove of the Notification hook entry in
# $ATELIER_CONFIG_DIR/settings.json, reconciled against
# $ATELIER_CONFIG_DIR/operator.json's `.notification.enabled`).
#
# Coverage:
#   Group A — materialize: enabled=true adds atelier's Notification entry.
#   Group B — remove: enabled=false / absent removes it.
#   Group C — supersede-in-place: a pre-existing hand-added `afplay` entry is
#     replaced by atelier's entry rather than duplicated (entry count stays
#     the same, not +1).
#   Group D — merge-safety: an UNRELATED Notification hook entry and
#     arbitrary other top-level settings.json keys survive both the on and
#     off runs, byte-for-byte.
#   Group E — idempotence: a second run in the already-desired state is a
#     genuine no-op (mtime + content both unchanged).
#   Group F — operator.json integrity: `.language` and any other operator.json
#     key are never touched by this hook (it only reads .notification.enabled;
#     it never opens operator.json for writing).
#   Group G — edge cases: no pre-existing settings.json (created from
#     scratch); malformed existing settings.json is left alone, fail-open.
#   Group H — signature word-boundary correctness: an unrelated command that
#     merely contains "aplay" as a substring (not the aplay binary itself) is
#     NOT mistaken for atelier's own entry.
#
# Hermetic: temp ATELIER_CONFIG_DIR + HOME per case; no writes outside temp
# dirs; no real audio backend required (the hook never invokes a player).
#
# Run:  hooks/tests/notification-hook-materialize.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/sync-notification-hook.sh"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# get_mtime <file> — portable (BSD/macOS or GNU/Linux) mtime-in-seconds.
get_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# seed_settings <dir> — writes a settings.json with:
#   - an arbitrary top-level key ($schema-ish + a nested custom object)
#   - a permissions block (arbitrary other key)
#   - hooks.SessionStart: an unrelated hook event, untouched by this script
#   - hooks.Notification: [ pre-existing hand-added afplay entry, an
#     UNRELATED Notification hook (a different notifier entirely) ]
seed_settings() {
  local dir="$1"
  jq -n '{
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    customArbitraryKey: {foo: "bar", nested: [1,2,3]},
    permissions: {allow: ["Bash(git:*)"], deny: [], ask: []},
    hooks: {
      SessionStart: [
        {hooks: [{type: "command", command: "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/some-other.sh"}]}
      ],
      Notification: [
        {hooks: [{type: "command", command: "/usr/bin/afplay /Users/op/Music/ding.aiff"}]},
        {hooks: [{type: "command", command: "terminal-notifier -message hi"}]}
      ]
    }
  }' > "$dir/settings.json"
}

# seed_settings_substring_aplay <dir> — same as above, but the "unrelated"
# entry contains "aplay" as a bare substring (no word boundary) to probe the
# SIGNATURE regex's `\baplay\b` anchor (Group H).
seed_settings_substring_aplay() {
  local dir="$1"
  jq -n '{
    hooks: {
      Notification: [
        {hooks: [{type: "command", command: "my-aplayer-notify-tool --ping"}]}
      ]
    }
  }' > "$dir/settings.json"
}

# mk_op_json <dir> <enabled: true|false> [sound] — writes operator.json with
# BOTH .language (unrelated key) and .notification, to prove the hook never
# touches operator.json at all (Group F).
mk_op_json() {
  local dir="$1" enabled="$2" sound="${3:-}"
  if [ -n "$sound" ]; then
    jq -n --argjson en "$enabled" --arg s "$sound" \
      '{language: "Spanish", notification: {enabled: $en, sound: $s}}' > "$dir/operator.json"
  else
    jq -n --argjson en "$enabled" \
      '{language: "Spanish", notification: {enabled: $en}}' > "$dir/operator.json"
  fi
}

run_hook() {
  local cfg="$1" home="$2"
  ATELIER_CONFIG_DIR="$cfg" HOME="$home" bash "$HOOK"
}

# NOTIFY_BIN_FOR <home> — the exact settings.json command string atelier
# writes for its Notification entry. The hook quotes the absolute path
# (matching hooks.json's own `"${CLAUDE_PLUGIN_ROOT}"/hooks/x.sh` convention
# for paths that may contain spaces) — the stored JSON string value itself
# contains literal double-quote characters around the path.
NOTIFY_BIN_FOR() { printf '"%s/.local/bin/atelier-notify"' "$1"; }

echo "notification-hook-materialize (#41) — hermetic regression"
echo ""

# ---------------------------------------------------------------------------
# Syntax gate
# ---------------------------------------------------------------------------
bash -n "$HOOK" && pass "bash -n sync-notification-hook.sh" || fail "sync-notification-hook.sh has syntax errors"

# ===========================================================================
# Group A/C/D — materialize on: adds atelier's entry, supersedes the
# pre-existing afplay entry IN PLACE (no duplication), leaves the unrelated
# hook + arbitrary keys untouched.
# ===========================================================================

A_CFG="$TMP/a_cfg"; A_HOME="$TMP/a_home"; mkdir -p "$A_CFG" "$A_HOME"
seed_settings "$A_CFG"
mk_op_json "$A_CFG" true
BEFORE_SESSIONSTART="$(jq -c '.hooks.SessionStart' "$A_CFG/settings.json")"
BEFORE_UNRELATED="$(jq -c '.hooks.Notification[] | select(.hooks[0].command | test("terminal-notifier"))' "$A_CFG/settings.json")"
BEFORE_ARBITRARY="$(jq -c '{schema: ."$schema", custom: .customArbitraryKey, perms: .permissions}' "$A_CFG/settings.json")"

run_hook "$A_CFG" "$A_HOME" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "A: hook exits 0 (enabled=true)" || fail "A: hook exited $rc"

NOTIFY_BIN_A="$(NOTIFY_BIN_FOR "$A_HOME")"
COUNT_A="$(jq '.hooks.Notification | length' "$A_CFG/settings.json")"
[ "$COUNT_A" = "2" ] \
  && pass "A/C: Notification array still has 2 entries (afplay superseded in place, not duplicated)" \
  || fail "A/C: expected 2 Notification entries, got $COUNT_A"

jq -e --arg bin "$NOTIFY_BIN_A" \
  '.hooks.Notification[] | select(.hooks[0].command == $bin)' "$A_CFG/settings.json" >/dev/null 2>&1 \
  && pass "A: atelier's Notification entry present with command == \$HOME/.local/bin/atelier-notify" \
  || fail "A: atelier's Notification entry not found (want command == $NOTIFY_BIN_A)"

jq -e '.hooks.Notification[] | select(.hooks[0].command | test("^/usr/bin/afplay"))' "$A_CFG/settings.json" >/dev/null 2>&1 \
  && fail "C: stale hand-added afplay entry still present (should have been superseded)" \
  || pass "C: stale hand-added afplay entry is gone (superseded, not left duplicated)"

AFTER_SESSIONSTART="$(jq -c '.hooks.SessionStart' "$A_CFG/settings.json")"
[ "$BEFORE_SESSIONSTART" = "$AFTER_SESSIONSTART" ] \
  && pass "D: unrelated hooks.SessionStart entry untouched" \
  || fail "D: hooks.SessionStart changed: before=$BEFORE_SESSIONSTART after=$AFTER_SESSIONSTART"

AFTER_UNRELATED="$(jq -c '.hooks.Notification[] | select(.hooks[0].command | test("terminal-notifier"))' "$A_CFG/settings.json")"
[ "$BEFORE_UNRELATED" = "$AFTER_UNRELATED" ] \
  && pass "D: unrelated Notification hook (terminal-notifier) survives untouched" \
  || fail "D: unrelated Notification hook changed: before=$BEFORE_UNRELATED after=$AFTER_UNRELATED"

AFTER_ARBITRARY="$(jq -c '{schema: ."$schema", custom: .customArbitraryKey, perms: .permissions}' "$A_CFG/settings.json")"
[ "$BEFORE_ARBITRARY" = "$AFTER_ARBITRARY" ] \
  && pass "D: arbitrary other top-level keys (\$schema/customArbitraryKey/permissions) survive untouched" \
  || fail "D: arbitrary keys changed: before=$BEFORE_ARBITRARY after=$AFTER_ARBITRARY"

# ===========================================================================
# Group E — idempotence: a second run in the desired (already-on) state is a
# true no-op: content AND mtime unchanged.
# ===========================================================================

CONTENT_BEFORE_2ND="$(cat "$A_CFG/settings.json")"
MTIME_BEFORE_2ND="$(get_mtime "$A_CFG/settings.json")"
sleep 1.1   # ensure a real write would be detectable via a bumped mtime (1s resolution on some filesystems)
run_hook "$A_CFG" "$A_HOME" >/dev/null 2>&1
CONTENT_AFTER_2ND="$(cat "$A_CFG/settings.json")"
MTIME_AFTER_2ND="$(get_mtime "$A_CFG/settings.json")"
[ "$CONTENT_BEFORE_2ND" = "$CONTENT_AFTER_2ND" ] \
  && pass "E: second run in desired state (on) leaves content unchanged" \
  || fail "E: second run changed settings.json content"
[ "$MTIME_BEFORE_2ND" = "$MTIME_AFTER_2ND" ] \
  && pass "E: second run in desired state (on) does not bump mtime (true no-op, no write)" \
  || fail "E: mtime changed on a no-op run: before=$MTIME_BEFORE_2ND after=$MTIME_AFTER_2ND"

# ===========================================================================
# Group F — operator.json integrity: .language and .notification survive
# byte-for-byte; the hook never opens operator.json for writing.
# ===========================================================================

OP_CONTENT_AFTER="$(cat "$A_CFG/operator.json")"
OP_EXPECTED="$(jq -n '{language: "Spanish", notification: {enabled: true}}')"
[ "$(printf '%s' "$OP_CONTENT_AFTER" | jq -S .)" = "$(printf '%s' "$OP_EXPECTED" | jq -S .)" ] \
  && pass "F: operator.json (.language + .notification) unchanged after hook runs" \
  || fail "F: operator.json was mutated: $OP_CONTENT_AFTER"

# ===========================================================================
# Group B — remove: enabled=false removes atelier's entry, keeps the
# unrelated hook + arbitrary keys.
# ===========================================================================

B_CFG="$TMP/b_cfg"; B_HOME="$TMP/b_home"; mkdir -p "$B_CFG" "$B_HOME"
seed_settings "$B_CFG"
mk_op_json "$B_CFG" false

run_hook "$B_CFG" "$B_HOME" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "B: hook exits 0 (enabled=false)" || fail "B: hook exited $rc"

COUNT_B="$(jq '.hooks.Notification | length' "$B_CFG/settings.json")"
[ "$COUNT_B" = "1" ] \
  && pass "B: atelier-owned entry (afplay) removed, leaving exactly the unrelated entry" \
  || fail "B: expected 1 remaining Notification entry, got $COUNT_B"

jq -e '.hooks.Notification[] | select(.hooks[0].command | test("terminal-notifier"))' "$B_CFG/settings.json" >/dev/null 2>&1 \
  && pass "B: unrelated Notification hook (terminal-notifier) survives the off run" \
  || fail "B: unrelated Notification hook was lost on the off run"

NOTIFY_BIN_B="$(NOTIFY_BIN_FOR "$B_HOME")"
jq -e --arg bin "$NOTIFY_BIN_B" '.hooks.Notification[] | select(.hooks[0].command == $bin)' "$B_CFG/settings.json" >/dev/null 2>&1 \
  && fail "B: atelier's Notification entry is still present after disabling" \
  || pass "B: atelier's Notification entry is absent after disabling"

# B idempotence: second run in the (already-off) desired state is a no-op too.
CONTENT_B_1="$(cat "$B_CFG/settings.json")"
MTIME_B_1="$(get_mtime "$B_CFG/settings.json")"
sleep 1.1
run_hook "$B_CFG" "$B_HOME" >/dev/null 2>&1
CONTENT_B_2="$(cat "$B_CFG/settings.json")"
MTIME_B_2="$(get_mtime "$B_CFG/settings.json")"
[ "$CONTENT_B_1" = "$CONTENT_B_2" ] && [ "$MTIME_B_1" = "$MTIME_B_2" ] \
  && pass "E: second run in desired state (off) is a true no-op (content + mtime unchanged)" \
  || fail "E: off-state second run was not a no-op (content changed or mtime bumped)"

# ===========================================================================
# Group B (absent) — no operator.json at all defaults to off, same removal
# behavior, and the hook does not fabricate an operator.json.
# ===========================================================================

C_CFG="$TMP/c_cfg"; C_HOME="$TMP/c_home"; mkdir -p "$C_CFG" "$C_HOME"
seed_settings "$C_CFG"
# deliberately no operator.json

run_hook "$C_CFG" "$C_HOME" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "B(absent): hook exits 0 with no operator.json" || fail "B(absent): hook exited $rc"

COUNT_C="$(jq '.hooks.Notification | length' "$C_CFG/settings.json")"
[ "$COUNT_C" = "1" ] \
  && pass "B(absent): no operator.json defaults to off — atelier entry removed" \
  || fail "B(absent): expected 1 remaining Notification entry, got $COUNT_C"

[ ! -f "$C_CFG/operator.json" ] \
  && pass "B(absent): hook does not fabricate an operator.json" \
  || fail "B(absent): hook created an operator.json it should not have"

# ===========================================================================
# Group A (fresh) — settings.json with NO hooks.Notification key at all;
# enabled=true adds a brand-new single-entry array; other keys survive.
# ===========================================================================

D_CFG="$TMP/d_cfg"; D_HOME="$TMP/d_home"; mkdir -p "$D_CFG" "$D_HOME"
jq -n '{customArbitraryKey: "keep-me", hooks: {SessionStart: [{hooks: [{type: "command", command: "x.sh"}]}]}}' > "$D_CFG/settings.json"
mk_op_json "$D_CFG" true

run_hook "$D_CFG" "$D_HOME" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "A(fresh): hook exits 0 with no pre-existing Notification key" || fail "A(fresh): hook exited $rc"

COUNT_D="$(jq '.hooks.Notification | length' "$D_CFG/settings.json" 2>/dev/null)"
[ "$COUNT_D" = "1" ] \
  && pass "A(fresh): a brand-new Notification array with exactly 1 entry is created" \
  || fail "A(fresh): expected a fresh 1-entry Notification array, got $COUNT_D"
[ "$(jq -r '.customArbitraryKey' "$D_CFG/settings.json")" = "keep-me" ] \
  && pass "A(fresh): unrelated top-level key survives" \
  || fail "A(fresh): unrelated top-level key was lost"

# ===========================================================================
# Group G — edge cases: no settings.json at all (created from scratch);
# malformed settings.json is left alone (fail-open).
# ===========================================================================

E_CFG="$TMP/e_cfg"; E_HOME="$TMP/e_home"; mkdir -p "$E_CFG" "$E_HOME"
mk_op_json "$E_CFG" true
# deliberately no settings.json

run_hook "$E_CFG" "$E_HOME" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "G: hook exits 0 when settings.json is entirely absent" || fail "G: hook exited $rc"
[ -f "$E_CFG/settings.json" ] \
  && pass "G: settings.json created from scratch when absent" \
  || fail "G: settings.json was not created"
NOTIFY_BIN_E="$(NOTIFY_BIN_FOR "$E_HOME")"
jq -e --arg bin "$NOTIFY_BIN_E" '.hooks.Notification[] | select(.hooks[0].command == $bin)' "$E_CFG/settings.json" >/dev/null 2>&1 \
  && pass "G: freshly created settings.json contains atelier's Notification entry" \
  || fail "G: freshly created settings.json missing atelier's entry"

F_CFG="$TMP/f_cfg"; F_HOME="$TMP/f_home"; mkdir -p "$F_CFG" "$F_HOME"
mk_op_json "$F_CFG" true
printf '{ this is not valid json' > "$F_CFG/settings.json"
MALFORMED_BEFORE="$(cat "$F_CFG/settings.json")"

rc=0
ERR_F="$TMP/err_f"
ATELIER_CONFIG_DIR="$F_CFG" HOME="$F_HOME" bash "$HOOK" >/dev/null 2>"$ERR_F" || rc=$?
[ "$rc" -eq 0 ] && pass "G: malformed settings.json — hook still exits 0 (fail-open)" || fail "G: malformed settings.json — hook exited $rc"
MALFORMED_AFTER="$(cat "$F_CFG/settings.json")"
[ "$MALFORMED_BEFORE" = "$MALFORMED_AFTER" ] \
  && pass "G: malformed settings.json is left byte-for-byte untouched" \
  || fail "G: malformed settings.json was modified"
[ -s "$ERR_F" ] \
  && pass "G: malformed settings.json produces a stderr warning (not a silent data-loss risk)" \
  || fail "G: expected a stderr warning for malformed settings.json"

# ===========================================================================
# Group H — SIGNATURE word-boundary correctness: a command that merely
# contains "aplay" as a substring (not the real aplay binary) must NOT be
# treated as atelier-owned, so it is left alone rather than being replaced.
# ===========================================================================

H_CFG="$TMP/h_cfg"; H_HOME="$TMP/h_home"; mkdir -p "$H_CFG" "$H_HOME"
seed_settings_substring_aplay "$H_CFG"
mk_op_json "$H_CFG" true

run_hook "$H_CFG" "$H_HOME" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "H: hook exits 0 (substring-aplay probe)" || fail "H: hook exited $rc"

COUNT_H="$(jq '.hooks.Notification | length' "$H_CFG/settings.json")"
[ "$COUNT_H" = "2" ] \
  && pass "H: 'my-aplayer-notify-tool' (aplay substring, no word boundary) is NOT superseded — atelier's entry is appended alongside it" \
  || fail "H: expected 2 Notification entries (unrelated substring entry kept + atelier's added), got $COUNT_H"

jq -e '.hooks.Notification[] | select(.hooks[0].command == "my-aplayer-notify-tool --ping")' "$H_CFG/settings.json" >/dev/null 2>&1 \
  && pass "H: the aplay-substring command survives verbatim (not mistaken for the real aplay binary)" \
  || fail "H: the aplay-substring command was altered or removed"

# ===========================================================================
# Result
# ===========================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "notification-hook-materialize (#41): all assertions passed."
  exit 0
else
  echo "notification-hook-materialize (#41): $fails assertion(s) failed."
  exit 1
fi
