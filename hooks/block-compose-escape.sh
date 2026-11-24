#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Allows a container-creating or
# container-starting `docker compose` command only in the exact shape the
# docker-env skill issues, and checks that shape's effective configuration
# (#811).
#
# Closed allowlist. When the lexed command (hooks/lib/shell-lex.sh; quotes
# removed, heredoc prose dropped) names `compose`/`docker-compose` together with
# `up`, `run`, `create`, `start`, `restart`, `watch` (also `alpha watch`),
# `scale`, `build`, `exec` or `cp`, it must be exactly one of:
#   docker compose -p <name> --file <worktree>/docker-compose.yml up -d --wait
#   cd <worktree> && docker compose -p <name> --file <worktree>/docker-compose.yml up -d --wait
# with nothing else on the line. <worktree> is the task worktree: a linked git
# worktree (which covers the `<repo>-worktrees/**` layout) or the toplevel the
# session started in; the compose file sits directly in it and is not a symlink;
# <name> is a plain project-name word. Anything else that names such a
# subcommand (a wrapper in front, extra or reordered flags, another connector, a
# subshell or substitution, a `-c` or eval body, unparseable text) is blocked.
#
# The allowed shape's effective config is then resolved read-only with
#   docker compose -p <name> --file <file> --profile '*' config --no-env-resolution --format json
# (time-bounded, fail closed) and blocked when a service asks for privileged
# mode, host/foreign namespaces, devices, capability or weakened security
# grants, or volumes from another container, or when a bind source (service
# volume, volume driver option, secret/config file, build context, env_file,
# additional context) is outside the worktree, is a symlink, or is a socket.
#
# Any non-inert segment that holds an expansion ($X, ${X}, $(...), backticks,
# arithmetic) together with a docker/compose word, a subcommand word, or an
# expansion in command position is treated the same way, since the program or
# subcommand cannot be read from the text. A command that mentions neither
# docker nor compose is not examined.
#
# Exit 0 for read-only subcommands (down/logs/ps/version/config/...), for text
# that only mentions compose (echo, quoted prose, heredoc, commit messages,
# searches), and when `docker` is not on PATH or jq is missing. Text that only
# mentions compose is still treated as naming it when it is piped into another
# interpreter.
#
# Defense in depth, not a sandbox: a script written first and run later, indirect
# runs (package scripts, Makefiles), obfuscated invocations and a daemon reached
# through other means are not covered. Server-side controls own the final
# boundary (PLAN.md §3).
#
# Contract (PreToolUse): stdin JSON { tool_name, tool_input: { command }, cwd };
# exit 0 allow, exit 2 block (stderr goes to Claude).

# shellcheck disable=SC2016,SC2088,SC1003
set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"
# shellcheck source=lib/shell-lex.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/shell-lex.sh"
# shellcheck source=lib/portable-timeout.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/portable-timeout.sh"

HOOK_NAME="block-compose-escape"
BUDGET_SECS=12      # total wall budget for config resolution (hook timeout is 30)

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$command_str" ] || exit 0

# Fast path: no compose or docker word anywhere.
case "$command_str" in *compose*|*docker*) ;; *) exit 0 ;; esac
command -v docker >/dev/null 2>&1 || exit 0

hook_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$hook_cwd" ] || hook_cwd="$PWD"
[ -d "$hook_cwd" ] || hook_cwd="$PWD"
CWD="$(cd -P "$hook_cwd" 2>/dev/null && pwd -P)" || CWD="$hook_cwd"
START_WT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$START_WT" ] || START_WT="$CWD"
START_WT="$(cd -P "$START_WT" 2>/dev/null && pwd -P)" || START_WT="${START_WT%/}"
WT="$START_WT"   # task boundary; set from the compose file in set_boundary

