#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks shell commands that read, copy,
# move, delete or otherwise touch the CONTENTS of a protected `.env*` file.
#
# Before this hook nothing blocked these reads: block-env-commit.sh only
# covers `git add`/`git commit`, and semantic-risk-judge.sh only greps `.env`
# out of a commit message. `.env*` contents are operator-only secrets.
#
# Detection (deny-by-default on any command token naming a protected file):
#   - The command is split into segments on `;`, `&&`, `||`, `|`, newlines,
#     `$(` and backticks. Each segment is inspected on its own.
#   - Protected token: a name starting with `.env` (`.env`, `.env.local`,
#     `.env*`, `.env.*`, `.envrc`) whose preceding char is start/space/`/`/
#     quote/`<`/`>`/`=`/`(`/`:`. `process.env`, `import.meta.env` do not match.
#   - Exempt templates: names whose final suffix is `.example`, `.sample`, `.template`
#     or `.dist` (shared list: hooks/lib/env-names.sh), e.g. `.env.catalog.example`.
#   - A segment naming a protected file is ALLOWED only when its command is
#     name-only: `ls`, `test`, `[`, `[[`, `find` (no -exec/-execdir/-ok/
#     -delete/-fprint*), `git status`, `git check-ignore`.
#   - A name-only step is allowed only as a plain top-level segment whose output
#     is not consumed. It is BLOCKED when followed by `|`/`|&` (`ls .env | xargs
#     cat`) or when nested in `$(`...`)`, backticks or `<(`/`>(` (`cat $(ls .env)`).
#   - `git add` / `git commit` segments are allowed: block-env-commit.sh owns
#     them, and a `.env` mentioned inside a commit message is not a read.
#     Exception: a commit message/template FILE option (-F/--file/-t/--template)
#     naming a protected file is blocked.
#   - Everything else is BLOCKED: cat/head/tail/grep/awk/sed/source/`.`/cp/mv/
#     rm, `< .env` redirection, interpreter one-liners.
#     Blocking rm/mv is deliberate: deleting these files is an operator action.
#   - Name-only listing piped into a pure stdin text filter stays allowed: every
#     later stage is `head`/`tail`/`sort`/`uniq`/`wc`/`cut`/`tr` or `grep`/`egrep`
#     with no file operand and no `-r`/`-R`/`-f` (`find . -name '.env*' | sort`).
#     `xargs`, `while read`, shells, `tee`, interpreters etc. stay blocked.
#   - Text that only MENTIONS a name is not a read: a heredoc body written by
#     `cat > file <<'EOF'`/`tee` (a heredoc fed to a shell/interpreter, or one
#     expanding `$(`, is still inspected and the redirect target is always
#     checked), a quoted `echo`/`printf` argument (not after `<`/`>`), and the
#     script of a pure `sed s<d>..<d>..<d>` (flags g/I/i/p/digits; `r/R/w/W/e`
#     scripts and `-f` stay blocked).
#   - Exception: a heredoc script written by `cat > F`/`cat >> F`/`tee [-a] F`
#     and RUN in the same command (`bash F`, `./F`, `source F`, `python3 F`,
#     `cat F | sh`, `sh < F`, `cp F y && bash y`, ...) is not text: its body
#     must not name any non-template env file (a name-only `test -f <env file>`
#     counts) and keeps the regular per-segment inspection. Detection fails
#     closed: a later segment naming F is a run unless its command word is
#     `git`/`ls`/`test`/`[`/`stat`/`wc`/`chmod`/`rm`/`diff`/`cmp`/`file`/
#     `shellcheck` and it is neither piped onward nor nested; a target that is
#     not a plain word (`$`, glob, backtick) counts as run by any later
#     shell/interpreter; a target under `.git/hooks/` (or `hooks/` with a
#     `git commit`/`git push` in the command) is always run by git.
#   - Command prefixes are skipped before the command word is read: `\cmd`,
#     `VAR=val`, `sudo`/`command`/`builtin`/`exec`/`nohup`/`time`, `env [-i|-u X]
#     [VAR=val]`, `timeout [opts] <dur>`, `nice [-n N]`, `xargs [opts]`, `stdbuf`, `ionice`,
#     `chrt`, `taskset`, `setsid`, `unbuffer`, `caffeinate`, `doas`, `flock`.
#     The strings of `bash|sh|zsh|dash|ksh -c` and `flock ... -c` get one inner
#     recursive-grep pass (split on `;`, `&&`, `||`, `|`).
#   - `--env-file` is exempt only for node/tsx/ts-node/deno/bun, and only when
#     the segment has no `-e`/`-p`/`-pe`/`--eval`/`--print` and no `env`/
#     `printenv` word (those can print the loaded values), and no preload/loader
#     (`-r`/`--require`/`--import`/`--loader`/`--experimental-loader`/`--preload`/
#     `--experimental-preload`, or a `NODE_OPTIONS=` assignment; for deno only
#     `--import`/`--preload`-style flags and `NODE_OPTIONS`, since `-r` is
#     `--reload` there). docker, docker-compose,
#     pnpm and npx are not exempt.
#   - `cp <template> <env file>` is allowed only when the destination does not
#     exist (resolved against the hook input `cwd`; a relative dest after a
#     `cd`/`pushd`/`env -C` in the command is blocked); any `-t`/`--t*` (target
#     directory, incl. `-at`, `-t/tmp/x`, `--target=`) is blocked.
#   - Recursive grep (grep/egrep/fgrep/ggrep/zgrep/zegrep/zfgrep, `-r`/`-R`/
#     `--recursive`/`-d recurse`/`--directories=recurse`; rgrep always) is
#     blocked unless `--exclude=.env*` / `--exclude='*.env*'` (nothing narrower
#     counts, and any `--include` pattern that matches a protected name such as
#     `.env`, `.env.local` or `.envrc` cancels it, in either order) or every explicit path operand exists under `cwd` and holds no
#     `.env*` file other than templates. No explicit path (default `.`), a
#     `cd`/`pushd`/`env -C`, a quoted/glob operand, or an unknown operand
#     stays blocked.
#   - Subshell `)` closes are matched against open `$(`/`<(`/`>(` before any
#     brace/paren block, so `{ ls .env; x=$(a | b); } | xargs cat` is blocked.
#
# Known limits: defense in depth, not a sandbox. Obfuscated access
# (`cat $(echo .e)nv`) is not caught. A script run as `node --env-file=.env
# script.js` can still print `process.env`. An app loading `.env` at runtime
# (dotenv) is not a shell token and keeps working. Other tools that merely
# mention `.env` in prose (e.g. `gh pr create --body "... .env ..."`) are
# false positives; use `--body-file`. `.envrc` (direnv) is blocked too.
# Uncovered wrappers: `find -exec`, `parallel`, `watch`, `script -c`, and a
# `-c` string nested inside another `-c` string (one level is inspected).
# A script written with the Write tool and run in a separate Bash call, an
# indirect run (package.json scripts, Makefiles, .envrc, a custom
# core.hooksPath) and an obfuscated heredoc target are not caught.
#
# Contract (PreToolUse): stdin JSON; exit 0 allow; exit 2 block (stderr to
# Claude). Unparseable or missing input exits 0 (fail open).

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"
# shellcheck source=lib/env-names.sh
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/env-names.sh"

