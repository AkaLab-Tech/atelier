#!/usr/bin/env bash
#
# Regression test for #747 (#744 part 2) — hooks/safe-commit.sh accepts a red
# `test` step only when a signed baseline-override record (written with the #746
# library hooks/lib/baseline-override-record.sh) covers EVERY failing test.
#
# Covered: jest- and vitest-shaped reporter output; npm and pnpm shims (the
# `--` passthrough); outside-set / empty-set / runtime-error / suite-error /
# reporter-missing / reporter-unparsable / runner-unsupported fail-closed
# reasons; no record, forged HMAC, wrong key, symlinked record, record for
# another branch or repo; red lint/typecheck with a valid record; and the
# unchanged green, docs-only, ATELIER_SKIP_SAFE_COMMIT and testScope paths.
#
# Hermetic: throwaway git repos under a temp dir, a temp ATELIER_CONFIG_DIR,
# and a pnpm/npm shim on PATH. The shim runs `<pm> run <script>` via sh, except
# for scripts starting with `jest` / `vitest`: those are "red" runners that,
# when given --outputFile <path>, write a fixture JSON (BOR_MODE selects
# fixture | none | garbage; @ROOT@ in the fixture is replaced with the cwd).
# The shim logs its argv to ./argv.txt. Requires git + jq + openssl.
#
# Run:  hooks/tests/safe-commit-baseline-override.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2015 # A && pass || fail is the suite idiom (pass never fails)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export ATELIER_CONFIG_DIR="$TMP/cfg"
# shellcheck source=../lib/baseline-override-record.sh disable=SC1091
source "$REPO_ROOT/hooks/lib/baseline-override-record.sh"

# --- package-manager shim ---------------------------------------------------
SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/pnpm" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  echo "$*" >> argv.txt
  script="$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)"
  [ -z "$script" ] && { echo "no script: $2" >&2; exit 1; }
  case "${script%% *}" in
    jest|vitest)
      out=""; prev=""
      for a in "$@"; do [ "$prev" = "--outputFile" ] && out="$a"; prev="$a"; done
      if [ -n "$out" ]; then
        case "${BOR_MODE:-none}" in
          fixture) sed "s#@ROOT@#$PWD#g" "$BOR_FIXTURE" > "$out" ;;
          garbage) echo 'not json {' > "$out" ;;
        esac
      fi
      echo "FAIL src/x.test.js" >&2
      exit 1 ;;
  esac
  exec sh -c "$script"
fi
exit 0
SHIM
chmod +x "$SHIM_BIN/pnpm"
ln -s pnpm "$SHIM_BIN/npm"
export PATH="$SHIM_BIN:$PATH"

# --- fixtures ----------------------------------------------------------------
FX="$TMP/fx"; mkdir -p "$FX"
cat > "$FX/jest-waived.json" <<'J'
{"numRuntimeErrorTestSuites":0,"testResults":[
 {"name":"@ROOT@/src/a.test.js","status":"failed","assertionResults":[
  {"ancestorTitles":["Suite"],"title":"does x","status":"failed"},
  {"ancestorTitles":["Suite"],"title":"does ok","status":"passed"}]}]}
J
cat > "$FX/vitest-waived.json" <<'J'
{"numFailedTests":1,"testResults":[
 {"name":"@ROOT@/src/b.test.ts","status":"failed","assertionResults":[
  {"ancestorTitles":[],"title":"handles y","status":"failed"}]}]}
J
cat > "$FX/jest-outside.json" <<'J'
{"numRuntimeErrorTestSuites":0,"testResults":[
 {"name":"@ROOT@/src/a.test.js","status":"failed","assertionResults":[
  {"ancestorTitles":["Suite"],"title":"does x","status":"failed"},
  {"ancestorTitles":["Other"],"title":"brand new bug","status":"failed"}]}]}
J
cat > "$FX/jest-runtime.json" <<'J'
{"numRuntimeErrorTestSuites":1,"testResults":[
 {"name":"@ROOT@/src/a.test.js","status":"failed","assertionResults":[
  {"ancestorTitles":["Suite"],"title":"does x","status":"failed"}]}]}
