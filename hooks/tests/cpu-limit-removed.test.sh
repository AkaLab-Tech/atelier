#!/usr/bin/env bash
#
# Absence guard for #584/#588 — the machine-wide CPU limit is gone. No agent,
# skill, command, template, operator rule or the safe-commit hook may carry the
# capacity options, the `capacity-held` state, "wait for a CPU turn" wording or
# an instruction to wrap work in `cpu-slot`.
#
# Allowed (stripped before scanning):
#   - the mandated negation sentence in operator-rules.md;
#   - the permission entry "Bash(atelier-cpu-slot:*)" in settings.template.json.
# scripts/atelier-cpu-slot itself is NOT scanned (retired in #587).
#
# Hermetic: greps committed files; the negative check uses a temp dir.
#
# Run:  hooks/tests/cpu-limit-removed.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2015,SC2016 # `A && pass || fail` idiom; backticks are literal prose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

ALLOWED_SENTENCE='There is no machine-wide CPU limit (#584): commits and suites never wait for a CPU turn; `cpu-slot <cmd>` is a pass-through kept for compatibility.'
ALLOWED_PERM='"Bash(atelier-cpu-slot:*)",'
# Any line that itself negates the limit ("There is no machine-wide CPU limit")
# is a denial, not an instruction: the operator-rules sentence and the matching
# statement in skills/safe-commit/SKILL.md.
ALLOWED_NEGATION='no machine-wide CPU limit'

FORBIDDEN=(
  'capacityRequeues'
  'slotMaxWait'
  'capacity-held'
  'held: CPU capacity'
  '(wait|waits|waiting|queue|queues|queued)[^.]*(for|on)[^.]*CPU (turn|slot)'
  'CPU turn'
  '(wrap|prefix|run|under|via|through|with)[^.]*`?(atelier-)?cpu-slot'
  '(^|[^A-Za-z-])(atelier-)?cpu-slot[[:space:]]+[<A-Za-z-]'
)

# scan <root>: prints offending lines (file:line:text) after removing the
# allowed exceptions; returns 0 when something forbidden is found.
scan() {
  local root="$1" hits="" p f
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    { find "$root/agents" "$root/skills" "$root/commands" "$root/templates" -type f 2>/dev/null
      ls "$root/operator-rules.md" "$root/hooks/safe-commit.sh" 2>/dev/null; } | sort)
  for p in "${FORBIDDEN[@]}"; do
    hits+="$(grep -HnEi -e "$p" "${files[@]}" 2>/dev/null \
      | grep -vF -e "$ALLOWED_SENTENCE" -e "$ALLOWED_PERM" -e "$ALLOWED_NEGATION" || true)"$'\n'
  done
  hits="$(printf '%s' "$hits" | sed '/^$/d' | sort -u)"
  [ -n "$hits" ] && { printf '%s\n' "$hits"; return 0; }
  return 1
}

echo "cpu-limit-removed"

# 1. Live tree is clean.
if out="$(scan "$REPO_ROOT")"; then
  fail "forbidden CPU-limit text remains:"; printf '%s\n' "$out" | sed 's/^/        /'
else
  pass "no CPU-limit options/state/wording in agents, skills, commands, templates, operator-rules, safe-commit.sh"
fi

# 2. The allowed exceptions really exist (so the strip is exercised).
grep -qF "$ALLOWED_SENTENCE" "$REPO_ROOT/operator-rules.md" \
  && pass "operator-rules.md carries the negation sentence" \
  || fail "operator-rules.md lost the negation sentence"
grep -qF "$ALLOWED_PERM" "$REPO_ROOT/templates/settings.template.json" \
  && pass "settings.template.json keeps the atelier-cpu-slot permission" \
  || fail "settings.template.json lost the atelier-cpu-slot permission"

# 3. Negative check: each forbidden token planted in a fixture is detected.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/agents" "$tmp/skills" "$tmp/commands" "$tmp/templates" "$tmp/hooks"
cp "$REPO_ROOT/operator-rules.md" "$tmp/operator-rules.md"
: > "$tmp/hooks/safe-commit.sh"
if scan "$tmp" >/dev/null; then
  fail "fixture without planted text was flagged"
else
  pass "pristine fixture is not flagged (allow-list works)"
fi
for planted in 'capacityRequeues' 'slotMaxWait' 'capacity-held' 'held: CPU capacity' \
               'Wait for a CPU turn before committing.' 'Wrap the suite in `cpu-slot pnpm test`.'; do
  printf '%s\n' "$planted" > "$tmp/agents/x.md"
  if scan "$tmp" >/dev/null; then
    pass "detects planted: $planted"
  else
    fail "did not detect planted: $planted"
  fi
done

echo
if [ "$fails" -eq 0 ]; then echo "All assertions passed."; exit 0; fi
echo "$fails assertion(s) failed."; exit 1