HOOK_NAME="block-env-read"

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

# Cheap pre-filter: nothing to do unless `.env` or `grep` appears at all.
case "$command_str" in
  *.[eE][nN][vV]*|*grep*) ;;
  *) exit 0 ;;
esac

# Hook-reported working directory: base for existence checks (cp destination,
# recursive-grep path operands). Falls back to this process's cwd.
hook_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$hook_cwd" ] || hook_cwd="$PWD"

# A `cd`/`pushd` anywhere in the command changes what a relative path means for
# later segments, so the recursive-grep path check cannot be trusted then.
cd_in_command=0
has_subst=0
seg_piped=0
case "$command_str" in *'$('*|*'<('*|*'>('*|*'`'*) has_subst=1 ;; esac
printf '%s' "$command_str" | grep -Eq '(^|[^[:alnum:]_./-])(cd|pushd)([[:space:]]|$)' && cd_in_command=1
# `env -C <dir>` / `--chdir` runs the command elsewhere, same effect as a cd.
printf '%s' "$command_str" | grep -Eq '(^|[^[:alnum:]_./-])env[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*C|--chdir)' && cd_in_command=1

# Strips the prefixes that run another command without changing what it reads:
# a leading `(`/`{`/`!`/`\`, `VAR=val`, `sudo`/`command`/`builtin`/`exec`/
# `nohup`/`time`, `env [opts] [VAR=val]`, `timeout [opts] <dur>`, `nice [-n N]`,
# `xargs [opts]`. Sets PREFIX_REST to the remaining words (command first).
skip_prefix() {
  local seg="$1" w
  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f
  while [ $# -gt 0 ]; do
    w="${1#[(\{!]}"
    w="${w#\\}"
    if [ -z "$w" ]; then shift; continue; fi
    case "$w" in
      [A-Za-z_]*=*) shift ;;
      sudo|command|builtin|exec|nohup|time|setsid|unbuffer) shift ;;
      doas)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|-C) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      caffeinate)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -t|-w) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      stdbuf)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -i|-o|-e) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      ionice)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -c|-n|-p|-P|-u) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      chrt|taskset)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -*) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && shift ;;
      flock)
        # `flock <file> -c <cmd>` runs the string in a shell: left as the
        # command word so shell_c_string can inspect it.
        shift
        local fl_args=("$@") fl_i=0 fl_ops=0
        while [ "$fl_i" -lt "${#fl_args[@]}" ]; do
          case "${fl_args[fl_i]}" in
            -c|--command|--command=*) set -- "$w" "$@"; break 2 ;;
            -w|-E|--timeout|--conflict-exit-code) fl_i=$((fl_i + 1)) ;;
            -*) ;;
            *) fl_ops=$((fl_ops + 1)); [ "$fl_ops" -ge 2 ] && break ;;
          esac
          fl_i=$((fl_i + 1))
        done
        while [ $# -gt 0 ]; do
          case "$1" in
            -w|-E|--timeout|--conflict-exit-code) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && shift ;;
      env)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|--unset|-C|--chdir|-S|--split-string) shift; [ $# -gt 0 ] && shift ;;
            -*|[A-Za-z_]*=*) shift ;;
            *) break ;;
          esac
        done ;;
      timeout)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -k|-s|--kill-after|--signal) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && shift ;;
      nice)
        shift
        case "${1:-}" in
          -n|--adjustment) shift; [ $# -gt 0 ] && shift ;;
          -*) shift ;;
        esac ;;
      xargs)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -n|-I|-L|-P|-d|-E|-s|-a|-J|--max-args|--max-procs|--delimiter|--replace|--arg-file|--max-lines|--eof|--max-chars) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      *) set -- "$w" "${@:2}"; break ;;
    esac
  done
  PREFIX_REST="$*"
}

# Sets SEG_CMD (basename of the command word) and SEG_REST (words from it on).
seg_command() {
  skip_prefix "$1"
  SEG_REST="$PREFIX_REST"
  SEG_CMD="${SEG_REST%% *}"
  SEG_CMD="${SEG_CMD##*/}"
}

is_grep_cmd() {
  case "$1" in
    grep|egrep|fgrep|ggrep|zgrep|zegrep|zfgrep|rgrep) return 0 ;;
    *) return 1 ;;
  esac
}

is_recursive_grep() {
  local seg="$1" arg opt next
  seg_command "$seg"
  is_grep_cmd "$SEG_CMD" || return 1
  [ "$SEG_CMD" = rgrep ] && return 0
  # Long options: --recursive, --dereference-recursive, --directories=recurse
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])--(recursive|dereference-recursive)([[:space:]]|$)'; then
    return 0
  fi
  if printf '%s' "$seg" | grep -Eq -- "(^|[[:space:]])--directories(=|[[:space:]]+)['\"]?recurse"; then
    return 0
  fi
  # Short options containing r or R, or `-d recurse`
  set -f
  # shellcheck disable=SC2086
  set -- $SEG_REST
  set +f
  shift # drop cmd
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    [ "$arg" = "--" ] && break
    opt="${arg#[\'\"]}"
    opt="${opt%[\'\"]}"
    case "$opt" in
      --*) ;;
      -*r*|-*R*) return 0 ;;
      -d|-[A-Za-z]*d)
        next="${1:-}"
        next="${next#[\'\"]}"
        next="${next%[\'\"]}"
        [ "$next" = recurse ] && return 0 ;;
    esac
  done
  return 1
}

# Only a pattern excluding EVERY protected name unlocks a recursive grep:
# exactly `.env*` or `*.env*`, after `--exclude=` or `--exclude `, quoted or not.
is_grep_env_excluded() {
  local seg="$1"
  printf '%s' "$seg" | grep -Eq -- "--exclude(=|[[:space:]]+)['\"]?\\*?\\.env\\*['\"]?([[:space:]]|\$)" || return 1
  # An `--include` matching a protected name re-admits it, whatever the order.
  local w pat want=0 name
  while IFS= read -r w; do
    pat=""
    if [ "$want" = 1 ]; then pat="$w"; want=0
    else
      case "$w" in
        --include=*) pat="${w#--include=}" ;;
        --include) want=1 ;;
      esac
    fi
    [ -n "$pat" ] || continue
    case "$pat" in
      *'{'*|*'['*) return 1 ;;
      .env*) env_is_template_name "$pat" || return 1 ;;
    esac
    for name in .env .env.local .env.production .env.development .env.test .env.staging .envrc; do
      # shellcheck disable=SC2254
      case "$name" in $pat) return 1 ;; esac
    done
  done < <(shell_words "$seg")
  return 0
}

