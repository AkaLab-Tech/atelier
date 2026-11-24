#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks container-creating `docker compose`
# commands whose effective configuration (or command-line flags) would reach
# outside the task worktree (#811).
#
# The static permission matrix only allows the compose shapes the docker-env
# skill issues (`-p <name> --file <worktree>/docker-compose.yml ...`). A compose
# file lives in the worktree and is project code, so what it asks the daemon to
# start must be checked at run time, not by a path glob.
#
# Rule: for `up`, `run`, `create`, `start`, `restart` (and `watch`, `scale`),
# resolve the effective config read-only with
#   docker compose [-p N] [-f F]... [--project-directory D] [--env-file E]...
#                  [--profile P]... config --format json
# (same project/file/directory/env arguments as the command) and block when:
#   - a `--file` / `--project-directory` / COMPOSE_FILE path is outside the
#     worktree (or is a symlink, `-`, or not a plain word);
#   - a service asks for privileged mode, host/foreign namespaces, devices,
#     capability or weakened security grants, or volumes from another container;
#   - a bind source (service volume, volume driver option, secret/config file,
#     build context) is outside the worktree, is a symlink, or is a socket;
#   - `run`/`create` flags (`-v`, `--volume`, `--mount`, `--privileged`,
#     `--cap-add`, `--device`, `--security-opt`, `--pid`/`--ipc`/`--uts`/
#     `--network host`...) ask for the same.
# Fail closed when the config cannot be resolved (error, timeout, not JSON).
# Relative paths and the `config` call follow a literal `cd <dir>` only when it
# is at top level and every connector up to the compose command is `&&`; any
# other `cd`/`pushd`/`popd` before a checked compose command (subshell, `||`
# branch, pipe, background job, `-c` body, unresolvable target) blocks it. The
# boundary is the git toplevel of that effective location (--project-directory,
# else first --file, else the directory), accepted only when it is a linked task
# worktree or the toplevel the session started in.
# `$(...)` / backtick bodies inside words are scanned one level deeper, like
# `bash -c` bodies. Service `env_file` paths (read via `config
# --no-env-resolution`, which needs a recent compose; older ones fail closed),
# `build.additional_contexts` sources and `build.ssh` are checked as well, and
# `docker compose cp` is blocked outright.
# Exit 0 for every other subcommand (down/logs/ps/version/config/...), for text
# that only mentions compose (heredoc prose and quoted strings are not
# commands), and when `docker` is not on PATH or jq is missing.
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

# Fast path: no compose word anywhere.
case "$command_str" in *compose*) ;; *) exit 0 ;; esac
command -v docker >/dev/null 2>&1 || exit 0

hook_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$hook_cwd" ] || hook_cwd="$PWD"
[ -d "$hook_cwd" ] || hook_cwd="$PWD"
CWD="$(cd -P "$hook_cwd" 2>/dev/null && pwd -P)" || CWD="$hook_cwd"
START_WT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$START_WT" ] || START_WT="$CWD"
START_WT="$(cd -P "$START_WT" 2>/dev/null && pwd -P)" || START_WT="${START_WT%/}"
WT="$START_WT"   # task boundary; re-derived per compose command in set_boundary
CUR="$CWD"       # directory the next command runs in; follows literal `cd` segments
CD_BAD=0         # set when a `cd` cannot be followed with certainty
CD_OK=0; CD_AND=0 # per segment: at top level / joined to the next command by &&

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

# Derive the worktree boundary for a compose command from where it really runs:
# the --project-directory, else the first --file, else the current directory
# (after any literal `cd`). The boundary is that path's git toplevel, accepted
# only when it is a linked task worktree or the toplevel the session started in.
set_boundary() { # anchor-or-empty
  local a="$1" r dir top
  if [ -n "$a" ]; then
    _unresolvable "$a" && deny "unresolvable-path"
    r="$(_phys "$CUR" "$a")"
    [ "$r" = "SYMLINK" ] && deny "symlinked-path"
    dir="$r"; [ -d "$dir" ] || dir="$(dirname "$r")"
    [ -d "$dir" ] || deny "unresolvable-path"
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || deny "path-outside-worktree"
  else
    top="$(git -C "$CUR" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || top="$CUR"
  fi
  top="$(cd -P "$top" 2>/dev/null && pwd -P)" || deny "unresolvable-path"
  if [ "$top" != "$START_WT" ] && ! _is_linked_wt "$top"; then deny "path-outside-worktree"; fi
  WT="$top"
}