J
cat > "$FX/jest-suiteerr.json" <<'J'
{"numRuntimeErrorTestSuites":0,"testResults":[
 {"name":"@ROOT@/src/a.test.js","status":"failed","assertionResults":[
  {"ancestorTitles":["Suite"],"title":"does x","status":"failed"}]},
 {"name":"@ROOT@/src/broken.test.js","status":"failed","assertionResults":[]}]}
J
cat > "$FX/jest-empty.json" <<'J'
{"numRuntimeErrorTestSuites":0,"testResults":[
 {"name":"@ROOT@/src/a.test.js","status":"passed","assertionResults":[
  {"ancestorTitles":["Suite"],"title":"does x","status":"passed"}]}]}
J

JEST_ID="src/a.test.js › Suite › does x"
VITEST_ID="src/b.test.ts › handles y"

# --- helpers ----------------------------------------------------------------
LOG_ROOT="$TMP/logs"
LOG_FILE="$LOG_ROOT/.task-log/hook-decisions.jsonl"
REPO_SLUG="acme/widget"
BRANCH="task/747-x"

# make_project <dir> <lockfile> <test-script> [lint-script] [typecheck-script]
make_project() {
  local dir="$1" lock="$2" test_s="$3" lint_s="${4:-}" tc_s="${5:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  git -C "$dir" remote add origin "https://github.com/$REPO_SLUG.git"
  jq -n --arg t "$test_s" --arg l "$lint_s" --arg c "$tc_s" \
    '{name:"fixture",version:"0.0.0",scripts:({test:$t}
      + (if $l != "" then {lint:$l} else {} end)
      + (if $c != "" then {typecheck:$c} else {} end))}' > "$dir/package.json"
  : > "$dir/$lock"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  git -C "$dir" checkout -q -b "$BRANCH"
  printf 'console.log(1)\n' > "$dir/feature.js"
  git -C "$dir" add -A
}

# write_record <waived ids, newline-joined> [repo] [branch]
write_record() {
  bor_write "${2:-$REPO_SLUG}" "${3:-$BRANCH}" "$(printf 'a%.0s' {1..40})" "$1" \
    "q" "Yes, waive these tests for this branch" "sid" "2026-11-10T00:00:00Z"
}

reset_cfg() { rm -rf "$ATELIER_CONFIG_DIR"; }

CODE=0; ERR=""
# run <pwd> <command> [preseed-line]: sets CODE and ERR; fresh decision log.
run() {
  local pwd_dir="$1" command_str="$2" seed="${3:-}" payload
  rm -rf "$LOG_ROOT"
  if [ -n "$seed" ]; then mkdir -p "$LOG_ROOT/.task-log"; printf '%s\n' "$seed" > "$LOG_FILE"; fi
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  ERR="$(
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$LOG_ROOT" \
      bash "$HOOK" <<<"$payload" 2>&1 1>/dev/null
    echo "__CODE_$?__"
  )"
  CODE="$(printf '%s' "$ERR" | grep -o '__CODE_[0-9]*__' | grep -o '[0-9]*')"
  ERR="$(printf '%s' "$ERR" | sed 's/__CODE_[0-9]*__//')"
}

log_has() { grep -q "\"pattern\":\"$1\"" "$LOG_FILE" 2>/dev/null; }
argv() { tr '\n' '|' < "$1/argv.txt" 2>/dev/null; }

# expect_blocked <label> <reason|""> : exit 2, no test-red-waived, reason shown + logged.
expect_blocked() {
  local label="$1" reason="$2"
  if [ "$CODE" = "2" ] && ! log_has "test-red-waived"; then pass "$label → blocked (exit 2)"
  else fail "$label: expected exit 2 and no test-red-waived, got exit $CODE"; fi
  if [ -n "$reason" ]; then
    grep -q -- "Baseline override: not applied — $reason" <<<"$ERR" \
      && pass "$label → message says '$reason'" \
      || fail "$label: stderr lacks 'Baseline override: not applied — $reason' (got: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-300))"
    log_has "baseline-override-$reason" \
      && pass "$label → log has baseline-override-$reason" \
      || fail "$label: log lacks baseline-override-$reason"
  fi
}