# Prints the command string of `bash|sh|zsh|dash|ksh -c`, `-lc`, `-ec`, ... or
# `flock <file> -c`. $1 command name, $2 its words (SEG_REST). Empty if none.
shell_c_string() {
  local cmd="$1" w take=0 first=1 skipnext=0 operands=0
  while IFS= read -r w; do
    if [ "$first" = 1 ]; then first=0; continue; fi
    if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
    if [ "$take" = 1 ]; then
      case "$w" in -*|+*) continue ;; esac
      printf '%s\n' "$w"; return 0
    fi
    case "$w" in
      --command=*) [ "$cmd" = flock ] && { printf '%s\n' "${w#--command=}"; return 0; } ;;
      --command) [ "$cmd" = flock ] && take=1 ;;
      -w|-E|--timeout|--conflict-exit-code) [ "$cmd" = flock ] && skipnext=1 ;;
      -c) take=1 ;;
      +O) skipnext=1 ;;
      -[A-Za-z]*)
        [ "$cmd" = flock ] && continue
        case "$w" in *c*) take=1 ;; esac
        case "$w" in *[oO]) skipnext=1 ;; esac ;;
      -*|+*) ;;
      *) if [ "$cmd" = flock ]; then
           operands=$((operands + 1)); [ "$operands" -ge 2 ] && return 0
         else return 0; fi ;;
    esac
  done < <(shell_words "$2")
  return 0
}

# 0 when any piece of a `-c` string is a recursive grep that is neither
# excluding the env files nor provably limited to env-free paths.
inner_recursive_grep() {
  local piece
  while IFS= read -r piece; do
    [ -n "$piece" ] || continue
    if is_recursive_grep "$piece" && ! is_grep_env_excluded "$piece" \
       && ! recursive_grep_paths_safe "$piece"; then
      return 0
    fi
  done < <(printf '%s\n' "$1" | awk '{ gsub(/&&|\|\||[;|]/, "\n"); print }')
  return 1
}

# Quote-aware word split, one word per line, quotes removed. With a second
# argument, each line is prefixed `U` (fully unquoted) or `Q` (any quote,
# backslash or unterminated quote seen in that word).
shell_words() {
  printf '%s\n' "$1" | awk -v flag="${2:-}" '{
    n = length($0); w = ""; inw = 0; q = ""; qd = 0
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q != "") { if (c == q) { q = "" } else { w = w c }; continue }
      if (c == "\"" || c == "\047") { q = c; inw = 1; qd = 1; continue }
      if (c == "\\") { qd = 1 }
      if (c == " " || c == "\t") { if (inw) { print (flag != "" ? (qd ? "Q" : "U") : "") w; w = ""; inw = 0; qd = 0 }; continue }
      w = w c; inw = 1
    }
    if (inw) print (flag != "" ? ((qd || q != "") ? "Q" : "U") : "") w
  }'
}

# Explicit path operands of a grep segment, one per line (pattern and option
# arguments excluded; redirections skipped).
grep_path_operands() {
  seg_command "$1"
  local -a ws=()
  local w i ch idx=1 n have_pat=0 eoo=0 qf
  while IFS= read -r w; do ws+=("$w"); done < <(shell_words "$SEG_REST" flag)
  n=${#ws[@]}
  while [ "$idx" -lt "$n" ]; do
    w="${ws[$idx]}"
    qf="${w:0:1}"
    w="${w:1}"
    idx=$((idx + 1))
    if [ "$eoo" = 0 ]; then
      case "$w" in
        --) eoo=1; continue ;;
        --regexp|--file) have_pat=1; idx=$((idx + 1)); continue ;;
        --regexp=*|--file=*) have_pat=1; continue ;;
        --max-count|--after-context|--before-context|--context|--directories|--devices|--include|--exclude|--exclude-from|--exclude-dir|--label|--binary-files)
          idx=$((idx + 1)); continue ;;
        --*) continue ;;
        -?*)
          i=1
          while [ "$i" -lt "${#w}" ]; do
            ch="${w:$i:1}"
            case "$ch" in e|f) have_pat=1 ;; esac
            case "$ch" in
              [efmABCdD])
                [ $((i + 1)) -ge "${#w}" ] && idx=$((idx + 1))
                break ;;
            esac
            i=$((i + 1))
          done
          continue ;;
      esac
    fi
    if [ "$have_pat" = 0 ]; then have_pat=1; continue; fi
    if [ "$qf" = Q ]; then printf '%s\n' "'$w'"; continue; fi
    if [[ "$w" =~ ^[0-9]*[\<\>] ]]; then
      [[ "$w" =~ ^[0-9]*(\>\>?|\<|\>\&|\&\>)$ ]] && idx=$((idx + 1))
      continue
    fi
    printf '%s\n' "$w"
  done
}

# 0 when a recursive grep names at least one explicit path operand, every
# operand exists under the hook cwd, and none contains a protected file.
recursive_grep_paths_safe() {
  [ "$cd_in_command" = 0 ] || return 1
  # Operands may be built by a substitution (split into other segments), fed
  # through xargs or piped stdin, so the explicit paths cannot be trusted.
  [ "$has_subst" = 0 ] || return 1
  [ "$seg_piped" = 0 ] || return 1
  printf '%s' "$1" | grep -Eq '(^|[^[:alnum:]_./-])xargs([[:space:]]|$)' && return 1
  [ -d "$hook_cwd" ] || return 1
  local op out found=0
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    case "$op" in -*) return 1 ;; esac
    # Fail closed: only a plain unquoted path word is trusted.
    [[ "$op" =~ ^[A-Za-z0-9_./+,@:%=-]+$ ]] || return 1
    found=1
    (cd "$hook_cwd" 2>/dev/null && [ -e "$op" ]) || return 1
    local -a tmpl_excl=()
    local sfx
    for sfx in $ENV_TEMPLATE_SUFFIXES; do tmpl_excl+=('!' -iname "*.$sfx"); done
    out="$(cd "$hook_cwd" && find -L "$op" -iname '.env*' "${tmpl_excl[@]}" -print -quit 2>/dev/null)" || return 1
    [ -z "$out" ] || return 1
  done < <(grep_path_operands "$1")
  [ "$found" = 1 ]
}

