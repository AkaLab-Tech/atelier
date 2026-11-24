#!/usr/bin/env bash
#
# Regression test for #811 — code-execution and container allow rules are
# narrowed, and a PreToolUse hook checks compose configs at run time.
#
#   T  templates/settings.template.json (static matrix)
#        - the broad allow entries for tsx, general `pnpm run`, and general
#          `docker compose` are gone; the narrow replacements are present
#        - 12 inline-evaluation denies live in deny[] only
#        - sanctioned shapes (project gate, e2e, docker-env) still match an
#          allow entry; the removed shapes match none; denied shapes match deny
#   P  scripts/atelier-permission-diff has a row for every new/changed entry
#   D  PLAN.md section 3 Allow list agrees with the template
#   H  hooks/block-compose-escape.sh (hermetic: `docker` is a stub on a
#      sanitized PATH that prints fixture config JSON; no daemon is reached)
#        - closed allowlist: only the exact docker-env up shape (optionally
#          behind `cd <worktree> &&`) may start containers; any other
#          container-creating compose command is blocked
#        - the allowed shape's effective config is checked (specific tags)
#        - ignores text that only mentions compose, read-only subcommands, and
#          the repo's own test runner
#        - fails closed when the config cannot be resolved, within its budget
#
# Hermetic: mktemp sandbox, fake HOME, stub docker, no network.
#
# Run:  hooks/tests/permission-code-exec-narrowing.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2015,SC2016,SC2181
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-compose-escape.sh"
PD="$REPO_ROOT/scripts/atelier-permission-diff"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
PLAN="$REPO_ROOT/PLAN.md"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"; trap 'rm -rf "$TMP"' EXIT
cases=0; fails=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); fails=$((fails + 1)); printf '  FAIL: %s\n' "$1"; }

echo "permission code-exec narrowing (#811)"

# ---------------------------------------------------------------------------
# T. Static matrix
# ---------------------------------------------------------------------------
echo "-- template"

jq empty "$TEMPLATE" 2>/dev/null && pass "T0 template parses (jq empty)" || fail "T0 template is not valid JSON"

in_list() { # list entry
  jq -e --arg e "$2" --arg l "$1" '(.permissions[$l] // []) | index($e) != null' "$TEMPLATE" >/dev/null 2>&1
}

for e in 'Bash(pnpm exec tsx*)' 'Bash(pnpm run *)' 'Bash(docker compose*)'; do
  if in_list allow "$e" || in_list ask "$e"; then fail "T1 removed entry still granted: $e"
  else pass "T1 removed entry absent from allow/ask: $e"; fi
done

for e in 'Bash(pnpm run lint*)' 'Bash(pnpm run typecheck*)' 'Bash(pnpm run test*)' \
         'Bash(docker compose version*)' \
         'Bash(docker compose -p * --file <worktree>/docker-compose.yml *)' \
         'Bash(docker compose -p * --file <worktree>-worktrees/**/docker-compose.yml *)'; do
  if in_list allow "$e"; then pass "T2 replacement present in allow: $e"
  else fail "T2 replacement missing from allow: $e"; fi
done

# Unchanged neighbours stay (env-prefixed test shapes, test runners).
for e in 'Bash(pnpm test*)' 'Bash(pnpm exec eslint*)' 'Bash(pnpm exec prettier*)' 'Bash(pnpm exec tsc*)' \
         'Bash(pnpm exec vitest*)' 'Bash(pnpm exec jest*)' 'Bash(pnpm exec playwright*)' \
         'Bash(PW_CHROME_CHANNEL=chrome pnpm exec playwright test*)' 'Bash(CI=1 pnpm test*)' \
         'Bash(CI=true pnpm run test*)' 'Bash(vitest*)' 'Bash(jest*)' 'Bash(pytest*)' \
         'Bash(docker info*)' 'Bash(docker ps*)' 'Bash(docker logs*)'; do
  if in_list allow "$e"; then pass "T3 unchanged entry kept: $e"
  else fail "T3 unchanged entry missing: $e"; fi
done

INLINE_DENY=(
  'Bash(*pnpm*exec tsx* -e *)' 'Bash(*pnpm*exec tsx* -p *)'
  'Bash(*pnpm*exec tsx* --eval *)' 'Bash(*pnpm*exec tsx* --print *)'
  'Bash(*pnpm*exec tsx* --eval=*)' 'Bash(*pnpm*exec tsx* --print=*)'
  'Bash(*pnpm*exec node* -e *)' 'Bash(*pnpm*exec node* -p *)'
  'Bash(*pnpm*exec node* --eval *)' 'Bash(*pnpm*exec node* --print *)'
  'Bash(*pnpm*exec node* --eval=*)' 'Bash(*pnpm*exec node* --print=*)'
)
for e in "${INLINE_DENY[@]}"; do
  if in_list deny "$e" && ! in_list allow "$e" && ! in_list ask "$e"; then
    pass "T4 inline-eval deny only in deny[]: $e"
  else
    fail "T4 inline-eval entry misplaced or missing: $e"
  fi
done

# Glob matcher over the template's Bash entries (shell glob; `*` spans anything).
bash_patterns() { # list
  jq -r --arg l "$1" '(.permissions[$l] // [])[] | select(startswith("Bash(") and endswith(")")) | .[5:-1]' "$TEMPLATE"
}
matches_list() { # list command
  local pat
  while IFS= read -r pat; do
    # shellcheck disable=SC2254
    case "$2" in $pat) return 0 ;; esac
  done < <(bash_patterns "$1")
  return 1
}

WTP='<worktree>'
SANCTIONED=(
  'pnpm test'
  'pnpm test --run src/foo.test.ts'
  'pnpm run test'
  'pnpm run test:unit'
  'pnpm run lint'
  'pnpm run lint:fix'
  'pnpm run typecheck'
  'pnpm exec eslint .'
  'pnpm exec prettier --check .'
  'pnpm exec tsc --noEmit'
  'pnpm exec vitest run'
  'pnpm exec jest --ci'
  'pnpm exec playwright test e2e/login.spec.ts'
  'CI=1 pnpm exec playwright test'
  'CI=true pnpm test'
  'CI=1 pnpm run test:e2e'
  'PW_CHROME_CHANNEL=chrome pnpm exec playwright test --project=chromium'
  'vitest run'
  'pytest -q'
  'docker compose version'
  "docker compose -p demo --file $WTP/docker-compose.yml up -d --wait"
  "docker compose -p demo --file $WTP/docker-compose.yml down"
  "docker compose -p demo --file $WTP/docker-compose.yml down --volumes --remove-orphans"
  "docker compose -p demo --file $WTP/docker-compose.yml logs --tail 50 web"
  "docker compose -p demo --file $WTP/docker-compose.yml ps --format json"
  "docker compose -p demo --file $WTP-worktrees/task-1-x/docker-compose.yml ps"
  'docker ps'
  'docker logs web'
)
for c in "${SANCTIONED[@]}"; do
  if matches_list allow "$c" && ! matches_list deny "$c"; then pass "T5 sanctioned shape allowed: $c"
  else fail "T5 sanctioned shape not allowed (or denied): $c"; fi
done

NOT_ALLOWED=(
  'pnpm exec tsx script.ts'
  'pnpm run build'
  'pnpm run dev'
  'pnpm run deploy'
  'pnpm run prepare'
  'docker compose up -d'
  'docker compose down'
  'docker compose run web sh'
  'docker compose -f /etc/other/docker-compose.yml up'
  'docker compose -p demo --file /tmp/elsewhere/docker-compose.yml up -d'
  'docker compose -p demo up -d'
)
for c in "${NOT_ALLOWED[@]}"; do
  if matches_list allow "$c"; then fail "T6 removed shape still matches an allow entry: $c"
  else pass "T6 removed shape matches no allow entry: $c"; fi
done

DENIED=(
  'pnpm exec tsx -e "process.exit(0)"'
  'pnpm exec tsx -p 1+1 '
  'pnpm exec tsx --eval "x" '
  'pnpm exec tsx --print "x" '
  'pnpm exec tsx --eval=x'
  'pnpm exec tsx --print=x'
  'pnpm exec node -e "x" '
  'pnpm exec node -p 1 '
  'pnpm exec node --eval "x" '
  'pnpm exec node --print 1 '
  'pnpm exec node --eval=x'
  'pnpm exec node --print=x'
  'pnpm --silent exec node -e "x" '
  'CI=1 pnpm exec tsx -e "x" '
)
for c in "${DENIED[@]}"; do
  if matches_list deny "$c"; then pass "T7 inline evaluation denied: $c"
  else fail "T7 inline evaluation not matched by any deny entry: $c"; fi
done

for c in 'pnpm exec vitest run' 'pnpm exec playwright test' 'pnpm exec tsc -p tsconfig.json' 'pnpm run test -- -e foo'; do
  if matches_list deny "$c"; then
    # `-e` after `pnpm run test --` is not an exec form; only exec forms are in scope
    case "$c" in 'pnpm run test -- -e foo') pass "T8 (known glob overlap, not an exec form): $c" ;; *) fail "T8 sanctioned runner wrongly denied: $c" ;; esac
  else
    pass "T8 sanctioned runner not denied: $c"
  fi
