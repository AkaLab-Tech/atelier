#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Intercepts `git add` and scans the
# proposed staged contents for the patterns in hooks/patterns/scan-git-add.json,
# plus the catalogue from hooks/patterns/scan-edit-write.json (reused as
# documented in PLAN.md §3 threat-model addendum).
#
# Decision matrix:
#   - Block → exit 2 + stderr message (Claude sees it, the `git add` is rejected).
#   - Warn  → exit 0 + stderr warning (the `git add` proceeds).
#   - Ask   → stdout JSON  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#             "permissionDecision": "ask", "permissionDecisionReason": "..."}}
#             + exit 0 (Claude Code prompts the operator). The decision fields
#             MUST sit under hookSpecificOutput — a top-level
#             permissionDecision is ignored by the harness (#126).
#
# Layered defence: this is the second runtime check on `git add` (the
# first is block-env-commit, sub-PR 1, also matched on Bash). Both fire
# for every `git add`; this one looks at content + recognised secret
# shapes, the other looks at .env* path semantics.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="scan-git-add"
PATTERNS_FILE="${CLAUDE_PLUGIN_ROOT}/hooks/patterns/scan-git-add.json"
EDIT_WRITE_PATTERNS_FILE="${CLAUDE_PLUGIN_ROOT}/hooks/patterns/scan-edit-write.json"

if [ ! -f "$PATTERNS_FILE" ]; then
  printf '⚠️  atelier:%s — patterns file missing at %s; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" "$PATTERNS_FILE" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "patterns file missing — hook degraded"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded"
  exit 0
fi

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only intercept `git add` Bash calls.
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$command_str" ] || exit 0
# #130 — also match `git -C <path> add`, the atelier convention for
# addressing a task worktree from a cwd that stays at the main repo.
# Without this arm the command fell through to `exit 0` and NOTHING was
# scanned — a silent, total bypass of the secret scanner.
case "$command_str" in
  *"git add "*|*"git add"|*"git add;"*|*"git add&"*) ;;
  *"git -C "*"add "*|*"git -C "*"add"|*"git -C "*"add;"*|*"git -C "*"add&"*) ;;
  *) exit 0 ;;
esac

# #258 — resolve the directory the `git add` actually targets. This hook
# inherits the cwd of the Bash tool call, which (per atelier's
# cwd-vs-worktree rule) is normally the main repo, NOT the task worktree
# an agent addresses via `git -C <worktree> add …` or `cd <worktree> &&
# git add …`. Without this, every git/file operation below (ls-files,
# diff, cat, -f/-d checks) ran against the wrong tree. Mirrors
# safe-commit.sh's target_dir resolution (M7.1.F57); only the `-C` and
# `cd`-prefix arms are needed here (this hook has no --git-dir/--work-tree
# refusal to preserve).
target_dir="$PWD"
if printf '%s' "$command_str" | grep -qE 'git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]'; then
  c_path="$(printf '%s' "$command_str" | sed -nE "s/.*git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  [ -n "$c_path" ] && target_dir="$c_path"
elif printf '%s' "$command_str" | grep -qE '^[[:space:]]*cd[[:space:]]'; then
  cd_path="$(printf '%s' "$command_str" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]&;|]+)).*/\2\3\4/p")"
  [ -n "$cd_path" ] && target_dir="$cd_path"
fi
if [ -d "$target_dir" ]; then
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || target_dir="$PWD"
else
  target_dir="$PWD"
fi
# #297 — do NOT `cd` into target_dir and rely on it for the rest of the
# script. Every downstream git/file operation now takes target_dir
# explicitly (via `git -C` or a `$target_dir/`-prefixed path), so path
# resolution never silently depends on whether an actual `cd` happened
# to take effect in this process.

# ---- Resolve which paths would be staged --------------------------------
# Strategy:
#   - For `git add .` / `-A` / `--all` / `:/`: union of untracked + modified.
#   - For explicit paths: use the literal tokens from the command, after
#     stripping flags. We resolve real files only.
#
# Output: $TO_STAGE_FILE contains one path per line, scoped to the
# current cwd (which is the worktree Claude is operating in).
TO_STAGE_FILE="$(mktemp -t atelier-scan-git-add.XXXXXX)"
trap 'rm -f "$TO_STAGE_FILE"' EXIT