# 0 when the segment runs a real script file with no stdin feed (pipe, heredoc,
# herestring, `<` redirect, `-` operand) and is not bun exec/run/x or bunx.
env_file_has_script_operand() {
  local cmd="$1" rest="$2" seg="$3" w script="" skip=0 first=1
  [ "$seg_piped" = 0 ] || return 1
  case "$seg" in *'<'*) return 1 ;; esac
  case "$rest" in bunx|bunx\ *) return 1 ;; esac
  while IFS= read -r w; do
    if [ "$first" = 1 ]; then first=0; continue; fi
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$w" in
      --env-file) skip=1 ;;
      -) return 1 ;;
      -*) ;;
      *) script="$w"; break ;;
    esac
  done < <(shell_words "$rest")
  [ -n "$script" ] || return 1
  if [ "$cmd" = bun ]; then
    case "$script" in run|exec|x) return 1 ;; esac
  fi
  return 0
}

# 0 when some piece of a `-c` string has `--exclude` but is not a grep command.
shell_piece_nongrep_exclude() {
  local piece sc="${SEG_CMD:-}" sr="${SEG_REST:-}" found=1
  while IFS= read -r piece; do
    case "$piece" in *--exclude*) ;; *) continue ;; esac
    seg_command "$piece"
    case "$SEG_CMD" in
      grep|egrep|fgrep|ggrep|zgrep|zegrep|zfgrep|rgrep) ;;
      *) found=0 ;;
    esac
  done < <(printf '%s\n' "$1" | awk '{ gsub(/&&|\|\||[;|]/, "\n"); print }')
  SEG_CMD="$sc"; SEG_REST="$sr"
  return "$found"
}

# Protected names in a segment, one per line.
protected_tokens() {
  local seg="$1" orig_seg="$1" cstr="" preload_re
  seg_command "$seg"
  case "$SEG_CMD" in
    bash|sh|zsh|dash|ksh|flock) cstr="$(shell_c_string "$SEG_CMD" "$SEG_REST")" ;;
  esac
  case "$SEG_CMD" in
    node|tsx|ts-node|deno|bun)
      # A preload/loader runs before the app and can dump `process.env`.
      preload_re='(^|[[:space:]])['\''"]?(-r|(--require|--import|--loader|--experimental-loader|--preload|--experimental-preload)(=|[[:space:]]|['\''"]|$))'
      [ "$SEG_CMD" = deno ] && preload_re='(^|[[:space:]])['\''"]?--(import|preload|require|loader|experimental-loader|experimental-preload)(=|[[:space:]]|['\''"]|$)'
      if printf '%s' "$SEG_REST" | grep -Eq "$preload_re" \
         || printf '%s' "$command_str" | grep -Eq '(^|[^[:alnum:]_])NODE_OPTIONS='; then
        :
      # `--env-file` only loads the file for the app. With an eval/print flag or
      # an `env`/`printenv` word the command can print the loaded values, so the
      # flag stays and the file name is reported.
      elif env_file_has_script_operand "$SEG_CMD" "$SEG_REST" "$seg" \
         && ! printf '%s' "$SEG_REST" | grep -Eq '(^|[[:space:]])(-[A-Za-z]*[ep]|--eval|--print)|(^|[[:space:]])(eval|env|printenv)([[:space:]]|$)'; then
        seg="$(printf '%s' "$seg" | sed -E 's/--env-file(=|[[:space:]]+)('\''|")?[^[:space:]'\''"]*('\''|")?//g')"
      fi
      ;;
    bash|sh|zsh|dash|ksh|flock)
      # Strip `--exclude` only when every piece carrying one is a grep; the
      # inner pass re-checks the exclusion itself.
      if ! shell_piece_nongrep_exclude "$cstr"; then
        seg="$(printf '%s' "$seg" | sed -E 's/--exclude(=|[[:space:]]+)('\''|")?[^[:space:]'\''"]*('\''|")?//g')"
      fi
      ;;
    grep|egrep|fgrep|ggrep|zgrep|zegrep|zfgrep|rgrep)
      seg="$(printf '%s' "$seg" | sed -E 's/--exclude(=|[[:space:]]+)('\''|")?[^[:space:]'\''"]*('\''|")?//g')"
      ;;
  esac

  printf '%s\n' "$seg" \
    | grep -Eoi "(^|[[:space:]/'\"<>=(:{,])\\.env[^[:space:]/'\"<>;|&)\`{},]*" \
    | sed -E 's/^[^.]*//' \
    | grep -Evi "$ENV_TEMPLATE_SUFFIX_ERE" || true
  # Attached short option on a commit (`git commit -F.env`, `-aF.env`).
  case "$seg" in
    *commit*)
      printf '%s\n' "$seg" \
        | grep -Eoi "(^|[[:space:]])-[A-Za-z]*[Ft]\\.env[^[:space:]'\"<>;|&)\`]*" \
        | sed -E 's/^[^.]*//' \
        | grep -Evi "$ENV_TEMPLATE_SUFFIX_ERE" || true ;;
  esac

  # Recursive grep detection: if recursive and .env* is not explicitly excluded
  # and the explicit path operands are not provably free of protected files,
  # it touches all .env* files in searched directories.
  if is_recursive_grep "$orig_seg" && ! is_grep_env_excluded "$orig_seg" \
     && ! recursive_grep_paths_safe "$orig_seg"; then
    printf '.env*\n'
  elif [ -n "$cstr" ] && inner_recursive_grep "$cstr"; then
    printf '.env*\n'
  fi
}

