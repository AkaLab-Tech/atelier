#!/usr/bin/env bash
#
# Regression guard for task #699 — `printf '%s' "$x" | grep -q …` under
# `set -o pipefail` is flaky: grep -q exits on the first match, the producer
# takes SIGPIPE on large input, and pipefail fails the pipeline although the
# needle is present (and negative checks can pass without checking).
#
# (a) Static: no hooks/tests/*.test.sh may pipe printf/echo/cat into grep -q,
#     except files on the TEMPORARY allowlist below (sweep tracked in #700).
# (b) Dynamic: on a ~1 MB input, the here-string form always returns 0.
#
# Run:  hooks/tests/no-pipe-to-grep-q.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/hooks/tests"
SELF="$(basename "${BASH_SOURCE[0]}")"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# TEMPORARY allowlist: files still holding the pattern; remove each as #700
# (the sweep) converts it. worktree-create-routing.test.sh must never be here.
ALLOWLIST=(
  abandon-task-tracking-route.test.sh
  align-auto-policy.test.sh
  atelier-align-survey.test.sh
  atelier-uninstall-runtime.test.sh
  atelier-update-managed.test.sh
  atelier-update-no-tty-prompt.test.sh
  atelier-update-plugin-failure.test.sh
  atelier-update-tag-mismatch.test.sh
  atelier-worktree-create.test.sh
  automode-user-sync.test.sh
  block-env-read.test.sh
  bootstrap-repo-less.test.sh
  branch-protection-helper.test.sh
  cpu-slot-passthrough.test.sh
  decision-broker-host-only-rule.test.sh
  decision-broker-skill-policy-path.test.sh
  diff-scope-check.test.sh
  doctor-branch-protection.test.sh
  gate-run-permission-denial.test.sh
  gh-shim-path.test.sh
  gh-shim.test.sh
  housekeeping-claimed-task.test.sh
  housekeeping-cross-owner-board.test.sh
  housekeeping-id-mismatch.test.sh
  housekeeping-remote-delete.test.sh
  install-automode-user.test.sh
  install-credential-helper-git-identity.test.sh
  install-native-path-guard.test.sh
  install-plugin-prefer-https.test.sh
  install-runtime-dir.test.sh
  install-source-root.test.sh
  list-projects-render.test.sh
  migrate-task-ids.test.sh
  no-self-review-standalone.test.sh
  orchestrate-only-reroutes.test.sh
  orchestrator-handback-prose.test.sh
  orient-decision-tree.test.sh
  permission-diff-automode.test.sh
  plan-storage-config-consistency.test.sh
  plan-storage-local.test.sh
  post-merge-housekeeping-binary.test.sh
  pr-opener-delegation.test.sh
  preflight-plugin-cache.test.sh
  project-cache.test.sh
  refresh-mirror.test.sh
  release-pin-chain.test.sh
  resolve-base.test.sh
  safe-commit-bypass.test.sh
  safe-commit-matcher.test.sh
  safe-commit-test-scope.test.sh
  safe-commit-worktree.test.sh
  scan-git-add-diff-scope.test.sh
  scan-git-add-fail-closed.test.sh
  settings-template-agent-dispatch-allow.test.sh
  setup-project-backend-flag.test.sh
  status-blocked.test.sh
  visual-validation-gist-upload.test.sh
  workspace-status-mixed-backend.test.sh
  workspace-status-render.test.sh
)

# Producer (printf|echo|cat) piped into a grep whose flag cluster contains q.
PIPE_RE='(printf|echo|cat)[[:space:]][^|]*\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q'

echo "== guard regex fixtures =="
for line in \
  "printf '%s' \"\$x\" | grep -qF 'a'" \
  "echo \"\$x\" | grep -qiE 'a|b'" \
  "printf '%s' \"\$x\" | grep -Fq 'a'" \
  "cat f | grep -q a"; do
  grep -qE -- "$PIPE_RE" <<<"$line" && pass "regex matches: $line" || fail "regex misses: $line"
