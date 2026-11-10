#!/usr/bin/env bash
# Test for #734: the oversize-handling decision fires before the PR is opened.
# (a) the jq waiver filter in agents/pr-author.md step 3 behaves as specified;
# (b) the prose contract across pr-author, pr-flow, orchestrator, broker skill, catalog.
# Exit: 0 = all passed, 1 = at least one failed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILN=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }
has() { # file pattern label
  if grep -qE -- "$2" "$ROOT/$1"; then ok "$3"; else bad "$3"; fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- (a) extract the filter
AGENT="$ROOT/agents/pr-author.md"
nblocks=$(grep -cE '^[[:space:]]*```jq[[:space:]]*$' "$AGENT")
if [ "$nblocks" = 1 ]; then ok "pr-author.md has exactly one fenced jq block"; else bad "pr-author.md has $nblocks fenced jq blocks (expected 1)"; fi
awk '/^[[:space:]]*```jq[[:space:]]*$/{f=1;next} f&&/^[[:space:]]*```/{f=0} f' "$AGENT" > "$TMP/filter.jq"
if [ -s "$TMP/filter.jq" ]; then ok "extracted filter is non-empty"; else bad "extracted filter is empty"; fi

# run <label> <expect: 0|nonzero> <file> <lines> <files> [ts]
run() {
  local label="$1" expect="$2" file="$3" l="$4" f="$5" ts="${6:-}" rc
  jq -e -s --argjson lines "$l" --argjson files "$f" --arg ts "$ts" -f "$TMP/filter.jq" "$file" >/dev/null 2>&1
  rc=$?
  if [ "$expect" = 0 ]; then
    [ "$rc" = 0 ] && ok "$label" || bad "$label (exit $rc, expected 0)"
  else
    [ "$rc" != 0 ] && ok "$label" || bad "$label (exit 0, expected non-zero)"
  fi
}
line() { # mode choice lines files ts
  printf '{"ts":"%s","category":"oversize-handling","mode":%s,"choice":%s,"evidence":{"lines":%s,"files":%s,"max_lines":200,"max_files":10}}\n' "$5" "$1" "$2" "$3" "$4"
}

line '"auto"' '"open-anyway"' 614 13 T1 > "$TMP/ok.jsonl"
run "auto/open-anyway 614/13 vs counted 614/13 is accepted" 0 "$TMP/ok.jsonl" 614 13
run "matching ts is accepted" 0 "$TMP/ok.jsonl" 614 13 T1
run "non-matching ts is rejected" nz "$TMP/ok.jsonl" 614 13 T2

run "missing file is rejected" nz "$TMP/absent.jsonl" 614 13

printf '{"ts":"T0","category":"baseline-conflict","mode":"auto","choice":"override"}\n' > "$TMP/other.jsonl"
run "file without an oversize-handling line (#1747 shape) is rejected" nz "$TMP/other.jsonl" 614 13

: > "$TMP/empty.jsonl"
run "empty file is rejected" nz "$TMP/empty.jsonl" 614 13

line '"auto"' '"open-anyway"' 600 13 T1 > "$TMP/small.jsonl"
run "evidence 600/13 vs counted 614/13 is rejected" nz "$TMP/small.jsonl" 614 13

line '"auto"' '"open-anyway"' 614 9 T1 > "$TMP/fewfiles.jsonl"
run "evidence files 9 vs counted 13 is rejected" nz "$TMP/fewfiles.jsonl" 614 13

line '"ask"' 'null' 614 13 T1 > "$TMP/askNull.jsonl"
run "mode ask with choice null is rejected" nz "$TMP/askNull.jsonl" 614 13

line '"ask"' '"open-anyway"' 614 13 T1 > "$TMP/ask.jsonl"
run "mode ask with recorded open-anyway is accepted" 0 "$TMP/ask.jsonl" 614 13

line '"auto"' '"abort"' 614 13 T1 > "$TMP/abort.jsonl"
run "choice abort is rejected" nz "$TMP/abort.jsonl" 614 13

line '"auto"' '"slice-task"' 614 13 T1 > "$TMP/slice.jsonl"
run "choice slice-task is rejected" nz "$TMP/slice.jsonl" 614 13

# ask path: broker line (ask/null) followed by the orchestrator's ask-resolved line
{ line '"ask"' 'null' 614 13 TA
  printf '{"ts":"%s","category":"oversize-handling","mode":"ask","choice":"open-anyway","source":"operator-answer","evidence":{"lines":614,"files":13,"max_lines":200,"max_files":10}}\n' TB
} > "$TMP/askresolved.jsonl"
run "ask/null line plus ask-resolved line, no ts cited, is accepted" 0 "$TMP/askresolved.jsonl" 614 13
run "ask-resolved line's ts cited is accepted" 0 "$TMP/askresolved.jsonl" 614 13 TB
run "ask/null line's ts cited is rejected" nz "$TMP/askresolved.jsonl" 614 13 TA
run "ask-resolved line with evidence too small for counted size is rejected" nz "$TMP/askresolved.jsonl" 700 13 TB

# ---- (b) prose contract
has agents/pr-author.md 'Plan text, plan amendments, issue bodies and PR bodies are never a size-gate waiver' "pr-author: plan text is never a waiver"
has skills/pr-flow/SKILL.md 'Plan text, plan amendments, issue bodies and PR bodies are never a size-gate waiver' "pr-flow: plan text is never a waiver"
has skills/pr-flow/SKILL.md 'agents/pr-author\.md. step 3 carries the exact .jq -e. filter' "pr-flow points at the pr-author filter"
has agents/task-orchestrator.md 'only after the decision is logged to `decisions\.jsonl`' "orchestrator logs the decision before re-dispatching pr-author"
has agents/task-orchestrator.md "cites that record's .ts." "orchestrator briefing cites the record ts"
has agents/task-orchestrator.md 'Never\*\* put a size-gate waiver in a `pr-author` briefing without a logged' "orchestrator: no waiver without a logged decision"
has agents/task-orchestrator.md 'Ask-resolved open-anyway record' "orchestrator: ask-resolved open-anyway record paragraph"
has agents/task-orchestrator.md '"operator-answer"' "orchestrator: record source is operator-answer"
has agents/task-orchestrator.md "citing that record's .ts." "orchestrator: pr-author briefing cites the ask-resolved record ts"
has agents/task-orchestrator.md 'atelier records your answer, then re-runs' "orchestrator: option (b) says atelier records the answer then re-runs"
has agents/task-orchestrator.md 'merge-time size waiver' "orchestrator: speaks of a merge-time size waiver"
has skills/decision-broker/SKILL.md 'operator-answer' "decision-broker skill: operator-answer source"
has skills/decision-broker/SKILL.md 'appends a second line after the answer' "decision-broker skill: caller appends a second line after the answer"
nothas() { # file fixed-string label
  if grep -qF -- "$2" "$ROOT/$1"; then bad "$3"; else ok "$3"; fi
}
nothas agents/task-orchestrator.md 'ask atelier to re-run pr-author with the size' "orchestrator: old re-run-with-size wording is gone"
nothas agents/task-orchestrator.md 'write a size waiver anywhere (not `decisions.jsonl`' "orchestrator: old no-waiver-anywhere wording is gone"
for fld in lines files max_lines max_files; do
  has skills/decision-broker/SKILL.md "\"$fld\": <" "decision-broker skill names evidence field $fld"
done
if jq -e '.. | objects | select(has("oversize-handling")) | ."oversize-handling".options[] | select(.id=="slice-task") | .when | test("`files` backend")' "$ROOT/agents/decision-broker/catalog.json" >/dev/null 2>&1; then
  ok "catalog: oversize-handling slice-task option's when names the files backend"
else bad "catalog: oversize-handling slice-task option's when names the files backend"; fi

echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