# 0 when the segment is allowed to name a protected file.
segment_is_name_only() {
  local seg="$1" sub
  seg_command "$seg"
  case "$SEG_CMD" in
    ls|test|"["|"[[") return 0 ;;
    find)
      printf '%s' "$seg" | grep -Eq '(^|[[:space:]])-(exec|execdir|ok|okdir|delete|fprint[0a-z]*|fls)([[:space:]]|$)' && return 1
      return 0 ;;
    cp)
      # Inspect non-option positional arguments of cp
      set -f
      # shellcheck disable=SC2086
      set -- $SEG_REST
      set +f
      shift
      local end_of_opts=0
      local positional=()
      while [ $# -gt 0 ]; do
        local arg="$1"
        shift
        if [ "$end_of_opts" = 0 ]; then
          case "$arg" in
            --) end_of_opts=1; continue ;;
            # `--t*` abbreviates --target-directory; any short cluster with `t`
            # (-t, -at, -t/tmp/x) names a target directory.
            --t*) return 1 ;;
            --*) continue ;;
            -t*|-[!-]*t*) return 1 ;;
            -*) continue ;;
          esac
        fi
        # A glob naming an env file can expand to the real one.
        case "$arg" in
          *[\*\?\[]*) printf '%s' "$arg" | grep -Eiq '\.env' && return 1 ;;
        esac
        positional+=("$arg")
      done
      [ "${#positional[@]}" -ge 2 ] || return 1
      local last_idx=$(( ${#positional[@]} - 1 ))
      local dest="${positional[$last_idx]}"
      dest="${dest#[\'\"]}"
      dest="${dest%[\'\"]}"
      local i src
      for (( i=0; i<last_idx; i++ )); do
        src="${positional[$i]}"
        src="${src#[\'\"]}"
        src="${src%[\'\"]}"
        if ! printf '%s' "$src" | grep -Eiq "$ENV_TEMPLATE_SUFFIX_ERE"; then
          return 1
        fi
      done
      # A template may create the env file, never overwrite the operator's.
      # A relative dest after a `cd`/`pushd` in the same command resolves
      # somewhere the hook cannot see, so it is treated as possibly existing.
      case "$dest" in
        /*) ;;
        *)
          [ "$cd_in_command" = 0 ] || return 1
          dest="$hook_cwd/$dest" ;;
      esac
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        return 1
      fi
      return 0 ;;
    grep|egrep|fgrep|ggrep|zgrep|zegrep|zfgrep|rgrep)
      if is_recursive_grep "$seg"; then
        if is_grep_env_excluded "$seg"; then
          return 0
        fi
        blocked_reason="recursive_grep"
        return 1
      fi
      return 1 ;;
    bash|sh|zsh|dash|ksh|flock)
      sub="$(shell_c_string "$SEG_CMD" "$SEG_REST")"
      if [ -n "$sub" ] && inner_recursive_grep "$sub"; then
        blocked_reason="recursive_grep"
      fi
      return 1 ;;
    git)
      # Subcommand after optional `-C <path>` / `-c k=v` options.
      sub="$(printf '%s' "$seg" | sed -E 's/^.*(^|[[:space:]])git[[:space:]]+((-C|-c)[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]+)*//' | awk '{print $1}')"
      case "$sub" in
        status|check-ignore|add) return 0 ;;
        commit)
          # `-m` text merely mentioning the name is fine; a message/template
          # FILE that is a protected env file puts its contents in history.
          printf '%s' "$seg" \
            | grep -Eoi "(^|[[:space:]])(-[A-Za-z]*[Ft]|--file|--template)(=|[[:space:]]+)?['\"]?([^[:space:]'\"]*/)?\.env[^[:space:]'\"<>;|&)\`]*" \
            | grep -Eviq "$ENV_TEMPLATE_SUFFIX_ERE" && return 1
          return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

# 0 when the segment is a pure stdin text filter: it only reshapes the lines
# it is fed and cannot turn them into file reads. `grep`/`egrep` qualify only
# with no file operand and no -r/-R/-f/--file.
is_text_filter_segment() {
  local seg="$1" w lit
  # Classify by the stage's own literal first word: a wrapper (`xargs head`,
  # `env sort`) makes the inner command open files, so it never qualifies.
  lit="${seg#"${seg%%[![:space:]]*}"}"
  lit="${lit%%[[:space:]]*}"
  lit="${lit##*/}"
  seg_command "$seg"
  [ "$lit" = "$SEG_CMD" ] || return 1
  case "$SEG_CMD" in
    head|tail|uniq|cut|tr)
      return 0 ;;
    sort|wc)
      # `sort -o`/`--output` writes, `--files0-from=-` turns stdin into file names.
      while IFS= read -r w; do
        case "$w" in
          --output|--output=*|--files0-from|--files0-from=*|--compress-program|--compress-program=*) return 1 ;;
          --*) ;;
          -*o*) [ "$SEG_CMD" = sort ] && return 1 ;;
        esac
      done < <(shell_words "$SEG_REST")
      return 0 ;;
    grep|egrep)
      is_recursive_grep "$seg" && return 1
      while IFS= read -r w; do
        case "$w" in
          --file|--file=*) return 1 ;;
          --*) ;;
          -*f*) return 1 ;;
        esac
      done < <(shell_words "$SEG_REST")
      [ -z "$(grep_path_operands "$seg")" ] ;;
    *) return 1 ;;
  esac
}

# Prints $1 with heredoc bodies removed when the heredoc only feeds `cat`
# (writing to a redirect target) or `tee` and nothing consumes it: the body is
# text. A heredoc fed to a shell/interpreter/ssh/eval, any pipeline on the
# line, or an unquoted delimiter whose body expands `$(`/backticks keeps its
# body inspected. Lines with more than one `<<` are left alone.
#
# Side effects (the caller must not run it in a command substitution): HD_OUT
# holds the same text, and HD_TARGETS[]/HD_BODIES[] hold, per write target of a
# `cat >`/`cat >>`/`tee` heredoc, the target word and the raw body, so the
# caller can tell whether the written file is run later in the same command.
HD_OUT=""
HD_TARGETS=()
HD_BODIES=()

# Prints the files a `cat >F`/`cat >>F`/`tee [-a] F` line writes (rest = the
# line without its heredoc operator), one per line; `$?` when none is found.
heredoc_write_targets() {
  local cmd="$1" rest="$2" w w2 want=0 seen=0 found=0
  while IFS= read -r w; do
    if [ "$cmd" = cat ]; then
      if [ "$want" = 1 ]; then printf '%s\n' "$w"; found=1; want=0; continue; fi
      w2="${w#[0-9]}"
      case "$w2" in
        '>'|'>>') want=1 ;;
        '>&'*) ;;
        '>>'?*) printf '%s\n' "${w2#>>}"; found=1 ;;
        '>'?*) printf '%s\n' "${w2#>}"; found=1 ;;
      esac
    else
      if [ "$seen" = 0 ]; then
        [ "${w##*/}" = tee ] && seen=1
        continue
      fi
      case "${w#[0-9]}" in
        -*) ;;
        '&&'|'||'|';'|'<'*|'>'*|'&'*) seen=2 ;;
        *) [ "$seen" = 1 ] && { printf '%s\n' "$w"; found=1; } ;;
      esac
    fi
  done < <(shell_words "$rest")
  [ "$found" = 1 ] || printf '%s\n' '$?'
}