# blocked_case <label> <dir> <lock> <test-script> <fixture> <mode> <waived> <reason>
# Fresh config + valid record covering <waived>, runs the hook, expects a block.
blocked_case() {
  local label="$1" dir="$2" lock="$3" tscript="$4" fx="$5" mode="$6" waived="$7" reason="$8"
  reset_cfg; make_project "$dir" "$lock" "$tscript"; write_record "$waived"
  export BOR_MODE="$mode" BOR_FIXTURE="$FX/$fx"
  run "$dir" "git commit -m x"
  expect_blocked "$label" "$reason"
}

echo "#747 — safe-commit baseline override"

# === 1: jest, only waived failures → allowed (pnpm) ==========================
reset_cfg; S="$TMP/s1"; make_project "$S" pnpm-lock.yaml jest
write_record "$JEST_ID"
export BOR_MODE=fixture BOR_FIXTURE="$FX/jest-waived.json"
run "$S" "git commit -m x"
[ "$CODE" = "0" ] && log_has "test-red-waived" \
  && pass "jest, only waived failure (pnpm) → allowed, test-red-waived logged" \
  || fail "jest waived (pnpm): expected exit 0 + test-red-waived, got exit $CODE: $ERR"
case "$(argv "$S")" in *"run test -- --json --outputFile "*) pass "pnpm → flags forwarded after '--'" ;;
  *) fail "pnpm argv wrong: $(argv "$S")" ;; esac

# === 2: vitest, only waived failures → allowed ===============================
reset_cfg; S="$TMP/s2"; make_project "$S" pnpm-lock.yaml vitest
write_record "$VITEST_ID"
export BOR_MODE=fixture BOR_FIXTURE="$FX/vitest-waived.json"
run "$S" "git commit -m x"
[ "$CODE" = "0" ] && log_has "test-red-waived" \
  && pass "vitest (empty ancestorTitles, 2-part id) → allowed, test-red-waived logged" \
  || fail "vitest waived: expected exit 0 + test-red-waived, got exit $CODE: $ERR"
case "$(argv "$S")" in *"run test -- --reporter=json --outputFile "*) pass "vitest → --reporter=json forwarded after '--'" ;;
  *) fail "vitest argv wrong: $(argv "$S")" ;; esac

# === 3: npm shim → allowed, `--` passthrough =================================
reset_cfg; S="$TMP/s3"; make_project "$S" package-lock.json jest
write_record "$JEST_ID"
export BOR_MODE=fixture BOR_FIXTURE="$FX/jest-waived.json"
run "$S" "git commit -m x"
[ "$CODE" = "0" ] && log_has "test-red-waived" \
  && pass "jest via npm → allowed, test-red-waived logged" \
  || fail "jest waived (npm): expected exit 0, got exit $CODE: $ERR"
case "$(argv "$S")" in *"run test -- --json --outputFile "*) pass "npm → flags forwarded after '--'" ;;
  *) fail "npm argv wrong: $(argv "$S")" ;; esac

# === 4: failure outside the waived set → blocked, names the identifier =======
blocked_case "failure outside waived set" "$TMP/s4" pnpm-lock.yaml jest jest-outside.json fixture "$JEST_ID" outside-set
grep -qF -- "Other › brand new bug" <<<"$ERR" \
  && pass "outside-set → message names 'src/a.test.js › Other › brand new bug'" \
  || fail "outside-set: stderr does not name the non-waived identifier"
printf '%s' "$ERR" | grep -F -- "- $JEST_ID" >/dev/null \
  && fail "outside-set: waived identifier wrongly listed as not waived" \
  || pass "outside-set → waived identifier not listed as non-waived"

# === 5: override line in decisions.jsonl but no signed record → blocked ======
reset_cfg; S="$TMP/s5"; make_project "$S" pnpm-lock.yaml jest
export BOR_MODE=fixture BOR_FIXTURE="$FX/jest-waived.json"
run "$S" "git commit -m x" '{"ts":"2026-11-10T00:00:00Z","hook":"x","pattern":"baseline-conflict","decision":"override","reason":"operator said so"}'
expect_blocked "decisions.jsonl override line, no signed record" ""

