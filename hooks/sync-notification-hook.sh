#!/usr/bin/env bash
#
# atelier — reconciles the Notification hook entry in
# $ATELIER_CONFIG_DIR/settings.json against the operator's
# .notification.enabled preference in $ATELIER_CONFIG_DIR/operator.json.
#
# Shared by two call sites so install-time and session-time reconcile stay
# identical:
#   - hooks/hooks.json SessionStart entry (fires every session — picks up
#     toggles made via `atelier-set-notification` / /atelier:set-notification
#     since the last session start)
#   - install.sh phase_c_1_atelier_notification_hook (first-session coverage
#     at install time, before any session has started)
#   - atelier-set-notification itself (immediate reconcile right after a
#     write, so `--show` reflects reality without waiting for a new session)
#
# Merge-safety is the core invariant: atelier's own entry is identified by a
# stable SIGNATURE match on the hook's command string (references
# "atelier-notify", or one of the raw player binaries atelier-notify itself
# would invoke — afplay / paplay / aplay / canberra-gtk-play). That second
# half of the signature exists to supersede a pre-existing HAND-ADDED
# Notification entry (e.g. a bare `afplay ...` the operator wired up before
# this feature existed) in place, rather than leaving it duplicated
# alongside atelier's managed entry. Every other Notification hook and every
# other settings.json key is preserved untouched. Re-running in the already
# desired state is a no-op (no write, no mtime bump).
#
# The hook command anchors on the ABSOLUTE path $HOME/.local/bin/atelier-notify
# rather than $CLAUDE_PLUGIN_ROOT: Notification hooks can run with a PATH
# that excludes ~/.local/bin, and (per product-lead decision) resolving via
# the plugin root is not guaranteed available outside a live session either.
#
# Fail-open throughout: missing jq / config dir / malformed settings.json ->
# warn to stderr and exit 0. This runs as a SessionStart hook, where stdout
# becomes session context — a reconcile failure must never pollute that
# context or block the session.

set -uo pipefail

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
OP_FILE="$ATELIER_CONFIG_DIR/operator.json"
SETTINGS_FILE="$ATELIER_CONFIG_DIR/settings.json"
NOTIFY_BIN="$HOME/.local/bin/atelier-notify"

command -v jq >/dev/null 2>&1 || exit 0
[ -d "$ATELIER_CONFIG_DIR" ] || exit 0

ENABLED="false"
if [ -f "$OP_FILE" ]; then
  ENABLED="$(jq -r '.notification.enabled // false' "$OP_FILE" 2>/dev/null || printf 'false')"
fi
[ "$ENABLED" = "true" ] || ENABLED="false"

existing="{}"
if [ -f "$SETTINGS_FILE" ]; then
  existing="$(cat "$SETTINGS_FILE")"
  if ! printf '%s' "$existing" | jq empty >/dev/null 2>&1; then
    printf '!! atelier: %s is not valid JSON — leaving Notification hook alone\n' "$SETTINGS_FILE" >&2
    exit 0
  fi
fi

SIGNATURE='atelier-notify|afplay|paplay|\baplay\b|canberra-gtk-play'

if [ "$ENABLED" = "true" ]; then
  desired_entry=$(jq -n --arg cmd "\"$NOTIFY_BIN\"" '{hooks: [{type: "command", command: $cmd}]}')
  updated=$(printf '%s' "$existing" | jq \
    --argjson entry "$desired_entry" \
    --arg sig "$SIGNATURE" '
      .hooks = (.hooks // {}) |
      .hooks.Notification = (.hooks.Notification // []) |
      ((.hooks.Notification | any(.[]; any(.hooks[]?; .command // "" | test($sig)))) ) as $found |
      if $found then
        .hooks.Notification = ([.hooks.Notification[]
          | if (any(.hooks[]?; .command // "" | test($sig))) then $entry else . end])
      else
        .hooks.Notification = (.hooks.Notification + [$entry])
      end
    ')
else
  updated=$(printf '%s' "$existing" | jq \
    --arg sig "$SIGNATURE" '
      if ((.hooks.Notification // null) != null) then
        .hooks.Notification = ([.hooks.Notification[]?
          | select((any(.hooks[]?; .command // "" | test($sig))) | not)]) |
        (if (.hooks.Notification | length) == 0 then .hooks |= del(.Notification) else . end) |
        (if (.hooks | length) == 0 then del(.hooks) else . end)
      else . end
    ')
fi

if [ -z "$updated" ] || ! printf '%s' "$updated" | jq empty >/dev/null 2>&1; then
  printf '!! atelier: failed to compute Notification hook reconcile for %s\n' "$SETTINGS_FILE" >&2
  exit 0
fi

# No-op guard: skip the write entirely when the desired state already
# matches, so re-running never bumps the file's mtime.
if [ "$(printf '%s' "$existing" | jq -S .)" = "$(printf '%s' "$updated" | jq -S .)" ]; then
  exit 0
fi

mkdir -p "$ATELIER_CONFIG_DIR"
tmp="$(mktemp "${SETTINGS_FILE}.atelier.XXXXXX" 2>/dev/null)" || exit 0
printf '%s\n' "$updated" > "$tmp" 2>/dev/null && mv "$tmp" "$SETTINGS_FILE" || rm -f "$tmp"

exit 0