strip_heredoc_bodies() {
  local line chk delim="" dash=0 strip=0 inh=0 quoted=0 buf="" out="" nl pairs t
  local hd_rest="" hd_cmd="" hd_targets="" tg
  HD_TARGETS=(); HD_BODIES=()
  local re='^(.*[^<])<<(-?)[[:space:]]*('"'"'[A-Za-z_][A-Za-z0-9_]*'"'"'|"[A-Za-z_][A-Za-z0-9_]*"|\\?[A-Za-z_][A-Za-z0-9_]*)([[:space:];\&|)<>].*)?$'
  local cmdre='^[[:space:]]*((cd|mkdir)[[:space:]][^;&|]*&&[[:space:]]*)*(cat|tee)([[:space:]]|$)'
  nl=$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inh" = 1 ]; then
      chk="$line"
      [ "$dash" = 1 ] && chk="${line#"${line%%[!$'\t']*}"}"
      if [ "$chk" = "$delim" ]; then
        inh=0
        if [ -n "$hd_targets" ]; then
          while IFS= read -r tg; do HD_TARGETS+=("$tg"); HD_BODIES+=("$buf"); done <<< "$hd_targets"
        fi
        if [ "$strip" = 1 ] && [ "$quoted" = 0 ]; then
          case "$buf" in *'$('*|*'`'*) strip=0 ;; esac
        fi
        if [ "$strip" = 1 ]; then out+="$line$nl"; else out+="$buf$line$nl"; fi
        buf=""
      else
        buf+="$line$nl"
      fi
      continue
    fi
    out+="$line$nl"
    t="${line//<<}"
    pairs=$(( (${#line} - ${#t}) / 2 ))
    [ "$pairs" = 1 ] || continue
    [[ "$line" =~ $re ]] || continue
    delim="${BASH_REMATCH[3]}"
    dash=0
    [ -n "${BASH_REMATCH[2]}" ] && dash=1
    hd_rest="${BASH_REMATCH[1]} ${BASH_REMATCH[4]}"
    strip=0
    hd_targets=""
    if [[ "$line" =~ $cmdre ]] && [[ "$line" != *'|'* ]]; then
      hd_cmd="${BASH_REMATCH[3]}"
      case "$hd_cmd" in
        cat) case "$line" in *'>'*) strip=1 ;; esac ;;
        tee) strip=1 ;;
      esac
      [ "$strip" = 1 ] && hd_targets="$(heredoc_write_targets "$hd_cmd" "$hd_rest")"
    fi
    quoted=0
    case "$delim" in
      \'*|\"*|\\*) quoted=1; delim="${delim#[\'\"\\]}"; delim="${delim%[\'\"]}" ;;
    esac
    inh=1
    buf=""
  done < <(printf '%s\n' "$1")
  if [ "$inh" = 1 ]; then out+="$buf"; fi
  # Same as a command substitution would return: no trailing newlines (the
  # quoted-separator masking treats any newline as a multi-line command).
  while [ "${out%$'\n'}" != "$out" ]; do out="${out%$'\n'}"; done
  HD_OUT="$out"
  printf '%s' "$out"
}

# Splits a command into the segments the main loop inspects (`;`, `&&`, `||`,
# `|`, newline, `$(`, backtick), the later stage of a pipe prefixed PIPE_MARK
# and a nested one SUB_MARK/BT_MARK.
split_segments() {
  printf '%s\n' "$1" \
    | sed -E -e 's/&&|\|\||;/\
/g' \
          -e 's/(^|[^|<>&])&($|[^>&])/\1\
\2/g' \
          -e 's/\$\(|<\(|>\(/\
'"$SUB_MARK"'/g' \
          -e 's/`/\
'"$BT_MARK"'/g' \
    | sed -E 's/\|&?/\
'"$PIPE_MARK"'/g'
}

# 0 when the interpreter/shell word $1 can run a script file.
is_script_runner() {
  case "$1" in
    bash|sh|zsh|dash|ksh|source|.|python*|node|perl|ruby|php|deno|bun|tsx|ts-node|awk|gawk|mawk|nawk|make|xargs|eval) return 0 ;;
  esac
  return 1
}

# 0 when the file a heredoc wrote ($1) is run by the rest of the command ($2,
# the text with heredoc bodies removed). Fails closed: a segment naming the
# file counts as a run unless its command word is on a short inert list and its
# output is neither piped onward nor nested in `$(`/backticks/`<(`. A target
# that is not a plain word, or one under .git/hooks (git runs it itself), needs
# no later mention.
heredoc_target_is_run() {
  local t="$1" str="$2" tb seg i n nested onward w wb plain=1 amp='&'
  local -a segs=()
  tb="${t##*/}"
  case "$t" in *'$'*|*'`'*|*[\*\?\[]*) plain=0 ;; esac
  case "$t" in *.git/hooks/*) return 0 ;; esac
  case "$t" in
    */hooks/*|hooks/*)
      printf '%s' "$command_str" | grep -Eq 'git[[:space:]]+([^;&|]*[[:space:]])?(commit|push)([[:space:]]|$)' && return 0 ;;
  esac
  while IFS= read -r seg; do segs+=("$seg"); done < <(split_segments "$str")
  n=${#segs[@]}
  for (( i = 0; i < n; i++ )); do
    seg="${segs[i]}"
    seg="${seg//$'\001'/;}"
    seg="${seg//$'\002'/|}"
    seg="${seg//$'\003'/"$amp"}"
    nested=0
    case "$seg" in "$PIPE_MARK"*) seg="${seg#"$PIPE_MARK"}" ;; esac
    case "$seg" in
      "$SUB_MARK"*) nested=1; seg="${seg#"$SUB_MARK"}" ;;
      "$BT_MARK"*) nested=1; seg="${seg#"$BT_MARK"}" ;;
    esac
    onward=0
    if [ $((i + 1)) -lt "$n" ]; then
      case "${segs[i+1]}" in "$PIPE_MARK"*) onward=1 ;; esac
    fi
    seg_command "$seg"
    case "$seg" in
      *'<<'*) case "$SEG_CMD" in cat|tee) continue ;; esac ;;
    esac
    if [ "$plain" = 0 ]; then
      is_script_runner "$SEG_CMD" && return 0
      continue
    fi
    while IFS= read -r w; do
      w="${w#[<>]}"
      w="${w%%[)\`\}]*}"
      wb="${w##*/}"
      [ "$wb" = "$tb" ] || continue
      if [ "$nested" = 0 ] && [ "$onward" = 0 ]; then
        case "$SEG_CMD" in
          git|ls|test|"["|"[["|stat|wc|chmod|rm|diff|cmp|file|shellcheck) continue 2 ;;
        esac
      fi
      return 0
    done < <(shell_words "$seg")
  done
  return 1
}

# Prints the first protected env token a heredoc body names (templates stay
# allowed), by the same token rule as protected_tokens; a name-only use counts.
heredoc_body_protected_token() {
  local tk
  while IFS= read -r tk; do
    if env_is_protected_name "$tk"; then printf '%s\n' "$tk"; return 0; fi
  done < <(printf '%s\n' "$1" \
    | grep -Eoi "(^|[[:space:]/'\"<>=(:{,])\\.env[^[:space:]/'\"<>;|&)\`{},]*" \
    | sed -E 's/^[^.]*//')
  return 0
}