# === 6: record integrity ======================================================
# 6a forged HMAC
reset_cfg; S="$TMP/s6a"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID"
rec="$(bor_record_path "$REPO_SLUG" "$BRANCH")"
jq --arg h "$(printf '0%.0s' {1..64})" '.hmac=$h' "$rec" > "$rec.n" && mv "$rec.n" "$rec"
run "$S" "git commit -m x"; expect_blocked "forged HMAC" ""
# 6b edited waived list (stale HMAC)
reset_cfg; S="$TMP/s6b"; make_project "$S" pnpm-lock.yaml jest; write_record "src/other.test.js › nope"
rec="$(bor_record_path "$REPO_SLUG" "$BRANCH")"
jq --arg id "$JEST_ID" '.waived=[$id]' "$rec" > "$rec.n" && mv "$rec.n" "$rec"
run "$S" "git commit -m x"; expect_blocked "edited waived list" ""
# 6c wrong key
reset_cfg; S="$TMP/s6c"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID"
printf '%s' "$(printf 'b%.0s' {1..64})" > "$ATELIER_CONFIG_DIR/state/consent/baseline-override.key"
run "$S" "git commit -m x"; expect_blocked "wrong key" ""
# 6d symlinked record
reset_cfg; S="$TMP/s6d"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID"
rec="$(bor_record_path "$REPO_SLUG" "$BRANCH")"; mv "$rec" "$TMP/real-record.json"; ln -s "$TMP/real-record.json" "$rec"
run "$S" "git commit -m x"; expect_blocked "symlinked record" ""
# 6e record for another branch only
reset_cfg; S="$TMP/s6e"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID" "$REPO_SLUG" "task/999-other"
run "$S" "git commit -m x"; expect_blocked "record for another branch" ""
# 6f other-branch record copied onto this branch's path (content mismatch)
reset_cfg; S="$TMP/s6f"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID" "$REPO_SLUG" "task/999-other"
cp "$(bor_record_path "$REPO_SLUG" "task/999-other")" "$(bor_record_path "$REPO_SLUG" "$BRANCH")"
run "$S" "git commit -m x"; expect_blocked "other-branch record copied to this path" ""
# 6g record for another repo only
reset_cfg; S="$TMP/s6g"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID" "acme/other" "$BRANCH"
run "$S" "git commit -m x"; expect_blocked "record for another repo" ""
# 6h other-repo record copied onto this repo's path
reset_cfg; S="$TMP/s6h"; make_project "$S" pnpm-lock.yaml jest; write_record "$JEST_ID" "acme/other" "$BRANCH"
cp "$(bor_record_path "acme/other" "$BRANCH")" "$(bor_record_path "$REPO_SLUG" "$BRANCH")"
run "$S" "git commit -m x"; expect_blocked "other-repo record copied to this path" ""

# === 7: fail-closed reasons ==================================================
blocked_case "runtime error"                   "$TMP/s7a" pnpm-lock.yaml jest jest-runtime.json  fixture "$JEST_ID" runtime-error
blocked_case "suite-level error"               "$TMP/s7b" pnpm-lock.yaml jest jest-suiteerr.json fixture "$JEST_ID" suite-error
blocked_case "reporter output missing"         "$TMP/s7c" pnpm-lock.yaml jest jest-waived.json   none    "$JEST_ID" reporter-missing
blocked_case "reporter output unparsable"      "$TMP/s7d" pnpm-lock.yaml jest jest-waived.json   garbage "$JEST_ID" reporter-unparsable
blocked_case "wrapped runner (turbo run test)" "$TMP/s7e" pnpm-lock.yaml "turbo run test; exit 1" jest-waived.json fixture "$JEST_ID" runner-unsupported
blocked_case "empty failed set"                "$TMP/s7f" pnpm-lock.yaml jest jest-empty.json    fixture "$JEST_ID" empty-set

