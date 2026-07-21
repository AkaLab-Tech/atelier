#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Intercepts pnpm install/add/update/run
# and scans the proposed change for the patterns catalogued in PLAN.md §3
# threat-model addendum.
#
# This is defence in depth with the per-project .npmrc that /setup-project
# writes (ignore-scripts=true, minimum-release-age=10080, audit-level=
# moderate per PLAN.md §4):
#   - .npmrc is the silent baseline — pnpm enforces it without asking.
#   - This hook surfaces explicit decisions and catches the cases where:
#       (a) the operator (or a transitive dep) re-enables lifecycle scripts,
#       (b) someone disables the .npmrc, or
#       (c) the project never had the .npmrc to begin with.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="safe-package-change"
PATTERNS_FILE="${CLAUDE_PLUGIN_ROOT}/hooks/patterns/safe-package-change.json"

if [ ! -f "$PATTERNS_FILE" ]; then
  log_decision "$HOOK_NAME" "?" "" "allow" "patterns file missing — hook degraded"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded"
  exit 0
fi

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

[ "$tool_name" = "Bash" ] || exit 0
[ -n "$command_str" ] || exit 0

# Only intercept pnpm install / add / update / run, plus explicit rm of
# the lockfile (caught by the lockfile-removal command_regex pattern).
is_pnpm_target=0
case "$command_str" in
  *"pnpm install"*|*"pnpm i "*|*"pnpm add"*|*"pnpm update"*|*"pnpm up "*|*"pnpm run "*) is_pnpm_target=1 ;;
esac
case "$command_str" in
  *"rm "*"pnpm-lock"*) is_pnpm_target=1 ;;
esac
[ "$is_pnpm_target" -eq 1 ] || exit 0

# ---- Decision tracking --------------------------------------------------
declare -a ask_reasons=()
declare -a warn_reasons=()

block_now() {
  local name="$1" subject="$2" match="$3" rationale="$4"
  local preview="${match:0:160}"
  [ "${#match}" -gt 160 ] && preview="$preview…"
  cat >&2 <<MSG
🚫 atelier:safe-package-change BLOCKED
   Tool:    Bash($subject)
   Pattern: $name
   Match:   $preview
   Why:     $rationale
   Rule:    PLAN.md §3 threat-model addendum (safe-package-change catalogue).
   Action:  reconsider the install. Many cases are typosquats / brand-adjacent
            packages, fresh publishes that haven't aged, or lifecycle scripts
            doing unexpected things. If you have a real reason to override,
            the operator can run the command manually after explicit consent.
MSG
  log_decision "$HOOK_NAME" "Bash" "$name" "block" "$name on $subject: $preview"
  exit 2
}

# ---- helpers ------------------------------------------------------------

# Look up a pattern object by name. Returns the JSON object or empty.
pattern_by_name() {
  jq -c --arg n "$1" '.patterns[] | select(.name == $n)' "$PATTERNS_FILE" 2>/dev/null || true
}

# Read the lifecycle-script allowlist once.
lifecycle_allowlist_json() {
  jq -c '.lifecycle_script_allowlist // []' "$PATTERNS_FILE" 2>/dev/null
}

# Return 0 if $pkg is on the lifecycle-script allowlist (allowed to ship
# their own pre/post install steps; only the regex-based block still applies).
# Uses `jq -en` (null-input mode) so we don't need a dummy file — the
# previous `jq -e ... /dev/null` form returned rc=4 (no JSON input read)
# and false-asked every allowlisted package.
is_lifecycle_allowed() {
  local pkg="$1"
  jq -en --arg p "$pkg" --argjson list "$(lifecycle_allowlist_json)" \
    '$list | index($p) | type == "number"' >/dev/null 2>&1
}

# Run `pnpm view <pkg> <field>` with a tight timeout and return its
# stdout. Empty on any failure — callers must tolerate missing data.
pnpm_view() {
  local pkg="$1" field="$2"
  ( timeout 8 pnpm view "$pkg" "$field" --json 2>/dev/null || true )
}

# Resolve a "pkg@spec" arg into its bare name and version spec.
# Handles scopes (@scope/name), pin-style (name@1.2.3), and bare names.
split_pkg() {
  local arg="$1" name spec
  case "$arg" in
    @*/*@*)
      # @scope/name@version
      name="${arg%@*}"
      spec="${arg##*@}"
      ;;
    @*/*)
      # @scope/name (no version)
      name="$arg"
      spec=""
      ;;
    *@*)
      # name@version
      name="${arg%@*}"
      spec="${arg##*@}"
      ;;
    *)
      name="$arg"
      spec=""
      ;;
  esac
  printf '%s\t%s\n' "$name" "$spec"
}

