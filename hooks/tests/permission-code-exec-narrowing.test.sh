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
#        - blocks container-creating subcommands whose effective config or
#          flags reach outside the worktree
#        - allows the docker-env shapes on a compliant fixture
#        - ignores text that only mentions compose, other subcommands, and the
#          repo's own test runner
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
SBX="$TMP/sbx"; SBX_NODOCKER="$TMP/sbx-nodocker"; mkdir -p "$SBX" "$SBX_NODOCKER"
for t in bash sh jq git env cat dirname basename sleep kill mktemp rm date awk sed tr head tail sort uniq grep cut wc mkdir ls readlink uname id printf expr; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$p" in /*) ln -sf "$p" "$SBX/$t"; ln -sf "$p" "$SBX_NODOCKER/$t" ;; esac
done
cat > "$SBX/docker" <<'STUB'
#!/bin/sh
# Hermetic stub: records argv, prints the fixture config for `config`.
echo "$*" >> "$STUB_LOG"
case " $* " in
  *" config "*)
    if [ -n "${STUB_FAIL_PROFILE:-}" ]; then
      case " $* " in *" --profile "*) exit 1 ;; esac
    fi
    [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
    [ -n "${STUB_CFG:-}" ] && [ -f "$STUB_CFG" ] && cat "$STUB_CFG"
    exit "${STUB_RC:-0}" ;;
  *" version "*|*" version") echo "Docker Compose version v2.0.0-stub"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$SBX/docker"

FH="$TMP/home"; mkdir -p "$FH"
WT="$TMP/wt"; mkdir -p "$WT/data" "$WT/run" && git -C "$WT" init -q 2>/dev/null
: > "$WT/docker-compose.yml"
: > "$WT/run/docker.sock"
WT2="$TMP/sibling"; mkdir -p "$WT2" && git -C "$WT2" init -q 2>/dev/null; : > "$WT2/docker-compose.yml"
OUTSIDE="$TMP/outside"; mkdir -p "$OUTSIDE"; : > "$OUTSIDE/docker-compose.yml"
ln -s "$FH" "$WT/linkdir"
ln -s "$OUTSIDE/docker-compose.yml" "$WT/linked-compose.yml"
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
      STUB_FAIL_PROFILE="${STUB_FAIL_PROFILE:-}" \
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

UP="docker compose -p demo --file $WT/docker-compose.yml up -d --wait"

# --- docker-env shapes on a compliant fixture ---
mkcfg '.'
expect_allow "H1 docker-env up on a compliant fixture" "$UP"
expect_allow "H1 docker-env up with quoted arguments (as the skill writes it)" \
  "docker compose -p \"demo\" --file \"$WT/docker-compose.yml\" up -d --wait"
expect_allow "H1 docker-env down" "docker compose -p demo --file $WT/docker-compose.yml down"
expect_allow "H1 docker-env down --volumes --remove-orphans" \
  "docker compose -p demo --file $WT/docker-compose.yml down --volumes --remove-orphans"
expect_allow "H1 docker-env logs" "docker compose -p demo --file $WT/docker-compose.yml logs --tail 50 web"
expect_allow "H1 docker-env ps" "docker compose -p demo --file $WT/docker-compose.yml ps --format json"
run_hook "$UP"
if grep -qE 'compose .*config --format json' "$STUB_LOGF" && grep -qF -- "-p demo" "$STUB_LOGF" \
   && grep -qF -- "--file $WT/docker-compose.yml" "$STUB_LOGF" && grep -qF -- "--profile *" "$STUB_LOGF"; then
  pass "H1 config resolved read-only with the command's project/file and all profiles"
else
  fail "H1 config resolution args unexpected: $(cat "$STUB_LOGF")"
fi
expect_allow "H1 up in a bash -c wrapper on a compliant fixture" "bash -c '$UP'"
expect_allow "H1 chained after another command" "echo start && $UP && echo done"

# --- config reaches outside the worktree ---
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