done
for line in \
  "printf '%s' \"\$x\" | grep -c 'a'" \
  "echo \"\$x\" | grep -n a" \
  "grep -qF -- 'a' <<<\"\$x\"" \
  "grep -qF -e \"\$p\" \"\$file\""; do
  grep -qE -- "$PIPE_RE" <<<"$line" && fail "regex wrongly matches: $line" || pass "regex ignores: $line"
done

echo "== static scan of hooks/tests =="
for a in "${ALLOWLIST[@]}"; do
  [[ "$a" == worktree-create-routing.test.sh ]] && fail "allowlist must never contain $a"
done
# scan_dir DIR SELF_BASENAME ALLOWED_BASENAME... -> prints "file:line:text" hits
scan_dir() {
  local dir="$1" self="$2"; shift 2
  local f base a allowed hits out=""
  for f in "$dir"/*.test.sh; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "$self" ]] && continue
    allowed=0
    for a in "$@"; do [[ "$a" == "$base" ]] && allowed=1; done
    [[ $allowed -eq 1 ]] && continue
    hits="$(grep -nE -- "$PIPE_RE" "$f" | sed "s|^|$base:|")"
    [[ -n "$hits" ]] && out+="$hits"$'\n'
  done
  printf '%s' "$out"
}

offenders="$(scan_dir "$TESTS_DIR" "$SELF" "${ALLOWLIST[@]}")"
if [[ -z "$offenders" ]]; then
  pass "no printf|echo|cat piped into grep -q outside the allowlist"
else
  fail "pipe-to-grep-q found (use grep -q -- PATTERN <<<\"\$x\"):"
  printf '%s\n' "$offenders" | sed 's/^/    /'
fi
for a in "${ALLOWLIST[@]}"; do
  [[ -f "$TESTS_DIR/$a" ]] || fail "allowlist entry does not exist: $a"
done

echo "== guard fails on a non-allowlisted fixture (temp dir) =="
fxdir="$(mktemp -d)"
trap 'rm -rf "$fxdir"' EXIT
printf '%s\n' '#!/usr/bin/env bash' 'x=1' \
  "printf '%s' \"\$x\" | grep -qF 'a'" > "$fxdir/bad.test.sh"
printf '%s\n' '#!/usr/bin/env bash' "grep -qF -- 'a' <<<\"\$x\"" > "$fxdir/good.test.sh"
got="$(scan_dir "$fxdir" "$SELF")"
[[ "$got" == "bad.test.sh:3:printf '%s' \"\$x\" | grep -qF 'a'" ]] \
  && pass "offender reported as file:line for non-allowlisted file" || fail "unexpected scan output: [$got]"
got="$(scan_dir "$fxdir" "$SELF" bad.test.sh)"
[[ -z "$got" ]] && pass "allowlisted fixture is skipped" || fail "allowlist not honoured: [$got]"
cp "$fxdir/bad.test.sh" "$fxdir/worktree-create-routing.test.sh"
got="$(scan_dir "$fxdir" "$SELF" bad.test.sh)"
[[ "$got" == worktree-create-routing.test.sh:3:* ]] \
  && pass "worktree-create-routing.test.sh is flagged when it holds the pattern" || fail "worktree-create-routing fixture not flagged: [$got]"

echo "== dynamic proof on ~1 MB input =="
big="needle-line"$'\n'"$(head -c 1000000 /dev/zero | tr '\0' 'x')"
TRIES=30
old_bad=0
new_bad=0
for ((i = 0; i < TRIES; i++)); do
  (set -o pipefail; printf '%s' "$big" | grep -qF 'needle-line') || old_bad=$((old_bad + 1))
  (set -o pipefail; grep -qF -- 'needle-line' <<<"$big") || new_bad=$((new_bad + 1))
done
echo "  INFO: old printf|grep -q form returned non-zero in $old_bad/$TRIES tries (informational)"
[[ $new_bad -eq 0 ]] && pass "here-string form returned 0 in $TRIES/$TRIES tries" || fail "here-string form failed $new_bad/$TRIES tries"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