done

# ---------------------------------------------------------------------------
# P. atelier-permission-diff rows
# ---------------------------------------------------------------------------
echo "-- permission-diff"

printf '{"permissions":{"allow":[],"deny":[]}}\n' > "$TMP/old.json"
PD_OUT="$("$PD" --old "$TMP/old.json" --new "$TEMPLATE" --no-color 2>&1)"
for e in 'Bash(pnpm run lint*)' 'Bash(pnpm run typecheck*)' 'Bash(pnpm run test*)' \
         'Bash(docker compose version*)' \
         'Bash(docker compose -p * --file <worktree>/docker-compose.yml *)' \
         'Bash(docker compose -p * --file <worktree>-worktrees/**/docker-compose.yml *)'; do
  line="$(printf '%s\n' "$PD_OUT" | grep -F -- "+ $e " | head -1)"
  if [ -n "$line" ] && ! grep -qF 'no description' <<<"$line"; then pass "P1 diff row for allow entry: $e"
  else fail "P1 diff row missing/undescribed for $e: '$line'"; fi
done
for e in "${INLINE_DENY[@]}"; do
  line="$(printf '%s\n' "$PD_OUT" | grep -F -- "+ $e " | head -1)"
  case "$line" in
    *'BLOCKED: inline code evaluation'*) pass "P2 diff BLOCKED row for deny entry: $e" ;;
    *) fail "P2 diff row missing/not BLOCKED for $e: '$line'" ;;
  esac
done
# Removed entries show up as removals when diffing against the previous template.
jq '.permissions.allow += ["Bash(pnpm exec tsx*)","Bash(pnpm run *)","Bash(docker compose*)"]' "$TEMPLATE" > "$TMP/prev.json"
PD_RM="$("$PD" --old "$TMP/prev.json" --new "$TEMPLATE" --no-color 2>&1)"
for e in 'Bash(pnpm exec tsx*)' 'Bash(pnpm run *)' 'Bash(docker compose*)'; do
  if printf '%s\n' "$PD_RM" | grep -F -- "- $e" | grep -q .; then pass "P4 diff reports removal of $e"
  else fail "P4 diff does not report removal of $e"; fi
done

# ---------------------------------------------------------------------------
# D. PLAN.md section 3 Allow list
# ---------------------------------------------------------------------------
echo "-- PLAN.md"

PLAN_ALLOW="$(awk '/^### .*Allow/{f=1;next} /^### /{f=0} f' "$PLAN" | sed 's/ *(#811:[^)]*)//')"
plan_has() { grep -qF -- "$1" <<<"$PLAN_ALLOW"; }
for s in 'run lint*' 'run typecheck*' 'run test*' 'docker compose version*' \
         'docker compose -p <name> --file <worktree>/docker-compose.yml'; do
  if plan_has "$s"; then pass "D1 PLAN Allow list names: $s"; else fail "D1 PLAN Allow list missing: $s"; fi
done
if grep -qE '`run \*`[,.]|, `exec \*`|`docker compose\*`' <<<"$PLAN_ALLOW"; then
  fail "D2 PLAN Allow list still lists a general run/exec/compose entry"
else
  pass "D2 PLAN Allow list no longer lists general run/exec/compose entries"
fi
# every pnpm/docker allow entry in the template is reflected in the PLAN bullet text
for e in $(jq -r '.permissions.allow[] | select(test("^Bash\\(pnpm (run|exec) ")) | sub("^Bash\\(pnpm (run|exec) "; "") | sub("\\*?\\)$"; "") | split(" ")[0]' "$TEMPLATE" | sort -u); do
  if grep -qF -- "$e" <<<"$PLAN_ALLOW"; then pass "D3 PLAN Allow list mentions pnpm run/exec target: $e"
  else fail "D3 PLAN Allow list does not mention template pnpm run/exec target: $e"; fi
done

# ---------------------------------------------------------------------------
# H. Compose hook
# ---------------------------------------------------------------------------
echo "-- compose hook"

[ -x "$HOOK" ] && pass "H0 hook is executable" || fail "H0 hook is not executable: $HOOK"
bash -n "$HOOK" 2>/dev/null && pass "H0 hook passes bash -n" || fail "H0 hook fails bash -n"
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | .command | select(test("block-compose-escape\\.sh"))] | length == 1' "$HOOKS_JSON" >/dev/null 2>&1; then
  pass "H0 hooks.json registers block-compose-escape once under the Bash matcher"
else
  fail "H0 hooks.json does not register block-compose-escape exactly once for Bash"
fi

# Sanitized PATH: only the tools the hook needs, plus a stub docker.
SBX="$TMP/sbx"; SBX_NODOCKER="$TMP/sbx-nodocker"; SBX_NOJQ="$TMP/sbx-nojq"; mkdir -p "$SBX" "$SBX_NODOCKER" "$SBX_NOJQ"
for t in bash sh jq git env cat dirname basename sleep kill mktemp rm date awk sed tr head tail sort uniq grep cut wc mkdir ls readlink uname id printf expr; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$p" in /*) ln -sf "$p" "$SBX/$t"; ln -sf "$p" "$SBX_NODOCKER/$t"; [ "$t" = jq ] || ln -sf "$p" "$SBX_NOJQ/$t" ;; esac
done
cat > "$SBX/docker" <<'STUB'
#!/bin/sh
# Hermetic stub: records argv, prints the fixture config for `config`.
echo "$*" >> "$STUB_LOG"
case " $* " in
  *" config "*)
    if [ -n "${STUB_REJECT_NOENV:-}" ]; then
      case " $* " in *" --no-env-resolution "*) exit 1 ;; esac
    fi
    if [ -n "${STUB_FAIL_PROFILE:-}" ]; then
      case " $* " in *" --profile "*) exit 1 ;; esac
    fi
    if [ -n "${STUB_FAIL_STAR:-}" ]; then
      case " $* " in *" --profile * "*) exit 1 ;; esac
    fi
    if [ -n "${STUB_FAIL_PNAME:-}" ]; then
      case " $* " in *" --profile $STUB_FAIL_PNAME "*) exit 1 ;; esac
    fi
    if [ -n "${STUB_PCFG:-}" ] && [ -f "$STUB_PCFG" ]; then
      case " $* ,${COMPOSE_PROFILES:-}, " in *" --profile p "*|*" --profile=p "*|*,p,*) cat "$STUB_PCFG"; exit 0 ;; esac
    fi
    [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
    if [ -f "$PWD/.stub-cfg.json" ]; then cat "$PWD/.stub-cfg.json"
    elif [ -n "${STUB_CFG:-}" ] && [ -f "$STUB_CFG" ]; then cat "$STUB_CFG"; fi
    exit "${STUB_RC:-0}" ;;
  *" version "*|*" version") echo "Docker Compose version v2.0.0-stub"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$SBX/docker"
cp "$SBX/docker" "$SBX_NOJQ/docker"

FH="$TMP/home"; mkdir -p "$FH"
WT="$TMP/wt"; mkdir -p "$WT/data" "$WT/run" && git -C "$WT" init -q 2>/dev/null
: > "$WT/docker-compose.yml"
: > "$WT/run/docker.sock"
WT2="$TMP/sibling"; mkdir -p "$WT2" && git -C "$WT2" init -q 2>/dev/null; : > "$WT2/docker-compose.yml"
OUTSIDE="$TMP/outside"; mkdir -p "$OUTSIDE"; : > "$OUTSIDE/docker-compose.yml"
ln -s "$FH" "$WT/linkdir"
ln -s "$OUTSIDE/docker-compose.yml" "$WT/linked-compose.yml"
LNK="$TMP/lnk"; mkdir -p "$LNK" && git -C "$LNK" init -q 2>/dev/null
ln -s "$OUTSIDE/docker-compose.yml" "$LNK/docker-compose.yml"
STUB_LOGF="$TMP/stub.log"
CFGF="$TMP/cfg.json"

# Config fixtures: compliant base, then a jq edit per case.
mkcfg() { # jq-expr
  jq -n --arg wt "$WT" --arg home "$FH" --arg out "$OUTSIDE" \
    '{name:"demo",services:{web:{image:"nginx:1",volumes:[{type:"bind",source:($wt+"/data"),target:"/d"}]}}} | '"$1" > "$CFGF"
}

HOOK_RC=0; HOOK_ERR=""; HOOK_SECS=0
run_hook() { # command [cwd] ; env knobs STUB_* inherited via env -i list below
  local cwd="${2:-$WT}" payload errf="$TMP/err.txt" t0
  payload="$(jq -n --arg c "$1" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  : > "$STUB_LOGF"
  t0=$SECONDS
  printf '%s' "$payload" | env -i PATH="${HOOK_PATH:-$SBX}" HOME="$FH" TMPDIR="$TMP" \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$WT" \
      STUB_LOG="$STUB_LOGF" STUB_CFG="$CFGF" STUB_SLEEP="${STUB_SLEEP:-}" STUB_RC="${STUB_RC:-}" \
      STUB_FAIL_STAR="${STUB_FAIL_STAR:-}" STUB_FAIL_PNAME="${STUB_FAIL_PNAME:-}" STUB_PCFG="${STUB_PCFG:-}" \
      STUB_FAIL_PROFILE="${STUB_FAIL_PROFILE:-}" STUB_REJECT_NOENV="${STUB_REJECT_NOENV:-}" \
      "$SBX/bash" "$HOOK" >/dev/null 2>"$errf"
  HOOK_RC=$?
  HOOK_SECS=$((SECONDS - t0))
  HOOK_ERR="$(cat "$errf")"
}