# #258 — normalise "git [-C <path>] add …" → an expression beginning at
# `add …` so the wildcard detector and add_args extraction below work
# whether or not a `-C <path>` sits between `git` and `add`.
add_expr="$(printf '%s' "$command_str" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:]]+)[[:space:]]+(add[[:space:]].*)/\2/p")"
if [ -z "$add_expr" ]; then
  add_expr="$(printf '%s' "$command_str" | sed -nE "s/.*(git[[:space:]]+add([[:space:]].*)?)/\1/p")"
  # strip the leading "git " so add_expr starts at "add"
  add_expr="$(printf '%s' "$add_expr" | sed -E 's/^git[[:space:]]+//')"
fi
[ -z "$add_expr" ] && add_expr="$command_str"

# Wildcard detection. `*"git add ."*` (plain glob) is too greedy — it
# also matches `git add .env`. Use a regex that requires the wildcard
# token to be word-bounded: either followed by whitespace / chain
# operator, or sitting at end-of-string. Anchored at `add_expr` (which
# starts at `add`) so `git -C <path> add .` is detected too (#258).
if [[ "$add_expr" =~ ^add[[:space:]]+(\.|-A|--all|:/|\*)([[:space:]]|;|\&|\||$) ]]; then
  is_wildcard=1
else
  is_wildcard=0
fi

if [ "$is_wildcard" -eq 1 ]; then
  {
    git -C "$target_dir" ls-files --others --exclude-standard 2>/dev/null || true
    git -C "$target_dir" diff --name-only 2>/dev/null || true
  } | sort -u > "$TO_STAGE_FILE"