deny() { # tag
  log_decision "$HOOK_NAME" "Bash" "$1" "block" "compose config reaches outside the task worktree: $1"
  cat >&2 <<MSG
🛑 atelier:${HOOK_NAME} — blocked a docker compose command that would start containers reaching outside this task's worktree (${1}).
   Keep the compose file self-contained: bind mounts only under the worktree, no privileged mode,
   host namespaces, devices, capability grants or runtime-socket mounts. If the configuration
   cannot be resolved, fix the compose file or the --file / --project-directory arguments and retry.
MSG
  exit 2
}

# Lexically normalise an absolute path (no symlink resolution).
_norm() {
  local p="$1" part out="" IFS=/
  local -a parts=() stack=()
  read -r -a parts <<< "$p"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) [ "${#stack[@]}" -gt 0 ] && unset "stack[$((${#stack[@]} - 1))]" ;;
      *) stack+=("$part") ;;
    esac
  done
  for part in ${stack[@]+"${stack[@]}"}; do out="$out/$part"; done
  printf '%s' "${out:-/}"
}

# Absolute, normalised path of $2 resolved against base $1; symlinked parents
# are resolved, a symlinked final component is reported as "SYMLINK".
_phys() {
  local base="$1" p="$2" abs dir name
  case "$p" in
    '~') p="${HOME:-/nonexistent}" ;;
    '~/'*) p="${HOME:-/nonexistent}/${p#'~/'}" ;;
  esac
  case "$p" in /*) abs="$p" ;; *) abs="$base/$p" ;; esac
  abs="$(_norm "$abs")"
  if [ -L "$abs" ]; then printf 'SYMLINK'; return; fi
  if [ -d "$abs" ]; then
    (cd -P "$abs" 2>/dev/null && pwd -P) || printf '%s' "$abs"
    return
  fi
  dir="$(dirname "$abs")"; name="$(basename "$abs")"
  if [ -d "$dir" ]; then
    dir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || dir="$(dirname "$abs")"
    printf '%s' "${dir%/}/$name"
  else
    printf '%s' "$abs"
  fi
}

_in_wt() { case "$1" in "$WT"|"$WT"/*) return 0 ;; esac; return 1; }

# A path argument that is checked, not resolved from shell state.
_unresolvable() {
  case "$1" in ''|-|*'$'*|*'`'*|*'*'*|*'?'*|*'{'*) return 0 ;; esac
  return 1
}

# A linked git worktree has a `.git` file pointing into <common>/worktrees/.
_is_linked_wt() {
  [ -f "$1/.git" ] || return 1
  case "$(head -c 4096 "$1/.git" 2>/dev/null)" in *"/worktrees/"*) return 0 ;; esac
  return 1
}

block_shape() {
  if [ "${explicit:-1}" -eq 0 ]; then
    log_decision "$HOOK_NAME" "Bash" "not-allowlisted-shape" "block" "docker command holds an expansion where the program or subcommand cannot be read from the text"
    cat >&2 <<MSG
🛑 atelier:${HOOK_NAME} — blocked a docker command whose program or subcommand is hidden behind a shell expansion (\$VAR, \$(...), backticks), so it cannot be checked.
   Write the program and subcommand out literally. Expansions are fine in the arguments of down/logs/ps/version/config.
MSG
    exit 2
  fi
  log_decision "$HOOK_NAME" "Bash" "not-allowlisted-shape" "block" "container-starting compose command is not the docker-env skill's exact shape"
  cat >&2 <<MSG
🛑 atelier:${HOOK_NAME} — blocked a docker compose command that would create or start containers: it is not the exact form the docker-env skill issues.
   Only this shape is allowed, with nothing else on the line (an optional leading "cd <worktree> &&" is accepted):
     docker compose -p <name> --file <worktree>/docker-compose.yml up -d --wait
MSG
  exit 2
}

# The task boundary is the git toplevel of the compose file's directory,
# accepted only when it is a linked task worktree or the toplevel the session
# started in.
set_boundary() { # compose-file
  local r dir top
  _unresolvable "$1" && deny "unresolvable-path"
  r="$(_phys / "$1")"
  [ "$r" = "SYMLINK" ] && deny "symlinked-path"
  dir="$(dirname "$r")"
  [ -d "$dir" ] || deny "unresolvable-path"
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || deny "path-outside-worktree"
  top="$(cd -P "$top" 2>/dev/null && pwd -P)" || deny "unresolvable-path"
  if [ "$top" != "$START_WT" ] && ! _is_linked_wt "$top"; then deny "path-outside-worktree"; fi
  WT="$top"
  [ "$dir" = "$WT" ] || block_shape
}

# Bind source named on the command line or in the resolved config.
check_bind_source() { # base src
  local base="$1" src="$2" r
  _unresolvable "$src" && deny "unresolvable-path"
  r="$(_phys "$base" "$src")"
  [ "$r" = "SYMLINK" ] && deny "symlinked-bind-source"
  _in_wt "$r" || deny "bind-outside-worktree"
  [ -S "$r" ] && deny "runtime-socket"
  case "$r" in *docker.sock|*containerd.sock|*podman.sock|*crio.sock) deny "runtime-socket" ;; esac
  return 0
}

CFG_JQ='
def inside($p): ($p | type == "string") and ($p == $wt or ($p | startswith($wt + "/")));
def hostns: . != null and (. == "host" or (type == "string" and startswith("container:")));
def bindsrc($p):
  if ($p | type) != "string" or $p == "" then empty
  elif inside($p) then "BIND:" + $p
  else "bind-outside-worktree" end;
[
  ((.services // {}) | to_entries[] | .value as $s |
    (if $s.privileged == true then "privileged" else empty end),
    ((($s.post_start // []) + ($s.pre_stop // []))[]
      | if type == "object" and .privileged == true then "privileged" else empty end),
    (if $s.provider != null then "provider-service" else empty end),
    (if $s.use_api_socket == true then "runtime-socket" else empty end),
    (if ($s.pid | hostns) or ($s.ipc | hostns) or ($s.uts | hostns) or ($s.network_mode | hostns)
        or $s.userns_mode == "host" or $s.cgroup == "host" then "host-namespace" else empty end),
    (if (($s.cap_add // []) | length) > 0 or (($s.devices // []) | length) > 0
        or (($s.device_cgroup_rules // []) | length) > 0 then "device-or-capability" else empty end),
    (if (($s.security_opt // []) | map(tostring | test("unconfined|disable")) | any) then "weakened-security" else empty end),
    (if (($s.volumes_from // []) | map(tostring | startswith("container:")) | any) then "container-volumes" else empty end),
    (($s.volumes // [])[] | select(type == "object") |
      if .type == "npipe" then "runtime-socket"
      elif .type == "bind" then bindsrc(.source) else empty end),
    (($s.build // null) | select(type == "object") | .context // empty
      | select(type == "string" and startswith("/")) | bindsrc(.)),
    (($s.build // null) | select(type == "string" and startswith("/")) | bindsrc(.)),
    (($s.build // null) | select(type == "object") | .additional_contexts // empty
      | (if type == "object" then to_entries | map(.value) else . end)[]
      | tostring | select(test("^[a-z][a-z0-9+.-]*:") | not) | bindsrc(.)),
    (($s.build // null) | select(type == "object") | .ssh // empty
      | select(length > 0) | "build-ssh"),
    (($s.build // null) | select(type == "object")
      | if .privileged == true or ((.entitlements // []) | length) > 0 then "elevated-build"
        elif (.network | hostns) then "host-namespace" else empty end),
    (($s.env_file // [])
      | (if type == "array" then . else [.] end)[]
      | (if type == "object" then .path else . end) | bindsrc(.))
  ),
  (((.volumes // {}) | to_entries[] | .value | select(type == "object") | .driver_opts.device? // empty
      | select(type == "string" and startswith("/")) | bindsrc(.))),
  ((((.secrets // {}), (.configs // {})) | to_entries[] | .value | select(type == "object") | .file? // empty)
      | bindsrc(.))
] | unique | .[]
'

# Effective config of the allowed shape; blocks on any escape, fails closed.
check_config() { # project-name compose-file
  local remaining out rc=0 cfg line
  remaining=$((BUDGET_SECS - SECONDS))
  [ "$remaining" -ge 2 ] || deny "unresolved-config"
  out="$(cd "$WT" 2>/dev/null && atelier_timeout "$remaining" \
    docker compose -p "$1" --file "$2" --profile '*' config --no-env-resolution --format json 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    remaining=$((BUDGET_SECS - SECONDS))
    [ "$remaining" -ge 2 ] || deny "unresolved-config"
    rc=0
    out="$(cd "$WT" 2>/dev/null && atelier_timeout "$remaining" \
      docker compose -p "$1" --file "$2" config --no-env-resolution --format json 2>/dev/null)" || rc=$?
  fi
  [ "$rc" -eq 0 ] || deny "unresolved-config"
  cfg="$out"
  printf '%s' "$cfg" | jq -e 'type == "object"' >/dev/null 2>&1 || deny "unresolved-config"
  out="$(printf '%s' "$cfg" | jq -r --arg wt "$WT" "$CFG_JQ" 2>/dev/null)" || deny "unresolved-config"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      BIND:*) check_bind_source "$WT" "${line#BIND:}" ;;
      *) deny "$line" ;;
    esac
  done <<< "$out"
  return 0
}

# --- naming detection ----------------------------------------------------------
RE_COMPOSE='(^|[^[:alnum:]_.-])(docker-)?compose($|[^[:alnum:]_./-])'
RE_SUB='(^|[^[:alnum:]_./-])(up|run|create|start|restart|watch|scale|build|exec|cp)($|[^[:alnum:]_./-])'
RE_DOCK='(^|[^[:alnum:]_.-])(docker(-compose)?|compose)($|[^[:alnum:]_.-])'
RE_ASSIGN='^[A-Za-z_][A-Za-z0-9_]*='
RE_EXPAND='^(\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$\(.*\)|`.*`|\$['"'"'"].*)$'
RE_NAME='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
RE_PATH='^/[A-Za-z0-9_./@+-]*$'

# Text names a container-creating compose call (compose word + subcommand word).
names_container() {
  [[ "$1" =~ $RE_COMPOSE ]] && [[ "$1" =~ $RE_SUB ]]
}

# The word in command position (after assignments and common wrappers) holds
# an expansion, so the program that runs is not known from the text.
cmdpos_expands() {
  local t base wrapped=0
  for t in "$@"; do
    [[ "$t" =~ $RE_ASSIGN ]] && continue
    if [ "$wrapped" -eq 1 ]; then
      case "$t" in -*|[0-9]*) continue ;; esac
    fi
    case "$t" in *'$'*|*'`'*) return 0 ;; esac
    base="${t#\\}"; base="${base##*/}"
    case "$base" in
      env|command|builtin|exec|sudo|time|nohup|nice|timeout|xargs) wrapped=1; continue ;;
    esac
    return 1
  done
  return 1
}