expect_block() { # label tag command [cwd]
  run_hook "$3" "${4:-$WT}"
  if [ "$HOOK_RC" -eq 2 ] && grep -qF -- "($2)" <<<"$HOOK_ERR"; then pass "$1"
  else fail "$1 (rc=$HOOK_RC, want 2 with tag '$2'; stderr: $(printf '%s' "$HOOK_ERR" | head -2 | tr '\n' ' '))"; fi
}
expect_allow() { # label command [cwd]
  run_hook "$2" "${3:-$WT}"
  if [ "$HOOK_RC" -eq 0 ]; then pass "$1"
  else fail "$1 (rc=$HOOK_RC, want 0; stderr: $(printf '%s' "$HOOK_ERR" | head -2 | tr '\n' ' '))"; fi
}

# The shape block's stderr does not print its tag; the tag is the `pattern`
# field of the decision log entry the hook writes.
expect_shape() { # label command [cwd]
  local log="$WT/.task-log/hook-decisions.jsonl"
  rm -f "$log"
  run_hook "$2" "${3:-$WT}"
  if [ "$HOOK_RC" -eq 2 ] && jq -e -s 'map(select(.hook == "block-compose-escape" and .action == "block" and .pattern == "not-allowlisted-shape")) | length == 1' "$log" >/dev/null 2>&1; then pass "$1"
  else fail "$1 (rc=$HOOK_RC, want 2 with logged tag 'not-allowlisted-shape'; log: $(tail -1 "$log" 2>/dev/null | cut -c1-160); stderr: $(printf '%s' "$HOOK_ERR" | head -1 | cut -c1-120))"; fi
}

UP="docker compose -p demo --file $WT/docker-compose.yml up -d --wait"
CPB="docker compose -p demo --file $WT/docker-compose.yml"

# --- the allowed shape on a compliant fixture ---
mkcfg '.'
expect_allow "H1 exact shape on a compliant fixture" "$UP"
expect_allow "H1 exact shape with quoted arguments (as the skill writes it)" \
  "docker compose -p \"demo\" --file \"$WT/docker-compose.yml\" up -d --wait"
expect_allow "H1 exact shape with single-quoted arguments" \
  "docker compose -p 'demo' --file '$WT/docker-compose.yml' up -d --wait"
expect_allow "H1 exact shape behind a cd to the worktree" "cd $WT && $UP"
expect_allow "H1 exact shape behind a quoted cd to the worktree" \
  "cd \"$WT\" && docker compose -p \"demo\" --file \"$WT/docker-compose.yml\" up -d --wait"
expect_allow "H1 exact shape with a trailing newline" "$UP
"
expect_allow "H1 project name with dots, dashes and underscores" \
  "docker compose -p my_proj-1.x --file $WT/docker-compose.yml up -d --wait"
run_hook "$UP"
if [ "$(sed -n '1p' "$STUB_LOGF")" = "compose -p demo --file $WT/docker-compose.yml --profile * config --no-env-resolution --format json" ]; then
  pass "H1 config resolved read-only with the command's project/file and all profiles"
else
  fail "H1 config resolution args unexpected: $(tr '\n' '|' < "$STUB_LOGF")"
fi
if [ "$(grep -c . "$STUB_LOGF")" -eq 1 ]; then pass "H1 one config call when the first succeeds"
else fail "H1 expected a single config call: $(tr '\n' '|' < "$STUB_LOGF")"; fi
for sub in up run create start restart watch scale build exec cp; do
  run_hook "$CPB $sub web"
  if [ "$HOOK_RC" -eq 2 ] && [ ! -s "$STUB_LOGF" ]; then pass "H1 '$sub' off-shape is blocked before any docker call"
  else fail "H1 '$sub' off-shape: rc=$HOOK_RC log=$(tr '\n' '|' < "$STUB_LOGF")"; fi
done

# --- the effective-config checks, on the allowed shape ---
mkcfg '.services.web.volumes[0].source = $home'
expect_block "H2 bind of the home directory" bind-outside-worktree "$UP"
mkcfg '.services.web.volumes[0].source = "/"'
expect_block "H2 bind of the filesystem root" bind-outside-worktree "$UP"
mkcfg '.services.web.volumes[0].source = "/var/run/docker.sock"'
expect_block "H2 bind of the runtime socket path" bind-outside-worktree "$UP"
mkcfg '.services.web.volumes[0].source = ($wt + "/run/docker.sock")'
expect_block "H2 runtime socket inside the worktree" runtime-socket "$UP"
mkcfg '.services.web.volumes[0].source = ($wt + "/linkdir")'
expect_block "H2 symlinked bind source inside the worktree" symlinked-bind-source "$UP"
mkcfg '.services.web.volumes[0].source = ($wt + "/../outside")'
expect_block "H2 bind source escaping by dot-dot" bind-outside-worktree "$UP"
mkcfg '.services.web.volumes = [{type:"npipe",source:"//./pipe/docker_engine",target:"/p"}]'
expect_block "H2 named-pipe runtime mount" runtime-socket "$UP"
mkcfg '.services.web.privileged = true'
expect_block "H2 privileged service" privileged "$UP"
mkcfg '.services.web.pid = "host"'
expect_block "H2 host pid namespace" host-namespace "$UP"
mkcfg '.services.web.ipc = "host"'
expect_block "H2 host ipc namespace" host-namespace "$UP"
mkcfg '.services.web.network_mode = "host"'
expect_block "H2 host network mode" host-namespace "$UP"
mkcfg '.services.web.uts = "host"'
expect_block "H2 host uts namespace" host-namespace "$UP"
mkcfg '.services.web.userns_mode = "host"'
expect_block "H2 host user namespace" host-namespace "$UP"
mkcfg '.services.web.network_mode = "container:other"'
expect_block "H2 network of another container" host-namespace "$UP"
mkcfg '.services.web.cap_add = ["SYS_ADMIN"]'
expect_block "H2 capability grant" device-or-capability "$UP"
mkcfg '.services.web.devices = ["/dev/sda:/dev/sda"]'
expect_block "H2 device grant" device-or-capability "$UP"
mkcfg '.services.web.device_cgroup_rules = ["c 1:3 rwm"]'
expect_block "H2 device cgroup rule" device-or-capability "$UP"
mkcfg '.services.web.security_opt = ["seccomp=unconfined"]'
expect_block "H2 seccomp unconfined" weakened-security "$UP"
mkcfg '.services.web.security_opt = ["apparmor=unconfined"]'
expect_block "H2 apparmor unconfined" weakened-security "$UP"
mkcfg '.services.web.volumes_from = ["container:other"]'
expect_block "H2 volumes from another container" container-volumes "$UP"
mkcfg '.services.db = {image:"pg",privileged:true}'
expect_block "H2 privileged flag on a second service" privileged "$UP"
mkcfg '.volumes = {data:{driver:"local",driver_opts:{type:"none",o:"bind",device:$home}}}'
expect_block "H2 volume driver option binding the home directory" bind-outside-worktree "$UP"
mkcfg '.secrets = {s:{file:($home + "/.ssh/id")}}'
expect_block "H2 secret file outside the worktree" bind-outside-worktree "$UP"
mkcfg '.services.web.build = {context:$home}'
expect_block "H2 build context outside the worktree" bind-outside-worktree "$UP"
mkcfg '.services.web.build = {context:($wt + "/data")}'
expect_allow "H2 build context inside the worktree is allowed" "$UP"
mkcfg '.services.web.privileged = true'
expect_block "H2 the cd form checks the config too" privileged "cd $WT && $UP"

# --- anything that is not exactly the shape is blocked ---
mkcfg '.'
# wrappers in front (including those whose option takes a value)
for w in 'timeout 5' 'timeout -s KILL 5' 'timeout --signal=KILL 5' 'timeout -k 1 5' \
         'env' 'env FOO=1' 'env -u FOO' 'env --unset=FOO' 'env -i' \
         'nice' 'nice -n 5' 'sudo' 'sudo -u root' 'nohup' 'time' 'command' 'exec' 'builtin' 'FOO=1' 'COMPOSE_PROJECT_NAME=demo' \
         'COMPOSE_FILE=/etc/other.yml' 'COMPOSE_PROFILES=p'; do
  expect_shape "H3 wrapper '$w' before the shape" "$w $UP"