# === 8: red lint / typecheck with a valid record → blocked ===================
export BOR_MODE=fixture BOR_FIXTURE="$FX/jest-waived.json"
reset_cfg; S="$TMP/s8a"; make_project "$S" pnpm-lock.yaml jest "exit 1"; write_record "$JEST_ID"
run "$S" "git commit -m x"
[ "$CODE" = "2" ] && grep -q -- 'pnpm run lint' <<<"$ERR" && ! log_has "test-red-waived" \
  && pass "red lint + valid record → blocked, names lint" \
  || fail "red lint: expected exit 2 naming lint, got exit $CODE"
reset_cfg; S="$TMP/s8b"; make_project "$S" pnpm-lock.yaml jest "exit 0" "exit 1"; write_record "$JEST_ID"
run "$S" "git commit -m x"
[ "$CODE" = "2" ] && grep -q -- 'pnpm run typecheck' <<<"$ERR" && ! log_has "test-red-waived" \
  && pass "red typecheck + valid record → blocked, names typecheck" \
  || fail "red typecheck: expected exit 2 naming typecheck, got exit $CODE"

# === 9: unchanged behaviour ==================================================
# 9a green path (record present but unused)
reset_cfg; S="$TMP/s9a"; make_project "$S" pnpm-lock.yaml "echo ok"; write_record "$JEST_ID"
run "$S" "git commit -m x"
[ "$CODE" = "0" ] && ! log_has "test-red-waived" && log_has "test-green" \
  && pass "green test step → allowed, no override involved" \
  || fail "green path: expected exit 0 + test-green, got exit $CODE"
# 9b red test, no record → plain block, no override line
reset_cfg; S="$TMP/s9b"; make_project "$S" pnpm-lock.yaml "exit 1"
run "$S" "git commit -m x"
[ "$CODE" = "2" ] && ! grep -q -- 'Baseline override' <<<"$ERR" \
  && pass "red test, no record → plain block without override line" \
  || fail "plain red: expected exit 2 without override line, got exit $CODE"
# 9c docs-only commit skips the gate even when test is red
reset_cfg; S="$TMP/s9c"; make_project "$S" pnpm-lock.yaml "exit 1"
git -C "$S" reset -q; rm -f "$S/feature.js"; echo '# hi' > "$S/README.md"; git -C "$S" add -A
run "$S" "git commit -m x"
[ "$CODE" = "0" ] && pass "docs-only commit → allowed without running the gate" \
  || fail "docs-only: expected exit 0, got $CODE"
# 9d ATELIER_SKIP_SAFE_COMMIT=1
reset_cfg; S="$TMP/s9d"; make_project "$S" pnpm-lock.yaml "exit 1"
ATELIER_SKIP_SAFE_COMMIT=1 run "$S" "git commit -m x"
[ "$CODE" = "0" ] && pass "ATELIER_SKIP_SAFE_COMMIT=1 → allowed" \
  || fail "skip env: expected exit 0, got $CODE"
# 9e testScope=changed: red test:changed (jest), no record → blocked, names the script
reset_cfg; S="$TMP/s9e"; make_project "$S" pnpm-lock.yaml "echo full-ok"
jq '.scripts["test:changed"]="jest --onlyChanged"' "$S/package.json" > "$S/p.n" && mv "$S/p.n" "$S/package.json"
echo '{ "safeCommit": { "testScope": "changed" } }' > "$S/.atelier.json"; git -C "$S" add -A
run "$S" "git commit -m x"
[ "$CODE" = "2" ] && grep -q -- 'pnpm run test:changed' <<<"$ERR" \
  && pass "testScope changed → red test:changed blocked, names the script" \
  || fail "testScope changed: expected exit 2 naming test:changed, got exit $CODE"
# 9f testScope=changed + valid record: override runs the scoped script
reset_cfg; write_record "$JEST_ID"
export BOR_MODE=fixture BOR_FIXTURE="$FX/jest-waived.json"
run "$S" "git commit -m x"
[ "$CODE" = "0" ] && log_has "test-red-waived" \
  && pass "testScope changed + valid record → scoped script red but waived, allowed" \
  || fail "testScope changed + record: expected exit 0 + test-red-waived, got exit $CODE: $ERR"

echo
if [ "$fails" -eq 0 ]; then
  echo "All #747 baseline-override checks passed."
  exit 0
else
  echo "$fails #747 baseline-override check(s) FAILED."
  exit 1
fi