# Backslash-escaped backticks and dollar signs are literal text outside single
# quotes (inside real backticks an escaped backtick is a nested substitution, so
# it is kept). Replace them with inert placeholder bytes before lexing so the
# lexed token text never shows a literal as a substitution.
neutralize_escaped() {
  local LC_ALL=C s="$1" n=${#1} i=0 c nx out="" sq=0 dq=0 bt=0
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    if [ "$sq" -eq 1 ]; then
      out+="$c"; [ "$c" = "'" ] && sq=0
    else
      case "$c" in
        '\')
          nx="${s:i+1:1}"
          if [ "$bt" -eq 0 ] && [ "$nx" = '`' ]; then out+=$'\x01'
          elif [ "$bt" -eq 0 ] && [ "$nx" = '$' ]; then out+=$'\x02'
          else out+="$c$nx"; fi
          i=$((i + 2)); continue ;;
        "'") [ "$dq" -eq 0 ] && sq=1; out+="$c" ;;
        '"') dq=$((1 - dq)); out+="$c" ;;
        '`') bt=$((1 - bt)); out+="$c" ;;
        *) out+="$c" ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# A literal `docker compose [flags] <read-only subcommand> ...` whose words up to
# and including the subcommand hold no expansion, with no container-starting
# word anywhere and no command substitution after the subcommand: expansions in
# its arguments cannot start containers.
readonly_compose() {
  local t
  [ "$1" = docker ] && [ "${2:-}" = compose ] || return 1
  shift 2
  while [ "$#" -gt 0 ]; do
    t="$1"
    case "$t" in *'$'*|*'`'*) return 1 ;; esac
    case "$t" in
      -p|--project-name|-f|--file|--project-directory|--profile|--env-file|--ansi|--parallel|-H|--host|--context|-c)
        shift; [ "$#" -gt 0 ] || return 1
        case "$1" in *'$'*|*'`'*) return 1 ;; esac
        shift ;;
      -*) shift ;;
      down|logs|ps|version|config) shift; break ;;
      *) return 1 ;;
    esac
  done
  for t in "$@"; do
    case "$t" in *'$('*|*'`'*) return 1 ;; esac
  done
  return 0
}