done
expect_shape "H3 xargs -I{} before the shape" "echo x | xargs -I{} $UP"
expect_shape "H3 xargs -I X before the shape" "echo x | xargs -I X $UP"
expect_shape "H3 xargs -n1 before the shape" "echo x | xargs -n1 $UP"
expect_shape "H3 xargs bare before the shape" "echo x | xargs $UP"
expect_shape "H3 wrapper behind a cd" "cd $WT && timeout -s KILL 5 $UP"
# extra, missing, renamed or reordered elements
expect_shape "H3 extra --profile" "$CPB --profile p up -d --wait"
expect_shape "H3 extra --project-directory" "$CPB --project-directory $WT up -d --wait"
expect_shape "H3 extra --env-file" "$CPB --env-file $WT/.e up -d --wait"
expect_shape "H3 extra --env-file outside" "$CPB --env-file $OUTSIDE/.e up -d --wait"
expect_shape "H3 short -f instead of --file" "docker compose -p demo -f $WT/docker-compose.yml up -d --wait"
expect_shape "H3 --file= form" "docker compose -p demo --file=$WT/docker-compose.yml up -d --wait"
expect_shape "H3 --project-name instead of -p" "docker compose --project-name demo --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 -p after --file" "docker compose --file $WT/docker-compose.yml -p demo up -d --wait"
expect_shape "H3 second --file" "$CPB --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 missing --wait" "$CPB up -d"
expect_shape "H3 missing -d" "$CPB up --wait"
expect_shape "H3 reordered --wait -d" "$CPB up --wait -d"
expect_shape "H3 bare up" "$CPB up"
expect_shape "H3 extra service name" "$CPB up -d --wait web"
expect_shape "H3 extra --build" "$CPB up -d --wait --build"
expect_shape "H3 extra --force-recreate" "$CPB up -d --wait --force-recreate"
expect_shape "H3 stderr redirect 2>&1" "$UP 2>&1"
expect_shape "H3 stdout redirect" "$UP > $WT/out.log"
expect_shape "H3 stdin redirect" "$UP < /dev/null"
expect_shape "H3 no -p" "docker compose --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 no --file" "docker compose -p demo up -d --wait"
expect_shape "H3 no -p and no --file" "docker compose up -d --wait"
expect_shape "H3 bare up -d" "docker compose up -d"
expect_shape "H3 global flag before compose (--context)" "docker --context other compose -p demo --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 global flag before compose (-H)" "docker -H tcp://127.0.0.1:2375 compose -p demo --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 standalone docker-compose binary" "docker-compose -p demo --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 docker-compose v1 bare" "docker-compose up -d"
# connectors and nesting
expect_shape "H3 || after the shape" "$UP || true"
expect_shape "H3 || before the shape" "false || $UP"
expect_shape "H3 ; after the shape" "$UP; true"
expect_shape "H3 ; before the shape" "true; $UP"
expect_shape "H3 && after the shape" "$UP && echo done"
expect_shape "H3 && before the shape (not a cd)" "true && $UP"
expect_shape "H3 chain around the shape" "echo start && $UP && echo done"
expect_shape "H3 pipe into the shape" "echo go | $UP"
expect_shape "H3 pipe out of the shape" "$UP | cat"
expect_shape "H3 background &" "$UP &"
expect_shape "H3 background & then command" "$UP & echo x"
expect_shape "H3 subshell" "($UP)"
expect_shape "H3 brace group" "{ $UP; }"
expect_shape "H3 command substitution" "echo \$($UP)"
expect_shape "H3 substitution assigned" "x=\$($UP)"
expect_shape "H3 nested substitution" "echo \$(echo \$($UP))"
expect_shape "H3 backticks" "echo \`$UP\`"
expect_shape "H3 bash -c" "bash -c '$UP'"
expect_shape "H3 sh -c after a separator" "true; sh -c \"$UP\""
expect_shape "H3 bash -c with a substitution inside" "bash -c 'echo \$($UP)'"
expect_shape "H3 eval" "eval $UP"
expect_shape "H3 eval nested" "eval eval eval eval $UP"
expect_shape "H3 here-string into bash" "bash <<< \"$UP\""
expect_shape "H3 if/then" "if true; then $UP; fi"
expect_shape "H3 negation" "! $UP"
expect_shape "H3 for/do" "for i in 1; do $UP; done"
expect_shape "H3 while then up" "while false; do :; done; $UP"
expect_shape "H3 case/esac" "case x in x) $UP ;; esac"
expect_shape "H3 time keyword" "time $UP"
q1="$(printf '%q' "$UP")"; b1="bash -c $q1"
q2="$(printf '%q' "$b1")"; b2="bash -c $q2"
q3="$(printf '%q' "$b2")"; b3="bash -c $q3"
q4="$(printf '%q' "$b3")"; b4="bash -c $q4"
expect_shape "H3 bash -c nested 3 levels" "$b3"
expect_shape "H3 bash -c nested 4 levels" "$b4"
# the cd prefix
expect_shape "H3 cd to the sibling worktree, file in this one" "cd $WT2 && $UP"
expect_shape "H3 cd to a subdirectory" "cd $WT/data && $UP"
expect_shape "H3 cd to an outside directory" "cd $OUTSIDE && $UP"
expect_shape "H3 cd to a relative path" "cd ./ && $UP"
expect_shape "H3 cd to a relative subdirectory" "cd data && $UP"
expect_shape "H3 cd with a flag" "cd -P $WT && $UP"
expect_shape "H3 cd followed by ;" "cd $WT; $UP"
expect_shape "H3 cd followed by ||" "cd $WT || $UP"
expect_shape "H3 cd followed by |" "cd $WT | $UP"
expect_shape "H3 cd followed by a newline" "cd $WT
$UP"
expect_shape "H3 two cds" "cd $WT && cd $WT && $UP"
expect_shape "H3 bare cd" "cd && $UP"
expect_shape "H3 cd -" "cd - && $UP"
expect_shape "H3 cd with a variable" 'cd $X && '"$UP"
expect_shape "H3 cd with a substitution" 'cd $(pwd) && '"$UP"
expect_shape "H3 cd with backticks" 'cd `pwd` && '"$UP"
expect_shape "H3 cd to a nonexistent target" "cd $TMP/no-such-dir && $UP"
expect_shape "H3 cd with a glob" "cd $TMP/w* && $UP"
expect_shape "H3 pushd instead of cd" "pushd $WT && $UP"
expect_shape "H3 cd inside a subshell" "(cd $WT && true); $UP"
expect_shape "H3 cd inside a subshell group holding the shape" "(cd $WT && $UP)"
expect_shape "H3 cd in a skipped || branch" "true || cd $WT; $UP"
expect_shape "H3 cd sent to the background" "cd $WT & $UP"
expect_shape "H3 cd inside a substitution" "echo \$(cd $WT && true) && $UP"
expect_shape "H3 cd and the shape inside one substitution" "x=\$(cd $WT && $UP)"
expect_shape "H3 brace group with cd and the shape" "{ cd $WT && $UP; }"
expect_shape "H3 cd to the worktree, extra flag on the shape" "cd $WT && $CPB up -d"
# file and project-name variants
expect_shape "H3 file in a subdirectory of the worktree" "docker compose -p demo --file $WT/data/docker-compose.yml up -d --wait"
expect_shape "H3 file with a relative path" "docker compose -p demo --file docker-compose.yml up -d --wait"
expect_shape "H3 file with a dot-dot path" "docker compose -p demo --file ../outside/docker-compose.yml up -d --wait"
expect_shape "H3 file with another basename" "docker compose -p demo --file $WT/compose.yml up -d --wait"
expect_shape "H3 file with .yaml extension" "docker compose -p demo --file $WT/docker-compose.yaml up -d --wait"
expect_shape "H3 file symlink with another basename" "docker compose -p demo --file $WT/linked-compose.yml up -d --wait"
expect_shape "H3 file with a space in the path" "docker compose -p demo --file '$WT/a b/docker-compose.yml' up -d --wait"
expect_shape "H3 file from stdin" "docker compose -p demo --file - up -d --wait"
expect_shape "H3 file with a shell variable" 'docker compose -p demo --file "$F" up -d --wait'
expect_shape "H3 file with a glob" "docker compose -p demo --file $WT/*.yml up -d --wait"
expect_shape "H3 file with a tilde" "docker compose -p demo --file ~/docker-compose.yml up -d --wait"
expect_shape "H3 project name with a space" "docker compose -p 'de mo' --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 project name starting with a dash" "docker compose -p -x --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 project name with a semicolon" "docker compose -p 'a;b' --file $WT/docker-compose.yml up -d --wait"
expect_shape "H3 project name with a variable" 'docker compose -p "$N" --file '"$WT"'/docker-compose.yml up -d --wait'
expect_shape "H3 project name with a substitution" 'docker compose -p "$(whoami)" --file '"$WT"'/docker-compose.yml up -d --wait'
expect_block "H4 file outside the worktree" path-outside-worktree \
  "docker compose -p demo --file $OUTSIDE/docker-compose.yml up -d --wait"
expect_block "H4 file in a sibling repository" path-outside-worktree \
  "docker compose -p demo --file $WT2/docker-compose.yml up -d --wait"
expect_block "H4 file symlink named docker-compose.yml" symlinked-path \
  "docker compose -p demo --file $LNK/docker-compose.yml up -d --wait" "$LNK"
expect_block "H4 cwd in another repository, file in this one's sibling" path-outside-worktree \
  "docker compose -p demo --file $WT/docker-compose.yml up -d --wait" "$WT2"
