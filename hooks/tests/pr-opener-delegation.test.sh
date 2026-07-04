#!/usr/bin/env bash
#
# Regression test — pr-opener delegation for non-task PR authoring.
#
# Root cause: standalone commands (notably /atelier:align Tier 3 under `auto`)
# authored the base PR INLINE in the main session (commit/push/gh pr create),
# then dispatched `reviewer`/`auto-merge` from that same session — collapsing
# the "authoring actor" and the "reviewing actor" into one, which the
# auto-mode classifier blocks as self-approval. `pr-author` cannot cover this:
# it is hard-wired to task/<id>-<slug> branches, per-task worktrees, and the
# IN_PROGRESS -> HISTORY move. Fix: a generic `pr-opener` sub-agent that
# authors non-task PRs in its own sub-agent context, so the dispatching
# session never itself pushed the PR it goes on to review.
#
# Contract invariants asserted:
#   Group 1 — agents/pr-opener.md exists and is structurally sound
#     - file exists
#     - frontmatter declares name: pr-opener
#     - tool list matches the spec (Read, Grep, Glob, Bash, TodoWrite, Skill)
#     - playwright is NOT in the tool list (generic non-UI authoring agent)
#     - references a non-task/* branch shape (chore/*, docs/*, fix/*)
#     - explicitly does NOT require task/<id> (states the contrast with pr-author)
#     - states the delegation / clean-actor rationale
#     - does not perform the IN_PROGRESS -> HISTORY tracking move
#   Group 2 — commands/align.md Tier 3 `auto` path delegates to pr-opener
#     - pr-opener is named in the Tier 3 auto section
#     - Task tool dispatch is described for the auto path
#     - Task is present in align's allowed-tools frontmatter
#     - the auto section does not inline `gh pr create` for its own authoring step
#     - the ask path is unchanged: still authors inline via AskUserQuestion offer
#   Group 3 — operator-rules.md documents the invariant
#     - the two-axis (git-identity vs actor/session) rationale is present
#     - the "never hand-author a PR you will then review" rule is present
#     - the pr-author (task) / pr-opener (non-task) delegation split is named
#     - the benign single-session-open-without-self-review exception is named
#   Group 4 — PLAN.md §7 documents pr-opener
#     - pr-opener row present in the agents table
#     - cross-reference to operator-rules.md invariant present
#
# Hermetic: greps committed prose only; no network, no jq required beyond
# what's already on PATH for other suite tests, no temp dirs.
#
# Run:  hooks/tests/pr-opener-delegation.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PR_OPENER="$REPO_ROOT/agents/pr-opener.md"
ALIGN_MD="$REPO_ROOT/commands/align.md"
OPERATOR_RULES="$REPO_ROOT/operator-rules.md"
PLAN="$REPO_ROOT/PLAN.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
# Passes when the fixed string is present in the file; fails otherwise.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is ABSENT from the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: agents/pr-opener.md exists and is structurally sound
# ---------------------------------------------------------------------------

if [ -f "$PR_OPENER" ]; then
  pass "pr-opener: agents/pr-opener.md exists"
else
  fail "pr-opener: agents/pr-opener.md does not exist"
fi

chk_prose "$PR_OPENER" 'name: pr-opener' \
  "pr-opener: frontmatter declares name: pr-opener"

chk_prose "$PR_OPENER" 'tools: ["Read", "Grep", "Glob", "Bash", "TodoWrite", "Skill"]' \
  "pr-opener: tool list matches spec (Read, Grep, Glob, Bash, TodoWrite, Skill)"

chk_absent "$PR_OPENER" 'playwright' \
  "pr-opener: playwright is NOT in the tool list (generic, non-UI agent)"

chk_prose "$PR_OPENER" 'chore/*' \
  "pr-opener: references a non-task branch shape (chore/*)"

chk_prose "$PR_OPENER" 'task/<id>-<slug>' \
  "pr-opener: names the task/<id>-<slug> shape to contrast against (belongs to pr-author)"

chk_prose "$PR_OPENER" 'Never**' \
  "pr-opener: has hard 'Never' decision rules (sanity check on decision-rules section)"

chk_prose "$PR_OPENER" 'stop and say so — that briefing belongs to `pr-author`' \
  "pr-opener: explicitly redirects task/<id> briefings to pr-author instead of handling them"

chk_prose "$PR_OPENER" 'authoring primitive the (generalized) `task-orchestrator` dispatches for non-task branches' \
  "pr-opener: states it is the authoring primitive the orchestrator dispatches for non-task branches"

chk_prose "$PR_OPENER" 'self-approval' \
  "pr-opener: names the self-approval classifier behaviour it exists to avoid"

chk_absent "$PR_OPENER" 'chore(tracking): move #<id> IN_PROGRESS' \
  "pr-opener: does not carry pr-author's tracking-move commit convention (not its job)"

chk_prose "$PR_OPENER" 'No `IN_PROGRESS.md → HISTORY.md` tracking move' \
  "pr-opener: explicitly disclaims the tracking move as out of scope"

# ---------------------------------------------------------------------------
# Group 2: commands/align.md Tier 3 `auto` path delegates to pr-opener
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" '### Tier 3 under `auto` (autonomous)' \
  "align: Tier 3 auto section header present"