# every container-creating subcommand is checked
mkcfg '.services.web.privileged = true'
for sub in up run create start restart watch scale; do
  expect_block "H3 subcommand '$sub' is checked" privileged \
    "docker compose -p demo --file $WT/docker-compose.yml $sub web"
done
expect_block "H3 standalone docker-compose binary" privileged \
  "docker-compose -p demo --file $WT/docker-compose.yml up -d"
expect_block "H3 global docker flags before compose" privileged \
  "docker --context other compose -p demo --file $WT/docker-compose.yml up -d"
expect_block "H3 short -f form" privileged "docker compose -p demo -f $WT/docker-compose.yml up -d"
expect_block "H3 --file= form" privileged "docker compose -p demo --file=$WT/docker-compose.yml up -d"
expect_block "H3 -p after --file" privileged "docker compose --file $WT/docker-compose.yml -p demo up -d"
expect_block "H3 inside bash -c" privileged "bash -c '$UP'"
expect_block "H3 inside sh -c after a separator" privileged "true; sh -c \"$UP\""
expect_block "H3 inside eval" privileged "eval $UP"
expect_block "H3 behind env prefix" privileged "env FOO=1 $UP"
expect_block "H3 behind a pipe" privileged "echo go | $UP"
expect_block "H3 behind && chain" privileged "cd $WT && $UP"
expect_block "H3 env assignment prefix reaching compose" privileged "COMPOSE_PROJECT_NAME=demo $UP"

# --- compose-file / directory arguments outside the worktree ---
mkcfg '.'
expect_block "H4 --file outside the worktree" path-outside-worktree \
  "docker compose -p demo --file $OUTSIDE/docker-compose.yml up -d"
expect_block "H4 --file in a sibling worktree" path-outside-worktree \
  "docker compose -p demo --file $WT2/docker-compose.yml up -d"
expect_block "H4 --file by relative dot-dot" path-outside-worktree \
  "docker compose -p demo --file ../outside/docker-compose.yml up -d"
expect_block "H4 --file symlink to a file outside" symlinked-path \
  "docker compose -p demo --file $WT/linked-compose.yml up -d"
expect_block "H4 --file from stdin" unresolvable-path "docker compose -p demo --file - up -d"
expect_block "H4 --file with a shell variable" unresolvable-path 'docker compose -p demo --file "$F" up -d'
expect_block "H4 --project-directory outside" path-outside-worktree \
  "docker compose -p demo --file $WT/docker-compose.yml --project-directory $OUTSIDE up -d"
expect_block "H4 --env-file outside" path-outside-worktree \
  "docker compose -p demo --file $WT/docker-compose.yml --env-file $OUTSIDE/.e up -d"
expect_block "H4 COMPOSE_FILE env prefix outside" path-outside-worktree \
  "COMPOSE_FILE=$OUTSIDE/docker-compose.yml docker compose -p demo up -d"
expect_block "H4 exported COMPOSE_FILE outside" path-outside-worktree \
  "export COMPOSE_FILE=$OUTSIDE/docker-compose.yml; docker compose -p demo up -d"
expect_block "H4 cwd in another worktree, file in this one's sibling" path-outside-worktree \
  "docker compose -p demo --file $WT/docker-compose.yml up -d" "$WT2"