expect_block "H4 cd form with a file outside" path-outside-worktree \
  "cd $OUTSIDE && docker compose -p demo --file $OUTSIDE/docker-compose.yml up -d --wait"

# --- container-creating subcommands off the shape are always blocked ---
for sub in run create start restart watch scale build exec cp; do
  expect_shape "H5 subcommand '$sub' (with --file)" "$CPB $sub web"
  expect_shape "H5 subcommand '$sub' (bare)" "docker compose $sub web"
  expect_shape "H5 subcommand '$sub' behind cd" "cd $WT && $CPB $sub web"
  expect_shape "H5 subcommand '$sub' with docker-compose v1" "docker-compose $sub web"
  expect_shape "H5 subcommand '$sub' with a global flag" "docker --context x compose $sub web"
done
RUN="$CPB run --rm"
for tail in "-v $FH:/h web sh" "-v /:/host web sh" "-v /var/run/docker.sock:/var/run/docker.sock web sh" \
            "-v$FH:/h web sh" "--volume $FH:/h web sh" "--volume=$FH:/h web sh" \
            "--mount type=bind,source=$FH,target=/h web sh" "--mount=type=bind,src=$FH,dst=/h web sh" \
            "-v ../../..:/h web sh" "-v ~/.ssh:/h web sh" "-v $WT/linkdir:/h web sh" \
            "--volumes-from other web sh" "--privileged web sh" "--cap-add SYS_ADMIN web sh" "--cap-add=ALL web sh" \
            "--device /dev/sda web sh" "--security-opt seccomp=unconfined web sh" "--pid host web sh" \
            "--pid=host web sh" "--ipc=host web sh" "--uts host web sh" "--network host web sh" "--net=host web sh" \
            "--network container:x web sh" "-v $WT/data:/d web sh" "-v ./data:/d web sh" "-v cache:/c web sh" \
            "--mount type=tmpfs,target=/t web sh" "--network bridge web sh" "-e FOO=1 -T web echo hi"; do
  expect_shape "H5 run: $tail" "$RUN $tail"
done
for sub in run create; do
  for tail in "-v $FH:/x web" "-v$FH:/x web" "-v=$FH:/x web" "-dv $FH:/x web" "-dv$FH:/x web" "-dv=$FH:/x web" \
              "-itv $FH:/x web" "-e A=1 -v $FH:/x web" "-T -v $FH:/x web" "--volume $FH:/x web" "--volume=$FH:/x web" \
              "--mount type=bind,src=$FH,dst=/x web" "--mount=type=bind,source=$FH,target=/x web" \
              "--network host web" "--network=host web" "--pid=host web" "--cap-add ALL web" "--privileged web" \
              "-dv $WT/data:/d web" "-v data:/d web" "-e -v web" "-dv" "--volume" "web -v $FH:/x" "web sh -v $FH:/x" "-- web sh -v $FH:/x"; do
    expect_shape "H5f $sub: $tail" "$CPB $sub $tail"
  done
done
EXB="$CPB exec"
for tail in "--privileged web sh" "--index 1 --privileged web sh" "--privileged=true web sh" "--cap-add=ALL web sh" \
            "web sh" "web sh --privileged" "-- web sh --privileged"; do
  expect_shape "H5x exec: $tail" "$EXB $tail"
done
expect_shape "H5x cp host copy" "$CPB cp web:/etc/passwd $WT/data/passwd"
expect_shape "H5x cp into a container from outside" "$CPB cp $FH/.ssh web:/root"
expect_shape "H5x cp inside a substitution" "echo \$($CPB cp web:/a $WT/data/a)"
expect_shape "H5x build on a clean fixture" "$CPB build"
expect_shape "H5x alpha watch" "$CPB alpha watch"
expect_allow "H5x alpha ls stays allowed" "$CPB alpha ls"
run_hook "$EXB web sh"
[ ! -s "$STUB_LOGF" ] && pass "H5x exec never calls docker" || fail "H5x exec invoked docker: $(cat "$STUB_LOGF")"

# --- expansion, alias, function and absolute-path probes ---
expect_shape "H6 variable as the subcommand word's neighbour (c=compose)" 'c=compose; docker $c up'
expect_shape "H6 variable as the program (d=docker)" 'd=docker; $d compose up'
expect_shape "H6 variable as the subcommand (s=up)" 's=up; docker compose $s'
expect_shape "H6 variable subcommand with the shape's prefix" "s=up; $CPB \$s -d --wait"
expect_shape "H6 braced variable as the subcommand" 'docker compose ${S:-up}'
expect_shape "H6 substitution as the subcommand" 'docker compose $(echo up)'
expect_shape "H6 backticks as the subcommand" 'docker compose `echo up`'
expect_shape "H6 ANSI-C quoting" "docker compose \$'up'"
expect_shape "H6 expansion in command position" '$CMD compose up'
expect_shape "H6 expansion in command position with a subcommand word, docker named earlier" 'echo docker; $CMD up -d'
expect_shape "H6 expansion in command position of a docker line" 'echo docker; $X'
expect_shape "H6 alias to a compose command" 'alias d="docker compose"; d up'
expect_shape "H6 alias with a single-quoted body" "alias d='docker compose up'; d"
expect_shape "H6 function wrapping compose" 'f(){ docker compose up; }; f'
expect_shape "H6 absolute path to docker" '/usr/local/bin/docker compose up'
expect_shape "H6 absolute path with the shape's arguments" "/usr/local/bin/docker compose -p demo --file $WT/docker-compose.yml up -d --wait"
expect_shape "H6 command docker" 'command docker compose up'
expect_shape "H6 backslash docker" '\docker compose up'
expect_shape "H6 env docker" 'env docker compose up'
expect_shape "H6 quoted program word" '"docker" compose up'
expect_shape "H6 quoted compose word" "docker 'compose' up"
expect_shape "H6 bare docker compose up" 'docker compose up'
expect_shape "H6 docker compose up -d" 'docker compose up -d'

# --- text that only mentions compose, and read-only subcommands ---
mkcfg '.services.web.privileged = true'
expect_allow "H7 echo that names a compose command" "echo \"docker compose -p demo --file $WT/docker-compose.yml up -d\""
expect_allow "H7 single-quoted mention" "echo 'docker compose up -d --privileged'"
expect_allow "H7 echo with a bare mention" "echo docker compose up"
expect_allow "H7 printf with a mention" "printf '%s\n' 'docker compose up'"
expect_allow "H7 heredoc prose naming compose up" "cat <<'EOF'
docker compose -p demo --file $WT/docker-compose.yml up -d
EOF"
expect_allow "H7 heredoc written to a file" "cat > $WT/notes.md <<EOF
run docker compose up to start
EOF"
expect_allow "H7 search for the word compose" "rg compose $WT"
expect_allow "H7 search with an expansion" 'rg compose $HOME'
expect_allow "H7 grep for a compose command" "grep -n 'docker compose up' $WT/notes.md"
expect_allow "H7 ls with an expansion" 'ls $HOME'
expect_allow "H7 head of a file naming compose" "head -5 $WT/docker-compose.yml"
expect_allow "H7 commit message mentioning compose" "git commit -m 'docs: describe docker compose up'"
expect_allow "H7 commit message with an expansion" 'git commit -m "docker compose up $X"'
expect_allow "H7 git status with an expanded directory" 'git -C "$W" status'
expect_allow "H7 git log naming compose" "git log --grep='docker compose up'"
expect_allow "H7 commit body in a heredoc" "git commit -F - <<'EOF'
feat: run docker compose up in the skill
EOF"
expect_allow "H7 commit body in a heredoc inside a substitution" "git commit -m \"\$(cat <<'EOF'
feat: run docker compose up in the skill
EOF
)\""
expect_allow "H7 gh pr create with a body mentioning compose" "gh pr create --title t --body 'run docker compose up -d after the change'"
expect_allow "H7 gh issue comment mentioning compose" "gh issue comment 1 --body 'docker compose up is slow'"
expect_allow "H7 pnpm with an expansion and no compose word" 'pnpm --dir $WT test'
expect_allow "H7 cd with an expansion then a read-only subcommand" 'cd "$WT" && docker compose ps'
expect_allow "H7 plain ps" "docker compose ps"
expect_allow "H7 timeout around logs" "timeout 5 docker compose logs"
expect_allow "H7 timeout around ps with a file" "timeout 5 $CPB ps"
expect_allow "H7 substitution naming compose as a word, no subcommand" 'echo $(echo compose) done'
expect_allow "H7 substitution without compose" 'x=$(date +%s); echo "$x"'
expect_allow "H7 keyword-only command without compose" "if true; then echo hi; fi"
expect_allow "H7 unresolvable cd with no compose command" 'cd $X && echo compose'
for sub in down logs ps version config ls images top port events; do
  expect_allow "H7 subcommand '$sub' is not checked" "$CPB $sub"
  expect_allow "H7 subcommand '$sub' behind a cd" "cd $WT && $CPB $sub"
  expect_allow "H7 subcommand '$sub' wrapped in timeout" "timeout 5 $CPB $sub"
