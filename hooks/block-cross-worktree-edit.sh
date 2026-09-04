#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Edit / Write / MultiEdit / NotebookEdit.
# Categorical enforcement of per-task worktree isolation (#196a). Denies a
# session from editing a sibling task's worktree while it already owns a
# DIFFERENT worktree of the same repository — without denying anything to a
# caller that owns nothing (the operator's own session, and troubleshooting
# reads/edits from outside a claimed worktree, must keep working).
#
# Why this hook exists (#196 board finding): narrowing the static
# `<worktree>-worktrees` Edit/Write grants in settings.template.json (the
# audit's cited fix site) would deny EVERY task, since every worktree lives
# under the same `-worktrees` parent directory as its siblings — there is no
# static glob that expresses "this task's worktree, not any other". The
# categorical mechanism has to be behavioural (who currently owns what),
# which only a PreToolUse hook can decide.
#
# Deny rule (design doc, verbatim):
#   deny <=> target path resolves into a worktree owned, FRESH, by token T1
#            AND T1 != T2 (the caller)
#            AND T2 already freshly owns some OTHER worktree in that same
#                container (the repo family sharing one git-common-dir).
#   Every other path allows.
#
# Ownership is SELF-CLAIMED ON FIRST WRITE (no binding required from
# callers — covers /next-task, /atelier:babysit-prs, the orchestrator's
# review-fix loop, /atelier:resume-task, and any future entry point, by
# construction) and keyed PER WORKTREE, not per session (one babysit pass
# may own many worktrees at once).
#
# Session token resolution (see the investigation note below): this hook
# needs a token that stays STABLE across a `Task` subagent dispatch — the
# orchestrator, implementer, tester, pr-author, etc. of one task chain must
# all be recognised as the same owner. Two sources were named by the design:
# the PreToolUse payload's `.session_id`, and a `.transcript_path`-derived
# session root. Investigating from inside a live `Task`-dispatched subagent
# in this harness (#196a implementation) found:
#   - `CLAUDE_CODE_SESSION_ID` (env) differs between a dispatching session
#     and the `Task` subagent it spawns (the subagent also carries
#     `CLAUDE_CODE_CHILD_SESSION=1`) — so a per-invocation session id is
#     NOT stable across dispatch, and neither is the hook payload's
#     `.session_id` field, which mirrors it.
#   - `CLAUDE_CODE_BRIDGE_SESSION_ID` (env), when present, IS inherited
#     unchanged by every subagent in the chain (ordinary child-process env
#     inheritance) and matches the top-level operator-facing session for
#     the whole interaction — exactly the granularity this hook needs: one
#     token per continuous operator-initiated run, however many
#     specialists it dispatches, distinct across separate concurrent runs.
#   This hook therefore prefers `CLAUDE_CODE_BRIDGE_SESSION_ID` when set,
#   falls back to the payload `.session_id` (still useful when a caller
#   invokes the hook directly / outside a bridged run), then to a session
#   root derived from `.transcript_path`, and degrades to "no stable
#   token" (always allow) only if none resolve — never to a denial. This
#   substitution was NOT independently re-confirmed against a live
#   PreToolUse payload (the harness's own self-modification classifier
#   correctly refused an attempt to wire a temporary diagnostic hook mid-
#   task) — flagged for operator/reviewer sign-off, per the design doc's
#   instruction to surface rather than silently narrow this mechanism.
#
# Atomic claim via `mkdir` (the exclusive primitive; no `flock` on bash
# 3.2.57/BSD) under
#   $ATELIER_CONFIG_DIR/state/worktree-owner/<container-id>--<worktree-id>/
# with the owner token in a `token` file and the raw worktree path in a
# `path` file (needed later to resolve THAT worktree's own TTL when
# checking whether the caller owns it fresh). Stale reclaim is `mv`
# (atomic) -> `rm -rf` -> `mkdir`, avoiding an `rm`-then-`mkdir` window. A
# racer finding the claim directory but no `token` file yet (the writer
# hasn't finished) treats it as unowned-in-flight -> allow, never as a
# foreign owner.
#
# TTL (`ownerTtlSeconds`, default 43200) for any one claim is read from
# THAT claim's own worktree's project `.atelier.json` — not the caller's
# cwd — since a workspace-scope babysit pass may act across projects with
# different configs.
#
# Portability: no GNU-only flags anywhere in this script. Canonicalisation
# is `cd "$dir" && pwd -P` (never `realpath`/`readlink -f`), walking up to
# the nearest existing ancestor for not-yet-existing Write targets. `stat`
# is tried in BSD form then GNU form; neither working degrades to allow.
#
# Failure posture — every degraded path allows: no `jq`; unset/unwritable
# `$ATELIER_CONFIG_DIR`; state dir uncreatable; no working `stat`; target
# worktree gone (not inside a git worktree at all); canonicalisation
# failure. This hook must never be why a write fails for an infrastructure
# reason — the operator's own session has to keep working regardless.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { session_id, transcript_path, tool_name,
#                    tool_input: { file_path | notebook_path, ... } }
#   exit 0 — allow the tool call
#   exit 2 — block (stderr goes to Claude's context with the explanation)

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-cross-worktree-edit"
DEFAULT_TTL_SECONDS=43200

