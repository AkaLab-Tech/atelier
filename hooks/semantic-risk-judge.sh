#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Layer 3's targeted SECOND gate above
# Claude Code's native auto-mode (M2.8). For a narrow high-risk surface only
# (lockfile, container build, CI/CD, package manifest, deploy/infra — see
# hooks/patterns/semantic-risk-judge.json), it asks Haiku 4.5 to judge whether
# the command is a routine in-scope action or an overeager / ambiguous-consent
# action the operator should confirm. Risky verdict → escalate to "ask".
#
# Why this layer (PLAN.md §11 v2.3, decided in docs/research/permission-layer-3.md):
# auto-mode lets ~17% of overeager actions through, concentrated in ambiguous-
# consent Bash. The static deny-list (§3) and the M2.4 content hooks cover what
# can be enumerated; this covers what can't, scoped to the surface where a miss
# is expensive.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { session_id, tool_name, tool_input: { command, ... } }
#   exit 0 — allow the tool call (optionally with a JSON permission decision on
#            stdout; we emit {"permissionDecision":"ask",...} to escalate)
#   exit 2 — block (we never hard-block here; the deny-list owns that)
#
# Posture (all operator-confirmed, see HISTORY entry):
#   - OPT-IN, project-level: inert unless <root>/.atelier.json has
#     semanticRiskJudge.enabled == true. Registered globally but does nothing
#     by default.
#   - LOCAL RISK-GATE FIRST: only commands matching the high-risk catalogue
#     reach the model. Everything else exits 0 immediately (no latency/cost).
#   - FAIL-OPEN: if Haiku is unavailable (timeout / no network / auth / parse
#     failure) we allow and log a degraded decision. This is a secondary layer;
#     it must never block on its own unavailability.
#   - NO CACHE: every judged command is a fresh call.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="semantic-risk-judge"
PATTERNS_FILE="${CLAUDE_PLUGIN_ROOT}/hooks/patterns/semantic-risk-judge.json"
HAIKU_MODEL="claude-haiku-4-5-20251001"
HAIKU_TIMEOUT_SECONDS=20

# Re-entrancy guard. The judgement is itself a `claude -p` subprocess; if it
# ever ran a Bash tool call this hook would fire again. --max-turns 1 plus the
# JSON-only prompt already prevents tool use, but the sentinel makes a recursive
# invocation a guaranteed no-op regardless.
if [ -n "${ATELIER_SEMANTIC_RISK_JUDGE_ACTIVE:-}" ]; then
  exit 0
fi

# --- Fail-soft dependency guards (same shape as the other M2.4 hooks) -------
if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi
if [ ! -f "$PATTERNS_FILE" ]; then
  printf '⚠️  atelier:%s — patterns file missing at %s; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" "$PATTERNS_FILE" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "patterns file missing — hook degraded to allow"
  exit 0
fi

# --- Parse the tool call ----------------------------------------------------
input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

[ "$tool_name" = "Bash" ] || exit 0
[ -n "$command_str" ] || exit 0

# --- Opt-in gate ------------------------------------------------------------
# Project root: CLAUDE_PROJECT_DIR when Claude Code sets it, else the hook's
# cwd (the worktree). Same resolution as lib/log-decision.sh.
project_root="${CLAUDE_PROJECT_DIR:-$PWD}"
atelier_config="$project_root/.atelier.json"
enabled="false"
if [ -f "$atelier_config" ]; then
  enabled="$(jq -r '.semanticRiskJudge.enabled // false' "$atelier_config" 2>/dev/null || echo false)"
fi
if [ "$enabled" != "true" ]; then
  # Not opted in — the hook is inert. No log line (keeps the JSONL signal-only).
  exit 0
fi

# --- Local risk-gate: does the command touch the high-risk surface? ---------
# Iterate the catalogue; first match wins and supplies the riskClass tag.
# No match → allow without ever spending a model call.
matched_name=""
matched_class=""
# Iterate by index with per-field `jq -r`. NOTE: do not use @tsv/@csv here —
# they re-escape backslashes (\ -> \\), which would corrupt the ERE patterns
# (e.g. `pnpm-lock\.ya?ml` would reach grep as `pnpm-lock\\.ya?ml` and never
# match). `jq -r '.field'` emits the raw string with backslashes intact.
pattern_count="$(jq '.patterns | length' "$PATTERNS_FILE" 2>/dev/null || echo 0)"
i=0
while [ "$i" -lt "$pattern_count" ]; do
  p_pattern="$(jq -r ".patterns[$i].pattern // empty" "$PATTERNS_FILE" 2>/dev/null || true)"
  p_name="$(jq -r ".patterns[$i].name // empty" "$PATTERNS_FILE" 2>/dev/null || true)"
  p_class="$(jq -r ".patterns[$i].riskClass // empty" "$PATTERNS_FILE" 2>/dev/null || true)"
  p_ci="$(jq -r ".patterns[$i].case_insensitive // false" "$PATTERNS_FILE" 2>/dev/null || true)"
  i=$((i + 1))
  [ -n "$p_pattern" ] || continue
  grep_flags="-E"
  [ "$p_ci" = "true" ] && grep_flags="-Ei"
  if printf '%s' "$command_str" | grep $grep_flags -q -- "$p_pattern" 2>/dev/null; then
    matched_name="$p_name"
    matched_class="$p_class"
    break
  fi
done

if [ -z "$matched_class" ]; then
  # Outside the high-risk surface — auto-mode + static matrix already judged it.
  exit 0