done
expect_allow "H7 down --volumes --remove-orphans" "$CPB down --volumes --remove-orphans"
expect_allow "H7 logs --tail 50 web" "$CPB logs --tail 50 web"
expect_allow "H7 ps --format json" "$CPB ps --format json"
expect_allow "H7 cd out of the worktree followed by down" "cd $OUTSIDE && docker compose down"
expect_allow "H7 unresolvable cd followed by logs" 'cd $X && docker compose logs web'
run_hook "$CPB down"
[ ! -s "$STUB_LOGF" ] && pass "H7 down does not resolve the config" || fail "H7 down invoked docker: $(cat "$STUB_LOGF")"
run_hook "timeout 5 docker compose logs"
[ ! -s "$STUB_LOGF" ] && pass "H7 wrapped logs does not resolve the config" || fail "H7 wrapped logs invoked docker: $(cat "$STUB_LOGF")"
run_hook "echo hello"
[ "$HOOK_RC" -eq 0 ] && [ ! -s "$STUB_LOGF" ] && pass "H7 a command with neither docker nor compose exits 0 without calling docker" || fail "H7 plain command: rc=$HOOK_RC log=$(cat "$STUB_LOGF")"
expect_allow "H7 hooks/tests/run-all.sh shard run" "hooks/tests/run-all.sh -j 8 --shard 1/8"
expect_allow "H7 run-all.sh with a compose-named filter" "hooks/tests/run-all.sh --only 'docker-compose*'"
expect_allow "H7 bash run-all.sh with a compose-named filter" "bash hooks/tests/run-all.sh --serial --only '*compose*'"
run_hook "hooks/tests/run-all.sh -j 8 --shard 2/8"

# --- the docker-env skill's own command lines (read from SKILL.md) ---
SKILL_MD="$REPO_ROOT/skills/docker-env/SKILL.md"
skill_block() { # fixed-string needle that identifies the fenced bash block
  awk -v n="$1" '
    /^```bash$/ {b=""; inb=1; next}
    /^```$/ && inb {inb=0; if (index(b, n)) {printf "%s", b; exit} next}
    inb {b = b $0 "\n"}' "$SKILL_MD"
}
skill_fill() { # stdin -> placeholders filled
  sed -e "s|<project_name>|demo|g" -e "s|<worktree>|$WT|g" -e "s|<service>|web|g"
}
mkcfg '.'
S_UP="$(skill_block 'up -d --wait' | skill_fill)"
S_DOWN="$(skill_block '" down' | skill_fill)"
S_LOGS="$(skill_block ' logs ' | skill_fill)"
S_PS="$(skill_block ' ps --format json' | skill_fill)"
for v in S_UP S_DOWN S_LOGS S_PS; do
  [ -n "${!v}" ] && pass "H8 SKILL.md block for $v extracted" || fail "H8 SKILL.md block for $v not found"
done
case "$S_UP" in *'docker info'*'docker compose version'*'up -d --wait'*) pass "H8 up block carries the availability probes" ;; *) fail "H8 up block lacks the probes" ;; esac
# The block is two parts: the availability probes, then the one up line (the
# up line must stand alone in the allowed shape; the probes run verbatim).
S_PROBES="${S_UP%%$'\n'# Bring up*}"
S_UPLINE="$(printf '%s\n' "$S_UP" | grep -E '^docker compose -p .* up -d --wait$')"
[ -n "$S_UPLINE" ] && [ "$S_PROBES" != "$S_UP" ] && pass "H8 up block split into probes and the up line" || fail "H8 could not split the up block"
expect_allow "H8 skill availability/compose v2 probe block, verbatim" "$S_PROBES"
expect_allow "H8 skill up line, verbatim" "$S_UPLINE"
expect_allow "H8 skill up line behind a cd to the worktree" "cd $WT && $S_UPLINE"
expect_allow "H8 skill down, verbatim" "$S_DOWN"
expect_allow "H8 skill logs with --tail \"\${tail:-50}\", verbatim" "$S_LOGS"
expect_allow "H8 skill ps, verbatim" "$S_PS"
case "$S_LOGS" in *'${tail:-50}'*) pass "H8 logs block still carries the \${tail:-50} expansion" ;; *) fail "H8 logs block lost \${tail:-50}" ;; esac
expect_allow "H8 skill down behind a cd to the worktree" "cd $WT && $S_DOWN"
expect_allow "H8 escaped backticks in a double-quoted echo" 'echo "x (\`docker compose up\`)"'
expect_allow "H8 escaped dollar in a double-quoted echo" 'echo "x \$(docker compose up -d)"'
expect_allow "H8 down with a trailing expansion" "$CPB down \$X"
expect_allow "H8 logs with \${tail:-50} and a service" "$CPB logs --tail \"\${tail:-50}\" web"

# expansions that can still start containers stay blocked
expect_shape "H8 backticks around compose up" 'echo `docker compose up -d`'
expect_shape "H8 command substitution inside a double-quoted echo" 'echo "$(docker compose up -d)"'
expect_shape "H8 down followed by a compose-up substitution" "$CPB down \$(docker compose up)"
expect_shape "H8 down followed by a variable-command substitution" "$CPB down \$(\$DC)"
expect_shape "H8 variable before the subcommand" "docker compose -p demo \$S down"
expect_shape "H8 variable as the docker subcommand" 'docker $S'
expect_shape "H8 variable as the compose subcommand" 'docker compose $S'
expect_shape "H8 expansion before the subcommand after -p" "docker compose -p \$P --file $WT/docker-compose.yml down"
[ ! -s "$STUB_LOGF" ] && pass "H7 run-all.sh never reaches docker" || fail "H7 run-all.sh invoked docker"
payload="$(jq -n --arg c "$UP" --arg d "$WT" '{tool_name:"Read",tool_input:{command:$c},cwd:$d}')"
printf '%s' "$payload" | env -i PATH="$SBX" HOME="$FH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" STUB_LOG="$STUB_LOGF" \
  STUB_CFG="$CFGF" "$SBX/bash" "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && pass "H7 a non-Bash tool_name exits 0 even with a bad fixture" || fail "H7 non-Bash tool_name not ignored"

# --- prose that still blocks ---
expect_shape "H8 prose piped into bash" "echo 'docker compose up -d' | bash"
expect_shape "H8 prose piped into sh" "echo 'docker compose up -d' | sh"
expect_shape "H8 prose piped into xargs docker" "echo 'compose up' | xargs docker"
expect_shape "H8 prose piped into eval-like interpreter" "printf 'docker compose up' | zsh"
expect_shape "H8 prose in a process substitution into bash" "bash <(echo 'docker compose up')"
expect_shape "H8 prose in an output process substitution" "echo 'docker compose up' > >(bash)"
expect_shape "H8 rg with --pre" "rg --pre ./filter 'compose up' ."
expect_shape "H8 rg with --pre=" "rg --pre=./filter 'compose up' ."
expect_shape "H8 grep with --hostname-bin" "rg --hostname-bin ./h 'compose up' ."
expect_shape "H8 git -c alias naming compose up" "git -c alias.x='!docker compose up' commit -m x"
expect_shape "H8 git with config-env" "git --config-env=alias.x=X commit -m 'docker compose up'"
expect_shape "H8 inner substitution with an expansion in prose" "echo \"\$(\$X compose up)\""
expect_shape "H8 inner backticks with an expansion in prose" "echo \"\`\$X compose up\`\""
expect_shape "H8 heredoc into bash" "bash <<'EOF'
docker compose up
EOF"

# --- fail closed ---
mkcfg '.'
STUB_RC=1 expect_block "H9 config command fails" unresolved-config "$UP"
echo 'not json at all' > "$CFGF"
expect_block "H9 config output is not JSON" unresolved-config "$UP"
echo '[]' > "$CFGF"
expect_block "H9 config output is not an object" unresolved-config "$UP"
: > "$CFGF"
expect_block "H9 config output is empty" unresolved-config "$UP"
rm -f "$CFGF"
expect_block "H9 config output missing" unresolved-config "$UP"
mkcfg '.'
STUB_FAIL_PROFILE=1 expect_allow "H9 retry without --profile succeeds on a compliant fixture" "$UP"
if [ "$(grep -c ' config ' "$STUB_LOGF")" -eq 2 ] \
   && [ "$(sed -n '1p' "$STUB_LOGF")" = "compose -p demo --file $WT/docker-compose.yml --profile * config --no-env-resolution --format json" ] \
   && [ "$(sed -n '2p' "$STUB_LOGF")" = "compose -p demo --file $WT/docker-compose.yml config --no-env-resolution --format json" ]; then
  pass "H9 second attempt drops --profile and keeps --no-env-resolution --format json"
else
  fail "H9 retry shape unexpected: $(tr '\n' '|' < "$STUB_LOGF")"
fi
mkcfg '.services.web.privileged = true'
STUB_FAIL_PROFILE=1 expect_block "H9 retry result is still checked" privileged "$UP"
mkcfg '.'
STUB_FAIL_STAR=1 expect_allow "H9 fallback after a failing --profile '*' call" "$UP"
mkcfg '.services.web.privileged = true'
STUB_FAIL_STAR=1 expect_block "H9 fallback result is still checked" privileged "$UP"
mkcfg '.'
STUB_REJECT_NOENV=1 expect_block "H9 compose without --no-env-resolution fails closed" unresolved-config "$UP"
STUB_RC=1 expect_block "H9 both config calls failing fail closed (cd form)" unresolved-config "cd $WT && $UP"

