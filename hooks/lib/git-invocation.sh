#!/usr/bin/env bash
# Shared git invocation resolver (#808): given the tokens that follow the `git`
# command word, finds the real subcommand the way git does (global options with
# their value arity, in-invocation `-c` config, aliases) and normalises push
# destinations the way git's ref lookup does. Sourced by block-protected-push.sh;
# defines functions only, runs nothing. The only commands it ever runs are
# read-only `git config --get*` / `git symbolic-ref -q`, in the repository the
# invocation itself selects (-C / --git-dir / --work-tree), tolerating a cwd that
# is not a repository.
#
# shellcheck disable=SC2034,SC2194,SC2018,SC2019
# (results are globals read by the sourcing hook; case on a constant word is a prefix test)
#
# Results are returned in globals (bash 3.2: no namerefs, no assoc arrays):
#   GI_SUB     subcommand token ("" when none)
#   GI_REST    arguments after the subcommand
#   GI_OPTS    -C / --git-dir / --work-tree tokens, replayed for config reads
#   GI_CFG     "key=value" pairs from -c (key lower-cased)
#   GI_CFG_ENV_RISK  1 when --config-env names alias / push configuration

GI_PROTECTED="main master develop staging"

GI_SUB=""
GI_REST=()
GI_OPTS=()
GI_CFG=()
GI_CFG_ENV_RISK=0

gi_reset() { GI_SUB=""; GI_REST=(); GI_OPTS=(); GI_CFG=(); GI_CFG_ENV_RISK=0; }

# Lower-case into GI_LC; forks only when the text has an upper-case letter.
GI_LC=""
gi_lc() {
  GI_LC="$1"
  case "$1" in *[A-Z]*) GI_LC="$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')" ;; esac
}

# Config keys that decide where a push goes or what a git command name means.
gi_key_is_push_risk() { # lower-cased key
  case "$1" in
    alias.*|push.default|remote.*.push|remote.*.pushurl|remote.pushdefault|remote.*.receivepack|remote.*.uploadpack) return 0 ;;
  esac
  return 1
}

# Walk git's global options. Value-taking ones consume the next token.
gi_walk() { # tokens after `git`
  local -a a=("$@")
  local n=${#a[@]} i=0 t k v
  GI_SUB=""; GI_REST=()
  while [ "$i" -lt "$n" ]; do
    t="${a[$i]}"
    case "$t" in
      -C) GI_OPTS+=("-C" "${a[$((i + 1))]:-}"); i=$((i + 2)) ;;
      -c)
        v="${a[$((i + 1))]:-}"
        k="${v%%=*}"
        gi_lc "$k"
        GI_CFG+=("$GI_LC=${v#*=}")
        i=$((i + 2)) ;;
      --git-dir|--work-tree)
        GI_OPTS+=("$t" "${a[$((i + 1))]:-}"); i=$((i + 2)) ;;
      --namespace|--super-prefix|--attr-source)
        i=$((i + 2)) ;;
      --config-env)
        v="${a[$((i + 1))]:-}"
        gi_lc "${v%%=*}"; k="$GI_LC"
        gi_key_is_push_risk "$k" && GI_CFG_ENV_RISK=1
        i=$((i + 2)) ;;
      --config-env=*)
        v="${t#--config-env=}"
        gi_lc "${v%%=*}"; k="$GI_LC"
        gi_key_is_push_risk "$k" && GI_CFG_ENV_RISK=1
        i=$((i + 1)) ;;
      --git-dir=*|--work-tree=*) GI_OPTS+=("$t"); i=$((i + 1)) ;;
      -*) i=$((i + 1)) ;;
      *)
        GI_SUB="$t"
        if [ "$((i + 1))" -lt "$n" ]; then GI_REST=("${a[@]:$((i + 1))}"); fi
        return 0 ;;
    esac
  done
  return 0
}

# Subcommands that are git builtins: git never lets an alias shadow them, so no
# alias lookup is needed for these.
gi_is_builtin_nonpush() {
  case "$1" in
    status|diff|log|show|add|commit|checkout|switch|branch|fetch|pull|merge|rebase|stash|tag|worktree|\
    rev-parse|ls-files|reset|clone|init|remote|apply|restore|rm|mv|describe|blame|cherry-pick|revert|\
    bisect|clean|grep|gc|fsck|ls-remote|shortlog|show-ref|symbolic-ref|update-ref|rev-list|cat-file|\
    diff-tree|for-each-ref|var|version|help|submodule|notes|format-patch|am|archive|bundle|config|\
    ls-tree|merge-base|name-rev|reflog|sparse-checkout|maintenance|diff-index|write-tree|read-tree|\
    commit-tree|hash-object|mktree|update-index|checkout-index|count-objects|verify-commit|verify-tag)
      return 0 ;;
  esac
  return 1
}