# Require a path to be a plain, in-worktree, non-symlink location. $1 base.
require_in_wt() {
  local base="$1" p="$2" r
  _unresolvable "$p" && deny "unresolvable-path"
  r="$(_phys "$base" "$p")"
  [ "$r" = "SYMLINK" ] && deny "symlinked-path"
  _in_wt "$r" || deny "path-outside-worktree"
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

# One volume/mount/volumes-from value. $1 kind (volume|mount|from), $2 base, $3 spec.
check_mount_spec() {
  local kind="$1" base="$2" spec="$3" src
  [ -n "$spec" ] || return 0
  case "$kind" in
    from) deny "container-volumes" ;;
    mount)
      case ",$spec," in
        *,type=tmpfs,*|*,type=volume,*|*,type=image,*) ;;
        *)
          src=""
          case ",$spec," in
            *,source=*) src="${spec#*source=}"; src="${src%%,*}" ;;
            *,src=*) src="${spec#*src=}"; src="${src%%,*}" ;;
          esac
          [ -n "$src" ] && check_bind_source "$base" "$src" ;;
      esac ;;
    *)
      src="${spec%%:*}"
      case "$src" in
        /*|.*|'~'*|*'$'*|*'`'*) check_bind_source "$base" "$src" ;;
      esac ;;
  esac
  return 0
}

# Flags of `run` / `create` that grant access beyond the worktree. Parsed the
# way the compose CLI (pflag) does: `--flag v`, `--flag=v`, `-x v`, `-xv`,
# `-x=v`, and grouped short flags (`-dv v`) where the first value-taking short
# flag takes the rest of the word (minus one leading `=`) or the next word.
# Short flags taking a value (`docker compose run --help`): -e -l -p -u -v -w.
# `run` stops at `--` and at its first positional (the service); other
# subcommands keep scanning.
check_flags() { # sub base tokens...
  local sub="$1" base="$2" k=3 n=$# tok val rest i c
  local -a a=("$@")
  while [ "$k" -le "$n" ]; do
    tok="${a[$((k - 1))]}"
    k=$((k + 1))
    case "$tok" in
      --) [ "$sub" = "run" ] && return 0; continue ;;
      --privileged|--privileged=*|--cap-add|--cap-add=*|--device|--device=*|--security-opt|--security-opt=*)
        deny "elevated-flag" ;;
      --pid|--ipc|--uts|--userns|--cgroupns|--network|--net)
        [ "$k" -le "$n" ] || deny "unresolvable-flag-value"
        val="${a[$((k - 1))]}"
        k=$((k + 1))
        case "$val" in host|host:*|container:*) deny "host-namespace-flag" ;; esac ;;
      --pid=*|--ipc=*|--uts=*|--userns=*|--cgroupns=*|--network=*|--net=*)
        val="${tok#*=}"
        case "$val" in host|host:*|container:*) deny "host-namespace-flag" ;; esac ;;
      --volume|--mount|--volumes-from)
        [ "$k" -le "$n" ] || deny "unresolvable-flag-value"
        val="${a[$((k - 1))]}"
        k=$((k + 1))
        case "$tok" in
          --volume) check_mount_spec volume "$base" "$val" ;;
          --mount) check_mount_spec mount "$base" "$val" ;;
          *) check_mount_spec from "$base" "$val" ;;
        esac ;;
      --volume=*) check_mount_spec volume "$base" "${tok#*=}" ;;
      --mount=*) check_mount_spec mount "$base" "${tok#*=}" ;;
      --volumes-from=*) check_mount_spec from "$base" "${tok#*=}" ;;
      --cap-drop|--entrypoint|--env|--env-from-file|--label|--name|--pull|--publish|--user|--workdir|--scale)
        k=$((k + 1)) ;;
      --*) ;;
      -?*)
        i=1
        while [ "$i" -lt "${#tok}" ]; do
          c="${tok:$i:1}"
          case "$c" in
            e|l|p|u|v|w)
              rest="${tok:$((i + 1))}"
              rest="${rest#=}"
              if [ -z "$rest" ]; then
                [ "$k" -le "$n" ] || deny "unresolvable-flag-value"
                rest="${a[$((k - 1))]}"
                k=$((k + 1))
              fi
              [ "$c" = "v" ] && check_mount_spec volume "$base" "$rest"
              break ;;
          esac
          i=$((i + 1))
        done ;;
      *) [ "$sub" = "run" ] && return 0 ;;
    esac
  done
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

ENVV=()
check_compose() { # sub, then compose-level facts in globals, then rest tokens
  local sub="$1"; shift
  local f d e p remaining out rc line cfg base0
  local -a cargs=() penv=()
  # `cp` moves files between a container and a host path; blocked outright.
  [ "$sub" = "cp" ] && deny "cp-host-copy"
  case "$sub" in up|run|create|start|restart|watch|scale) ;; *) return 0 ;; esac

  [ "$CD_BAD" -eq 0 ] || deny "unresolvable-cd"
  if [ -n "$C_PDIR" ]; then set_boundary "$C_PDIR"
  elif [ "${#C_FILES[@]}" -gt 0 ]; then set_boundary "${C_FILES[0]}"
  else set_boundary ""; fi

  base0="$CUR"
  if [ -n "$C_PDIR" ]; then require_in_wt "$CUR" "$C_PDIR"; base0="$(_phys "$CUR" "$C_PDIR")"; fi
  for f in ${C_FILES[@]+"${C_FILES[@]}"}; do require_in_wt "$CUR" "$f"; done
  for e in ${C_ENVF[@]+"${C_ENVF[@]}"}; do require_in_wt "$CUR" "$e"; done
  if [ -z "$C_PDIR" ] && [ "${#C_FILES[@]}" -gt 0 ]; then
    base0="$(dirname "$(_phys "$CUR" "${C_FILES[0]}")")"
  fi

  case "$sub" in run|create) check_flags "$sub" "$base0" "$@" ;; esac

  [ -n "$C_PROJ" ] && cargs+=(-p "$C_PROJ")
  for f in ${C_FILES[@]+"${C_FILES[@]}"}; do cargs+=(--file "$f"); done
  [ -n "$C_PDIR" ] && cargs+=(--project-directory "$C_PDIR")
  for e in ${C_ENVF[@]+"${C_ENVF[@]}"}; do cargs+=(--env-file "$e"); done
  for d in ${ENVV[@]+"${ENVV[@]}"}; do penv+=("$d"); done

  remaining=$((BUDGET_SECS - SECONDS))
  [ "$remaining" -ge 2 ] || deny "unresolved-config"
  rc=0
  out="$(cd "$CUR" 2>/dev/null && atelier_timeout "$remaining" env ${penv[@]+"${penv[@]}"} \
    docker compose ${cargs[@]+"${cargs[@]}"} --profile '*' config --no-env-resolution --format json 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    remaining=$((BUDGET_SECS - SECONDS))
    [ "$remaining" -ge 2 ] || deny "unresolved-config"
    rc=0
    out="$(cd "$CUR" 2>/dev/null && atelier_timeout "$remaining" env ${penv[@]+"${penv[@]}"} \
      docker compose ${cargs[@]+"${cargs[@]}"} config --no-env-resolution --format json 2>/dev/null)" || rc=$?
  fi
  [ "$rc" -eq 0 ] || deny "unresolved-config"
  cfg="$out"
  printf '%s' "$cfg" | jq -e 'type == "object"' >/dev/null 2>&1 || deny "unresolved-config"

  out="$(printf '%s' "$cfg" | jq -r --arg wt "$WT" "$CFG_JQ" 2>/dev/null)" || deny "unresolved-config"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      BIND:*) check_bind_source "$base0" "${line#BIND:}" ;;
      *) deny "$line" ;;
    esac
  done <<< "$out"
  return 0
}

# Past the nesting cap a body is not scanned: deny it when it names compose.
_cap_deny() { # text...
  local re='(^|[^[:alnum:]_-])(docker-)?compose($|[^[:alnum:]_-])'
  if [[ "$*" =~ $re ]]; then deny "nesting-too-deep"; fi
  return 0
}

# Scan the bodies of $(...) / `...` substitutions kept inside words, one level
# deeper (so a `cd` inside counts as non-top-level), like bash -c / eval bodies.
scan_substitutions() { # depth tokens...
  local depth="$1"; shift
  local tok rest pre1 pre2 pre kind len body ok="$CD_OK" and="$CD_AND"
  if [ "$depth" -ge 3 ]; then
    case "$*" in *'$('*|*'`'*) _cap_deny "$@" ;; esac
    return 0
  fi
  for tok in "$@"; do
    rest="$tok"
    while :; do
      case "$rest" in *'$('*|*'`'*) ;; *) break ;; esac
      pre1="${rest%%'$('*}"; pre2="${rest%%'`'*}"
      if [ "${#pre1}" -le "${#pre2}" ]; then pre="$pre1"; kind='$'; else pre="$pre2"; kind='`'; fi
      rest="${rest:${#pre}}"
      len="$(_subst_len "$kind" "$rest")"
      if [ "$len" -eq 0 ]; then
        if [ "$kind" = '$' ]; then body="${rest:2}"; else body="${rest:1}"; fi
        rest=""
      elif [ "$kind" = '$' ]; then
        body="${rest:2:$((len - 3))}"; rest="${rest:$len}"
      else
        body="${rest:1:$((len - 2))}"; rest="${rest:$len}"
      fi
      scan_script "$body" $((depth + 1))
    done
  done
  CD_OK="$ok"; CD_AND="$and"
}

scan_segment() { # depth tokens...
  local depth="$1"; shift
  local -a t=("$@")
  local n=$# i=0 tok base
  local j k

  scan_substitutions "$depth" "$@"

  # Command word after harmless prefixes; COMPOSE_* / DOCKER_HOST assignments
  # in the prefix region reach the compose process.
  while [ "$i" -lt "$n" ]; do
    tok="${t[$i]}"
    case "$tok" in
      COMPOSE_*=*|DOCKER_HOST=*|DOCKER_CONTEXT=*) ENVV+=("$tok"); i=$((i + 1)) ;;
      '{'|*=*|env|command|builtin|exec|nohup|time|sudo|nice|stdbuf|ionice|timeout|setsid|caffeinate|xargs|-*) i=$((i + 1)) ;;
      *[!0-9.smhd]*|'') break ;;
      [0-9]*|.[0-9]*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  tok="${t[$i]#\\}"
  base="${tok##*/}"

  case "$base" in
    export|declare|typeset|readonly|local)
      for ((j = i + 1; j < n; j++)); do
        case "${t[$j]}" in COMPOSE_*=*|DOCKER_HOST=*|DOCKER_CONTEXT=*) ENVV+=("${t[$j]}") ;; esac
      done
      return 0 ;;
    bash|sh|zsh|dash|ksh)
      for ((j = i + 1; j < n - 1; j++)); do
        case "${t[$j]}" in
          -c|-[a-z]c|-[a-z][a-z]c)
            if [ "$depth" -lt 3 ]; then scan_script "${t[$((j + 1))]}" $((depth + 1)); else _cap_deny "${t[$((j + 1))]}"; fi
            break ;;
        esac
      done
      return 0 ;;
    eval)
      local joined=""
      for ((j = i + 1; j < n; j++)); do joined+="${t[$j]} "; done
      [ "$depth" -lt 3 ] || { _cap_deny "$joined"; return 0; }
      scan_script "$joined" $((depth + 1))
      return 0 ;;
    cd|pushd)
      local tgt="" r
      # Followed only when it surely changes the compose directory: top level
      # (scan_script sets CD_OK) and joined to what follows by `&&` (CD_AND).
      if [ "$CD_OK" -ne 1 ]; then CD_BAD=1; return 0; fi
      for ((j = i + 1; j < n; j++)); do
        case "${t[$j]}" in -P|-L|-e|-@|--) ;; *) tgt="${t[$j]}"; break ;; esac
      done
      case "$tgt" in
        ''|-|*'$'*|*'`'*|*'*'*|*'?'*|*'{'*|*'['*) CD_BAD=1; return 0 ;;
        '~') tgt="${HOME:-/nonexistent}" ;;
        '~/'*) tgt="${HOME:-/nonexistent}/${tgt#'~/'}" ;;
        '~'*) CD_BAD=1; return 0 ;;
      esac
      r="$(cd -P "$CUR" 2>/dev/null && cd -P -- "$tgt" 2>/dev/null && pwd -P)" || r=""
      if [ -n "$r" ] && [ "$CD_AND" -eq 1 ]; then CUR="$r"; else CD_BAD=1; fi
      return 0 ;;
    popd) CD_BAD=1; return 0 ;;
    docker|docker-compose) ;;
    *) return 0 ;;
  esac

  j=$((i + 1))
  if [ "$base" = "docker" ]; then
    while [ "$j" -lt "$n" ]; do
      case "${t[$j]}" in
        compose) break ;;
        -H|--host|--context|-c|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey) j=$((j + 2)) ;;
        -*) j=$((j + 1)) ;;
        *) return 0 ;;
      esac
    done
    [ "$j" -lt "$n" ] || return 0
    j=$((j + 1))
  fi

  C_PROJ=""; C_PDIR=""; C_FILES=(); C_ENVF=()
  local sub="" cf
  if [ -n "${COMPOSE_FILE:-}" ]; then
    IFS=: read -r -a cf <<< "$COMPOSE_FILE"; C_FILES+=("${cf[@]}")
  fi
  for tok in ${ENVV[@]+"${ENVV[@]}"}; do
    case "$tok" in
      COMPOSE_FILE=*) IFS=: read -r -a cf <<< "${tok#COMPOSE_FILE=}"; C_FILES+=("${cf[@]}") ;;
      COMPOSE_PROJECT_NAME=*) C_PROJ="${tok#*=}" ;;
    esac
  done
  while [ "$j" -lt "$n" ]; do
    tok="${t[$j]}"
    case "$tok" in
      -p|--project-name) C_PROJ="${t[$((j + 1))]:-}"; j=$((j + 2)) ;;
      --project-name=*) C_PROJ="${tok#*=}"; j=$((j + 1)) ;;
      -f|--file) C_FILES+=("${t[$((j + 1))]:--}"); j=$((j + 2)) ;;
      --file=*) C_FILES+=("${tok#*=}"); j=$((j + 1)) ;;
      -f?*) C_FILES+=("${tok#-f}"); j=$((j + 1)) ;;
      --project-directory) C_PDIR="${t[$((j + 1))]:--}"; j=$((j + 2)) ;;
      --project-directory=*) C_PDIR="${tok#*=}"; j=$((j + 1)) ;;
      --env-file) C_ENVF+=("${t[$((j + 1))]:--}"); j=$((j + 2)) ;;
      --env-file=*) C_ENVF+=("${tok#*=}"); j=$((j + 1)) ;;
      --profile|--parallel|--ansi|--progress) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) sub="$tok"; break ;;
    esac
  done
  [ -n "$sub" ] || return 0
  k=$((j + 1))
  check_compose "$sub" ${t[@]+"${t[@]:$k}"}
}