# --- time budget ---
mkcfg '.'
STUB_SLEEP=40 run_hook "$UP"
if [ "$HOOK_RC" -eq 2 ] && grep -qF '(unresolved-config)' <<<"$HOOK_ERR" && [ "$HOOK_SECS" -le 20 ]; then
  pass "H10 a stalled config resolution is cut off and blocked in ${HOOK_SECS}s (budget 12s, stub sleeps 40s)"
else
  fail "H10 stall handling: rc=$HOOK_RC secs=$HOOK_SECS stderr='$(printf '%s' "$HOOK_ERR" | head -1)'"
fi

# --- docker or jq absent ---
HOOK_PATH="$SBX_NODOCKER" expect_allow "H11 docker absent from PATH: exits 0" "$UP"
mkcfg '.services.web.privileged = true'
HOOK_PATH="$SBX_NODOCKER" expect_allow "H11 docker absent from PATH: exits 0 even for a bad fixture" "$UP"
HOOK_PATH="$SBX_NODOCKER" expect_allow "H11 docker absent from PATH: exits 0 for an off-shape command" "$CPB run web"
HOOK_PATH="$SBX_NOJQ" expect_allow "H11 jq absent from PATH: exits 0" "$UP"
HOOK_PATH="$SBX_NOJQ" expect_allow "H11 jq absent from PATH: exits 0 for an off-shape command" "$CPB run web"

# --- linked worktrees: boundary and directory tracking ---
# A temp main checkout with two linked worktrees. The stub prints
# <cwd>/.stub-cfg.json when present (so the directory the config is resolved
# from is observable), else the shared fixture.
MAIN="$TMP/main"; LW1="$TMP/lw1"; LW2="$TMP/lw2"
mkdir -p "$MAIN" && git -C "$MAIN" init -q 2>/dev/null
git -C "$MAIN" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid \
  commit -q --allow-empty -m init 2>/dev/null
git -C "$MAIN" worktree add -q -b lw1 "$LW1" 2>/dev/null
git -C "$MAIN" worktree add -q -b lw2 "$LW2" 2>/dev/null
mkdir -p "$LW1/data" "$LW2/data"
: > "$MAIN/docker-compose.yml"; : > "$LW1/docker-compose.yml"; : > "$LW2/docker-compose.yml"
if [ -f "$LW1/.git" ] && [ -f "$LW2/.git" ] && [ -d "$MAIN/.git" ]; then pass "W0 fixture: two linked worktrees of a main checkout"
else fail "W0 fixture: linked worktrees were not created"; fi
# The `<repo>-worktrees/<task>` layout.
PROJ="$TMP/proj"; PWT="$TMP/proj-worktrees/task-1-x"
mkdir -p "$PROJ" "$TMP/proj-worktrees" && git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid \
  commit -q --allow-empty -m init 2>/dev/null
git -C "$PROJ" worktree add -q -b task-1-x "$PWT" 2>/dev/null
mkdir -p "$PWT/data"; : > "$PWT/docker-compose.yml"
if [ -f "$PWT/.git" ]; then pass "W0 fixture: a linked worktree under <repo>-worktrees/"
else fail "W0 fixture: <repo>-worktrees worktree was not created"; fi

cfg_for() { # dir jq-expr -> compliant-by-default config rooted at dir, to stdout
  jq -n --arg wt "$1" --arg home "$FH" --arg out "$OUTSIDE" \
    '{name:"demo",services:{web:{image:"nginx:1",volumes:[{type:"bind",source:($wt+"/data"),target:"/d"}]}}} | '"$2"
}
mkcfg_for() { cfg_for "$1" "$2" > "$CFGF"; }
setcfg() { cfg_for "$1" "$2" > "$1/.stub-cfg.json"; }
clearcfg() { rm -f "$MAIN/.stub-cfg.json" "$LW1/.stub-cfg.json" "$LW2/.stub-cfg.json" "$PWT/.stub-cfg.json"; }
upf() { printf 'docker compose -p x --file %s/docker-compose.yml up -d --wait' "$1"; }

# 1. the shape into a linked worktree, session elsewhere
clearcfg; mkcfg_for "$LW1" '.'
expect_allow "W1 file in a linked worktree from the main checkout" "$(upf "$LW1")" "$MAIN"
expect_allow "W1 file in a linked worktree from an unrelated directory" "$(upf "$LW1")" "$OUTSIDE"
expect_allow "W1 quoted -p and --file into a linked worktree" \
  "docker compose -p \"x\" --file \"$LW1/docker-compose.yml\" up -d --wait" "$MAIN"
expect_allow "W1 cd to the linked worktree then the shape" "cd $LW1 && $(upf "$LW1")" "$MAIN"
mkcfg_for "$PWT" '.'
expect_allow "W1 file in a <repo>-worktrees/<task> worktree" "$(upf "$PWT")" "$WT"
expect_allow "W1 cd form in a <repo>-worktrees/<task> worktree" "cd $PWT && $(upf "$PWT")" "$WT"
mkcfg_for "$PWT" '.services.web.privileged = true'
expect_block "W1 privileged service in a <repo>-worktrees worktree is blocked" privileged "$(upf "$PWT")" "$WT"
mkcfg_for "$LW1" '.services.web.privileged = true'
expect_block "W1 a privileged service in a linked worktree is blocked" privileged "$(upf "$LW1")" "$MAIN"
mkcfg_for "$LW1" '.services.web.volumes[0].source = $home'
expect_block "W1 an outside bind in a linked worktree is blocked" bind-outside-worktree "$(upf "$LW1")" "$MAIN"
expect_shape "W1 --project-directory into a linked worktree" \
  "docker compose -p x --project-directory $LW1 up -d --wait" "$MAIN"
expect_shape "W1 --project-directory with --file into a linked worktree" \
  "docker compose -p x --project-directory $LW1 --file $LW1/docker-compose.yml up -d --wait" "$MAIN"
expect_shape "W1 subdirectory of a <repo>-worktrees worktree" \
  "docker compose -p x --file $PWT/data/docker-compose.yml up -d --wait" "$WT"

# 2. the cd form: the cd target must be the compose file's worktree
clearcfg; mkcfg_for "$MAIN" '.'
setcfg "$LW1" '.'
expect_allow "W2 cd <wt> && shape from the main checkout" "cd $LW1 && $(upf "$LW1")" "$MAIN"
expect_shape "W2 cd <wt> && up without --file" "cd $LW1 && docker compose up -d" "$MAIN"
expect_shape "W2 cd <wt> && up with a relative --file" "cd $LW1 && docker compose --file docker-compose.yml up -d" "$MAIN"
expect_shape "W2 cd <wt> && up -p/--file ./relative" "cd $LW1 && docker compose -p x -f ./docker-compose.yml up -d --wait" "$MAIN"
expect_shape "W2 cd <wt> && run with a relative in-worktree bind" "cd $LW1 && docker compose run --rm -v ./data:/d web sh" "$MAIN"
expect_shape "W2 cd <wt> && run with a relative dot-dot bind" "cd $LW1 && docker compose run --rm -v ../main:/d web sh" "$MAIN"
expect_shape "W2 cd to one worktree, file in another" "cd $LW1 && $(upf "$LW2")" "$MAIN"
setcfg "$LW1" '.services.web.volumes[0].source = $out'
expect_block "W2 cd <wt> && shape: the cd target's outside bind is checked" bind-outside-worktree \
  "cd $LW1 && $(upf "$LW1")" "$MAIN"
clearcfg; mkcfg_for "$MAIN" '.'
setcfg "$LW2" '.'
expect_allow "W2 session in one linked worktree, cd to another linked worktree" \
  "cd $LW2 && $(upf "$LW2")" "$LW1"
expect_shape "W2 session in one linked worktree, cd to another, file in the first" \
  "cd $LW2 && $(upf "$LW1")" "$LW1"
clearcfg

# 3. session in a worktree, target is the main checkout
mkcfg_for "$MAIN" '.'
expect_block "W3 cd <main> && shape from a linked worktree" path-outside-worktree \
  "cd $MAIN && $(upf "$MAIN")" "$LW1"
expect_block "W3 --file in the main checkout from a linked worktree" path-outside-worktree "$(upf "$MAIN")" "$LW1"
expect_shape "W3 --project-directory in the main checkout from a linked worktree" \
  "docker compose -p x --project-directory $MAIN up -d --wait" "$LW1"
expect_allow "W3 the main checkout is accepted as the session's own toplevel" "$(upf "$MAIN")" "$MAIN"

# 4. a plain (non-worktree) repository or a non-git directory
mkcfg_for "$WT2" '.'
expect_block "W4 file in a plain git repository from the main checkout" path-outside-worktree "$(upf "$WT2")" "$MAIN"
expect_block "W4 file in a plain git repository from a linked worktree" path-outside-worktree "$(upf "$WT2")" "$LW1"
expect_block "W4 file in a non-git directory" path-outside-worktree "$(upf "$OUTSIDE")" "$MAIN"
expect_block "W4 cd into a plain git repository" path-outside-worktree "cd $WT2 && $(upf "$WT2")" "$MAIN"
expect_block "W4 cd into a non-git directory" path-outside-worktree "cd $OUTSIDE && $(upf "$OUTSIDE")" "$MAIN"
expect_shape "W4 --project-directory in a non-git directory" "docker compose -p x --project-directory $OUTSIDE up -d --wait" "$MAIN"