# --- run / create flags ---
mkcfg '.'
RUN="docker compose -p demo --file $WT/docker-compose.yml run --rm"
expect_block "H5 run -v home directory" bind-outside-worktree "$RUN -v $FH:/h web sh"
expect_block "H5 run -v root" bind-outside-worktree "$RUN -v /:/host web sh"
expect_block "H5 run -v runtime socket" bind-outside-worktree "$RUN -v /var/run/docker.sock:/var/run/docker.sock web sh"
expect_block "H5 run -v joined form" bind-outside-worktree "$RUN -v$FH:/h web sh"
expect_block "H5 run --volume" bind-outside-worktree "$RUN --volume $FH:/h web sh"
expect_block "H5 run --volume=" bind-outside-worktree "$RUN --volume=$FH:/h web sh"
expect_block "H5 run --mount bind outside" bind-outside-worktree "$RUN --mount type=bind,source=$FH,target=/h web sh"
expect_block "H5 run --mount=src= outside" bind-outside-worktree "$RUN --mount=type=bind,src=$FH,dst=/h web sh"
expect_block "H5 run -v relative dot-dot" bind-outside-worktree "$RUN -v ../../..:/h web sh"
expect_block "H5 run -v tilde" bind-outside-worktree "$RUN -v ~/.ssh:/h web sh"
expect_block "H5 run -v symlink" symlinked-bind-source "$RUN -v $WT/linkdir:/h web sh"
expect_block "H5 run --volumes-from" container-volumes "$RUN --volumes-from other web sh"
expect_block "H5 run --privileged" elevated-flag "$RUN --privileged web sh"
expect_block "H5 run --cap-add" elevated-flag "$RUN --cap-add SYS_ADMIN web sh"
expect_block "H5 run --cap-add=" elevated-flag "$RUN --cap-add=ALL web sh"
expect_block "H5 run --device" elevated-flag "$RUN --device /dev/sda web sh"
expect_block "H5 run --security-opt" elevated-flag "$RUN --security-opt seccomp=unconfined web sh"
expect_block "H5 run --pid host" host-namespace-flag "$RUN --pid host web sh"
expect_block "H5 run --pid=host" host-namespace-flag "$RUN --pid=host web sh"
expect_block "H5 run --ipc=host" host-namespace-flag "$RUN --ipc=host web sh"
expect_block "H5 run --uts host" host-namespace-flag "$RUN --uts host web sh"
expect_block "H5 run --network host" host-namespace-flag "$RUN --network host web sh"
expect_block "H5 run --net=host" host-namespace-flag "$RUN --net=host web sh"
expect_block "H5 run --network container:x" host-namespace-flag "$RUN --network container:x web sh"
expect_block "H5 create -v outside" bind-outside-worktree \
  "docker compose -p demo --file $WT/docker-compose.yml create -v $FH:/h web"
expect_allow "H5 run with an in-worktree bind" "$RUN -v $WT/data:/d web sh"
expect_allow "H5 run with a relative in-worktree bind" "$RUN -v ./data:/d web sh"
expect_allow "H5 run with a named volume" "$RUN -v cache:/c web sh"
expect_allow "H5 run with a tmpfs mount" "$RUN --mount type=tmpfs,target=/t web sh"
expect_allow "H5 run with a bridge network" "$RUN --network bridge web sh"
expect_allow "H5 run with plain flags" "$RUN -e FOO=1 -T web echo hi"

# --- text that only mentions compose, other subcommands, the repo's runner ---
mkcfg '.services.web.privileged = true'
expect_allow "H6 echo that names a compose command" "echo \"docker compose -p demo --file $WT/docker-compose.yml up -d\""
expect_allow "H6 single-quoted mention" "echo 'docker compose up -d --privileged'"
expect_allow "H6 heredoc prose naming compose up" "cat <<'EOF'
docker compose -p demo --file $WT/docker-compose.yml up -d
EOF"
expect_allow "H6 heredoc written to a file" "cat > $WT/notes.md <<EOF
run docker compose up to start
EOF"
expect_allow "H6 grep for the word compose" "rg compose $WT"
expect_allow "H6 commit message mentioning compose" "git commit -m 'docs: describe docker compose up'"
for sub in down logs ps version config pull ls images top port; do
  expect_allow "H6 subcommand '$sub' is not checked" "docker compose -p demo --file $WT/docker-compose.yml $sub"