# Commands whose arguments are data, not code: text that mentions compose is
# prose there. $1 is the command word, the rest its arguments.
is_inert() {
  local first="${1#\\}"; first="${first##*/}"
  shift
  local tok
  case "$first" in
    echo|printf|cat|head|tail|wc|ls) return 0 ;;
    rg|grep)
      for tok in "$@"; do
        case "$tok" in --pre|--pre=*|--hostname-bin|--hostname-bin=*) return 1 ;; esac
      done
      return 0 ;;
    git|gh)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -C|-R|--repo|--git-dir|--work-tree) shift; [ "$#" -gt 0 ] && shift ;;
          -c*|--config-env*) return 1 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      case "$first:${1:-}" in
        git:commit|git:log|git:show|git:diff|git:status|git:add|git:tag|git:branch|git:stash|git:grep|git:blame) return 0 ;;
        gh:pr|gh:issue|gh:api|gh:release|gh:gist) return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

# Pure filters that cannot run text as code.
is_filter() {
  local first="${1#\\}"; first="${first##*/}"
  case "$first" in head|tail|wc|cat|grep|rg|jq|sort|uniq|cut|tr|ls|less) return 0 ;; esac
  return 1
}

# The whole command is exactly one allowed shape: [cd <wt> &&] docker compose
# -p <name> --file <wt>/docker-compose.yml up -d --wait
check_shape() {
  local k idx=() T file name r
  for ((k = 0; k < nseg; k++)); do [ -n "${segs[k]//$'\n'/}" ] && idx+=("$k"); done
  case "${#idx[@]}" in
    1) [ "$conn" = "" ] || block_shape ;;
    2) [ "$conn" = "&&" ] && [ "${idx[0]}" -eq 0 ] && [ "${idx[1]}" -eq 2 ] || block_shape ;;
    *) block_shape ;;
  esac
  split_tokens "${segs[${idx[${#idx[@]} - 1]}]}"
  T=("${TOKS[@]}")
  [ "${#T[@]}" -eq 9 ] || block_shape
  [ "${T[0]}" = docker ] && [ "${T[1]}" = compose ] && [ "${T[2]}" = -p ] && [ "${T[4]}" = --file ] \
    && [ "${T[6]}" = up ] && [ "${T[7]}" = -d ] && [ "${T[8]}" = --wait ] || block_shape
  name="${T[3]}"; file="${T[5]}"
  [[ "$name" =~ $RE_NAME ]] || block_shape
  [[ "$file" =~ $RE_PATH ]] && [ "${file##*/}" = docker-compose.yml ] || block_shape
  set_boundary "$file"
  if [ "${#idx[@]}" -eq 2 ]; then
    split_tokens "${segs[${idx[0]}]}"
    [ "${#TOKS[@]}" -eq 2 ] && [ "${TOKS[0]}" = cd ] && [[ "${TOKS[1]}" =~ $RE_PATH ]] || block_shape
    r="$(cd -P -- "${TOKS[1]}" 2>/dev/null && pwd -P)" || block_shape
    [ "$r" = "$WT" ] || block_shape
  fi
  check_config "$name" "$file"
}