# Levenshtein distance via Python — used for typosquat detection.
levenshtein() {
  python3 - "$1" "$2" <<'PY'
import sys
a, b = sys.argv[1], sys.argv[2]
if a == b:
    print(0); sys.exit()
m, n = len(a), len(b)
if m == 0: print(n); sys.exit()
if n == 0: print(m); sys.exit()
prev = list(range(n + 1))
for i, ca in enumerate(a, 1):
    cur = [i] + [0] * n
    for j, cb in enumerate(b, 1):
        cost = 0 if ca == cb else 1
        cur[j] = min(cur[j-1] + 1, prev[j] + 1, prev[j-1] + cost)
    prev = cur
print(prev[n])
PY
}

# ---- command-level patterns ---------------------------------------------
# Lockfile-removal regex runs against the raw command_str regardless of
# subcommand.
scan_command_level() {
  local lockfile_pat
  lockfile_pat="$(pattern_by_name 'lockfile-removal')"
  [ -z "$lockfile_pat" ] && return 0
  local regex
  regex="$(printf '%s' "$lockfile_pat" | jq -r '.pattern // empty')"
  [ -z "$regex" ] && return 0
  if printf '%s' "$command_str" | grep -Eq -- "$regex"; then
    local rationale
    rationale="$(printf '%s' "$lockfile_pat" | jq -r '.rationale')"
    block_now "lockfile-removal" "$command_str" "$command_str" "$rationale"
  fi
}