degrade_allow() {
  local reason="$1"
  printf '⚠️  atelier:%s — %s; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" "$reason" >&2
  log_decision "$HOOK_NAME" "${tool_name:-?}" "" "allow" "degraded — $reason"
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  degrade_allow "jq missing"
fi

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

target_path=""
case "$tool_name" in
  NotebookEdit)
    target_path="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null || true)"
    ;;
  *)
    target_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    ;;
esac
[ -n "$target_path" ] || exit 0

# ---- portable helpers -------------------------------------------------

# Nearest existing ancestor directory of a (possibly not-yet-existing)
# path, canonicalised with `cd && pwd -P` — never realpath/readlink -f.
_canon_existing_ancestor() {
  local d="$1" parent
  while [ ! -d "$d" ]; do
    parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && { printf ''; return 1; }
    d="$parent"
  done
  (cd "$d" 2>/dev/null && pwd -P) || return 1
}

# BSD stat (`-f %m`) then GNU stat (`-c %Y`); neither working -> failure,
# caller must treat that as a degraded/allow path, never as "stale".
_stat_mtime() {
  local f="$1" m
  m="$(stat -f %m "$f" 2>/dev/null)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  m="$(stat -c %Y "$f" 2>/dev/null)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  return 1
}

# Stable filesystem-safe id for an absolute path. Not a security boundary
# (collisions only cost isolation strength, never safety — a false
# collision could at worst under- or over-scope a claim within the state
# dir) — `cksum` is POSIX and needs no extra dependency beyond what every
# other hook in this repo already assumes (coreutils-equivalent `stat`).
_encode_id() {
  printf '%s' "$1" | cksum | tr -s ' ' '-'
}

# ownerTtlSeconds for a given worktree, read from THAT worktree's own
# project .atelier.json (never the caller's cwd). Missing/unreadable/
# non-numeric -> DEFAULT_TTL_SECONDS.
_ttl_for_worktree() {
  local wt="$1" ttl=""
  if [ -f "$wt/.atelier.json" ]; then
    ttl="$(jq -r '.ownerTtlSeconds // empty' "$wt/.atelier.json" 2>/dev/null || true)"
  fi
  case "$ttl" in
    ''|*[!0-9]*) ttl="$DEFAULT_TTL_SECONDS" ;;
  esac
  printf '%s' "$ttl"
}

# ---- resolve the target's worktree + container -------------------------

target_dir="$(dirname "$target_path")"
canon_dir="$(_canon_existing_ancestor "$target_dir")" || degrade_allow "no existing ancestor for $target_path"
[ -n "$canon_dir" ] || degrade_allow "canonicalisation failed for $target_path"

command -v git >/dev/null 2>&1 || degrade_allow "git missing"

W="$(cd "$canon_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$W" ] || degrade_allow "target worktree gone — $target_path is not inside any git worktree"