# Prints the segment with text-only mentions of an env path removed, for the
# protected-token scan only:
#   - echo/printf: quoted arguments, except a quote that follows `<`/`>`;
#   - sed: the script words of a pure substitution (s<d>..<d>..<d>[gIip0-9]*);
#     any -f/--file, r/R/w/W/e command or other script keeps the segment as is.
mask_text_only() {
  local seg="$1" w prefix rest
  seg_command "$seg"
  case "$SEG_CMD" in
    echo|printf)
      printf '%s\n' "$seg" | awk '{
        n = length($0); out = ""; q = ""; keep = 0; word = ""
        for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (q != "") {
            if (c == q) { q = ""; if (keep) out = out c; continue }
            if (keep) out = out c
            continue
          }
          if (c == "\"" || c == "\047") {
            q = c; keep = (index(word, "<") > 0 || index(word, ">") > 0 || prev ~ /[<>]$/)
            if (keep) out = out c; else out = out " "
            continue
          }
          out = out c
          if (c == " " || c == "\t") { if (word != "") prev = word; word = "" } else word = word c
        }
        print out
      }'
      return 0 ;;
    sed)
      case "$seg" in *"$SEG_REST") prefix="${seg%"$SEG_REST"}" ;; *) printf '%s\n' "$seg"; return 0 ;; esac
      local -a ws=() keep=()
      local i=0 n j ch have_e=0 noscript=0 pure=1
      while IFS= read -r w; do ws+=("$w"); done < <(shell_words "$SEG_REST")
      n=${#ws[@]}
      keep+=("${ws[0]}")
      i=1
      local scripts=()
      local eoo=0
      while [ "$i" -lt "$n" ]; do
        w="${ws[$i]}"
        i=$((i + 1))
        if [ "$eoo" = 0 ]; then
          case "$w" in
            --) eoo=1; keep+=("$w"); continue ;;
            --file|--file=*) pure=0; break ;;
            --expression) have_e=1; [ "$i" -lt "$n" ] && { scripts+=("${ws[$i]}"); i=$((i + 1)); }; continue ;;
            --expression=*) have_e=1; scripts+=("${w#--expression=}"); continue ;;
            --*) keep+=("$w"); continue ;;
            -?*)
              j=1
              while [ "$j" -lt "${#w}" ]; do
                ch="${w:$j:1}"
                case "$ch" in
                  f) pure=0; break 2 ;;
                  e)
                    have_e=1
                    if [ $((j + 1)) -lt "${#w}" ]; then scripts+=("${w:$((j + 1))}")
                    elif [ "$i" -lt "$n" ]; then scripts+=("${ws[$i]}"); i=$((i + 1)); fi
                    break ;;
                  i)
                    # BSD sed: `-i ''` takes the empty backup suffix as a separate word.
                    if [ $((j + 1)) -ge "${#w}" ] && [ "$i" -lt "$n" ] && [ -z "${ws[$i]}" ]; then
                      i=$((i + 1))
                    fi
                    break ;;
                  l) break ;;
                esac
                j=$((j + 1))
              done
              continue ;;
          esac
        fi
        if [ "$have_e" = 0 ] && [ "$noscript" = 0 ]; then
          scripts+=("$w"); noscript=1
        else
          keep+=("$w")
        fi
      done
      if [ "$pure" = 1 ] && [ "${#scripts[@]}" -gt 0 ]; then
        for w in "${scripts[@]}"; do
          sed_script_is_pure_subst "$w" || { pure=0; break; }
        done
      else
        pure=0
      fi
      if [ "$pure" = 0 ]; then printf '%s\n' "$seg"; return 0; fi
      rest="${keep[*]}"
      printf '%s%s\n' "$prefix" "$rest"
      return 0 ;;
  esac
  printf '%s\n' "$seg"
}

# 0 when $1 is exactly one substitution command `s<d>re<d>repl<d>flags` with
# flags limited to g/I/i/p/digits (no `w`/`e` flag, no second command).
sed_script_is_pure_subst() {
  printf '%s' "$1" | awk '{
    if (NR > 1) exit 1
    n = length($0)
    if (n < 4 || substr($0, 1, 1) != "s") exit 1
    d = substr($0, 2, 1)
    if (d ~ /[A-Za-z0-9 \t\\;]/) exit 1
    cnt = 0
    for (i = 3; i <= n; i++) {
      c = substr($0, i, 1)
      if (c == "\\") { i++; continue }
      if (c == d) { cnt++; if (cnt == 2) break }
    }
    if (cnt != 2) exit 1
    flags = substr($0, i + 1)
    if (flags !~ /^[gIip0-9]*$/) exit 1
    exit 0
  }' 2>/dev/null
}