scan_script() { # script depth
  local script="$1" depth="$2" stripped seg conn k nseg pd=0 prev
  local -a segs
  case "$script" in *compose*) ;; *) return 0 ;; esac
  stripped="$(strip_heredocs "$script")" || stripped="$script"
  lex "$stripped"
  conn="$LEX_CONN"
  IFS="$RS" read -r -d '' -a segs <<< "$LEX_OUT" || true
  nseg=${#segs[@]}
  for ((k = 0; k < nseg; k++)); do
    seg="${segs[k]}"
    if [ -n "$seg" ]; then
      prev=""; [ "$k" -gt 0 ] && prev="${conn:$((k - 1)):1}"
      CD_OK=0; CD_AND=0
      if [ "$depth" -eq 0 ] && [ "$pd" -eq 0 ] && [ "$prev" != "|" ]; then CD_OK=1; fi
      if [ "${conn:$k:1}" = "&" ] && [ "$((k + 1))" -lt "$nseg" ] \
         && [ -z "${segs[k + 1]}" ] && [ "${conn:$((k + 1)):1}" = "&" ]; then CD_AND=1; fi
      split_tokens "$seg"
      scan_segment "$depth" ${TOKS[@]+"${TOKS[@]}"}
    fi
    case "${conn:$k:1}" in '(') pd=$((pd + 1)) ;; ')') [ "$pd" -gt 0 ] && pd=$((pd - 1)) ;; esac
  done
}

SECONDS=0
scan_script "$command_str" 0
exit 0