# ---- per-package analysis (for `pnpm add <pkgs>` and similar) ----------
analyse_package() {
  local raw="$1" subject="$2"
  local name spec
  IFS=$'\t' read -r name spec < <(split_pkg "$raw")

  # 1. non-ASCII name → block.
  # We use the printable-ASCII range `[ -~]` (space=0x20 to tilde=0x7E)
  # for the negation, because BSD grep (macOS) does NOT expand `\xNN`
  # hex escapes — it treats them as literal sets of {\, x, 0..F, -}.
  # Earlier draft used `[^\x00-\x7F]` and false-positived every package
  # name on macOS; caught in smoke test.
  if printf '%s' "$name" | LC_ALL=C grep -q '[^ -~]'; then
    local pat ration
    pat="$(pattern_by_name 'non-ascii-package-name')"
    ration="$(printf '%s' "$pat" | jq -r '.rationale')"
    block_now "non-ascii-package-name" "$subject" "$name" "$ration"
  fi

  # 2. non-registry version spec → ask.
  # The catalogue pattern uses a PCRE-style negative lookahead which
  # `grep -E` doesn't support, so we evaluate the rule with bash `case`
  # statements instead. The JSON pattern remains as documentation; the
  # authoritative logic lives here.
  if [ -n "$spec" ]; then
    local is_non_registry=0
    case "$spec" in
      git+*|git:*|file:*|*.tgz|*.tar.gz)
        is_non_registry=1
        ;;
      http://*|https://*)
        case "$spec" in
          *"registry.npmjs.org"*) ;;  # canonical registry — fine
          *) is_non_registry=1 ;;
        esac
        ;;
    esac
    if [ "$is_non_registry" -eq 1 ]; then
      local spec_pat ration
      spec_pat="$(pattern_by_name 'non-registry-version-specifier')"
      ration="$(printf '%s' "$spec_pat" | jq -r '.rationale')"
      ask_reasons+=("non-registry-version-specifier|$name|$spec|$ration")
    fi
  fi

  # 3. typosquatting → ask
  local typo_pat max_dist
  typo_pat="$(pattern_by_name 'typosquatting-suspect')"
  max_dist="$(printf '%s' "$typo_pat" | jq -r '.max_distance // 2')"
  local known_pkg
  while IFS= read -r known_pkg; do
    [ -z "$known_pkg" ] && continue
    [ "$known_pkg" = "$name" ] && continue   # exact match is fine
    local d
    d="$(levenshtein "$name" "$known_pkg" 2>/dev/null || echo 99)"
    if [ "$d" -gt 0 ] && [ "$d" -le "$max_dist" ]; then
      local ration
      ration="$(printf '%s' "$typo_pat" | jq -r '.rationale')"
      ask_reasons+=("typosquatting-suspect|$name|near $known_pkg (distance $d)|$ration")
      break
    fi
  done < <(jq -r '.typosquat_known_packages[]?' "$PATTERNS_FILE")

  # 4-6. remote queries (pnpm view). Skip when no network or pnpm missing.
  if ! command -v pnpm >/dev/null 2>&1; then
    log_decision "$HOOK_NAME" "Bash" "skip:no-pnpm" "allow" "pnpm not on PATH, skipping remote checks for $name"
    return 0
  fi

  # 4. package age — block if < min_age_days
  local age_pat min_age_days
  age_pat="$(pattern_by_name 'package-age-under-7-days')"
  min_age_days="$(printf '%s' "$age_pat" | jq -r '.min_age_days // 7')"
  local time_json
  time_json="$(pnpm_view "$name" time 2>/dev/null || true)"
  if [ -n "$time_json" ]; then
    local published_iso
    # Find the earliest version's `time` entry. The `created` entry is the
    # package's first-ever publish, which is what threat-model "first publish"
    # refers to. Fall back to the listed version's timestamp if `created`
    # isn't present.
    published_iso="$(printf '%s' "$time_json" | jq -r '
      if type == "object" then (.created // (to_entries | min_by(.value) | .value)) else empty end
    ' 2>/dev/null || true)"
    if [ -n "$published_iso" ] && [ "$published_iso" != "null" ]; then
      local age_days
      age_days="$(python3 - "$published_iso" "$min_age_days" <<'PY'
import sys, datetime
iso = sys.argv[1]
# Tolerate trailing Z or +00:00.
iso = iso.replace("Z", "+00:00")
try:
    published = datetime.datetime.fromisoformat(iso)
except ValueError:
    print(-1); sys.exit()
now = datetime.datetime.now(datetime.timezone.utc)
delta = (now - published).total_seconds() / 86400
print(int(delta))
PY
)"
      if [ "$age_days" -ge 0 ] && [ "$age_days" -lt "$min_age_days" ]; then
        local ration
        ration="$(printf '%s' "$age_pat" | jq -r '.rationale')"
        block_now "package-age-under-7-days" "$subject" "$name (age=${age_days}d)" "$ration"
      fi
    fi
  fi

  # 5. lifecycle scripts: present (ask, unless allowlisted) + fetch/exec regex (block)
  local lifecycle_pat_present lifecycle_pat_fetch
  lifecycle_pat_present="$(pattern_by_name 'lifecycle-script-added')"
  lifecycle_pat_fetch="$(pattern_by_name 'lifecycle-script-fetch-execute')"
  local fetch_regex
  fetch_regex="$(printf '%s' "$lifecycle_pat_fetch" | jq -r '.pattern // empty')"
  local scripts_json
  scripts_json="$(pnpm_view "$name" scripts 2>/dev/null || true)"
  if [ -n "$scripts_json" ] && [ "$scripts_json" != "{}" ] && [ "$scripts_json" != "null" ]; then
    local lifecycle_keys=("preinstall" "postinstall" "prepare" "install")
    for sk in "${lifecycle_keys[@]}"; do
      local sv
      sv="$(printf '%s' "$scripts_json" | jq -r --arg k "$sk" '.[$k] // empty' 2>/dev/null || true)"
      [ -z "$sv" ] && continue

      # 5a. fetch/exec pattern in the script — block unconditionally
      if [ -n "$fetch_regex" ] && printf '%s' "$sv" | grep -Eq -- "$fetch_regex"; then
        local ration
        ration="$(printf '%s' "$lifecycle_pat_fetch" | jq -r '.rationale')"
        block_now "lifecycle-script-fetch-execute" "$subject" "$name:$sk = $sv" "$ration"
      fi

      # 5b. presence — ask, unless allowlisted
      if is_lifecycle_allowed "$name"; then
        log_decision "$HOOK_NAME" "Bash" "allowlist:lifecycle" "allow" "$name $sk on lifecycle-script allowlist"
      else
        local ration
        ration="$(printf '%s' "$lifecycle_pat_present" | jq -r '.rationale')"
        ask_reasons+=("lifecycle-script-added|$name|$sk: ${sv:0:80}|$ration")
      fi
    done
  fi

  # 6. bin path traversal — block
  local bin_json
  bin_json="$(pnpm_view "$name" bin 2>/dev/null || true)"
  if [ -n "$bin_json" ] && [ "$bin_json" != "null" ]; then
    # bin can be a string (single-entry) or an object {name: path}.
    local bin_values
    bin_values="$(printf '%s' "$bin_json" | jq -r '
      if type == "string" then . elif type == "object" then (.[]) else empty end
    ' 2>/dev/null || true)"
    if [ -n "$bin_values" ]; then
      while IFS= read -r bv; do
        [ -z "$bv" ] && continue
        case "$bv" in
          /*|*../*)
            local bin_pat ration
            bin_pat="$(pattern_by_name 'bin-path-traversal')"
            ration="$(printf '%s' "$bin_pat" | jq -r '.rationale')"
            block_now "bin-path-traversal" "$subject" "$name bin=$bv" "$ration"
            ;;
        esac
      done <<< "$bin_values"
    fi
  fi
}

# ---- local package.json analysis (for `pnpm run <script>`) -------------
analyse_local_run_script() {
  local script_name="$1"
  # Walk up looking for package.json.
  local root="$PWD"
  while [ "$root" != "/" ] && [ ! -f "$root/package.json" ]; do
    root="$(dirname "$root")"
  done
  [ ! -f "$root/package.json" ] && return 0

  local script_val
  script_val="$(jq -r --arg s "$script_name" '.scripts[$s] // empty' "$root/package.json" 2>/dev/null || true)"
  [ -z "$script_val" ] && return 0

  local fetch_pat regex
  fetch_pat="$(pattern_by_name 'lifecycle-script-fetch-execute')"
  regex="$(printf '%s' "$fetch_pat" | jq -r '.pattern // empty')"
  if [ -n "$regex" ] && printf '%s' "$script_val" | grep -Eq -- "$regex"; then
    local ration
    ration="$(printf '%s' "$fetch_pat" | jq -r '.rationale')"
    block_now "lifecycle-script-fetch-execute" "$command_str" "local script $script_name: $script_val" "$ration"
  fi
}

# ---- main dispatch ------------------------------------------------------

# Lockfile-removal scan first (independent of subcommand).
scan_command_level

# Parse subcommand. Extract everything after `pnpm <verb>` up to a
# chained-operator (;, &&, ||, |).
extract_after() {
  local verb="$1"
  printf '%s' "$command_str" \
    | sed -E "s/.*pnpm[[:space:]]+${verb}[[:space:]]*//" \
    | sed -E 's/[[:space:]]*(;|&&|\|\||\|).*//'
}