else
    # Extract tokens after `git add` up to the next chained operator
    # (`;`, `&&`, `||`, `|`). Strip flags (-f / --force / -p / -u …).
    # We don't try to perfectly emulate git's CLI; a few false positives
    # in token extraction at worst over-scan, never under-scan.
    add_args="$(printf '%s' "$add_expr" | sed -E 's/^add[[:space:]]+//' | sed -E 's/[[:space:]]*(;|&&|\|\||\|).*//' )"
    for tok in $add_args; do
      case "$tok" in
        -*) continue ;;  # flag, skip
        '') continue ;;
      esac
      # #297/#301 — resolve every token against target_dir explicitly.
      # `git [-C target_dir] add <tok>` resolves <tok> relative to
      # target_dir, never to this hook's own $PWD; the existence check
      # and any dir expansion below must match that exactly.
      case "$tok" in
        /*) full_tok="$tok" ;;
        *) full_tok="$target_dir/$tok" ;;
      esac
      if [ -f "$full_tok" ] || [ -d "$full_tok" ]; then
        # If it's a dir, expand to the files git would see.
        if [ -d "$full_tok" ]; then
          {
            git -C "$full_tok" ls-files --others --exclude-standard 2>/dev/null
            git -C "$full_tok" diff --name-only 2>/dev/null
          } | sed "s|^|${tok%/}/|"
        else
          printf '%s\n' "$tok"
        fi
      fi
    done | sort -u > "$TO_STAGE_FILE"
fi

# If we found nothing concrete to scan, allow. Git itself will surface
# any error about non-existent paths.
if ! [ -s "$TO_STAGE_FILE" ]; then
  log_decision "$HOOK_NAME" "Bash" "no-paths" "allow" "no resolvable paths from command"
  exit 0
fi

# ---- Helpers ------------------------------------------------------------

# Read pattern JSON arrays from the catalogue, one per line of compact JSON.
own_patterns()      { jq -c '.patterns[]?' "$PATTERNS_FILE" 2>/dev/null; }
own_skip_subs()     { jq -r '.skips.path_substrings[]?' "$PATTERNS_FILE" 2>/dev/null; }
own_lockfiles()     { jq -r '.skips.lockfile_basenames[]?' "$PATTERNS_FILE" 2>/dev/null; }
edit_write_patterns() {
  if [ -f "$EDIT_WRITE_PATTERNS_FILE" ]; then
    jq -c '.patterns[]?' "$EDIT_WRITE_PATTERNS_FILE" 2>/dev/null
  fi
}

# Return 0 if $1 matches a `path_substring` skip rule from the catalogue.
is_skipped_path() {
  local path="$1"
  local subs
  subs="$(own_skip_subs)"
  if [ -n "$subs" ]; then
    while IFS= read -r sub; do
      [ -z "$sub" ] && continue
      case "$path" in
        *"$sub"*) return 0 ;;
      esac
    done <<< "$subs"
  fi
  return 1
}

# Return 0 if basename of $1 is in the lockfile list (entropy-skip).
is_lockfile() {
  local b
  b="$(basename "$1")"
  local lockfiles
  lockfiles="$(own_lockfiles)"
  if [ -n "$lockfiles" ]; then
    while IFS= read -r lf; do
      [ -z "$lf" ] && continue
      [ "$b" = "$lf" ] && return 0
    done <<< "$lockfiles"
  fi
  return 1
}

# Extract added lines for a path, scoped to $target_dir (#297: never the
# hook's own $PWD). If untracked, return the whole file (there is no
# "base" to diff against — the entire content is new). If tracked,
# return only lines starting with `+` from `git diff HEAD` against
# target_dir (the diff lines, excluding the `+++` filename header) —
# `--unified=0` drops context lines entirely so a pre-existing line
# sitting near a real change is never mistaken for an added one (#297:
# a private-key example already committed, unchanged, must never read
# as newly added just because something else in the same file moved).
# Diffing against HEAD (not just the index) also covers content this
# `git add` is about to stage as well as anything staged by an earlier
# `git add` in the same session — either way it's about to be committed.
#
# Sets SCAN_PARSE_ERROR=1 and returns empty when the diff can't be
# scoped cleanly (binary content, or the `git diff` invocation itself
# failing) — callers must fail closed (block) on that signal rather
# than silently treating "no diff text" as "nothing added".
SCAN_PARSE_ERROR=0
added_lines_for() {
  local path="$1"
  SCAN_PARSE_ERROR=0
  # $path may be absolute (a literal absolute token in the `git add`
  # command) or relative to target_dir — resolve once for the plain
  # `cat` fallback below; git itself resolves either form fine as a
  # pathspec under `-C target_dir`.
  local abs_path
  case "$path" in
    /*) abs_path="$path" ;;
    *) abs_path="$target_dir/$path" ;;
  esac
  if git -C "$target_dir" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    local diff_out
    if ! diff_out="$(git -C "$target_dir" diff HEAD --no-color --unified=0 -- "$path" 2>/dev/null)"; then
      SCAN_PARSE_ERROR=1
      return 0
    fi
    if printf '%s\n' "$diff_out" | grep -qE '^Binary files '; then
      SCAN_PARSE_ERROR=1
      return 0
    fi
    printf '%s\n' "$diff_out" | awk '/^\+\+\+/ { next } /^\+/ { sub(/^\+/, ""); print }'
  else
    # Untracked → entire file content, read from target_dir (not $PWD).
    cat -- "$abs_path" 2>/dev/null || true
  fi
}

# Combined entropy check in Python. Reads added content from stdin and
# passes it through a tmpfile to Python (since the HEREDOC already
# occupies python's stdin). Pattern config is arg 1. Returns the FIRST
# run of ≥ min_length base64-ish characters whose Shannon entropy is
# ≥ min_entropy, on a line that does NOT start with a comment prefix.
# Empty stdout means no match. One Python invocation avoids fragile
# bash-side regex chains that break on prefixes like `/*`.
entropy_check_added() {
  local pat_json="$1"
  local content_file
  content_file="$(mktemp -t atelier-entropy.XXXXXX)"
  cat > "$content_file"
  python3 - "$pat_json" "$content_file" <<'PY'
import json
import math
import re
import sys

cfg = json.loads(sys.argv[1])
with open(sys.argv[2], "r", encoding="utf-8", errors="replace") as fh:
    content = fh.read()

min_len = int(cfg.get("min_length", 32))
min_ent = float(cfg.get("min_entropy", 4.5))
prefixes = cfg.get("skip_line_prefixes", [])

def shannon(s: str) -> float:
    if not s:
        return 0.0
    freq = {}
    for c in s:
        freq[c] = freq.get(c, 0) + 1
    n = len(s)
    return -sum((k / n) * math.log2(k / n) for k in freq.values())

candidate = re.compile(r"[A-Za-z0-9+/=]{" + str(min_len) + r",}")
for raw_line in content.splitlines():
    stripped = raw_line.lstrip()
    if any(stripped.startswith(p) for p in prefixes):
        continue
    for m in candidate.findall(raw_line):
        if shannon(m) >= min_ent:
            print(m)
            sys.exit(0)
PY
  local rc=$?
  rm -f "$content_file"
  return $rc
}

# ---- Decision tracking --------------------------------------------------
# We collect outcomes across all paths and patterns, then decide at the end.
declare -a ask_reasons=()
declare -a warn_reasons=()

block_now() {
  local pattern_name="$1" path="$2" matched="$3" rationale="$4"
  local preview="${matched:0:120}"
  [ "${#matched}" -gt 120 ] && preview="$preview…"
  cat >&2 <<MSG
🚫 atelier:scan-git-add BLOCKED
   Tool:    Bash(git add)
   Path:    $path
   Pattern: $pattern_name
   Match:   $preview
   Why:     $rationale
   Rule:    PLAN.md §3 threat-model addendum (scan-git-add catalogue).
   Action:  remove the offending content (or path), then \`git add\` again.
            For genuine test fixtures, add a leading "scan-edit-write: skip"
            comment to the file (also honoured by this hook for content
            patterns reused from scan-edit-write).
MSG
  log_decision "$HOOK_NAME" "Bash" "$pattern_name" "block" "$pattern_name in $path: $preview"
  exit 2
}

# ---- file-level scan ----------------------------------------------------
# Patterns whose match is the path itself (not the content): env-file-added,
# secrets-directory-added, etc.
scan_path_level() {
  local path="$1"

  while IFS= read -r pat_json; do
    [ -z "$pat_json" ] && continue
    local name match_type action rationale matched=0 matched_text=""
    name="$(printf '%s' "$pat_json" | jq -r '.name // empty')"
    match_type="$(printf '%s' "$pat_json" | jq -r '.match_type // empty')"
    action="$(printf '%s' "$pat_json" | jq -r '.action // empty')"
    rationale="$(printf '%s' "$pat_json" | jq -r '.rationale // empty')"

    case "$match_type" in
      path_basename_glob)
        local b
        b="$(basename "$path")"
        while IFS= read -r glob; do
          [ -z "$glob" ] && continue
          # Glob expansion in case patterns is intentional here: the
          # catalogue's `patterns` field is meant to be a shell glob
          # (e.g. `.env.*`), not a literal string.
          # shellcheck disable=SC2254
          case "$b" in
            $glob) matched=1; matched_text="$b matches $glob"; break ;;
          esac
        done < <(printf '%s' "$pat_json" | jq -r '.patterns[]?')
        ;;
      path_substring_any)
        while IFS= read -r sub; do
          [ -z "$sub" ] && continue
          case "$path" in
            *"$sub"*) matched=1; matched_text="$path contains $sub"; break ;;
          esac
        done < <(printf '%s' "$pat_json" | jq -r '.patterns[]?')
        ;;
      *)
        continue  # not a path-level pattern
        ;;
    esac

    [ "$matched" -eq 0 ] && continue

    if [ "$action" = "block" ]; then
      block_now "$name" "$path" "$matched_text" "$rationale"
    fi
  done < <(own_patterns)
}

# ---- added-line scan ----------------------------------------------------
# Patterns matched against the diff "added" content for the path.
scan_added_lines() {
  local path="$1"
  local added
  added="$(added_lines_for "$path")"
  # #297 fail-closed — a diff we couldn't scope (binary, or the `git
  # diff` invocation itself erroring) must block, not silently pass.
  [ "$SCAN_PARSE_ERROR" -eq 1 ] && block_now "diff-parse-error" "$path" "" \
    "could not scope the staged diff for this path (binary content or a diff error) — failing closed"
  [ -z "$added" ] && return 0

  local skip_entropy=0
  is_lockfile "$path" && skip_entropy=1

  while IFS= read -r pat_json; do
    [ -z "$pat_json" ] && continue
    local name match_type action rationale matched=0 matched_text="" ci
    name="$(printf '%s' "$pat_json" | jq -r '.name // empty')"
    match_type="$(printf '%s' "$pat_json" | jq -r '.match_type // empty')"
    action="$(printf '%s' "$pat_json" | jq -r '.action // empty')"
    rationale="$(printf '%s' "$pat_json" | jq -r '.rationale // empty')"
    ci="$(printf '%s' "$pat_json" | jq -r '.case_insensitive // false')"

    case "$match_type" in
      added_line_regex)
        local regex grep_flags=("-E" "-m1" "-o")
        regex="$(printf '%s' "$pat_json" | jq -r '.pattern // empty')"
        [ -z "$regex" ] && continue
        [ "$ci" = "true" ] && grep_flags+=("-i")
        if matched_text="$(printf '%s' "$added" | grep "${grep_flags[@]}" -- "$regex" 2>/dev/null)"; then
          [ -n "$matched_text" ] && matched=1
        fi
        ;;
      added_line_substring_any)
        while IFS= read -r sub; do
          [ -z "$sub" ] && continue
          case "$added" in
            *"$sub"*) matched=1; matched_text="$sub"; break ;;
          esac
        done < <(printf '%s' "$pat_json" | jq -r '.patterns[]?')
        ;;
      added_line_entropy)
        if [ "$skip_entropy" -eq 1 ]; then
          continue
        fi
        # Hand the entire scan (line filter + run extraction + Shannon
        # entropy) to Python in one invocation. Bash regex alternation
        # over the configured prefixes is fragile because some prefixes
        # like `/*` and `*` are regex metacharacters.
        local hit
        hit="$(printf '%s' "$added" | entropy_check_added "$pat_json" || true)"
        if [ -n "$hit" ]; then
          matched=1
          matched_text="$hit"
        fi
        ;;
      *)
        continue
        ;;
    esac

    [ "$matched" -eq 0 ] && continue

    case "$action" in
      block) block_now "$name" "$path" "$matched_text" "$rationale" ;;
      warn)  warn_reasons+=("$name|$path|$matched_text|$rationale") ;;
      ask)   ask_reasons+=("$name|$path|$matched_text|$rationale") ;;
    esac
  done < <(own_patterns)
}

# ---- reused scan-edit-write content scan --------------------------------
# Apply scan-edit-write content patterns to the added content of each
# path. Honour the catalogue's skip directives (path_substrings,
# basename_prefixes, content_directive) the same way scan-edit-write does.
scan_with_reused_patterns() {
  local path="$1"
  local content
  content="$(added_lines_for "$path")"
  # #297 fail-closed — mirrors the guard in scan_added_lines; kept here
  # too in case call order ever changes.
  [ "$SCAN_PARSE_ERROR" -eq 1 ] && block_now "diff-parse-error" "$path" "" \
    "could not scope the staged diff for this path (binary content or a diff error) — failing closed"
  [ -z "$content" ] && return 0

  # Skip rules from scan-edit-write catalogue.
  if [ -f "$EDIT_WRITE_PATTERNS_FILE" ]; then
    local sub_globs
    sub_globs="$(jq -r '.skips.path_substrings[]?' "$EDIT_WRITE_PATTERNS_FILE" 2>/dev/null)"
    if [ -n "$sub_globs" ]; then
      while IFS= read -r sub; do
        [ -z "$sub" ] && continue
        case "$path" in *"$sub"*) return 0 ;; esac
      done <<< "$sub_globs"
    fi
    local prefixes
    prefixes="$(jq -r '.skips.basename_prefixes[]?' "$EDIT_WRITE_PATTERNS_FILE" 2>/dev/null)"
    local b
    b="$(basename "$path")"
    if [ -n "$prefixes" ]; then
      while IFS= read -r pfx; do
        [ -z "$pfx" ] && continue
        case "$b" in "$pfx"*) return 0 ;; esac
      done <<< "$prefixes"
    fi
    local directive
    directive="$(jq -r '.skips.content_directive // empty' "$EDIT_WRITE_PATTERNS_FILE" 2>/dev/null)"
    if [ -n "$directive" ] && printf '%s\n' "$content" | head -n 5 | grep -qF -- "$directive"; then
      return 0
    fi
  fi

  while IFS= read -r pat_json; do
    [ -z "$pat_json" ] && continue
    local name match_type action rationale matched=0 matched_text="" ci
    name="$(printf '%s' "$pat_json" | jq -r '.name // empty')"
    match_type="$(printf '%s' "$pat_json" | jq -r '.match_type // empty')"
    action="$(printf '%s' "$pat_json" | jq -r '.action // empty')"
    rationale="$(printf '%s' "$pat_json" | jq -r '.rationale // empty')"
    ci="$(printf '%s' "$pat_json" | jq -r '.case_insensitive // false')"

    case "$match_type" in
      regex)
        local regex grep_flags=("-E" "-m1" "-o")
        regex="$(printf '%s' "$pat_json" | jq -r '.pattern // empty')"
        [ -z "$regex" ] && continue
        [ "$ci" = "true" ] && grep_flags+=("-i")
        if matched_text="$(printf '%s' "$content" | grep "${grep_flags[@]}" -- "$regex" 2>/dev/null)"; then
          [ -n "$matched_text" ] && matched=1
        fi
        ;;
      substring_any)
        while IFS= read -r sub; do
          [ -z "$sub" ] && continue
          case "$content" in *"$sub"*) matched=1; matched_text="$sub"; break ;; esac
        done < <(printf '%s' "$pat_json" | jq -r '.patterns[]?')
        ;;
      *) continue ;;
    esac

    [ "$matched" -eq 0 ] && continue

    case "$action" in
      block) block_now "(scan-edit-write/$name)" "$path" "$matched_text" "$rationale" ;;
      warn)  warn_reasons+=("(scan-edit-write/$name)|$path|$matched_text|$rationale") ;;
    esac
  done < <(edit_write_patterns)
}

# ---- main loop ----------------------------------------------------------
while IFS= read -r path; do
  [ -z "$path" ] && continue

  # path-level skips (snapshot files etc.)
  if is_skipped_path "$path"; then
    log_decision "$HOOK_NAME" "Bash" "skip:path" "allow" "skipped $path by path_substrings"
    continue
  fi

  scan_path_level "$path"
  scan_added_lines "$path"
  scan_with_reused_patterns "$path"
done < "$TO_STAGE_FILE"

# Emit warnings (if any) — the git add proceeds.
if [ "${#warn_reasons[@]}" -gt 0 ]; then
  {
    printf '⚠️  atelier:scan-git-add WARNING\n'
    printf '   Tool: Bash(git add)\n'
    printf '   The following pattern(s) matched but only warn; the add is allowed:\n'
    for w in "${warn_reasons[@]}"; do
      IFS='|' read -r wname wpath wmatch wrationale <<< "$w"
      printf '   - %s in %s\n     match: %s\n     why:   %s\n' "$wname" "$wpath" "$wmatch" "$wrationale"
      log_decision "$HOOK_NAME" "Bash" "$wname" "warn" "warn in $wpath: $wmatch"
    done
  } >&2
fi

# Emit ask (if any). Single combined permission prompt for the operator.
if [ "${#ask_reasons[@]}" -gt 0 ]; then
  reason=""
  for a in "${ask_reasons[@]}"; do
    IFS='|' read -r aname apath amatch _arationale <<< "$a"
    reason+="$aname in $apath — match: ${amatch:0:80}; "
    log_decision "$HOOK_NAME" "Bash" "$aname" "ask" "ask in $apath: $amatch"
  done
  reason="${reason%; }"
  jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
fi

exit 0