common_dir_raw="$(cd "$W" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$common_dir_raw" ] || degrade_allow "could not resolve git-common-dir for $W"
case "$common_dir_raw" in
  /*) container_dir="$common_dir_raw" ;;
  *) container_dir="$(cd "$W/$common_dir_raw" 2>/dev/null && pwd -P || true)" ;;
esac
[ -n "$container_dir" ] || container_dir="$W" # degrade gracefully — under-scopes isolation, never over-denies

# ---- session token -------------------------------------------------------

token="${CLAUDE_CODE_BRIDGE_SESSION_ID:-}"
if [ -z "$token" ]; then
  token="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  [ -n "$transcript_path" ] && token="$(dirname "$transcript_path" 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  # No stable identity available at all — an unstable token can never be
  # denied (PLAN.md #196a design doc). Degrades enforcement, never blocks
  # a legitimate edit.
  exit 0
fi

# ---- state dir -----------------------------------------------------------

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
state_dir="$ATELIER_CONFIG_DIR/state/worktree-owner"
mkdir -p "$state_dir" 2>/dev/null || degrade_allow "\$ATELIER_CONFIG_DIR ($ATELIER_CONFIG_DIR) unwritable"

container_id="$(_encode_id "$container_dir")"
w_id="$(_encode_id "$W")"
key="${container_id}--${w_id}"
target_claim_dir="$state_dir/$key"
target_token_file="$target_claim_dir/token"

block() {
  local other_worktree="$1"
  cat >&2 <<MSG
🚫 atelier:block-cross-worktree-edit BLOCKED
   Tool:      $tool_name $target_path
   Worktree:  $W
   Reason:    this worktree is owned by a different, still-active session, and your session already owns a different worktree of the same repository ($other_worktree).
   Rule:      PLAN.md #196a — per-task worktree isolation is enforced categorically by this hook, not by the (necessarily shared) Edit/Write permission glob.
   Action:    finish or hand off the worktree you already own before touching this one, or run this edit from a session that owns nothing yet (e.g. a fresh /atelier:resume-task on this worktree).
   Override:  none from inside this session — a genuine deliberate cross-worktree edit is the operator's call, made manually outside Claude Code, or after the owning session's claim ages out (ownerTtlSeconds in .atelier.json, default ${DEFAULT_TTL_SECONDS}s).
MSG
  log_decision "$HOOK_NAME" "$tool_name" "$key" "block" "worktree $W owned by a foreign fresh session; caller already owns $other_worktree"
  exit 2
}

# ---- claim / check the target worktree -----------------------------------

if mkdir "$target_claim_dir" 2>/dev/null; then
  # Fresh claim — self-claimed on first write. Minimize the window between
  # mkdir and the token write, but a crash in between is an accepted,
  # extremely narrow residual gap (same class as every other hook's
  # best-effort logging).
  printf '%s' "$token" > "$target_token_file" 2>/dev/null
  printf '%s' "$W" > "$target_claim_dir/path" 2>/dev/null
  log_decision "$HOOK_NAME" "$tool_name" "$key" "allow" "claimed $W"
  exit 0
fi

if [ ! -f "$target_token_file" ]; then
  # Race: another caller's mkdir won but hasn't written its token file yet.
  # Unowned-in-flight, never a foreign owner.
  exit 0
fi

owner_token="$(cat "$target_token_file" 2>/dev/null || true)"
if [ -z "$owner_token" ] || [ "$owner_token" = "$token" ]; then
  # Empty/unreadable token file (same as the in-flight race above) or we
  # are the recorded owner ourselves.
  exit 0
fi

# Foreign owner — is the claim still fresh?
ttl="$(_ttl_for_worktree "$W")"
mtime="$(_stat_mtime "$target_token_file")" || degrade_allow "no working stat — cannot judge claim freshness for $W"
now="$(date +%s)"
age=$((now - mtime))

if [ "$age" -ge "$ttl" ]; then
  # Stale — reclaim atomically: mv out, rm -rf, mkdir fresh. Avoids an
  # rm-then-mkdir window where a third caller could win the mkdir race
  # against an empty slot.
  stale_dir="${target_claim_dir}.stale.$$"
  if mv "$target_claim_dir" "$stale_dir" 2>/dev/null; then
    rm -rf "$stale_dir" 2>/dev/null
    if mkdir "$target_claim_dir" 2>/dev/null; then
      printf '%s' "$token" > "$target_token_file" 2>/dev/null
      printf '%s' "$W" > "$target_claim_dir/path" 2>/dev/null
    fi
  fi
  log_decision "$HOOK_NAME" "$tool_name" "$key" "allow" "reclaimed stale claim on $W (age ${age}s >= ttl ${ttl}s)"
  exit 0
fi

# Fresh foreign owner. Deny only if the caller already owns a DIFFERENT
# worktree, fresh, in this same container.
for candidate in "$state_dir/${container_id}--"*; do
  [ -d "$candidate" ] || continue
  [ "$candidate" = "$target_claim_dir" ] && continue
  [ -f "$candidate/token" ] || continue
  candidate_token="$(cat "$candidate/token" 2>/dev/null || true)"
  [ "$candidate_token" = "$token" ] || continue

  candidate_path="$(cat "$candidate/path" 2>/dev/null || true)"
  [ -n "$candidate_path" ] || candidate_path="$W"
  candidate_ttl="$(_ttl_for_worktree "$candidate_path")"
  candidate_mtime="$(_stat_mtime "$candidate/token")" || continue
  candidate_age=$((now - candidate_mtime))

  if [ "$candidate_age" -lt "$candidate_ttl" ]; then
    block "$candidate_path"
  fi
done

# Caller owns nothing else in this container — never denied.
exit 0