# --- config reads (read-only) ------------------------------------------------
# In-invocation -c value of a key (last wins); returns 1 when not set.
gi_cfg_lookup() { # lower-cased key
  local i found=1 e
  for ((i = 0; i < ${#GI_CFG[@]}; i++)); do
    e="${GI_CFG[$i]}"
    if [ "${e%%=*}" = "$1" ]; then GI_VAL="${e#*=}"; found=0; fi
  done
  return $found
}
GI_VAL=""

gi_git() { git ${GI_OPTS[@]+"${GI_OPTS[@]}"} "$@" 2>/dev/null; }

# Persistent config read through `git config --get`; honours the -C chain.
gi_config_get() { # key
  GI_VAL="$(gi_git config --get "$1")" || { GI_VAL=""; return 1; }
  return 0
}

gi_cur_branch() { gi_git symbolic-ref -q --short HEAD || true; }

# --- push destinations -------------------------------------------------------
gi_is_protected_name() { # name (compared case-insensitively: case-folding filesystems)
  local nm b
  gi_lc "$1"; nm="$GI_LC"
  for b in $GI_PROTECTED; do
    [ "$nm" = "$b" ] && return 0
  done
  return 1
}

# Normalise a push destination the way git's DWIM ref lookup reads it: repeated
# leading `refs/` and `heads/` are dropped, empty path components collapsed.
# GI_DST_TAG=1 when the result lives in the tags namespace.
GI_DST=""; GI_DST_TAG=0
gi_norm_dest() { # dst
  local n="$1"
  GI_DST_TAG=0
  while [ "${n#/}" != "$n" ]; do n="${n#/}"; done
  while [ "${n//\/\//\/}" != "$n" ]; do n="${n//\/\//\/}"; done
  while [ "${n%/}" != "$n" ]; do n="${n%/}"; done
  while [ "${n#refs/}" != "$n" ]; do n="${n#refs/}"; done
  case "$n" in tags/*) GI_DST_TAG=1 ;; esac
  while :; do
    case "$n" in
      refs/*) n="${n#refs/}" ;;
      heads/*) n="${n#heads/}" ;;
      *) break ;;
    esac
  done
  GI_DST="$n"
}

# Does the (normalised) destination hit a protected branch?  Echoes the name.
# A glob destination counts when it could match a protected name outright; a
# literal one when its last path component is protected (last-component rule).
gi_dest_protected() { # normalised destination
  local n="$1" b last
  case "$n" in
    *'*'*|*'?'*|*'['*)
      for b in $GI_PROTECTED; do
        # shellcheck disable=SC2053
        if [[ "$b" == $n ]]; then printf '%s' "$b"; return 0; fi
      done
      last="${n##*/}"
      case "$last" in *'*'*|*'?'*|*'['*) return 1 ;; esac
      ;;
  esac
  last="${n##*/}"
  if gi_is_protected_name "$last"; then printf '%s' "$last"; return 0; fi
  return 1
}

# Does a token still carry shell expansion that was not resolved?
gi_has_expansion() {
  case "$1" in *'$'*|*'`'*|*'{'*) return 0 ;; esac
  return 1
}

# Match a push long option the way git's option parser does: an unambiguous
# prefix selects the option. The prefix is matched against the full table of
# push long options, so the minimum accepted length is whatever is unique in
# that table (including one-letter forms). Sets GI_OPT to the canonical class:
#   force | lease | all | prune | tags | delete | receive-pack | repo |
#   push-option | recurse | other
# When a prefix is shared by several options git rejects it; the riskiest
# class among the candidates is returned, since a rejected command does
# nothing either way.
GI_OPT=""
GI_PUSH_LONG_OPTS="all:all atomic:other branches:all delete:delete dry-run:other exec:receive-pack follow-tags:other force:force force-with-lease:lease force-if-includes:lease ipv4:other ipv6:other mirror:all porcelain:other progress:other prune:prune push-option:push-option quiet:other receive-pack:receive-pack recurse-submodules:recurse repo:repo set-upstream:other signed:other tags:tags thin:other verbose:other verify:other"
gi_push_long_opt() { # name without leading dashes and without =value
  local nm="$1" ent full cls exact="" hits="" c
  GI_OPT="other"
  case "$nm" in no-*) return 0 ;; esac
  [ -z "$nm" ] && return 0
  for ent in $GI_PUSH_LONG_OPTS; do
    full="${ent%%:*}"; cls="${ent#*:}"
    if [ "$full" = "$nm" ]; then exact="$cls"; break; fi
    case "$full" in "$nm"*) hits+=" $cls " ;; esac
  done
  if [ -n "$exact" ]; then GI_OPT="$exact"; return 0; fi
  for c in receive-pack force all prune delete tags repo push-option recurse lease; do
    case "$hits" in *" $c "*) GI_OPT="$c"; return 0 ;; esac
  done
  return 0
}