case "$command_str" in
  *"pnpm add"*)
    args="$(extract_after 'add')"
    # Skip flags and bare options.
    pkgs=()
    for tok in $args; do
      case "$tok" in
        -*) continue ;;
        '') continue ;;
      esac
      pkgs+=("$tok")
    done
    for pkg_arg in "${pkgs[@]}"; do
      analyse_package "$pkg_arg" "pnpm add"
    done
    ;;
  *"pnpm update"*|*"pnpm up "*)
    args="$(extract_after 'update|up')"
    for tok in $args; do
      case "$tok" in -*|'') continue ;; esac
      analyse_package "$tok" "pnpm update"
    done
    ;;
  *"pnpm run "*)
    args="$(extract_after 'run')"
    # First non-flag token is the script name.
    for tok in $args; do
      case "$tok" in -*|'') continue ;; esac
      analyse_local_run_script "$tok"
      break
    done
    ;;
  *"pnpm install"*|*"pnpm i "*)
    # `pnpm install` (no args) only triggers the lockfile-removal check
    # (already done above) and the no-op exit. Lifecycle scripts of every
    # dep COULD be checked here, but that's expensive (one pnpm view per
    # transitive dep) and duplicates what the per-project `.npmrc`
    # `ignore-scripts=true` already blocks. We let install proceed.
    :
    ;;
esac

# ---- emit collected warnings / ask --------------------------------------
if [ "${#warn_reasons[@]}" -gt 0 ]; then
  {
    printf '⚠️  atelier:safe-package-change WARNING\n'
    for w in "${warn_reasons[@]}"; do
      IFS='|' read -r wname wpkg wmatch wration <<< "$w"
      printf '   - %s on %s: %s\n     why: %s\n' "$wname" "$wpkg" "$wmatch" "$wration"
      log_decision "$HOOK_NAME" "Bash" "$wname" "warn" "warn on $wpkg: $wmatch"
    done
  } >&2
fi

if [ "${#ask_reasons[@]}" -gt 0 ]; then
  reason=""
  for a in "${ask_reasons[@]}"; do
    IFS='|' read -r aname apkg amatch _ration <<< "$a"
    reason+="$aname ($apkg): ${amatch:0:80}; "
    log_decision "$HOOK_NAME" "Bash" "$aname" "ask" "ask on $apkg: $amatch"
  done
  reason="${reason%; }"
  jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
fi

exit 0