# Extract the Tier-3-auto section (from its header to the next H2/H3, or EOF)
# so the "no inline gh pr create" assertion below is scoped correctly and
# doesn't get confused by the (unchanged) ask-path prose earlier in the file.
tier3_auto_section() {
  awk '
    /^### Tier 3 under `auto`/ { capture=1 }
    capture && /^## / && !/^### Tier 3 under `auto`/ { exit }
    capture && /^### / && !/^### Tier 3 under `auto`/ { exit }
    capture { print }
  ' "$ALIGN_MD"
}

TIER3_AUTO="$(tier3_auto_section)"

if printf '%s' "$TIER3_AUTO" | grep -qF 'pr-opener'; then
  pass "align: Tier 3 auto section names the pr-opener agent"
else
  fail "align: Tier 3 auto section does not mention pr-opener"
fi

if printf '%s' "$TIER3_AUTO" | grep -qF '(via `Task`)'; then
  pass "align: Tier 3 auto section dispatches pr-opener via the Task tool"
else
  fail "align: Tier 3 auto section does not describe a Task-tool dispatch"
fi

chk_prose "$ALIGN_MD" 'allowed-tools: Bash(atelier-align:*), Bash(atelier-setup-project:*), Bash(git:*), Bash(gh:*), Read, AskUserQuestion, SlashCommand, Task' \
  "align: Task tool is present in align's allowed-tools frontmatter"

# The auto section must delegate the base-PR authoring step (push + gh pr
# create) to pr-opener rather than running gh pr create itself inline.
if printf '%s' "$TIER3_AUTO" | grep -qF 'instead of running `gh pr create` inline in this session'; then
  pass "align: Tier 3 auto section states it does not inline-author the base PR itself"
else
  fail "align: Tier 3 auto section does not disclaim inline gh pr create authoring"
fi

# Ask path unchanged: still authors inline via the AskUserQuestion offer.
chk_prose "$ALIGN_MD" '**Offer** (via `AskUserQuestion`) to open the PR for each repo — push the branch' \
  "align: Tier 3 ask path still authors inline via AskUserQuestion offer (no regression)"

chk_prose "$ALIGN_MD" 'and run `gh pr create --base <base>` inline in this session' \
  "align: Tier 3 ask path still runs gh pr create inline (no regression)"

# ---------------------------------------------------------------------------
# Group 3: operator-rules.md documents the invariant
# ---------------------------------------------------------------------------

chk_prose "$OPERATOR_RULES" '### PR authoring is always sub-agent work' \
  "operator-rules: invariant section header present"

chk_prose "$OPERATOR_RULES" '**Actor/session**' \
  "operator-rules: actor/session axis named"

chk_prose "$OPERATOR_RULES" '**Git identity**' \
  "operator-rules: git-identity axis named"

chk_prose "$OPERATOR_RULES" 'necessary but not sufficient' \
  "operator-rules: states dual gh identities are necessary but not sufficient"

chk_prose "$OPERATOR_RULES" 'Delegating only the authoring step is NOT sufficient' \
  "operator-rules: states delegating only the authoring is NOT sufficient"

chk_prose "$OPERATOR_RULES" 'a driving session never coordinates both authoring and review' \
  "operator-rules: states the corrected never-coordinate-both rule"

chk_prose "$OPERATOR_RULES" 'author→review→merge coordination' \
  "operator-rules: names the author→review→merge coordination the driving session delegates"

chk_prose "$OPERATOR_RULES" 'sub-agent (`pr-author` for `task/<id>-<slug>` branches, `pr-opener` for' \
  "operator-rules: names pr-author (task branches) and pr-opener (non-task branches) as the orchestrator's authoring sub-agents"

chk_prose "$OPERATOR_RULES" '`pr-opener` for non-task branches' \
  "operator-rules: names pr-opener as the non-task-branch authoring sub-agent"

chk_prose "$OPERATOR_RULES" 'One benign exception' \
  "operator-rules: names the benign open-without-self-review exception"

# ---------------------------------------------------------------------------
# Group 4: PLAN.md §7 documents pr-opener
# ---------------------------------------------------------------------------

chk_prose "$PLAN" '| `pr-opener` | Sonnet |' \
  "PLAN §7: pr-opener row present in the agents table"

chk_prose "$PLAN" 'Authoring primitive the orchestrator dispatches for non-task PRs' \
  "PLAN §7: pr-opener row purpose corrected to authoring primitive dispatched by the orchestrator"

chk_prose "$PLAN" '**Invariant — PR authoring is always sub-agent work.**' \
  "PLAN §7: prose note states the invariant"

chk_prose "$PLAN" 'Delegating only the authoring is NOT sufficient' \
  "PLAN §7: invariant note states delegating only the authoring is NOT sufficient"

chk_prose "$PLAN" 'entire author→review→merge coordination one level down to' \
  "PLAN §7: invariant note names the author→review→merge coordination delegated one level down"

chk_prose "$PLAN" 'operator-rules.md` § "PR authoring is always sub-agent' \
  "PLAN §7: cross-references operator-rules.md's invariant section"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "pr-opener-delegation: all assertions passed."
  exit 0
else
  echo "pr-opener-delegation: $fails assertion(s) failed."
  exit 1
fi
