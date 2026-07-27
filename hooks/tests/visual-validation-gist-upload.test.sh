#!/usr/bin/env bash
#
# Regression test for #33 — `skills/visual-validation/SKILL.md` step 4 (and
# the mirrored prose in `agents/e2e-runner.md`) documented a screenshot
# gist-upload recipe that cannot work against the real `gh` CLI:
#
#   1. `gh gist create --secret "<path>"` — `gh gist create` has NO `--secret`
#      flag (secret is the default; only `-p, --public` exists). The
#      documented command dies with `unknown flag: --secret`.
#   2. Even a working upload couldn't help: the GitHub Gists API is
#      text-only — it cannot store a PNG, so a screenshot could never become
#      an embeddable image URL.
#   3. `raw_url=$(gh gist view <id> --raw | head -n1)` — `gh gist view --raw`
#      prints the raw *contents* of a gist file (text), not a URL. Assigning
#      its output to a `*url*` variable and piping to `head` produced
#      garbage, not a link.
#
# Fix (strategic choice `honest-fallback`, logged in
# `.task-log/decisions.jsonl`): screenshots stay local under
# `.task-log/screenshots/`; only a generated text INDEX file is uploaded via
# a valid `gh gist create "$index_file"` (no visibility flag); the documented
# PR markdown block no longer emits fabricated `![](gist-raw-url)` embeds.
#
# Matcher design note (load-bearing): the fixed prose legitimately CONTAINS
# the substring `--secret`, in corrective sentences that explain the flag
# does not exist (e.g. "There is no `--secret` flag; passing one is an error
# (`unknown flag: --secret`)."), and it legitimately contains `gist view
# <id> --raw` in a sentence explaining what that command actually prints.
# A naive `grep -F -- '--secret'` or `grep -F 'gist view'` would false-fail
# on that correct, unrelated prose. Every negative check below is anchored on
# the INVOCATION SHAPE, not on the bare tokens:
#   - the --secret check requires `create` immediately followed by
#     `--secret` (only whitespace/newline between them) — the shape of an
#     actual flag argument to the command, which the corrective prose never
#     produces (corrective prose has "no", "flag:", or a backtick between
#     the two words, never "create --secret" adjacency);
#   - the --raw check requires either a `gist view ... --raw ... | ... head`
#     pipeline, or a `*url*=$(... gist view ...)` assignment — the two
#     concrete shapes the pre-fix recipe actually used to manufacture a
#     "URL" out of `gist view --raw`'s text output.
# Both directions are self-checked below (Group "matcher calibration") using
# synthetic fixtures: a positive control proves the regex fires on
# invocation-shaped text, a negative control proves it does not fire on the
# fixed files' own corrective prose (extracted from the real committed
# text, not reworded) — so this file cannot pass by accident on either side.
#
# Multi-line note: markdown sometimes wraps an inline code span across a
# line break (e.g. the pre-fix frontmatter had "`gh gist create\n  --secret`"
# split over two lines). Every file-level check below flattens the file to a
# single line (newlines -> spaces) before matching so a defect cannot escape
# detection purely by virtue of a line wrap, in either direction.
#
# Hermetic: greps committed prose (plus small synthetic fixtures written to
# a throwaway mktemp dir) only — no network, no `gh`, no git mutation.
#
# Run:  hooks/tests/visual-validation-gist-upload.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/visual-validation/SKILL.md"
E2E_RUNNER="$REPO_ROOT/agents/e2e-runner.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label> — passes when the literal string
# is present.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label> — passes when the literal string
# is ABSENT. Fails closed: a missing/unreadable file is a FAIL, not a
# vacuous pass, so an absence assertion can never go silently vacuous.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if [ ! -r "$file" ]; then
    fail "$label — $file is missing or unreadable, so absence proves nothing"
  elif grep -qF "$pattern" "$file"; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# flat <file> — the file's content flattened to one line (newlines -> a
# single space), so an ERE can match an invocation shape that markdown has
# wrapped across a line break.
flat() { tr '\n' ' ' <"$1"; }

# chk_absent_ere <file> <ere> <label> — passes when the extended regex does
# NOT match the flattened file content. Fails closed on a missing/unreadable
# file, same rationale as chk_absent.
chk_absent_ere() {
  local file="$1" ere="$2" label="$3"
  if [ ! -r "$file" ]; then
    fail "$label — $file is missing or unreadable, so absence proves nothing"
  elif flat "$file" | grep -Eq -- "$ere"; then
    fail "$label — pattern /$ere/ matched but should not in $file"
  else
    pass "$label"
  fi
}