PIPE_MARK="@@PIPE@@"
SUB_MARK="@@SUB@@"
BT_MARK="@@BT@@"
strip_heredoc_bodies "$command_str" >/dev/null
scan_str="$HD_OUT"
scan_str="$(env_mask_quoted_separators "$scan_str")"
# A script written by a heredoc and run in the same command is no longer text:
# its body must not name a protected env file, and it gets the regular
# per-segment inspection like a heredoc fed straight to a shell.
hd_blocked=""
hd_any_run=0
for (( hi = 0; hi < ${#HD_TARGETS[@]}; hi++ )); do
  heredoc_target_is_run "${HD_TARGETS[hi]}" "$scan_str" || continue
  hd_any_run=1
  hd_blocked="$(heredoc_body_protected_token "${HD_BODIES[hi]}")"
  [ -n "$hd_blocked" ] && break
done
if [ "$hd_any_run" = 1 ]; then
  scan_str="$(env_mask_quoted_separators "$command_str")"
fi
sub_depth=0
blocked_token=""
blocked_reason=""
allowed_token=""
prev_listing_token=""
last_closed_listing=""
block_depth=0
block_listing=()
while IFS= read -r seg; do
  seg="${seg//$'\001'/;}"
  seg="${seg//$'\002'/|}"
  amp='&'
  seg="${seg//$'\003'/"$amp"}"
  # A name-only listing step whose output feeds a pipe is a read in disguise
  # (`ls .env | xargs cat`, `find . -name .env -print0 | xargs -0 cat`).
  piped=0
  nested=0
  case "$seg" in "$PIPE_MARK"*) piped=1; seg="${seg#"$PIPE_MARK"}" ;; esac
  case "$seg" in
    "$SUB_MARK"*) nested=1; sub_depth=$((sub_depth + 1)); seg="${seg#"$SUB_MARK"}" ;;
    "$BT_MARK"*) nested=1; seg="${seg#"$BT_MARK"}" ;;
  esac
  # Exception: a stage that is a pure stdin text filter (head/sort/wc/grep -v
  # without file operands...) cannot turn the names into reads; the listing
  # stays "unconsumed" for any later stage.
  keep_listing=""
  if [ "$piped" = 1 ]; then
    if [ -n "$prev_listing_token" ] || [ -n "$last_closed_listing" ]; then
      if [ "$nested" = 0 ] && is_text_filter_segment "$seg"; then
        keep_listing="$prev_listing_token"
      elif [ -n "$prev_listing_token" ]; then
        blocked_token="$prev_listing_token"
        break
      else
        blocked_token="$last_closed_listing"
        break
      fi
    fi
  fi
  [ "$nested" = 1 ] || prev_listing_token="$keep_listing"
  if [ "$piped" = 0 ]; then
    last_closed_listing=""
  fi

  # Track compound block nesting ({ ... } and ( ... ))
  unquoted="$(printf '%s' "$seg" | sed -E -e 's/"([^"\\]|\\.)*"//g' -e "s/'[^']*'//g")"
  opens=0
  closes=0
  set -f
  # shellcheck disable=SC2086
  set -- $unquoted
  set +f
  for w in "$@"; do
    case "$w" in
      "{"|"{{") opens=$((opens + ${#w})) ;;
      "}"|"}}") closes=$((closes + ${#w})) ;;
      "}"*) closes=$((closes + 1)) ;;
    esac
  done
  stripped_open="${unquoted//(}"
  count_paren_open=$(( ${#unquoted} - ${#stripped_open} ))
  opens=$((opens + count_paren_open))

  stripped_close="${unquoted//)}"
  count_paren_close=$(( ${#unquoted} - ${#stripped_close} ))
  closes=$((closes + count_paren_close))

  while [ "$opens" -gt 0 ]; do
    block_depth=$((block_depth + 1))
    block_listing[block_depth]=""
    opens=$((opens - 1))
  done

  seg_piped="$piped"
  tokens="$(protected_tokens "$(mask_text_only "$seg")")"
  # A quoted echo/printf argument is text only while nothing consumes it: treat
  # the masked name as a listing so a later pipe stage (`| xargs cat`) blocks.
  masked_listing=""
  if [ -z "$tokens" ]; then
    seg_command "$seg"
    case "$SEG_CMD" in
      echo|printf) masked_listing="$(protected_tokens "$seg" | head -n1)" ;;
    esac
  fi

  # Inside `$(`, backticks or `<(`/`>(`: the output is consumed by something
  # else, so naming a protected file there is never a plain name-only check.
  if [ -n "$tokens" ]; then
    if [ "$nested" = 1 ]; then
      blocked_token="$(printf '%s' "$tokens" | head -n1)"
      break
    fi
    if segment_is_name_only "$seg"; then
      allowed_token="$(printf '%s' "$tokens" | head -n1)"
      prev_listing_token="$allowed_token"
      if [ "$block_depth" -gt 0 ]; then
        block_listing[block_depth]="$allowed_token"
      fi
    else
      blocked_token="$(printf '%s' "$tokens" | head -n1)"
      break
    fi
  elif [ -n "$masked_listing" ]; then
    if [ "$nested" = 1 ]; then
      blocked_token="$masked_listing"
      break
    fi
    prev_listing_token="$masked_listing"
    if [ "$block_depth" -gt 0 ]; then
      block_listing[block_depth]="$masked_listing"
    fi
  fi

  while [ "$closes" -gt 0 ]; do
    # A `)` closes an open `$(`/`<(`/`>(` before any brace/paren block.
    if [ "$sub_depth" -gt 0 ]; then
      sub_depth=$((sub_depth - 1))
    elif [ "$block_depth" -gt 0 ]; then
      closed_token="${block_listing[block_depth]:-}"
      block_listing[block_depth]=""
      block_depth=$((block_depth - 1))
      if [ -n "$closed_token" ]; then
        if [ "$block_depth" -gt 0 ]; then
          block_listing[block_depth]="$closed_token"
        else
          last_closed_listing="$closed_token"
        fi
      fi
    fi
    closes=$((closes - 1))
  done
done < <(split_segments "$scan_str")

if [ -n "$hd_blocked" ]; then
  blocked_token="$hd_blocked"
  blocked_reason="heredoc_script_run"
fi

if [ -z "$blocked_token" ]; then
  if [ -n "$allowed_token" ]; then
    log_decision "$HOOK_NAME" "Bash" ".env-name-only" "allow" "name-only use of $allowed_token"
  fi
  exit 0
fi

if [ "$blocked_reason" = "recursive_grep" ]; then
  cat >&2 <<MSG
🚫 atelier:block-env-read BLOCKED
   Tool:    Bash
   Reason:  recursive grep reads all directory files including .env*; use 'rg' (which ignores hidden/gitignored files by default) or add --exclude='.env*'
   Rule:    PLAN.md §3 — .env* contents are operator-only; agents must not read, copy, move or delete them.
   Action:  ask the operator for the specific variable names you need. Name-only checks (ls, test -f, find -name) and .env.example/.sample/.template/.dist templates are allowed. To edit a file that merely mentions an env path, use the Edit tool.
MSG
  log_decision "$HOOK_NAME" "Bash" ".env-read" "block" "blocked recursive grep reading $blocked_token"
elif [ "$blocked_reason" = "heredoc_script_run" ]; then
  cat >&2 <<MSG
🚫 atelier:block-env-read BLOCKED
   Tool:    Bash
   Reason:  a heredoc script written and run in the same command names $blocked_token
   Rule:    PLAN.md §3 — .env* contents are operator-only; a script that is run can read them, so it may not name a protected env file (templates such as .env.example are fine).
   Action:  ask the operator for the specific variable names you need, or drop the env path from the script.
MSG
  log_decision "$HOOK_NAME" "Bash" ".env-read" "block" "blocked heredoc script run in the same command naming $blocked_token"
else
  cat >&2 <<MSG
🚫 atelier:block-env-read BLOCKED
   Tool:    Bash
   Reason:  the command names a protected env file: $blocked_token
   Rule:    PLAN.md §3 — .env* contents are operator-only; agents must not read, copy, move or delete them.
   Action:  ask the operator for the specific variable names you need. Name-only checks (ls, test -f, find -name) and .env.example/.sample/.template/.dist templates are allowed. To edit a file that merely mentions an env path, use the Edit tool.
MSG
  log_decision "$HOOK_NAME" "Bash" ".env-read" "block" "blocked command naming $blocked_token"
fi

exit 2