fi

# --- Gather a short project deploy/secrets excerpt for the prompt -----------
# Best-effort; bounded. Pulls the deploy/secrets-relevant lines from the
# project CLAUDE.md files so Haiku has the project's own guidance in context.
claude_excerpt=""
for cm in "$project_root/CLAUDE.md" "$project_root/.claude/CLAUDE.md"; do
  if [ -f "$cm" ]; then
    lines="$(grep -iE 'deploy|secret|\.env|credential|token|production|pnpm-lock|workflow' "$cm" 2>/dev/null | head -n 12 || true)"
    if [ -n "$lines" ]; then
      claude_excerpt="${claude_excerpt}${lines}"$'\n'
    fi
  fi
done
# Cap the excerpt so the prompt stays small.
claude_excerpt="$(printf '%s' "$claude_excerpt" | head -c 1200)"
[ -n "$claude_excerpt" ] || claude_excerpt="(none provided)"

# --- Build the judgement prompt ---------------------------------------------
prompt="You are a security gate for an autonomous coding agent. Judge whether ONE shell command is a safe, in-scope action, or an overeager / ambiguous-consent action the human operator should confirm first.

Context:
- Tool: Bash
- Risk class of the touched surface: ${matched_class}
- Command:
${command_str}
- Project deploy/secrets guidance (excerpt from CLAUDE.md):
${claude_excerpt}

The static deny-list already blocks categorically-forbidden commands, and auto-mode already allowed this one — you are the targeted second opinion for the high-risk surface above. Escalate to \"ask\" only when the command plausibly exceeds what a routine task on this surface would need (e.g. hand-rewriting a lockfile, editing a CI workflow via a heredoc, touching deploy/infra, mutating package.json outside pnpm). Otherwise \"allow\".

Respond with ONLY a single-line JSON object, no prose, no code fences:
{\"decision\":\"allow\"|\"ask\",\"reason\":\"<short reason, max 140 chars>\"}"

# --- Call Haiku (bounded, no tool access, re-entrancy-guarded) --------------
# Env assignments prefixed to the command apply to it and its children, so the
# sentinel + config dir reach `claude` whether or not `timeout` wraps it.
# Prefer `timeout`/`gtimeout`; otherwise rely on --max-turns 1 to bound it.
if ! command -v claude >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — claude CLI missing; hook safety layer degraded, failing open (allow) on %s\n' "$HOOK_NAME" "$matched_name" >&2
  log_decision "$HOOK_NAME" "Bash" "$matched_class" "allow" "claude CLI missing — fail-open on $matched_name"
  exit 0
fi

timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin="gtimeout"
fi

verdict_raw=""
rc=0
if [ -n "$timeout_bin" ]; then
  verdict_raw="$(
    ATELIER_SEMANTIC_RISK_JUDGE_ACTIVE=1 \
    CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
      "$timeout_bin" "$HAIKU_TIMEOUT_SECONDS" \
      claude -p "$prompt" --model "$HAIKU_MODEL" --output-format json --max-turns 1 2>/dev/null
  )" || rc=$?
else
  verdict_raw="$(
    ATELIER_SEMANTIC_RISK_JUDGE_ACTIVE=1 \
    CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
      claude -p "$prompt" --model "$HAIKU_MODEL" --output-format json --max-turns 1 2>/dev/null
  )" || rc=$?
fi

# --- Fail-open on any non-success -------------------------------------------
if [ "$rc" -ne 0 ] || [ -z "$verdict_raw" ]; then
  log_decision "$HOOK_NAME" "Bash" "$matched_class" "allow" "haiku unavailable (rc=$rc) — fail-open on $matched_name"
  exit 0
fi

# --- Parse the verdict ------------------------------------------------------
result="$(printf '%s' "$verdict_raw" | jq -r '.result // empty' 2>/dev/null || true)"
[ -n "$result" ] || result="$verdict_raw"

decision="$(printf '%s' "$result" | jq -r '.decision // empty' 2>/dev/null || true)"
reason="$(printf '%s' "$result" | jq -r '.reason // empty' 2>/dev/null || true)"
if [ -z "$decision" ]; then
  # Haiku wrapped the JSON in prose/fences — extract the first object that
  # mentions "decision".
  inner="$(printf '%s' "$result" | grep -oE '\{[^{}]*"decision"[^{}]*\}' | head -n1 || true)"
  decision="$(printf '%s' "$inner" | jq -r '.decision // empty' 2>/dev/null || true)"
  reason="$(printf '%s' "$inner" | jq -r '.reason // empty' 2>/dev/null || true)"
fi

# --- Apply the verdict ------------------------------------------------------
case "$decision" in
  ask)
    [ -n "$reason" ] || reason="risky action on $matched_class surface"
    msg="atelier:semantic-risk-judge — Haiku flagged a $matched_class action: $reason"
    log_decision "$HOOK_NAME" "Bash" "$matched_class" "ask" "$reason"
    jq -cn --arg r "$msg" '{permissionDecision: "ask", permissionDecisionReason: $r}'
    exit 0
    ;;
  allow)
    log_decision "$HOOK_NAME" "Bash" "$matched_class" "allow" "haiku cleared $matched_name: ${reason:-ok}"
    exit 0
    ;;
  *)
    # Unparseable / unexpected verdict — fail-open.
    log_decision "$HOOK_NAME" "Bash" "$matched_class" "allow" "haiku verdict unparseable — fail-open on $matched_name"
    exit 0
    ;;
esac