# frontmatter <file> — the YAML frontmatter block only (between the first
# and second '---' lines), flattened to one line. Used to scope the
# SKILL.md description: check to the actual advertised text, not the whole
# document.
frontmatter() {
  awk 'NR==1 && /^---$/ { c=1; next } c && /^---$/ { exit } c' "$1" | tr '\n' ' '
}

# ---------------------------------------------------------------------------
# Group 0: preconditions — both files exist and are non-empty. Without this,
# every absence assertion below would report PASS vacuously after a rename.
# ---------------------------------------------------------------------------

for _f in "$SKILL" "$E2E_RUNNER"; do
  if [ -s "$_f" ]; then
    pass "precondition: $(basename "$(dirname "$_f")")/$(basename "$_f") exists and is non-empty"
  else
    fail "precondition: $_f is missing or empty — the assertions below cannot mean anything"
  fi
done

# ---------------------------------------------------------------------------
# Group "matcher calibration": prove the two ERE detectors below actually
# discriminate — they fire on invocation-shaped text and do NOT fire on the
# fixed files' own corrective prose (copied verbatim from the committed
# text, not reworded, so this calibration tracks the real sentences).
# ---------------------------------------------------------------------------

SECRET_INVOCATION_ERE='create[[:space:]]+--secret'
RAW_PIPE_ERE='gist view[^|]*--raw[^|]*\|[^|]*head'
URL_VAR_FROM_VIEW_ERE='[A-Za-z_][A-Za-z0-9_]*url[A-Za-z0-9_]*=\$\([^)]*gist view'

cat >"$TMP/fixture-invocation.txt" <<'EOF'
url=$(gh gist create --secret "<path>" 2>/dev/null | tail -n1)
raw_url=$(gh gist view <id> --raw 2>/dev/null | head -n1)
screenshot upload via `gh gist create
--secret`, and the exact markdown shape
EOF