SECONDS=0
command_str="${command_str#"${command_str%%[![:space:]]*}"}"
command_str="${command_str%"${command_str##*[![:space:]]}"}"
stripped="$(strip_heredocs "$command_str")" || stripped="$command_str"
stripped="${stripped%"${stripped##*[![:space:]]}"}"
case "$stripped" in *'\`'*|*'\$'*) stripped="$(neutralize_escaped "$stripped")" ;; esac
lex "$stripped"
conn="$LEX_CONN"
IFS="$RS" read -r -d '' -a segs <<< "$LEX_OUT" || true
nseg=${#segs[@]}

named=0; text_named=0; unsafe_sink=0; explicit=0
case "$stripped" in *'<('*|*'>('*) unsafe_sink=1 ;; esac
for ((k = 0; k < nseg; k++)); do
  [ -n "${segs[k]}" ] || continue
  split_tokens "${segs[k]}"
  [ "${#TOKS[@]}" -gt 0 ] || continue
  txt=" ${TOKS[*]} "
  if is_inert "${TOKS[@]}"; then
    # Prose in an inert command; only an embedded substitution can run.
    for tok in "${TOKS[@]}"; do
      case "$tok" in
        *'$('*|*'`'*)
          names_container " $tok " && { named=1; explicit=1; }
          for inner in "${tok#*'$('}" "${tok#*'`'}"; do
            [ "$inner" = "$tok" ] && continue
            case "$inner" in *'$'*|*'`'*) { [[ " $inner " =~ $RE_DOCK ]] || [[ " $inner " =~ $RE_SUB ]]; } && named=1 ;; esac
          done ;;
      esac
    done
    names_container "$txt" && text_named=1
    continue
  fi
  if names_container "$txt"; then named=1; explicit=1; fi
  if ! names_container "$txt" && readonly_compose "${TOKS[@]}"; then
    : # read-only subcommand: expansions in its arguments cannot start containers
  else
    if [[ "$txt" =~ $RE_COMPOSE ]]; then
      # A bare expansion could stand where the subcommand is.
      for tok in "${TOKS[@]}"; do [[ "$tok" =~ $RE_EXPAND ]] && named=1; done
    fi
    # An expansion could stand for the program or the subcommand: only the exact
    # allowed shape (no expansion in it) passes.
    case "$txt" in
      *'$'*|*'`'*)
        if [[ "$txt" =~ $RE_DOCK ]] || [[ "$txt" =~ $RE_SUB ]] || cmdpos_expands "${TOKS[@]}"; then named=1; fi ;;
    esac
  fi
  # An alias can bind a container command to a short name.
  if [ "${TOKS[0]}" = alias ] && [[ "$txt" =~ $RE_DOCK ]]; then named=1; fi
  prev=""; [ "$k" -gt 0 ] && prev="${conn:$((k - 1)):1}"
  if [ "$prev" = "|" ] && ! is_filter "${TOKS[0]}"; then unsafe_sink=1; fi
done
if [ "$text_named" -eq 1 ] && [ "$unsafe_sink" -eq 1 ]; then named=1; fi
[ "$named" -eq 1 ] || exit 0

check_shape
exit 0