done
run_hook "docker compose -p demo --file $WT/docker-compose.yml down"
[ ! -s "$STUB_LOGF" ] && pass "H6 down does not resolve the config" || fail "H6 down invoked docker: $(cat "$STUB_LOGF")"
expect_allow "H6 hooks/tests/run-all.sh shard run" "hooks/tests/run-all.sh -j 8 --shard 1/8"
expect_allow "H6 run-all.sh with a compose-named filter" "hooks/tests/run-all.sh --only 'docker-compose*'"
expect_allow "H6 bash run-all.sh with a compose-named filter" "bash hooks/tests/run-all.sh --serial --only '*compose*'"
run_hook "hooks/tests/run-all.sh -j 8 --shard 2/8"
[ ! -s "$STUB_LOGF" ] && pass "H6 run-all.sh never reaches docker" || fail "H6 run-all.sh invoked docker"
payload="$(jq -n --arg c "$UP" --arg d "$WT" '{tool_name:"Read",tool_input:{command:$c},cwd:$d}')"
printf '%s' "$payload" | env -i PATH="$SBX" HOME="$FH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" STUB_LOG="$STUB_LOGF" \
  STUB_CFG="$CFGF" "$SBX/bash" "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && pass "H6 a non-Bash tool_name exits 0 even with a bad fixture" || fail "H6 non-Bash tool_name not ignored"

# --- fail closed ---
mkcfg '.'
STUB_RC=1 expect_block "H7 config command fails" unresolved-config "$UP"
echo 'not json at all' > "$CFGF"
expect_block "H7 config output is not JSON" unresolved-config "$UP"
echo '[]' > "$CFGF"
expect_block "H7 config output is not an object" unresolved-config "$UP"
: > "$CFGF"
expect_block "H7 config output is empty" unresolved-config "$UP"
rm -f "$CFGF"
expect_block "H7 config output missing" unresolved-config "$UP"
mkcfg '.'
STUB_FAIL_PROFILE=1 expect_allow "H7 retry without --profile succeeds on a compliant fixture" "$UP"
if [ "$(grep -c ' config ' "$STUB_LOGF")" -eq 2 ] && ! sed -n '2p' "$STUB_LOGF" | grep -qF -- '--profile'; then
  pass "H7 second attempt drops --profile"
else
  fail "H7 retry shape unexpected: $(cat "$STUB_LOGF")"
fi
mkcfg '.services.web.privileged = true'
STUB_FAIL_PROFILE=1 expect_block "H7 retry result is still checked" privileged "$UP"

# --- time budget ---
mkcfg '.'
STUB_SLEEP=40 run_hook "$UP"
if [ "$HOOK_RC" -eq 2 ] && grep -qF '(unresolved-config)' <<<"$HOOK_ERR" && [ "$HOOK_SECS" -le 20 ]; then
  pass "H8 a stalled config resolution is cut off and blocked in ${HOOK_SECS}s (budget 12s, stub sleeps 40s)"
else
  fail "H8 stall handling: rc=$HOOK_RC secs=$HOOK_SECS stderr='$(printf '%s' "$HOOK_ERR" | head -1)'"
fi

# --- docker absent ---
HOOK_PATH="$SBX_NODOCKER" expect_allow "H9 docker absent from PATH: exits 0" "$UP"
mkcfg '.services.web.privileged = true'
HOOK_PATH="$SBX_NODOCKER" expect_allow "H9 docker absent from PATH: exits 0 even for a bad fixture" "$UP"

# --- decision log ---
mkcfg '.services.web.privileged = true'
rm -rf "$WT/.task-log"
run_hook "$UP"
if [ "$HOOK_RC" -eq 2 ] && jq -e -s 'map(select(.hook == "block-compose-escape" and .action == "block")) | length >= 1' "$WT/.task-log/hook-decisions.jsonl" >/dev/null 2>&1; then
  pass "H10 a block is recorded in hook-decisions.jsonl"
else
  fail "H10 no block record in the decision log ($(cat "$WT/.task-log/hook-decisions.jsonl" 2>/dev/null | head -1))"
fi

echo ""
echo "permission-code-exec-narrowing: $cases cases"
if [ "$fails" -eq 0 ]; then
  echo "permission-code-exec-narrowing: all assertions passed."
  exit 0
fi
echo "permission-code-exec-narrowing: $fails assertion(s) failed."
exit 1