# 5. cwd tricks around the shape
clearcfg
setcfg "$LW1" '.services.web.volumes[0].source = $out'
setcfg "$LW2" '.'
expect_block "W5 baseline: the session worktree's outside bind is checked" bind-outside-worktree "$(upf "$LW1")" "$LW1"
expect_shape "W5 cd inside a subshell group does not move the shape" "(cd $LW2 && true); $(upf "$LW1")" "$LW1"
expect_shape "W5 cd inside a subshell group, newline separator" "(cd $LW2)
$(upf "$LW1")" "$LW1"
expect_shape "W5 cd in a skipped || branch" "true || cd $LW2; $(upf "$LW1")" "$LW1"
expect_shape "W5 cd in a skipped && branch" "false && cd $LW2; $(upf "$LW1")" "$LW1"
expect_shape "W5 cd on the left of a pipe" "cd $LW2 | cat; $(upf "$LW1")" "$LW1"
expect_shape "W5 cd sent to the background" "cd $LW2 & $(upf "$LW1")" "$LW1"
expect_shape "W5 cd inside a command substitution" "echo \$(cd $LW2 && pwd); $(upf "$LW1")" "$LW1"
expect_shape "W5 cd in an if-branch that is not taken" "if false; then cd $LW2; fi; $(upf "$LW1")" "$LW1"
expect_shape "W5 cd then the shape inside a bash -c wrapper" "bash -c 'true || cd $LW2; $(upf "$LW1")'" "$LW1"
expect_shape "W5 cd <compliant> || true; shape" "cd $LW2 || true; $(upf "$LW2")" "$LW1"
expect_shape "W5 subshell group that contains the cd and the shape" "(cd $LW2 && $(upf "$LW2"))" "$LW1"
expect_shape "W5 cd <compliant>; shape (semicolon connector)" "cd $LW2; $(upf "$LW2")" "$LW1"
expect_shape "W5 brace group with cd and the shape" "{ cd $LW2 && $(upf "$LW2"); }" "$LW1"
expect_allow "W5 down after a cd that is not followed stays allowed" "cd $LW2; docker compose down" "$LW1"
expect_allow "W5 logs after a cd inside a subshell group stays allowed" "(cd $LW2 && docker compose logs web)" "$LW1"
expect_allow "W5 ps after a cd behind || stays allowed" "cd $LW2 || true; docker compose ps" "$LW1"
expect_allow "W5 version after popd stays allowed" 'popd; docker compose version' "$LW1"
clearcfg

# LEX_CONN records the separator that ended each segment.
lex_conn() { (
  # shellcheck disable=SC1091
  . "$REPO_ROOT/hooks/lib/shell-lex.sh"; lex "$1"; printf '%s' "$LEX_CONN"
); }
c="$(lex_conn 'a && b')"; [ "$c" = '&&' ] && pass "W9 LEX_CONN of 'a && b' is '&&'" || fail "W9 LEX_CONN of 'a && b' is '$c', want '&&'"
c="$(lex_conn 'a || b')"; [ "$c" = '||' ] && pass "W9 LEX_CONN of 'a || b' is '||'" || fail "W9 LEX_CONN of 'a || b' is '$c', want '||'"
c="$(lex_conn 'a; b')"; [ "$c" = ';' ] && pass "W9 LEX_CONN of 'a; b' is ';'" || fail "W9 LEX_CONN of 'a; b' is '$c', want ';'"
c="$(lex_conn 'a | b')"; [ "$c" = '|' ] && pass "W9 LEX_CONN of 'a | b' is '|'" || fail "W9 LEX_CONN of 'a | b' is '$c', want '|'"
clearcfg

# --- config fields on the allowed shape ---
echo "-- config fields"
mkcfg '.services.web.build = {context:($wt + "/data"), additional_contexts:{lib:$home}}'
expect_block "H13 additional_contexts absolute outside path (map)" bind-outside-worktree "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), additional_contexts:["lib=" + $home]}'
expect_block "H13 additional_contexts outside path in list form" bind-outside-worktree "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), additional_contexts:{lib:($wt + "/data")}}'
expect_allow "H13 additional_contexts inside the worktree" "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), additional_contexts:{a:"docker-image://alpine:3", b:"service:base", c:"https://example.invalid/r.git"}}'
expect_allow "H13 additional_contexts docker-image:// service: https: are allowed" "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), additional_contexts:{lib:($wt + "/linkdir")}}'
expect_block "H13 additional_contexts symlinked source" symlinked-bind-source "$UP"

mkcfg '.services.web.build = {context:($wt + "/data"), ssh:["default"]}'
expect_block "H14 build.ssh list [default]" build-ssh "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), ssh:{default:null}}'
expect_block "H14 build.ssh object form" build-ssh "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), ssh:{github:"/tmp/agent.sock"}}'
expect_block "H14 build.ssh object form with a path value" build-ssh "$UP"
mkcfg '.services.web.build = {context:($wt + "/data")}'
expect_allow "H14 build.ssh absent" "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), ssh:[]}'
expect_allow "H14 build.ssh empty list" "$UP"
mkcfg '.services.web.build = {context:($wt + "/data"), ssh:{}}'
expect_allow "H14 build.ssh empty object" "$UP"

mkcfg '.services.web.env_file = ($home + "/vars.list")'
expect_block "H15 env_file outside path as a string" bind-outside-worktree "$UP"
mkcfg '.services.web.env_file = [($wt + "/data"), ($home + "/vars.list")]'
expect_block "H15 env_file outside path in a list" bind-outside-worktree "$UP"
mkcfg '.services.web.env_file = [{path:($home + "/vars.list"), required:false}]'
expect_block "H15 env_file {path, required:false} outside" bind-outside-worktree "$UP"
mkcfg '.services.web.env_file = ($wt + "/data")'
expect_allow "H15 env_file inside the worktree (string)" "$UP"
mkcfg '.services.web.env_file = [{path:($wt + "/data"), required:false}]'
expect_allow "H15 env_file inside the worktree (object)" "$UP"
mkcfg '.services.web.env_file = ($wt + "/linkdir")'
expect_block "H15 env_file symlinked source" symlinked-bind-source "$UP"

mkcfg '.services.web.post_start = [{command:"x", privileged:true}]'
expect_block "F4 post_start privileged" privileged "$UP"
mkcfg '.services.web.pre_stop = [{command:"x", privileged:true}]'
expect_block "F4 pre_stop privileged" privileged "$UP"
mkcfg '.services.web.use_api_socket = true'
expect_block "F4 use_api_socket" runtime-socket "$UP"
mkcfg '.services.web.provider = {type:"model"}'
expect_block "F4 provider service" provider-service "$UP"
mkcfg '.services.web.build = {context:$wt, privileged:true}'
expect_block "F4 build.privileged" elevated-build "$UP"
mkcfg '.services.web.build = {context:$wt, entitlements:["security.insecure"]}'
expect_block "F4 build.entitlements" elevated-build "$UP"
mkcfg '.services.web.build = {context:$wt, network:"host"}'
expect_block "F4 build.network host" host-namespace "$UP"
mkcfg '.services.web.post_start = [{command:"x"}] | .services.web.pre_stop = [{command:"y", privileged:false}] | .services.web.use_api_socket = false | .services.web.build = {context:$wt, network:"default", entitlements:[]}'
expect_allow "F4 clean fixture with none of these" "$UP"

# --- decision log ---
mkcfg '.services.web.privileged = true'
rm -rf "$WT/.task-log"
run_hook "$UP"
if [ "$HOOK_RC" -eq 2 ] && jq -e -s 'map(select(.hook == "block-compose-escape" and .action == "block")) | length >= 1' "$WT/.task-log/hook-decisions.jsonl" >/dev/null 2>&1; then
  pass "H12 a config block is recorded in hook-decisions.jsonl"
else
  fail "H12 no block record in the decision log ($(cat "$WT/.task-log/hook-decisions.jsonl" 2>/dev/null | head -1))"
fi
rm -rf "$WT/.task-log"
run_hook "$CPB run web"
if [ "$HOOK_RC" -eq 2 ] && jq -e -s 'map(select(.hook == "block-compose-escape" and .action == "block")) | length >= 1' "$WT/.task-log/hook-decisions.jsonl" >/dev/null 2>&1; then
  pass "H12 a shape block is recorded in hook-decisions.jsonl"
else
  fail "H12 no shape block record in the decision log ($(cat "$WT/.task-log/hook-decisions.jsonl" 2>/dev/null | head -1))"
fi

echo ""
echo "permission-code-exec-narrowing: $cases cases"
if [ "$fails" -eq 0 ]; then
  echo "permission-code-exec-narrowing: all assertions passed."
  exit 0
fi
echo "permission-code-exec-narrowing: $fails assertion(s) failed."
exit 1
