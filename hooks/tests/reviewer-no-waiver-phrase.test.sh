#!/usr/bin/env bash
# Prose test for #733: the reviewer agent must never write an operator-only override phrase.
# Pins the rule, the pre-post self-check, parity of the reviewer's phrase list with
# kind_phrases() in scripts/atelier-size-waiver, and the absence of any phrase in the
# review-body and size-finding templates.
# Exit: 0 = all passed, 1 = at least one failed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REV="$ROOT/agents/reviewer.md"
SCRIPT="$ROOT/scripts/atelier-size-waiver"
PASS=0; FAILN=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
ko() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }
has() { # file pattern label
  if grep -qE -- "$2" "$ROOT/$1"; then ok "$3"; else ko "$3"; fi
}

has agents/reviewer.md 'Never\*\* write a size-waiver or protected-paths approval phrase' "rule: Hard-refusals bullet present"
has agents/reviewer.md 'blocker for the operator' "rule: oversize is a blocker for the operator"
has agents/reviewer.md "grep -iE '.*review-body\\.md" "self-check: grep -iE against review-body.md"

# Phrases from kind_phrases() (size and protected-paths alternations), one per line.
PHRASES="$(
  { sed -n "s/^[[:space:]]*size) printf '%s' '\\([^']*\\)'.*/\\1/p" "$SCRIPT"
    sed -n "s/^[[:space:]]*protected-paths) printf '%s' '\\([^']*\\)'.*/\\1/p" "$SCRIPT"
  } | tr '|' '\n' | sed '/^$/d'
)"
N=$(printf '%s\n' "$PHRASES" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$N" -ge 5 ]; then ok "extraction: $N phrases from kind_phrases()"; else ko "extraction: only $N phrases from kind_phrases() (need >= 5)"; fi

# Drift guard: every script phrase is listed in reviewer.md.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if grep -qiF -- "$p" "$REV"; then ok "parity: reviewer.md lists a script phrase ($p)"; else ko "parity: reviewer.md misses script phrase ($p)"; fi
done <<< "$PHRASES"

# Exact-membership guard (#733 parity gap): pull the pre-post grep -iE pattern out of reviewer.md.
RE="$(sed -n "s/^grep -iE '\\([^']*\\)' .*review-body\\.md.*/\\1/p" "$REV")"
NRE=$(printf '%s\n' "$RE" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$NRE" = 1 ] && [ -n "$RE" ]; then ok "pattern: exactly one non-empty grep -iE pattern extracted"; else ko "pattern: extracted $NRE patterns (need exactly 1 non-empty)"; fi
RE_SET="$(tr '|' '\n' <<<"$RE")"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if grep -qxF -- "$p" <<<"$RE_SET"; then ok "pattern: exact member ($p)"; else ko "pattern: not an exact member of the grep -iE pattern ($p)"; fi
  if grep -iqE -- "$RE" <<<"$p"; then ok "pattern: matches phrase case-insensitively ($p)"; else ko "pattern: does not match phrase ($p)"; fi
done <<< "$PHRASES"

# Negative guard: templates carry no phrase.
BODY_TPL="$(awk '/^````markdown$/{f=1;next} /^````$/{f=0} f' "$REV")"
SIZE_TPL="$(awk '/^### Size finding template/{s=1} s&&/^```markdown$/{f=1;next} f&&/^```$/{exit} f' "$REV")"
if [ -n "$BODY_TPL" ]; then ok "templates: review-body fence extracted"; else ko "templates: review-body fence not found"; fi
if [ -n "$SIZE_TPL" ]; then ok "templates: size-finding fence extracted"; else ko "templates: size-finding fence not found"; fi
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if grep -qiF -- "$p" <<<"$BODY_TPL"; then ko "template: review-body contains phrase ($p)"; else ok "template: review-body free of ($p)"; fi
  if grep -qiF -- "$p" <<<"$SIZE_TPL"; then ko "template: size-finding contains phrase ($p)"; else ok "template: size-finding free of ($p)"; fi
done <<< "$PHRASES"

echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ]