cat >"$TMP/fixture-corrective-prose.txt" <<'EOF'
Upload it as a gist — `gh gist create` is **secret by default** (per `gh
gist create --help`: "By default, gists are secret; use `--public` to make
publicly listed ones."). There is no `--secret` flag; passing one is an
error (`unknown flag: --secret`). Do not pass `--public` either.
- **`--public` on `gh gist create`.** Gists default to secret already —
never pass `--public`. (There is no `--secret` flag; it does not exist on
the real `gh` CLI.)
Note there is no equivalent of a "raw image URL" here — `gh gist view <id>
--raw` prints the raw *contents* of a gist file (text), not a URL, and
there is nothing to point an `![]()` embed at. Do not use it as a URL
source.
EOF

if flat "$TMP/fixture-invocation.txt" | grep -Eq -- "$SECRET_INVOCATION_ERE"; then
  pass "calibration: the --secret detector fires on invocation-shaped text (positive control)"
else
  fail "calibration: the --secret detector did NOT fire on known invocation-shaped text — detector is dead"
fi

if flat "$TMP/fixture-corrective-prose.txt" | grep -Eq -- "$SECRET_INVOCATION_ERE"; then
  fail "calibration: the --secret detector false-positived on corrective prose that only explains the flag doesn't exist"
else
  pass "calibration: the --secret detector does NOT fire on corrective prose (negative control)"
fi

if flat "$TMP/fixture-invocation.txt" | grep -Eq -- "$RAW_PIPE_ERE"; then
  pass "calibration: the raw|head-pipeline detector fires on invocation-shaped text (positive control)"
else
  fail "calibration: the raw|head-pipeline detector did NOT fire on known invocation-shaped text — detector is dead"
fi

if flat "$TMP/fixture-corrective-prose.txt" | grep -Eq -- "$RAW_PIPE_ERE"; then
  fail "calibration: the raw|head-pipeline detector false-positived on corrective prose"
else
  pass "calibration: the raw|head-pipeline detector does NOT fire on corrective prose (negative control)"
fi

if flat "$TMP/fixture-invocation.txt" | grep -Eq -- "$URL_VAR_FROM_VIEW_ERE"; then
  pass "calibration: the url=\$(...gist view...) detector fires on invocation-shaped text (positive control)"
else
  fail "calibration: the url=\$(...gist view...) detector did NOT fire on known invocation-shaped text — detector is dead"
fi

if flat "$TMP/fixture-corrective-prose.txt" | grep -Eq -- "$URL_VAR_FROM_VIEW_ERE"; then
  fail "calibration: the url=\$(...gist view...) detector false-positived on corrective prose"
else
  pass "calibration: the url=\$(...gist view...) detector does NOT fire on corrective prose (negative control)"
fi

# ---------------------------------------------------------------------------
# Assertion 1: no `gh gist create --secret` invocation anywhere in
# skills/**/*.md or agents/*.md.
# ---------------------------------------------------------------------------

while IFS= read -r -d '' f; do
  chk_absent_ere "$f" "$SECRET_INVOCATION_ERE" \
    "no 'gist create --secret' invocation in ${f#"$REPO_ROOT"/}"
done < <(find "$REPO_ROOT/skills" -name '*.md' -print0)

chk_absent_ere "$E2E_RUNNER" "$SECRET_INVOCATION_ERE" \
  "no 'gist create --secret' invocation in agents/e2e-runner.md"

# ---------------------------------------------------------------------------
# Assertion 2: no `gh gist view ... --raw` used as a URL source — neither
# the raw|head pipeline shape nor a *url* variable assigned from a
# `gh gist view` command.
# ---------------------------------------------------------------------------

chk_absent_ere "$SKILL" "$RAW_PIPE_ERE" \
  "SKILL.md: no 'gist view ... --raw ... | head' pipeline"
chk_absent_ere "$SKILL" "$URL_VAR_FROM_VIEW_ERE" \
  "SKILL.md: no *url* variable assigned from a 'gh gist view' command"

chk_absent_ere "$E2E_RUNNER" "$RAW_PIPE_ERE" \
  "e2e-runner.md: no 'gist view ... --raw ... | head' pipeline"
chk_absent_ere "$E2E_RUNNER" "$URL_VAR_FROM_VIEW_ERE" \
  "e2e-runner.md: no *url* variable assigned from a 'gh gist view' command"

# ---------------------------------------------------------------------------
# Assertion 3: no fabricated raw-gist image embed in the documented PR
# markdown template in skills/visual-validation/SKILL.md.
# ---------------------------------------------------------------------------

RAW_EMBED_ERE='!\[[^]]*\]\(<gist-raw'

chk_absent_ere "$SKILL" "$RAW_EMBED_ERE" \
  "SKILL.md: no fabricated ![...](<gist-raw-url>) embed in the PR markdown template"

# Bonus — the same defect existed verbatim in agents/e2e-runner.md's copy of
# the markdown block; guard it there too so the two documents cannot drift
# apart on this point again.
chk_absent_ere "$E2E_RUNNER" "$RAW_EMBED_ERE" \
  "e2e-runner.md: no fabricated ![...](<gist-raw-url>) embed in its markdown block"

# ---------------------------------------------------------------------------
# Assertion 4: cross-file consistency.
# ---------------------------------------------------------------------------

# 4a. agents/e2e-runner.md no longer describes uploading the PNG screenshots
# themselves as gists — the mechanism moved to a text index.
chk_absent "$E2E_RUNNER" \
  'upload each PNG as a `gh gist create --secret` and collect the raw URLs' \
  "e2e-runner.md: no longer describes uploading each PNG itself as a gist"

chk_prose "$E2E_RUNNER" \
  'upload a text index of them via `gh gist create`' \
  "e2e-runner.md: describes the text-index-gist mechanism instead"

chk_prose "$E2E_RUNNER" \
  'keep every PNG local under `.task-log/screenshots/`' \
  "e2e-runner.md: states screenshots stay local (never uploaded as images)"

# 4b. skills/visual-validation/SKILL.md frontmatter `description:` no longer
# advertises `gh gist create --secret`.
FRONTMATTER="$(frontmatter "$SKILL")"

if printf '%s' "$FRONTMATTER" | grep -Eq -- "$SECRET_INVOCATION_ERE"; then
  fail "SKILL.md frontmatter description: still advertises 'gist create --secret'"
else
  pass "SKILL.md frontmatter description: does not advertise 'gist create --secret'"
fi

if printf '%s' "$FRONTMATTER" | grep -qF 'a text index of the screenshots uploaded via'; then
  pass "SKILL.md frontmatter description: advertises the text-index-gist mechanism instead"
else
  fail "SKILL.md frontmatter description: does not describe the text-index-gist mechanism"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "visual-validation-gist-upload (#33): all assertions passed."
  exit 0
else
  echo "visual-validation-gist-upload (#33): $fails assertion(s) failed."
  exit 1
fi
