#!/usr/bin/env bash
#
# atelier install.sh — single entry-point installer.
#
# Phases (per PLAN.md §2):
#   0    preflight: resolve $ATELIER_CONFIG_DIR + collision check  (M5.0.2)
#   A    base deps (git, gh, fnm, pnpm, jq, fzf) + Claude Code
#   B    Claude + GitHub auth
#   C.1  git-wt, .env* excludes, git identity, shellrc,
#        atelier-setup-project helper symlink, .atelier-managed marker
#   C.2  drive Claude Code to install the atelier plugin
#
# Conventions:
#   - strict mode: `set -euo pipefail` and a defensive IFS.
#   - logging via phase() / log() / sublog() / step_ok() / step_skip() /
#     step_fail() / ok() / warn() / die() helpers (M7.1.F2). ANSI color +
#     Unicode markers (✓ / ↷ / ✗) when stdout is a TTY and NO_COLOR is
#     unset; auto-degrades to plain output otherwise.
#   - all idempotent: every install step short-circuits if the tool is already
#     present on PATH or in its expected install location.
#   - all installs are user-scope (no `sudo` on macOS; minimal `sudo` on apt-
#     based Linux for system packages, never for atelier files).
#   - one function per phase. main() dispatches and prints a final summary.
#
# Tested on: macOS (manual smoke). Linux (apt-based) is best-effort until a
# clean Ubuntu VM run validates it.

set -euo pipefail
IFS=$'\n\t'

# Absolute path of the directory this install.sh lives in (git clone, plugin
# cache, or unpacked tarball — install.sh no longer assumes a clone, #39 F1).
# Computed once at script load; doesn't follow symlinks because the tree the
# operator invoked is the canonical source. resolve_source_root() turns this
# into $ATELIER_SOURCE_ROOT unless the --source-root flag or the
# ATELIER_SOURCE_ROOT env var override it.
_ATELIER_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The tree atelier is installed FROM (#39 F1). Resolved by
# resolve_source_root(): --source-root flag > $ATELIER_SOURCE_ROOT env >
# the directory install.sh lives in. Every phase that used to read from
# "the clone" ($ATELIER_REPO_ROOT pre-#39) reads from here instead.
# NOTE: intentionally not clobbered at load — same rationale as
# $ATELIER_CONFIG_DIR below (the env var is a documented override).

# Set by parse_args. Empty unless --source-root was given on the command line.
ATELIER_SOURCE_ROOT_FLAG=""

# Set by parse_args (--from-cache). Sugar for "the source tree is a plugin-
# cache snapshot": forces SOURCE_MODE=snapshot. Nothing else is skipped —
# every phase runs exactly as in a clone-sourced install.
FROM_CACHE=false

# Set by detect_source_mode(): "clone" when $ATELIER_SOURCE_ROOT is a git
# repo (legacy/dev flow), "snapshot" otherwise (plugin cache, unpacked
# tarball — both are plain trees). Informational in F1/F2: all phases run
# identically in both modes; later phases (#39 F3/F4) branch on it.
SOURCE_MODE=""

# Default path for atelier's isolated Claude config root (M5.0). The operator
# may override via the --config-dir flag or the ATELIER_CONFIG_DIR env var;
# Phase 0 preflight (M5.0.2) resolves the final value into ATELIER_CONFIG_DIR
# and then exports CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR so every claude
# invocation in this script (Phase B auth, Phase C.2 plugin install) lands
# in the right place.
ATELIER_CONFIG_DIR_DEFAULT="${HOME}/.claude-work"

# Set by parse_args. Empty unless --config-dir was given on the command line.
ATELIER_CONFIG_DIR_FLAG=""

# Set by parse_args. true → preflight refuses (rather than prompts) when the
# target directory has unrelated content.
NONINTERACTIVE=false
# When true (--refresh-shellrc), main() re-injects ONLY the shellrc hook block
# and exits — used by atelier-update so shellrc changes (e.g. the atelier()
# entry point) ship without a full install re-run.
REFRESH_SHELLRC_ONLY=false

# M4.23 / M4.27 / M4.28: set true by the phase_c_2_* opt-in steps when the
# operator enables an optional integration, so print_first_steps can surface the
# per-project follow-up.
COOLIFY_SET_UP=false
VERCEL_SET_UP=false
NEON_SET_UP=false

# M7.1.F11b: $ATELIER_CONFIG_DIR is intentionally NOT clobbered here.
# Previous versions had `ATELIER_CONFIG_DIR=""` at this point, which
# silently broke the F11 lookup chain — the operator's exported env var
# (typically set by the shellrc hook block written by a previous install)
# got overwritten with "" before resolve_config_dir() could read it,
# making the env-var branch unreachable.
#
# Either the env var is inherited from the parent shell (the operator's
# chosen path) or it is unset; either way resolve_config_dir() handles
# both states via `${ATELIER_CONFIG_DIR:-}` plus the --config-dir flag
# override plus the default fallback. `set -u` is satisfied because the
# `:-` expansion never tries to substitute an unset bare reference.
#
# Maintainers: do NOT add an unconditional `ATELIER_CONFIG_DIR=""` here.
# If a future refactor needs a "not-yet-resolved" sentinel, route through
# a separate ATELIER_CONFIG_DIR_RESOLVED guard variable rather than
# clobbering the operator-facing one.

# ---------- logging (M7.1.F2) ----------

# Color support detection. Cached once at script load so every helper reads
# the same constants. Honors the https://no-color.org convention plus an
# atelier-specific override (ATELIER_NO_COLOR=1) for parity with --yes /
# ATELIER_AUTO style flags. When color is off, all _C_* expand to empty
# strings — the printf templates stay valid; the output is just plain text.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ -z "${ATELIER_NO_COLOR:-}" ]; then
  _C_RESET=$'\033[0m'
  _C_BOLD=$'\033[1m'
  _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_CYAN=$'\033[36m'
else
  _C_RESET=""; _C_BOLD=""; _C_DIM=""
  _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_CYAN=""
fi

# phase()  : top-of-phase header. Blank line + bold cyan ==> banner. Use this
#            for "Phase 0 / A / B / C.1 / C.2 / Verification" etc.
# log()    : generic top-level message (no implied phase boundary). Bold cyan
#            ==> banner without the leading blank line.
# sublog() : indented sub-step, plain text. Use for narrative ("cloning
#            git-wt..." style lines).
# step_ok(): indented sub-step with a green ✓ — confirms a presence/install
#            check, an idempotent skip, or a single success inside a phase.
# step_skip(): indented sub-step with a dim ↷ — explicitly marks a no-op or
#            skipped check (already installed, already configured, etc.).
# step_fail(): indented sub-step with a red ✗, written to stderr. Non-fatal —
#            use die() for fatal errors.
# warn()   : non-fatal warning, yellow !! prefix, to stderr.
# die()    : fatal error, red !!ERROR prefix, to stderr, exit 1.
# ok()     : end-of-phase confirmation, bold green "OK: ..." marker. Pairs
#            with phase() to bracket each phase visually.
phase() { printf '\n%s%s==> %s%s\n' "$_C_BOLD" "$_C_CYAN" "$*" "$_C_RESET"; }
log()      { printf '%s%s==> %s%s\n'    "$_C_BOLD" "$_C_CYAN"  "$*" "$_C_RESET"; }
sublog()   { printf '    %s\n' "$*"; }
step_ok()  { printf '    %s✓%s %s\n'    "$_C_GREEN"  "$_C_RESET" "$*"; }
step_skip(){ printf '    %s↷%s %s\n'    "$_C_DIM"    "$_C_RESET" "$*"; }
step_fail(){ printf '    %s✗%s %s\n'    "$_C_RED"    "$_C_RESET" "$*" >&2; }
warn()     { printf '%s!!%s %s\n'        "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()      { printf '%s%s!! ERROR: %s%s\n' "$_C_BOLD" "$_C_RED" "$*" "$_C_RESET" >&2; exit 1; }
ok()       { printf '    %s%s✓ %s%s\n'  "$_C_BOLD$_C_GREEN" "" "$*" "$_C_RESET"; }

# ---------- tiny utilities ----------

has() { command -v "$1" >/dev/null 2>&1; }

# M7.1.F3: offer to update an outdated base dep. The decision to detect
# outdatedness is per-dep / per-OS (see callers in phase_a_*) — this helper
# only handles the prompt + the gated update execution. Defaults:
#   - ATELIER_SKIP_UPDATE_PROMPTS=1 → silent skip (info line only).
#   - --yes / no TTY                → silent skip (info line only).
#   - Interactive Y                 → run `update_cmd` via eval (the cmd is
#                                     a string built by the caller, e.g.
#                                     "brew upgrade gh" or "fnm install
#                                     --lts && fnm default lts-latest").
#   - Anything else                 → no-op (info line only).
# Args: $1 dep_name, $2 current_version, $3 latest_version, $4 update_cmd.
_offer_dep_update() {
  local dep="$1" current="$2" latest="$3" update_cmd="$4"
  local notice
  notice="$dep $current (latest $latest available)"
  if [ "${ATELIER_SKIP_UPDATE_PROMPTS:-}" = "1" ]; then
    step_skip "$notice — skipped via ATELIER_SKIP_UPDATE_PROMPTS=1"
    return
  fi
  if $NONINTERACTIVE || [ ! -t 0 ]; then
    step_skip "$notice — non-interactive run; run \`$update_cmd\` manually to update"
    return
  fi
  printf '    %s↷%s %s — update now via %s\`%s\`%s? [y/N]: ' \
    "$_C_YELLOW" "$_C_RESET" "$notice" "$_C_BOLD" "$update_cmd" "$_C_RESET"
  local upd_choice=""
  read -r upd_choice
  case "$upd_choice" in
    y|Y|yes|YES)
      sublog "running: $update_cmd"
      eval "$update_cmd"
      step_ok "updated $dep"
      ;;
    *)
      step_skip "$dep update declined — operator can run \`$update_cmd\` later"
      ;;
  esac
}

# ---------- platform detection ----------

detect_os() {
  case "${OSTYPE:-}" in
    darwin*) printf 'mac\n' ;;
    linux*)  printf 'linux\n' ;;
    *)       die "unsupported OS '${OSTYPE:-unknown}' (atelier supports macOS and Linux)" ;;
  esac
}

# ---------- usage / argparse ----------

usage() {
  cat <<EOF
atelier install.sh — bootstrap a fresh Mac (or apt-based Linux) for atelier.

USAGE:
  install.sh [OPTIONS]

OPTIONS:
  --config-dir <path>   Path for atelier's isolated Claude config root
                        (M5.0). Used as CLAUDE_CONFIG_DIR for every claude
                        invocation in this script, baked into the shellrc
                        hook block, and recorded in scripts/
                        atelier-setup-project for the project registry.
                        Resolution priority: this flag, then the
                        ATELIER_CONFIG_DIR env var, then the default
                        \`~/.claude-work/\`.
  --source-root <path>  Directory to install atelier FROM (scripts/,
                        templates/, .claude-plugin/). Resolution priority:
                        this flag, then the ATELIER_SOURCE_ROOT env var,
                        then the directory install.sh itself lives in.
                        Accepts a git clone (legacy/dev), the Claude Code
                        plugin cache, or an unpacked tarball.
  --from-cache          Declare the source tree a plugin-cache snapshot
                        (forces snapshot mode even if a .git dir is
                        somehow present). All phases still run — this is
                        only a mode hint used by the repo-less install
                        flow (#39).
  --yes, -y             Non-interactive mode. The preflight collision
                        check refuses (rather than prompts) if the target
                        config dir already has unrelated content.
  --refresh-shellrc     Re-inject ONLY the atelier shellrc hook block (the
                        PATH / env exports + task() / atelier() functions)
                        and exit — no deps, auth, or plugin work. Used by
                        atelier-update so shellrc changes propagate without a
                        full re-install. Idempotent (no-ops if up to date).
  --help, -h            Show this help and exit.
EOF
}

# M7.1.F1: the preflight + marker design contract (formerly printed in
# `--help`) lives as code comments instead — see `preflight_check()`,
# `mark_install_started()`, and `phase_0_preflight()` for the canonical
# state machine and the `--yes` non-interactive branch. Operator-facing
# help should not leak internal design-doc text.

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --config-dir)
        [ -n "${2:-}" ] || die "--config-dir requires a path"
        ATELIER_CONFIG_DIR_FLAG="$2"; shift 2 ;;
      --config-dir=*)
        ATELIER_CONFIG_DIR_FLAG="${1#--config-dir=}"; shift ;;
      --source-root)
        [ -n "${2:-}" ] || die "--source-root requires a path"
        ATELIER_SOURCE_ROOT_FLAG="$2"; shift 2 ;;
      --source-root=*)
        ATELIER_SOURCE_ROOT_FLAG="${1#--source-root=}"; shift ;;
      --from-cache)
        FROM_CACHE=true; shift ;;
      --yes|-y)
        NONINTERACTIVE=true; shift ;;
      --refresh-shellrc)
        REFRESH_SHELLRC_ONLY=true; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        die "unknown argument: $1 (try --help)" ;;
    esac
  done
}

resolve_config_dir() {
  # Persistence model (M7.1.F11): the resolved $ATELIER_CONFIG_DIR is baked
  # into the shellrc hook block written by phase_c_1_shellrc_hooks. On every
  # subsequent login, `source ~/.zshrc` (or ~/.bashrc) exports
  # ATELIER_CONFIG_DIR for the operator's shell. Downstream tools
  # (atelier-uninstall, atelier-setup-project, /doctor's bash calls) inherit
  # the env var and resolve the same path.
  #
  # Priority: --config-dir flag > $ATELIER_CONFIG_DIR env > default. The env
  # var branch covers the case where the operator picked an alternative path
  # in a previous run's Phase 0 prompt: their shellrc now exports that path,
  # and install.sh on re-run picks it up automatically (no Phase 0 prompt).
  if [ -n "$ATELIER_CONFIG_DIR_FLAG" ]; then
    ATELIER_CONFIG_DIR="$ATELIER_CONFIG_DIR_FLAG"
  elif [ -n "${ATELIER_CONFIG_DIR:-}" ]; then
    : # use existing env var value
  else
    ATELIER_CONFIG_DIR="$ATELIER_CONFIG_DIR_DEFAULT"
  fi
  # Expand leading ~ tilde if present (operator may type `~/.foo`).
  ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR/#\~/$HOME}"
  export ATELIER_CONFIG_DIR
}

# ---------- source root + mode (#39 F1) ----------

# Resolve $ATELIER_SOURCE_ROOT — the tree atelier installs FROM. Single
# shared concept for every source-reading phase (templates, helper scripts,
# the runtime-dir copy in Phase C.1). Priority: --source-root flag >
# $ATELIER_SOURCE_ROOT env > the directory install.sh lives in (today's
# behavior). The resolved path must exist and look like an atelier tree
# (scripts/ + .claude-plugin/plugin.json) so a typo'd flag fails here with
# a clear message instead of half-way through Phase C.1.
resolve_source_root() {
  if [ -n "$ATELIER_SOURCE_ROOT_FLAG" ]; then
    ATELIER_SOURCE_ROOT="$ATELIER_SOURCE_ROOT_FLAG"
  elif [ -n "${ATELIER_SOURCE_ROOT:-}" ]; then
    : # use existing env var value
  else
    ATELIER_SOURCE_ROOT="$_ATELIER_SCRIPT_DIR"
  fi
  # Expand leading ~ tilde if present, then normalize to an absolute
  # physical path (symlink-free) so comparisons and copies are stable.
  ATELIER_SOURCE_ROOT="${ATELIER_SOURCE_ROOT/#\~/$HOME}"
  [ -d "$ATELIER_SOURCE_ROOT" ] \
    || die "source root '$ATELIER_SOURCE_ROOT' is not a directory (from --source-root / \$ATELIER_SOURCE_ROOT)"
  ATELIER_SOURCE_ROOT="$(cd -P "$ATELIER_SOURCE_ROOT" && pwd)"
  if [ ! -d "$ATELIER_SOURCE_ROOT/scripts" ] || [ ! -f "$ATELIER_SOURCE_ROOT/.claude-plugin/plugin.json" ]; then
    die "source root '$ATELIER_SOURCE_ROOT' does not look like an atelier tree (missing scripts/ or .claude-plugin/plugin.json)"
  fi
  export ATELIER_SOURCE_ROOT
}

# Detect how the source tree is delivered. "clone" — a git repo (the
# legacy/dev flow, includes worktrees); "snapshot" — a plain tree (Claude
# Code plugin cache, unpacked tarball). --from-cache short-circuits to
# snapshot. Sets the SOURCE_MODE global; behavior-neutral in F1/F2.
detect_source_mode() {
  if [ "$FROM_CACHE" = true ]; then
    SOURCE_MODE="snapshot"
  elif git -C "$ATELIER_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    SOURCE_MODE="clone"
  else
    SOURCE_MODE="snapshot"
  fi
}

# ---------- install-status marker (M7.1.F6) ----------

# Plant an in_progress marker as soon as install commits to writing under
# $ATELIER_CONFIG_DIR. Subsequent install runs read this in preflight_check
# and offer "Resume previous install?" instead of treating a partially-
# populated directory as an unrelated-content collision (M5.0.2 trap).
mark_install_started() {
  mkdir -p "$ATELIER_CONFIG_DIR"
  cat > "$ATELIER_CONFIG_DIR/.atelier-managed" <<MARKER
{
  "managedBy": "atelier",
  "installStatus": "in_progress",
  "pid": $$,
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "atelierConfigDir": "$ATELIER_CONFIG_DIR"
}
MARKER
}

# Stamp the marker installStatus=complete after every phase succeeds. Only
# after this runs does the install count as idempotent-reusable on the next
# install.sh invocation. Called from main() after phase_verify.
mark_install_complete() {
  cat > "$ATELIER_CONFIG_DIR/.atelier-managed" <<MARKER
{
  "managedBy": "atelier",
  "installStatus": "complete",
  "completedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "installerVersion": "0.1.0",
  "atelierConfigDir": "$ATELIER_CONFIG_DIR"
}
MARKER
}

# ---------- phase 0: preflight (M5.0.2) ----------

# Return 0 if $1 (path) is safe to use as atelier's config dir; 1 if it has
# unrelated content; 2 if it has an in_progress marker from a crashed
# previous install (M7.1.F6 — resumable). Safe-without-prompt states:
# doesn't exist, exists but empty, contains a complete/legacy
# .atelier-managed marker, or contains plugins/<*>/atelier/.
preflight_check() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  [ -z "$(ls -A "$dir" 2>/dev/null)" ] && return 0
  if [ -f "$dir/.atelier-managed" ]; then
    # M7.1.F6: in_progress means a previous install crashed mid-flight.
    # Surface that to phase_0_preflight so it can offer a resume prompt
    # instead of treating the half-populated dir as opaque collision.
    if grep -q '"installStatus"[[:space:]]*:[[:space:]]*"in_progress"' "$dir/.atelier-managed" 2>/dev/null; then
      return 2
    fi
    return 0
  fi
  # Glob expands to nothing if no match; the nullglob behaviour is the
  # safe path. Wrap in a subshell so set -e + nullglob don't leak out.
  if ( shopt -s nullglob; matches=("$dir/plugins"/*/atelier); [ ${#matches[@]} -gt 0 ] ); then
    return 0
  fi
  return 1
}

phase_0_preflight() {
  phase "Phase 0 — preflight: atelier config dir collision check"
  while true; do
    local pf_status=0
    preflight_check "$ATELIER_CONFIG_DIR" || pf_status=$?

    case $pf_status in
      0)
        sublog "atelier config dir OK: $ATELIER_CONFIG_DIR"
        mark_install_started
        return 0
        ;;
      2)
        # M7.1.F6: previous install left an in_progress marker. Offer to
        # resume rather than asking for an alternative path.
        warn "previous atelier install at $ATELIER_CONFIG_DIR did not complete"
        warn "(marker says installStatus: in_progress)"
        if $NONINTERACTIVE; then
          sublog "non-interactive mode: resuming previous install"
          mark_install_started
          return 0
        fi
        printf "    resume previous install? [Y/abort]: " >&2
        local resume=""
        read -r resume
        case "$resume" in
          ""|y|Y|yes|YES)
            sublog "resuming previous install"
            mark_install_started
            return 0
            ;;
          *)
            die "aborted by operator"
            ;;
        esac
        ;;
      *)
        warn "atelier wants to install under $ATELIER_CONFIG_DIR but that"
        warn "directory already contains content that does not look like atelier:"
        ls -A "$ATELIER_CONFIG_DIR" 2>/dev/null | head -10 | sed 's/^/      /' >&2

        if $NONINTERACTIVE; then
          die "non-interactive mode refuses to proceed.

   Options:
     1. Re-run with --config-dir <path> pointing at an empty or atelier-
        managed directory.
     2. Set ATELIER_CONFIG_DIR=<path> before running install.sh.
     3. Manually clear / move \$ATELIER_CONFIG_DIR's contents and re-run.
     4. Re-run install.sh interactively (without --yes / -y) to be
        prompted for an alternative path."
        fi

        # Interactive: ask operator for an alternative.
        # M7.1.F8: sample paths shown WITHOUT trailing slash. Operators tend
        # to copy the pattern; storing the path with `/` suffix produces
        # `//` everywhere it's concatenated.
        printf "    pick an alternative path (e.g. ~/.claude-atelier, ~/.atelier): " >&2
        local answer=""
        read -r answer
        # M7.1.F8: format validation BEFORE storing. Empty / whitespace /
        # tilde-resolve / trailing-slash strip / non-directory rejection.
        # Failed validations re-prompt (continue) — no death-spiral exits.
        [ -n "$answer" ] || { warn "empty path, try again"; continue; }
        case "$answer" in
          *[[:space:]]*)
            warn "path contains whitespace; please use a path without spaces"
            continue
            ;;
        esac
        # Expand leading `~` to $HOME so subsequent checks see the real path.
        answer="${answer/#\~/$HOME}"
        # Strip trailing `/` so concatenations don't produce `//`.
        answer="${answer%/}"
        # Reject explicit non-directory existing entries (a file at this path
        # would break `mkdir -p` later, or worse, get treated as the config
        # root). Non-existent paths are fine — Phase C.1 creates them.
        if [ -e "$answer" ] && [ ! -d "$answer" ]; then
          warn "$answer exists but is not a directory; please pick a different path"
          continue
        fi
        ATELIER_CONFIG_DIR="$answer"
        export ATELIER_CONFIG_DIR
        sublog "trying $ATELIER_CONFIG_DIR ..."
        ;;
    esac
  done
}

# ---------- phase A: base deps + Claude Code ----------

phase_a_mac_deps() {
  if ! has brew; then
    die "Homebrew is required on macOS. Install it from https://brew.sh and re-run install.sh."
  fi

  local formulas=(git gh fnm jq fzf)
  local missing=()
  for f in "${formulas[@]}"; do
    if has "$f"; then
      step_skip "$f already installed"
    else
      missing+=("$f")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    sublog "installing via brew: ${missing[*]}"
    brew install "${missing[@]}"
  fi

  # M7.1.F3: offer updates for the brew-installed deps atelier cares about
  # most (gh + fnm — most likely to drift; git/jq/fzf are stable enough that
  # a stale version doesn't change atelier's behavior). A single
  # `brew outdated --json --formula` call lists outdated formulae; we
  # iterate the ones we care about + ask the operator per formula.
  if has brew; then
    local outdated_json
    outdated_json="$(brew outdated --json --formula 2>/dev/null || printf '{}')"
    local pkg
    for pkg in gh fnm; do
      if has "$pkg" && printf '%s' "$outdated_json" | jq -e --arg p "$pkg" '.formulae[]? | select(.name == $p)' >/dev/null 2>&1; then
        local current latest
        current="$(printf '%s' "$outdated_json" | jq -r --arg p "$pkg" '.formulae[] | select(.name == $p) | .installed_versions[0] // ""')"
        latest="$(printf '%s' "$outdated_json" | jq -r --arg p "$pkg" '.formulae[] | select(.name == $p) | .current_version // ""')"
        [ -n "$current" ] && [ -n "$latest" ] && _offer_dep_update "$pkg" "$current" "$latest" "brew upgrade $pkg"
      fi
    done
  fi
}

phase_a_linux_deps() {
  if ! has apt-get; then
    die "atelier install.sh currently supports apt-based Linux (Debian, Ubuntu). For Fedora/RHEL/Alpine, install the deps manually (git gh jq fzf) and a recent Node via fnm, then re-run install.sh — it will detect them and skip ahead."
  fi

  # git, jq, fzf are in default apt repos.
  # `unzip` is required by fnm's official installer below.
  local apt_packages=(git jq fzf curl unzip)
  local missing_apt=()
  for p in "${apt_packages[@]}"; do
    if has "$p"; then
      step_skip "$p already installed"
    else
      missing_apt+=("$p")
    fi
  done

  if [ ${#missing_apt[@]} -gt 0 ]; then
    sublog "installing via apt-get: ${missing_apt[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing_apt[@]}"
  fi

  # gh: official GitHub repo (the apt default is often outdated).
  if has gh; then
    step_skip "gh already installed"
  else
    sublog "installing gh from GitHub's official apt repo"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y gh
  fi

  # fnm: no apt package; use the official installer. `--skip-shell` keeps the
  # shellrc edits out of Phase A — Phase C.1 owns shellrc injection.
  if has fnm; then
    step_skip "fnm already installed"
  else
    sublog "installing fnm via its official installer (no shellrc edit yet)"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
    # Make fnm available for the remainder of this script run.
    export PATH="${HOME}/.local/share/fnm:${PATH}"
  fi

  # M7.1.F3: offer update for gh on apt-based systems. `apt list
  # --upgradable` lists upgradable packages; we grep for `gh/` and parse the
  # versions to feed _offer_dep_update. fnm is not apt-managed (curl
  # installer above), so it's skipped here — operator updates via the same
  # curl|bash with a new version.
  if has apt-get && has gh; then
    local upgradable_line
    upgradable_line="$(apt list --upgradable 2>/dev/null | grep -E '^gh/' | head -1 || true)"
    if [ -n "$upgradable_line" ]; then
      local latest current
      # Format: gh/now 2.92.0 amd64 [upgradable from: 2.85.0]
      latest="$(printf '%s' "$upgradable_line" | awk '{print $2}')"
      current="$(printf '%s' "$upgradable_line" | sed -n 's/.*upgradable from: \([^]]*\)\].*/\1/p')"
      [ -n "$current" ] && [ -n "$latest" ] && _offer_dep_update gh "$current" "$latest" "sudo apt-get update && sudo apt-get install -y gh"
    fi
  fi
}

phase_a_node_and_pnpm() {
  # fnm should be on PATH at this point (either already installed or just
  # installed above). Activate it for this shell so `node` and `corepack` work.
  if has fnm; then
    eval "$(fnm env --shell bash)"
  else
    die "fnm not on PATH after install attempt — aborting"
  fi

  if ! has node; then
    sublog "installing latest LTS Node via fnm"
    fnm install --lts
    fnm default lts-latest
    # Re-activate so the freshly installed node lands on PATH.
    eval "$(fnm env --shell bash)"
  else
    step_skip "node already available ($(node --version))"
  fi

  if has pnpm; then
    step_skip "pnpm already installed ($(pnpm --version))"
  else
    sublog "enabling pnpm via corepack"
    corepack enable
    corepack prepare pnpm@latest --activate
  fi
}

phase_a_claude_code() {
  if has claude; then
    local v
    v="$(claude --version 2>/dev/null || echo unknown)"
    step_skip "Claude Code already installed ($v)"
    return
  fi

  # The `curl|bash` pattern is in the agent-level deny-list (PLAN.md §3), but
  # install.sh runs in the operator's terminal *before* atelier's agent layer
  # is active, so it falls outside that scope. The installer is hosted by
  # Anthropic on a domain we already trust (claude.ai) and the binary it lands
  # is GPG-signed by Anthropic (see https://code.claude.com/docs/en/setup).
  sublog "installing Claude Code via the official native installer"
  sublog "(see https://code.claude.com/docs/en/setup, 'Native Install')"
  curl -fsSL https://claude.ai/install.sh | bash
}

phase_a_chrome_optional() {
  # The atelier plugin ships an MCP server (mcp__plugin_atelier_playwright)
  # that uses the operator's system Chrome by default for visual validation
  # by the implementer and reviewer agents on UI tasks. If Chrome is missing,
  # the MCP returns an actionable error on first call but does NOT auto-
  # download. This step pre-flights the dependency: detect Chrome; if absent
  # and a TTY is available, prompt; otherwise warn and continue.
  local os chrome_found=false
  os="$(detect_os)"

  case "$os" in
    mac)
      if [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]; then
        chrome_found=true
      fi
      ;;
    linux)
      if has google-chrome || has google-chrome-stable; then
        chrome_found=true
      fi
      ;;
  esac

  if $chrome_found; then
    step_ok "system Chrome detected (used by mcp__plugin_atelier_playwright)"
    return
  fi

  # Chrome missing. Non-interactive (--yes or no TTY): warn + continue.
  if [ "$NONINTERACTIVE" = true ] || [ ! -t 0 ]; then
    warn "system Chrome not detected — mcp__plugin_atelier_playwright will fail on first call until installed"
    sublog "install later with one of:"
    sublog "    npx @playwright/mcp@latest install-browser chrome"
    case "$os" in
      mac)   sublog "    brew install --cask google-chrome" ;;
      linux) sublog "    sudo apt-get install -y google-chrome-stable    # (or your distro's equivalent)" ;;
    esac
    sublog "/doctor 4.f will warn you until installed"
    return
  fi

  # Interactive prompt path.
  echo
  sublog "atelier's playwright MCP needs system Chrome for visual validation"
  sublog "by the implementer and reviewer agents on UI tasks."
  echo
  case "$os" in
    mac)
      local ans
      read -r -p "    Install Google Chrome now via 'brew install --cask google-chrome'? [Y/n]: " ans
      case "${ans:-Y}" in
        [Yy]|[Yy][Ee][Ss])
          sublog "installing Google Chrome via brew cask"
          if brew install --cask google-chrome; then
            ok "Google Chrome installed"
          else
            warn "brew install --cask google-chrome failed — install continues. Install Chrome manually before using UI tasks."
          fi
          ;;
        *)
          sublog "skipped — install later with: brew install --cask google-chrome (or npx @playwright/mcp@latest install-browser chrome). /doctor will warn you."
          ;;
      esac
      ;;
    linux)
      # Linux Chrome install varies by distro and usually needs adding a repo;
      # not safe to automate generically here. Surface the instruction.
      sublog "Chrome install on Linux depends on your distro — install manually if you need the playwright MCP:"
      sublog "    apt:  sudo apt-get install -y google-chrome-stable"
      sublog "    rpm:  sudo yum install -y google-chrome-stable"
      sublog "    or:   npx @playwright/mcp@latest install-browser chrome"
      sublog "/doctor 4.f will warn you until installed."
      ;;
  esac
}

phase_a_docker_compose_optional() {
  # atelier's docker-env skill (M4.17) issues `docker compose -p ... up/down/...`
  # with v2 syntax. If the docker client lacks the compose plugin, the skill
  # fails on first lifecycle call. This step pre-flights: detect `docker compose`
  # v2 reachability; if missing and a TTY is available, prompt; otherwise warn
  # and continue.
  #
  # Note: this step does NOT install a Docker runtime (Docker Desktop / Colima /
  # OrbStack) — operator's choice per existing policy. Only the compose plugin
  # is in scope.
  local os
  os="$(detect_os)"

  # If `docker` itself isn't on PATH, there's no compose plugin to find. Skip
  # the check entirely (no atelier task can use docker-env without a runtime).
  if ! has docker; then
    sublog "docker CLI not on PATH — skipping docker compose plugin check (install a runtime first)"
    return
  fi

  if docker compose version >/dev/null 2>&1; then
    step_ok "docker compose v2 plugin detected (used by docker-env skill)"
    return
  fi

  # Plugin missing. Non-interactive (--yes or no TTY): warn + continue.
  if [ "$NONINTERACTIVE" = true ] || [ ! -t 0 ]; then
    warn "docker compose v2 plugin not detected — docker-env skill will fail on first lifecycle call until installed"
    case "$os" in
      mac)
        sublog "install later with:"
        sublog "    brew install docker-compose"
        sublog "    mkdir -p ~/.docker/cli-plugins"
        sublog "    ln -sf /opt/homebrew/lib/docker/cli-plugins/docker-compose ~/.docker/cli-plugins/docker-compose"
        ;;
      linux)
        sublog "install later with:"
        sublog "    sudo apt-get install docker-compose-plugin    # (or your distro's equivalent)"
        ;;
    esac
    sublog "/doctor 4.g will warn you until installed"
    return
  fi

  # Interactive prompt path.
  echo
  sublog "atelier's docker-env skill needs the docker compose v2 plugin"
  sublog "for tasks that scaffold containerized services (Postgres, Redis, etc.)."
  echo
  case "$os" in
    mac)
      local ans
      read -r -p "    Install docker compose v2 now via 'brew install docker-compose' + symlink? [Y/n]: " ans
      case "${ans:-Y}" in
        [Yy]|[Yy][Ee][Ss])
          sublog "installing docker-compose via brew"
          if brew install docker-compose; then
            mkdir -p "$HOME/.docker/cli-plugins"
            if [ -f "/opt/homebrew/lib/docker/cli-plugins/docker-compose" ]; then
              ln -sf /opt/homebrew/lib/docker/cli-plugins/docker-compose "$HOME/.docker/cli-plugins/docker-compose"
              ok "docker compose v2 plugin installed + symlinked"
            else
              warn "brew install succeeded but plugin binary not found at expected path — symlink skipped. Run: ln -sf <plugin-binary> ~/.docker/cli-plugins/docker-compose"
            fi
          else
            warn "brew install docker-compose failed — install continues. Install the plugin manually before using docker-env tasks."
          fi
          ;;
        *)
          sublog "skipped — install later via the commands above. /doctor 4.g will warn you."
          ;;
      esac
      ;;
    linux)
      sublog "docker compose plugin install on Linux depends on your distro — install manually if you need docker-env tasks:"
      sublog "    apt:  sudo apt-get install docker-compose-plugin"
      sublog "    rpm:  sudo dnf install docker-compose-plugin    # or your distro's equivalent"
      sublog "/doctor 4.g will warn you until installed."
      ;;
  esac
}

phase_a() {
  phase "Phase A — base dependencies + Claude Code"
  local os
  os="$(detect_os)"
  case "$os" in
    mac)   phase_a_mac_deps ;;
    linux) phase_a_linux_deps ;;
  esac
  phase_a_node_and_pnpm
  phase_a_claude_code
  phase_a_chrome_optional
  phase_a_docker_compose_optional
  ok "Phase A complete"
}

# ---------- phase B: authentication ----------

# M7.1.F43 — verify the atelier-scoped Claude token works against the real
# Anthropic API, not just the local .claude.json. `claude auth status`
# returns success whenever the file is present and well-formed, even when
# the OAuth token has been expired/revoked server-side. This helper
# returns 0 if a minimal `claude -p` API call succeeds, 1 if it returns
# api_error_status (401 typically). Cost: ~3s and $0 in tokens on
# failure (the model is never invoked when auth fails first); ~3s and a
# trivial token cost (~50 input + ~5 output) on success.
_phase_b_claude_api_ping() {
  local response api_status
  response="$(CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude -p "ok" --output-format json --max-turns 1 2>/dev/null || true)"
  api_status="$(printf '%s' "$response" | jq -r '.api_error_status // empty' 2>/dev/null)"
  [ -z "$api_status" ]
}

phase_b_claude_login() {
  # M7.1.F42 — All `claude auth …` calls below are scoped to atelier's
  # CLAUDE_CONFIG_DIR ($ATELIER_CONFIG_DIR), NOT the operator's personal
  # ~/.claude/. Before F42 these calls ran without the env override, which
  # meant install.sh would happily report "already authenticated" by
  # reading the operator's personal config — leaving
  # $ATELIER_CONFIG_DIR/.claude.json potentially empty or with an expired
  # token.
  #
  # M7.1.F43 — even with F42 in place, `claude auth status` is a local-only
  # check that does not validate the token against the Anthropic API. An
  # expired or revoked token still produces a success here, and the operator
  # only finds out when an `atelier`-launched session fails with 401. Phase B
  # now does a real API ping via `_phase_b_claude_api_ping` after the
  # local check passes, and forces a fresh login if the deep check returns
  # api_error_status. The browser opens, the operator re-authenticates, and
  # the next session works.
  #
  # `claude auth status` exits 0 if authenticated, non-0 otherwise. This is
  # the idempotency hinge — re-runs of install.sh on an already-logged-in
  # machine short-circuit here without touching the browser.
  if CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth status >/dev/null 2>&1; then
    # Deep-check before declaring victory: a local "logged in" answer can be
    # stale if the OAuth token has been revoked or expired server-side.
    sublog "verifying atelier Claude token against the Anthropic API (~3s)..."
    if _phase_b_claude_api_ping; then
      # M7.1.F4: offer to switch accounts. Skip the prompt in non-interactive
      # mode (--yes / no TTY) — keep the existing account silently.
      if $NONINTERACTIVE || [ ! -t 0 ]; then
        step_skip "atelier Claude Code already authenticated (token verified, keeping existing account)"
        return
      fi
      local current=""
      current="$(CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth status 2>&1 | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1 || true)"
      if [ -n "$current" ]; then
        printf '    atelier Claude Code already authenticated as %s%s%s (token verified). Keep (Y) or switch to another account (s)? [Y/s]: ' "$_C_BOLD" "$current" "$_C_RESET"
      else
        printf '    atelier Claude Code already authenticated (token verified). Keep current account (Y) or switch (s)? [Y/s]: '
      fi
      local switch_choice=""
      read -r switch_choice
      case "$switch_choice" in
        s|S|switch|SWITCH)
          sublog "logging out current atelier Claude account, fresh login coming up"
          CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth logout 2>/dev/null || true
          sublog "starting atelier Claude Code login (a browser tab will open)"
          CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth login
          ;;
        *)
          step_skip "atelier Claude Code already authenticated (keeping existing account)"
          ;;
      esac
      return
    fi
    # Local says yes, API says 401 — token expired or revoked.
    warn "atelier Claude token is present but Anthropic API rejected it (401 — token expired or revoked)"
    warn "logging out the stale credentials and starting a fresh login"
    CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth logout 2>/dev/null || true
    if $NONINTERACTIVE || [ ! -t 0 ]; then
      die "no TTY available to complete the browser-based login. Re-run \`./install.sh\` from a real terminal, or run by hand: CLAUDE_CONFIG_DIR=\"$ATELIER_CONFIG_DIR\" claude auth login"
    fi
    sublog "starting atelier Claude Code login (a browser tab will open)"
    CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth login
    return
  fi
  sublog "starting atelier Claude Code login (a browser tab will open) — this is separate from your personal ~/.claude/ login"
  CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth login
}

# Authenticate one of the two atelier-isolated `gh` identities (M5.0.1). Each
# identity owns a dedicated config dir under $ATELIER_CONFIG_DIR/gh/<role>/, so
# the operator's primary `gh` at ~/.config/gh/ is never touched by install.sh.
# Idempotent: if `gh auth status` reports OK for the given config dir, the
# browser-based OAuth is skipped on re-runs.
#
# Args: $1 = role (`author` | `reviewer`), $2 = human-friendly purpose string
#       used in the prompt so the operator knows which account they're signing
#       in with on this round.
# M7.1.F5: before each `gh auth login`, print a labeled requirements block
# so the non-technical operator knows what GitHub account to pick and what
# access it must have. Different access requirements per role:
#   - author   : push + PR open + issue ops on every repo atelier will touch.
#   - reviewer : at minimum read + review (approve / comment) on the same
#                repos; must be a DIFFERENT GitHub account than author so
#                approvals are honoured (PLAN.md dogfood-1 Finding #11).
# Org reminder applies to both. The operator hits Enter to confirm they've
# read the block before the device-code prompt opens.
_phase_b_print_gh_permissions() {
  local role="$1"
  printf '\n'
  printf '    %s%sBefore you sign in (role: %s):%s\n' "$_C_BOLD" "$_C_YELLOW" "$role" "$_C_RESET"
  case "$role" in
    author)
      printf '      - Purpose: atelier commits + pushes + opens PRs + manages issues under this account.\n'
      printf '      - Required access: %spush%s on every project repo atelier will touch.\n' "$_C_BOLD" "$_C_RESET"
      ;;
    reviewer)
      printf '      - Purpose: atelier-reviewer agent approves PRs opened by the author identity.\n'
      printf '      - Required access: at least %sread + review%s on every project repo.\n' "$_C_BOLD" "$_C_RESET"
      printf '      - MUST be a DIFFERENT GitHub account than the author identity (PLAN.md dogfood-1 Finding #11).\n'
      ;;
  esac
  printf '      - If the project lives under a GitHub org, this account must be a member or invited collaborator BEFORE this login — otherwise pushes/PRs/approvals fail later with confusing errors.\n'
  printf '      - Docs: see PLAN.md §2 step 5 (HTTPS-only, OAuth scopes) and M6.4 troubleshooting (when added).\n'
  printf '\n'
  printf '    Press Enter when ready, or Ctrl+C to abort and adjust the account: '
  local _ack=""
  read -r _ack
}

phase_b_atelier_gh_login() {
  local role="$1"
  local purpose="$2"
  local cfg="$ATELIER_CONFIG_DIR/gh/$role"

  mkdir -p "$cfg"

  if GH_CONFIG_DIR="$cfg" gh auth status --hostname github.com >/dev/null 2>&1; then
    # M7.1.F4: offer to switch accounts. Skip the prompt in non-interactive
    # mode (--yes / no TTY) — keep the existing account silently.
    if $NONINTERACTIVE || [ ! -t 0 ]; then
      step_skip "atelier gh ($role) already authenticated (keeping existing account)"
      return
    fi
    local current_login=""
    current_login="$(GH_CONFIG_DIR="$cfg" gh api user --jq .login 2>/dev/null || true)"
    if [ -n "$current_login" ]; then
      printf '    atelier gh (%s) already authenticated as %s@%s%s. Keep (Y) or switch to another account (s)? [Y/s]: ' "$role" "$_C_BOLD" "$current_login" "$_C_RESET"
    else
      printf '    atelier gh (%s) already authenticated. Keep current account (Y) or switch (s)? [Y/s]: ' "$role"
    fi
    local switch_choice=""
    read -r switch_choice
    case "$switch_choice" in
      s|S|switch|SWITCH)
        sublog "logging out current gh $role account, fresh login coming up"
        GH_CONFIG_DIR="$cfg" gh auth logout --hostname github.com 2>/dev/null || true
        # Fall through to the login block below.
        ;;
      *)
        step_skip "atelier gh ($role) already authenticated (keeping existing account)"
        return
        ;;
    esac
  fi

  sublog "atelier gh login: $role — $purpose"
  sublog "credentials will be stored under $cfg (isolated from ~/.config/gh/)"
  # M7.1.F5: explain GitHub access requirements + wait for explicit Enter
  # so the operator picks the right account on the device-code page.
  _phase_b_print_gh_permissions "$role"
  # --web              browser-based OAuth.
  # --git-protocol https  HTTPS only — atelier never uses SSH (PLAN.md §2 step 5).
  # --skip-ssh-key     defense-in-depth: even if a future flag combo would
  #                    suggest an SSH key prompt, skip it.
  # --scopes           per PLAN.md §2 step 5.
  GH_CONFIG_DIR="$cfg" gh auth login \
    --hostname github.com \
    --git-protocol https \
    --web \
    --skip-ssh-key \
    --scopes "repo,workflow,project,read:org"
}

phase_b_atelier_author_login() {
  phase_b_atelier_gh_login "author" \
    "the GitHub account atelier uses for commits, push, and PR/issue authoring"

  # Register `gh` as git credential helper for HTTPS, using the author config
  # dir as the source of credentials. `gh auth git-credential` reads
  # $GH_CONFIG_DIR at invocation time, so the helper line written into the
  # global gitconfig is dynamic: with $GH_CONFIG_DIR exported (the `task()`
  # alias does this), git uses the atelier-author token; without it, git falls
  # back to ~/.config/gh/ — i.e. the operator's normal shell outside atelier.
  # Idempotent.
  sublog "registering gh (atelier-author) as git credential helper (HTTPS, idempotent)"
  GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh auth setup-git
}

phase_b_atelier_reviewer_login() {
  phase_b_atelier_gh_login "reviewer" \
    "a SECOND GitHub account, distinct from the author one (so reviewer approvals are honoured by GitHub instead of being downgraded to comments — Finding #11 from dogfood-1)"
  # No `gh auth setup-git` here — the reviewer never pushes; one credential
  # helper registration (author's) is enough.
}

# Compare the GitHub login names recorded in $ATELIER_CONFIG_DIR/gh/{author,
# reviewer}/. When they match (or either lookup fails), warn the operator that
# Finding #11 will persist for this install; do NOT abort — the operator may
# intentionally accept a single-identity setup and merge PRs manually.
phase_b_verify_distinct_identities() {
  local author reviewer
  author="$(GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"   gh api user --jq .login 2>/dev/null || true)"
  reviewer="$(GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/reviewer" gh api user --jq .login 2>/dev/null || true)"

  if [ -z "$author" ] || [ -z "$reviewer" ]; then
    warn "could not read login from one of the atelier gh dirs:"
    warn "  author:   ${author:-<unreadable>}"
    warn "  reviewer: ${reviewer:-<unreadable>}"
    warn "auto-merge may not work until both identities authenticate cleanly"
    return
  fi

  if [ "$author" = "$reviewer" ]; then
    warn "atelier author and reviewer GitHub identities are the SAME: @$author"
    warn "GitHub will downgrade reviewer's 'approve' to a comment (Finding #11)"
    warn "auto-merge guardrail #2 will hold the PR until a human merges"
    warn "to fix: re-run install.sh after authenticating the reviewer dir with"
    warn "a different GitHub account:"
    warn "  GH_CONFIG_DIR=\"$ATELIER_CONFIG_DIR/gh/reviewer\" gh auth logout --hostname github.com"
    warn "  $0   # rerun and pick the second account at the reviewer prompt"
  else
    step_ok "atelier identities OK: author=@$author, reviewer=@$reviewer (distinct)"
  fi
}

# M7.1.F7a (install side): capture the atelier-author GitHub identity into a
# git-config file under $ATELIER_CONFIG_DIR. Orchestrator-driven commits
# (the F7b follow-up) will read this via
# GIT_CONFIG_GLOBAL=$ATELIER_CONFIG_DIR/git-identity.conf so atelier commits
# are authored by atelier-author rather than the operator's personal global
# identity. The operator's ~/.gitconfig is intentionally NOT modified.
phase_b_capture_atelier_git_identity() {
  local identity_file="$ATELIER_CONFIG_DIR/git-identity.conf"
  local login id name email

  login="$(GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh api user --jq .login 2>/dev/null || true)"
  id="$(GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"    gh api user --jq .id    2>/dev/null || true)"
  name="$(GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"  gh api user --jq -r '.name // empty'  2>/dev/null || true)"
  email="$(GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh api user --jq -r '.email // empty' 2>/dev/null || true)"

  if [ -z "$login" ] || [ -z "$id" ]; then
    warn "could not read atelier-author identity from gh — skipping $identity_file"
    warn "orchestrator-driven commits will fall back to the operator's global git identity"
    return
  fi

  # Defaults when GitHub exposes neither a real name nor a public email
  # (the common case for fresh service accounts). The no-reply pattern
  # uses the numeric account id so renamed logins still route mail.
  : "${name:=$login}"
  : "${email:=${id}+${login}@users.noreply.github.com}"

  cat > "$identity_file" <<CFG
# atelier-author git identity (M7.1.F7) — read by orchestrator-driven
# commits via GIT_CONFIG_GLOBAL=$identity_file so the Author: field of
# atelier-managed commits matches the GitHub account that pushes them
# (M5.0.1 dual-gh-id). DO NOT edit by hand — install.sh rewrites this
# every run from \`gh api user\`. The operator's personal global git
# identity (~/.gitconfig) is intentionally untouched.
[user]
    name = $name
    email = $email
CFG
  step_ok "atelier-author git identity captured: $name <$email>"
  sublog "  -> $identity_file"
}

phase_b() {
  phase "Phase B — authentication"

  # Phase B is the only interactive phase: it depends on browser-based OAuth
  # and a human at the keyboard. When install.sh runs without a TTY (CI, a
  # piped install, an `ssh host 'bash install.sh'` without -t), skip the
  # interactive flow with a clear message and let Phases C.1/C.2 continue.
  # The operator can complete auth later from a real terminal.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    warn "no TTY detected — skipping Phase B (interactive auth)"
    warn "to complete auth, re-run on a real terminal, or run these by hand:"
    warn "  CLAUDE_CONFIG_DIR=\"$ATELIER_CONFIG_DIR\" claude auth login"
    warn "  GH_CONFIG_DIR=\"$ATELIER_CONFIG_DIR/gh/author\" gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes 'repo,workflow,project,read:org'"
    warn "  GH_CONFIG_DIR=\"$ATELIER_CONFIG_DIR/gh/author\" gh auth setup-git"
    warn "  GH_CONFIG_DIR=\"$ATELIER_CONFIG_DIR/gh/reviewer\" gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes 'repo,workflow,project,read:org'"
    return
  fi

  phase_b_claude_login
  phase_b_atelier_author_login
  phase_b_atelier_reviewer_login
  phase_b_verify_distinct_identities
  phase_b_capture_atelier_git_identity
  ok "Phase B complete"
}

# ---------- phase C.1: host-OS configuration ----------

# Persistent state directory for atelier (XDG-compliant). /doctor (M1.6) reads
# the recorded git-wt SHA from here to detect drift against upstream.
ATELIER_STATE_DIR="${HOME}/.local/state/atelier"

# Versioned managed runtime dir (#39 F2). Phase C.1 copies scripts/ +
# templates/ (+ install.sh + .claude-plugin/plugin.json for version
# introspection) from $ATELIER_SOURCE_ROOT into
# $ATELIER_RUNTIME_BASE/<version>/ and atomically swaps the `current`
# symlink. The ~/.local/bin helper symlinks target current/scripts/* so the
# helpers keep working when the source (clone OR plugin cache) moves or is
# deleted, and a version bump is a single symlink swap with the previous
# version retained for rollback. Override the base with $ATELIER_RUNTIME_DIR
# (tests use a scratch HOME).
ATELIER_RUNTIME_BASE="${ATELIER_RUNTIME_DIR:-${HOME}/.local/share/atelier}"

phase_c_1_instantiate_templates() {
  # Atelier ships `templates/` with placeholders that depend on where atelier
  # is installed:
  #   - <atelier-config-dir> in settings.template.json (replaced once, here)
  #   - <worktree>           in settings.template.json (replaced per-task /
  #                          per-project at runtime by atelier-setup-project
  #                          and `/next-task` step 7)
  #   - <project-name>       in project-claude.md.template (replaced
  #                          per-project at runtime by atelier-setup-project)
  #
  # <atelier-config-dir> is install-time. The slash commands and the bash
  # helper shouldn't need to know "where atelier lives" — that's a decision
  # made here, in install.sh, when the operator chose --config-dir or
  # accepted the default. Per-task / per-project consumers read the
  # instantiated copy under $ATELIER_CONFIG_DIR/templates/ and only worry
  # about the runtime placeholders that genuinely change per invocation.
  local src_dir="$ATELIER_SOURCE_ROOT/templates"
  local dst_dir="$ATELIER_CONFIG_DIR/templates"
  mkdir -p "$dst_dir"

  # 1) settings.template.json — substitute <atelier-config-dir>; leave
  #    <worktree> untouched (per-task / per-project substitution).
  sed "s|<atelier-config-dir>|$ATELIER_CONFIG_DIR|g" \
      "$src_dir/settings.template.json" \
      > "$dst_dir/settings.template.json"
  if grep -q "<atelier-config-dir>" "$dst_dir/settings.template.json"; then
    rm -f "$dst_dir/settings.template.json"
    die "settings.template.json instantiation left a literal <atelier-config-dir> behind (template bug?)"
  fi
  sublog "instantiated $dst_dir/settings.template.json"

  # 2) project-claude.md.template — no install-time placeholders to
  #    substitute; copy verbatim. The per-project <project-name>
  #    substitution happens later in atelier-setup-project.
  cp "$src_dir/project-claude.md.template" "$dst_dir/project-claude.md.template"
  sublog "copied $dst_dir/project-claude.md.template"

  # 3) atelier.template.json — per-project atelier config (M7.1.F27). No
  #    install-time placeholders; copy verbatim. atelier-setup-project
  #    seeds <project>/.atelier.json from this on first run only.
  if [ -f "$src_dir/atelier.template.json" ]; then
    cp "$src_dir/atelier.template.json" "$dst_dir/atelier.template.json"
    sublog "copied $dst_dir/atelier.template.json"
  fi
}

phase_c_1_claude_config_dir() {
  # The .atelier-managed marker is planted by mark_install_started in
  # Phase 0 (installStatus=in_progress) and stamped installStatus=complete
  # by mark_install_complete at the end of main() — see M7.1.F6. This phase
  # now just confirms the directory is present and logs it for the operator.
  if [ ! -d "$ATELIER_CONFIG_DIR" ]; then
    mkdir -p "$ATELIER_CONFIG_DIR"
    sublog "created atelier config root: $ATELIER_CONFIG_DIR"
  else
    sublog "atelier config root already exists: $ATELIER_CONFIG_DIR"
  fi
}

phase_c_1_git_wt() {
  local sha_file="$ATELIER_STATE_DIR/git-wt.sha"

  # Supply-chain pin: the git-wt bootstrap clones an EXTERNAL repo and
  # executes its install.sh on this host. Running whatever upstream HEAD
  # happens to be at install time would let a compromised upstream execute
  # arbitrary code here, so we pin to a reviewed commit and verify the
  # checkout BEFORE executing anything from the clone. Bump this SHA
  # deliberately when adopting a new git-wt release. Maintainers can
  # override with ATELIER_GWT_REF=<sha-or-ref> to test unreleased git-wt
  # builds; the default is always the pin.
  local GWT_PINNED_SHA="f25e81f7170a4be3a8e8021a712a31fd62158ff8"
  local gwt_ref="${ATELIER_GWT_REF:-$GWT_PINNED_SHA}"
  local gwt_want gwt_head

  # Fully provisioned: git-wt on PATH and a SHA is on file. Skip clone +
  # install + re-record.
  if has git-wt && [ -s "$sha_file" ]; then
    step_skip "git-wt already installed (recorded SHA: $(head -c 12 "$sha_file"))"
    return
  fi

  # Either git-wt is missing, or the SHA file is missing (operator may have
  # installed git-wt manually before atelier started tracking it). Clone,
  # detach onto the pinned ref, verify, THEN install (only when git-wt is
  # not on PATH); always record the SHA. /doctor (M1.6) compares this value
  # against `gh api repos/AkaLab-Tech/git-wt/commits/main` — with a pin, a
  # drift report means "upstream moved past the pin", which is the cue to
  # review upstream and bump GWT_PINNED_SHA.
  # Full clone (not --depth 1): a shallow clone of upstream HEAD does not
  # contain the pinned commit once upstream advances past it.
  sublog "cloning AkaLab-Tech/git-wt into /tmp/git-wt (pinned ref: $gwt_ref)"
  rm -rf /tmp/git-wt
  git clone https://github.com/AkaLab-Tech/git-wt.git /tmp/git-wt

  if ! git -C /tmp/git-wt checkout --detach --quiet "$gwt_ref" 2>/dev/null; then
    rm -rf /tmp/git-wt
    die "git-wt: pinned ref '$gwt_ref' not found in the clone — upstream history may have been rewritten. Refusing to execute an unpinned installer. (Maintainers: override with ATELIER_GWT_REF=<ref>.)"
  fi
  gwt_want="$(git -C /tmp/git-wt rev-parse --verify --quiet "${gwt_ref}^{commit}" || true)"
  gwt_head="$(git -C /tmp/git-wt rev-parse HEAD)"
  if [ -z "$gwt_want" ] || [ "$gwt_head" != "$gwt_want" ]; then
    rm -rf /tmp/git-wt
    die "git-wt: checkout verification failed — HEAD is ${gwt_head:-unknown}, expected ${gwt_want:-unresolvable} (ref '$gwt_ref'). Refusing to execute its install.sh."
  fi
  sublog "verified git-wt checkout at pinned SHA ${gwt_head:0:12}"

  if ! has git-wt; then
    sublog "running git-wt installer (--skill-for=claude)"
    # M7.1.F10: drop the upstream installer's "==> installation complete /
    # next steps:" epilogue. That epilogue is the SUB-installer's notion of
    # "done" and misleads operators into thinking atelier's whole install
    # finished here — it has not (Phase C.1 still has git-identity prompts
    # + helper symlinks + Phase C.2 below). The per-action lines
    # ("==> installed binary →", "==> recorded clone path →", etc.) above
    # the epilogue stay — they're useful confirmations.
    /tmp/git-wt/install.sh --skill-for=claude 2>&1 \
      | awk 'BEGIN { skip=0 } /^==> installation complete$/ { skip=1 } !skip { print }'
  else
    sublog "git-wt already on PATH — clone only to backfill SHA"
  fi

  mkdir -p "$ATELIER_STATE_DIR"
  git -C /tmp/git-wt rev-parse HEAD > "$sha_file"
  sublog "recorded git-wt SHA in $sha_file"
  rm -rf /tmp/git-wt
}

phase_c_1_env_excludes() {
  # Ensure `.env*` is in git's global excludes (core.excludesFile). If the
  # setting is empty, default to the XDG path and create the file.
  local excludes_file
  excludes_file="$(git config --global --get core.excludesFile || true)"
  if [ -z "$excludes_file" ]; then
    excludes_file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
    mkdir -p "$(dirname "$excludes_file")"
    touch "$excludes_file"
    git config --global core.excludesFile "$excludes_file"
    sublog "set core.excludesFile to $excludes_file"
  fi

  # Expand leading ~ if the configured path uses it.
  excludes_file="${excludes_file/#\~/$HOME}"

  if [ -f "$excludes_file" ] && grep -qxF '.env*' "$excludes_file"; then
    sublog ".env* already in $excludes_file"
  else
    mkdir -p "$(dirname "$excludes_file")"
    printf '.env*\n' >> "$excludes_file"
    sublog "added .env* to $excludes_file"
  fi
}

phase_c_1_git_identity() {
  # Per PR #9: always prompt for user.name / user.email, showing the current
  # global values as defaults so the operator can accept with Enter or
  # overwrite. Graceful no-TTY handling: if both are already set and there is
  # no TTY (CI / piped install), keep silently. If either is missing and no
  # TTY, print a clear hint and continue (don't block the rest of the script).
  local name email
  name="$(git config --global --get user.name || true)"
  email="$(git config --global --get user.email || true)"

  if [ -n "$name" ] && [ -n "$email" ] && [ ! -t 0 ]; then
    sublog "git identity already set: $name <$email> (no TTY — keeping)"
    return
  fi
  if { [ -z "$name" ] || [ -z "$email" ]; } && [ ! -t 0 ]; then
    warn "git identity is incomplete and there is no TTY to prompt"
    warn "to set it from a real terminal:"
    warn "  git config --global user.name  'Your Name'"
    warn "  git config --global user.email 'you@example.com'"
    return
  fi

  local new_name new_email
  if [ -n "$name" ]; then
    read -r -p "    git user.name [$name]: " new_name
    new_name="${new_name:-$name}"
  else
    read -r -p "    git user.name: " new_name
    while [ -z "$new_name" ]; do
      read -r -p "    git user.name (required): " new_name
    done
  fi
  if [ -n "$email" ]; then
    read -r -p "    git user.email [$email]: " new_email
    new_email="${new_email:-$email}"
  else
    read -r -p "    git user.email: " new_email
    while [ -z "$new_email" ]; do
      read -r -p "    git user.email (required): " new_email
    done
  fi

  git config --global user.name "$new_name"
  git config --global user.email "$new_email"
  sublog "git identity set: $new_name <$new_email>"
}

# ---------- versioned runtime dir (#39 F2) ----------

# Read the atelier version shipped by the source tree from its plugin
# manifest. Echoes the version string; dies when the manifest is missing or
# carries no version (the runtime dir is keyed by it).
runtime_source_version() {
  local manifest="$ATELIER_SOURCE_ROOT/.claude-plugin/plugin.json"
  [ -f "$manifest" ] \
    || die "cannot version the runtime dir: $manifest not found (is --source-root pointing at an atelier tree?)"
  local version
  version="$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
  [ -n "$version" ] \
    || die "cannot version the runtime dir: no .version in $manifest"
  printf '%s\n' "$version"
}

# Copy the runtime payload from source root $1 into dir $2, preserving the
# scripts/ + templates/ layout. The layout invariant matters: helpers resolve
# their plugin root as dirname(realpath(self))/.. — from
# <runtime>/<version>/scripts/<helper> that lands on <runtime>/<version>/,
# which therefore must carry templates/ and .claude-plugin/plugin.json just
# like the clone did. install.sh itself rides along so a managed install can
# re-run phases (e.g. --refresh-shellrc) without any clone on disk.
_runtime_copy_payload() {
  local src="$1" dest="$2"
  mkdir -p "$dest/.claude-plugin"
  # -p preserves modes (helper exec bits) and timestamps; -R recurses.
  cp -pR "$src/scripts" "$dest/scripts"
  cp -pR "$src/templates" "$dest/templates"
  cp -p "$src/.claude-plugin/plugin.json" "$dest/.claude-plugin/plugin.json"
  if [ -f "$src/install.sh" ]; then
    cp -p "$src/install.sh" "$dest/install.sh"
  fi
  # #39 F2 layout audit: atelier-setup-project's decision-policy step reads
  # agents/decision-broker/catalog.json relative to the plugin root it
  # derives from its own realpath. Without this one agent asset the policy
  # prompts would silently skip ("catalog missing") on terminal-run
  # setup-project once helpers resolve into the runtime dir.
  if [ -f "$src/agents/decision-broker/catalog.json" ]; then
    mkdir -p "$dest/agents/decision-broker"
    cp -p "$src/agents/decision-broker/catalog.json" "$dest/agents/decision-broker/catalog.json"
  fi
}

# Keep at most the 2 most recent version dirs under $ATELIER_RUNTIME_BASE
# (current + one rollback candidate). NEVER prunes the dir `current` points
# to, even if it somehow isn't among the newest two. Staging leftovers
# (.staging-*) are dot-prefixed so `ls` never lists them here.
_runtime_prune_old_versions() {
  local current_target name dir count=0
  current_target="$(readlink "$ATELIER_RUNTIME_BASE/current" 2>/dev/null || true)"
  # Version dir names are jq-read semver strings (no newlines/controls);
  # `ls -1t` gives the mtime ordering we key off.
  # shellcheck disable=SC2012
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "current" ] && continue
    dir="$ATELIER_RUNTIME_BASE/$name"
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    count=$((count + 1))
    [ "$count" -le 2 ] && continue
    [ "$name" = "$current_target" ] && continue
    rm -rf "$dir"
    sublog "pruned old runtime version $name"
  done < <(ls -1t "$ATELIER_RUNTIME_BASE" 2>/dev/null)
}

# Phase C.1 (#39 F2): materialize $ATELIER_RUNTIME_BASE/<version>/ from
# $ATELIER_SOURCE_ROOT and swap the `current` symlink. Copy is atomic-ish:
# build into a .staging-<version>.$$ sibling, then a single mv into place.
# Idempotent: when <version>/ already exists with identical content
# (diff -rq), nothing is touched; when it exists but differs (e.g. a dev
# clone re-installed without a version bump), it is replaced via staging+mv.
# Runs in BOTH clone and snapshot mode — the clone is just another source,
# so existing installs migrate transparently on their next install.sh run.
phase_c_1_runtime_dir() {
  local version version_dir staging
  version="$(runtime_source_version)"
  version_dir="$ATELIER_RUNTIME_BASE/$version"
  mkdir -p "$ATELIER_RUNTIME_BASE"

  staging="$ATELIER_RUNTIME_BASE/.staging-${version}.$$"
  rm -rf "$staging"
  _runtime_copy_payload "$ATELIER_SOURCE_ROOT" "$staging"

  if [ -d "$version_dir" ] && diff -rq "$version_dir" "$staging" >/dev/null 2>&1; then
    rm -rf "$staging"
    step_skip "runtime $version already in place ($version_dir)"
  elif [ -d "$version_dir" ]; then
    # Same version, different content — replace atomically: move the stale
    # dir aside first (mv onto an existing dir would nest instead of swap).
    local stale="$ATELIER_RUNTIME_BASE/.stale-${version}.$$"
    mv "$version_dir" "$stale"
    mv "$staging" "$version_dir"
    rm -rf "$stale"
    sublog "replaced runtime $version (content changed without a version bump)"
  else
    mv "$staging" "$version_dir"
    sublog "installed runtime $version -> $version_dir"
  fi

  # Atomic swap. Relative target so the whole runtime base can be relocated
  # (or mounted elsewhere) without dangling; -n replaces an existing
  # `current` symlink instead of descending into it.
  ln -sfn "$version" "$ATELIER_RUNTIME_BASE/current"
  step_ok "runtime current -> $version"

  _runtime_prune_old_versions
}

_phase_c_1_symlink_helper() {
  # Helper that symlinks one of atelier's bin scripts into ~/.local/bin.
  # Idempotent: re-link if the existing symlink points elsewhere; leave
  # plain files alone (operator may have pinned a manual copy).
  #
  # #39 F2: the link target is the managed runtime dir
  # ($ATELIER_RUNTIME_BASE/current/scripts/<helper>), NOT the source tree.
  # Routing through `current` means a version bump swaps every helper at
  # once with zero bin-dir edits — and pre-#39 installs whose links still
  # point at the clone are migrated automatically by the "points elsewhere
  # → re-link" branch below.
  local helper_name="$1"
  local src="$ATELIER_RUNTIME_BASE/current/scripts/$helper_name"
  local bin_dir="${HOME}/.local/bin"
  local dest="$bin_dir/$helper_name"

  if [ ! -f "$src" ]; then
    warn "expected $src — skipping $helper_name install"
    warn "this likely means the runtime-dir phase did not run, or the source tree at $ATELIER_SOURCE_ROOT does not ship this helper"
    return
  fi
  if [ ! -x "$src" ]; then
    warn "$src is not executable — chmoding +x"
    chmod +x "$src"
  fi

  if [ -L "$dest" ]; then
    local current
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      sublog "$helper_name already symlinked ($dest -> $src)"
    else
      ln -sfn "$src" "$dest"
      sublog "updated symlink: $dest -> $src (was -> $current)"
    fi
  elif [ -e "$dest" ]; then
    # Regular file (or directory). The operator might have pinned a copy
    # manually; we don't clobber. Tell them what we would have done.
    warn "$dest exists and is not a symlink — leaving it alone"
    warn "to use the atelier-managed helper, remove $dest and re-run install.sh"
  else
    ln -s "$src" "$dest"
    sublog "linked $dest -> $src"
  fi
}

phase_c_1_setup_project_helper() {
  # Symlink scripts/atelier-setup-project and scripts/atelier-uninstall into
  # ~/.local/bin so:
  #   - the /atelier:setup-project slash command can invoke setup-project
  #     via Bash(atelier-setup-project:*) from inside Claude Code;
  #   - the operator can run either binary directly from any terminal
  #     (notably `atelier-uninstall` to decommission atelier — see M5.0.3).
  #
  # Why a symlink and not a copy: the helpers live in the managed runtime
  # dir ($ATELIER_RUNTIME_BASE/current/scripts/ — #39 F2), and `current` is
  # an atomically swapped symlink. Linking through it means a version bump
  # updates every helper at once without touching ~/.local/bin. The link
  # target is absolute so it survives the operator's cwd changing between
  # install runs.
  local bin_dir="${HOME}/.local/bin"
  mkdir -p "$bin_dir"

  _phase_c_1_symlink_helper atelier-setup-project
  _phase_c_1_symlink_helper atelier-uninstall
  # M7.1.F32: atelier-remove-project reverses atelier-setup-project for
  # ONE project (vs atelier-uninstall which removes atelier from the
  # whole system). Default mode preserves operator-owned content
  # (tracking files, .gitignore, .npmrc entries); --purge extends the
  # cleanup to those as well.
  _phase_c_1_symlink_helper atelier-remove-project
  # M7.1.F33: atelier-list-projects lists every project registered in
  # $ATELIER_CONFIG_DIR/projects.json, with a per-project on-disk
  # status (configured / partial / missing-directory). Read-only.
  _phase_c_1_symlink_helper atelier-list-projects
  # M4.29: atelier-import-conversations copies the operator's prior Claude Code
  # conversation transcripts (~/.claude/projects/<dir>/*.jsonl) into atelier's
  # separate $ATELIER_CONFIG_DIR so `claude --resume` inside an atelier session
  # can see them. Transcripts only — never personal CLAUDE.md / memory /
  # settings — non-destructive, never overwrites an existing atelier transcript.
  # Backs the /atelier:import-conversations command and the opt-in onboarding
  # step below.
  _phase_c_1_symlink_helper atelier-import-conversations
  # M7.1.F23: atelier-doctor bash binary — replaces the 10 inline Bash
  # checks the /atelier:doctor slash command used to run, each of which
  # surfaced a different Claude Code permission gate. With this binary
  # the slash command's allow-list collapses to `Bash(atelier-doctor:*)`.
  _phase_c_1_symlink_helper atelier-doctor
  # M5.3: atelier-task-resolve picks which registered project the
  # `task()` shell function should target — longest-prefix match
  # against cwd, fzf picker fallback when cwd is outside every
  # registered project.
  _phase_c_1_symlink_helper atelier-task-resolve
  # M7.3: atelier-measure-merge-rate samples the N most-recently merged
  # PRs and classifies each as autonomous vs intervention required. Used
  # to evaluate the Phase 7 ship gate (≥80% autonomous on a sample of 10
  # atelier-driven tasks).
  _phase_c_1_symlink_helper atelier-measure-merge-rate
  # M7.1.F27: atelier-pr-size-check enforces the per-PR size budget
  # (AND-gate over lines + files, after exempting tests / lockfiles /
  # migrations). Invoked by pr-author / pr-flow before `gh pr create`
  # and by reviewer / auto-merge after the PR exists. Reads
  # <project>/.atelier.json or falls back to built-in defaults.
  _phase_c_1_symlink_helper atelier-pr-size-check
  # M6.1.a: atelier-update pulls origin/main on the clone, refreshes the
  # instantiated templates in $ATELIER_CONFIG_DIR, and triggers
  # `claude plugin update` so Claude Code sessions load the new
  # agents/skills/commands on next start. The permission-diff prompt for
  # settings.template.json changes lands in M6.1.b along with the
  # /atelier:update slash command.
  _phase_c_1_symlink_helper atelier-update
  # M6.1.b: atelier-permission-diff renders a human-readable diff
  # between two settings.template.json files (added/removed/impact, in
  # the shape of PLAN.md §9). Invoked by atelier-update before applying
  # template changes, and by the /atelier:update slash command. Refuses
  # to apply permission changes without an interactive prompt.
  _phase_c_1_symlink_helper atelier-permission-diff
  # TASK_016: atelier-orient prints a prioritized "what to do next" for a dir;
  # backs the /atelier:orient command and the SessionStart orientation hook.
  _phase_c_1_symlink_helper atelier-orient
  # atelier-set-language persists the operator's chat language (how atelier
  # addresses you) in $ATELIER_CONFIG_DIR/operator.json; backs /atelier:set-language.
  _phase_c_1_symlink_helper atelier-set-language
  # #41: atelier-notify plays a best-effort, never-hard-failing audible cue
  # (Notification hook events); atelier-set-notification persists the
  # opt-in preference in $ATELIER_CONFIG_DIR/operator.json and backs
  # /atelier:set-notification.
  _phase_c_1_symlink_helper atelier-notify
  _phase_c_1_symlink_helper atelier-set-notification
  # #42: atelier-notify-cue plays the task-complete / task-blocked cues,
  # delegating actual playback to atelier-notify. Also backed by
  # atelier-set-notification's task-complete/task-blocked subcommands.
  _phase_c_1_symlink_helper atelier-notify-cue
  # TASK_017: atelier-align surveys (and applies Tier-1 fixes to) every registered
  # project/workspace so they converge to the installed atelier; backs /atelier:align.
  _phase_c_1_symlink_helper atelier-align
  # M7.4: atelier-migrate-task-ids renumbers a project's foreign task ids
  # (RLS.2 -> #NN) to PLAN.md §5; backs the atelier-doctor §5-id check.
  _phase_c_1_symlink_helper atelier-migrate-task-ids
  # M9.1: atelier-task-backend resolves a project's roadmap backend from
  # .roadmap.json so the task provider (next-task) can drive non-files backends.
  _phase_c_1_symlink_helper atelier-task-backend
  # M4.23 / M4.27 / M4.28: atelier-setup-{coolify,vercel,neon} install +
  # configure the optional integration plugins. Invoked by the Phase C.2 opt-in
  # prompts and by /atelier:setup-{coolify,vercel,neon}.
  _phase_c_1_symlink_helper atelier-setup-coolify
  _phase_c_1_symlink_helper atelier-setup-vercel
  _phase_c_1_symlink_helper atelier-setup-neon
  # M8.1: atelier-setup-workspace groups already-registered projects into a
  # workspace recorded in $ATELIER_CONFIG_DIR/workspaces.json, enabling
  # multi-repo routing, aggregated status, and cross-repo blocked_by deps
  # (PLAN.md §15). It never reconfigures members or changes the
  # one-task / one-worktree / one-PR model.
  _phase_c_1_symlink_helper atelier-setup-workspace
  # M8.3: atelier-resolve-dep resolves a cross-repo blocked_by:<token>#id
  # dependency OFFLINE against the sibling member's HISTORY.md (exit
  # 0/3/4/5). Called by the task-discovery skill and /next-task to gate a
  # task whose cross-repo blocker is not yet merged (PLAN.md §15.4).
  _phase_c_1_symlink_helper atelier-resolve-dep
  # M8.6: atelier-workspace-status renders an aggregated, read-only dashboard
  # for a workspace — one row per member plus a cross-repo-blocked section
  # (PLAN.md §15.6). Backs the /atelier:workspace-status command.
  _phase_c_1_symlink_helper atelier-workspace-status
  # M8.7: atelier-list-workspaces (read-only enumeration of workspaces with
  # per-member health) and atelier-remove-workspace (drop a grouping; members
  # stay registered unless --with-members). Back /atelier:list-workspaces and
  # /atelier:remove-workspace (PLAN.md §15.7).
  _phase_c_1_symlink_helper atelier-list-workspaces
  _phase_c_1_symlink_helper atelier-remove-workspace
  # M5.4: atelier-housekeeping sweeps the task-cycle debris auto-merge's
  # per-task cleanup leaves behind — orphan worktrees, merged/closed local
  # task/* branches, and merged/closed origin/task/* remotes — across every
  # registered project. Always enumerates first and deletes only on operator
  # authorization; never touches active/blocked/oversize tasks, open PRs,
  # dirty worktrees, or protected branches. Backs /atelier:housekeeping and
  # the once-a-day SessionStart nudge (hooks/daily-housekeeping.sh).
  _phase_c_1_symlink_helper atelier-housekeeping

  # PATH check. The shellrc hook block below adds ~/.local/bin to PATH for
  # future shells, but the current install.sh run probably doesn't have it
  # yet. Warn rather than fail.
  case ":${PATH:-}:" in
    *":$bin_dir:"*) sublog "$bin_dir is on PATH"               ;;
    *) sublog "$bin_dir not on PATH for this shell — will be set by shellrc hook on next login" ;;
  esac
}

phase_c_1_shellrc_hooks() {
  # Idempotent injection via sentinel comments + a version line embedded inside
  # the block (M7.1.F7c). On re-run, the function reads `# atelier-hooks-version:`
  # from any existing block: if it matches `current_version` below, we skip;
  # if it's older (or missing), we strip the block between sentinels and
  # re-inject the current heredoc. To force a refresh manually, edit the
  # version line in the rc file to 0 and re-run install.sh — or just delete
  # the block between sentinels.
  local sentinel_start='# >>> atelier hooks (managed by install.sh) >>>'
  local sentinel_end='# <<< atelier hooks (managed by install.sh) <<<'
  # Bump this number whenever you edit anything inside the BLOCK heredoc
  # below. Existing operators' rc files carry their version inline; on
  # install.sh re-run, an older or missing version triggers a strip +
  # re-inject so the upgrade propagates automatically.
  local current_version=6

  # Heredoc is single-quoted: `$(fnm env --use-on-cd)`, `$*`, and the alias
  # body are written as literal text, expanded later when the shell sources
  # the rc file (not now, while install.sh runs).
  local block
  block=$(cat <<'BLOCK'
# >>> atelier hooks (managed by install.sh) >>>
# atelier-hooks-version: 6
# (install.sh reads the version above; bump it when you edit anything between
#  these sentinels so existing operators get the refreshed block on re-run.)
# Ensure ~/.local/bin is on PATH so atelier-setup-project (and any future
# atelier-* CLI helpers installed by install.sh Phase C.1) are runnable from
# any terminal — including the Bash tool inside a Claude Code session.
# Note: a case-statement form would be more idiomatic, but the closing ")"
# would terminate the surrounding $(cat <<'BLOCK' ...) substitution early.
if [[ ":${PATH:-}:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# Atelier's isolated Claude config root (M5.0 + M5.0.2). The path is baked
# in here by install.sh based on the operator's choice (default
# ~/.claude-work/, may be overridden with --config-dir). To change it
# later, edit the path below and re-source this rc file — but note that
# install.sh on a re-run will re-inject this block from the current value.
export ATELIER_CONFIG_DIR="__ATELIER_CONFIG_DIR__"
# Auto-switch Node version per-project via .nvmrc.
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi
# `task`: open a Claude session for the next roadmap task in the project
# the operator's cwd currently belongs to (M5.3). Resolution is delegated
# to `atelier-task-resolve <cwd>` (longest-prefix match against the
# projects registered in $ATELIER_CONFIG_DIR/projects.json; falls back to
# an fzf picker if cwd is not inside any registered project).
#
# CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR pins the session to atelier's
# config root — separate from the operator's personal Claude config so
# atelier's autonomous-mode rules don't conflict with personal rules.
# GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author pins every `gh ...` call inside
# the session to atelier's author identity (M5.0.1). The `reviewer` agent
# overrides this inline with $ATELIER_CONFIG_DIR/gh/reviewer for its own
# gh calls so its approvals are honoured as a distinct GitHub identity.
# GIT_CONFIG_GLOBAL=$ATELIER_CONFIG_DIR/git-identity.conf pins every `git
# commit` (and any other git invocation that reads global config) to the
# atelier-author identity captured at install time (M7.1.F7a). This makes
# the Author / Committer fields of atelier-driven commits match the
# atelier-author GitHub account that pushes them (M5.0.1 dual-gh-id)
# rather than mixing operator personal identity with the atelier-author
# push token. The operator's ~/.gitconfig stays untouched (M7.1.F7b).
# The operator's normal shell (outside `task`) is unaffected by these exports.
task() {
  # M4.26.d: parse --policy and --ask-for flags that override the project's
  # .atelier.json decisionPolicy for this invocation only. The flags become
  # env vars (ATELIER_POLICY_OVERRIDE, ATELIER_ASK_FOR) read by the
  # decision-broker skill on every resolution. The flag parser uses
  # if/elif/else (not case) because the case-statement closing ")" would
  # terminate the surrounding $(cat <<'BLOCK' ...) substitution that ships
  # this function — same reason as the PATH check above.
  local project policy_override="" ask_for="" remaining=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "--policy" ]; then
      if [ -z "${2:-}" ]; then
        printf 'atelier: --policy requires a value (auto or ask)\n' >&2
        return 1
      fi
      policy_override="$2"
      shift 2
    elif [ "${1#--policy=}" != "$1" ]; then
      policy_override="${1#--policy=}"
      shift
    elif [ "$1" = "--ask-for" ]; then
      if [ -z "${2:-}" ]; then
        printf 'atelier: --ask-for requires a value (comma-separated categories)\n' >&2
        return 1
      fi
      ask_for="$2"
      shift 2
    elif [ "${1#--ask-for=}" != "$1" ]; then
      ask_for="${1#--ask-for=}"
      shift
    else
      if [ -z "$remaining" ]; then
        remaining="$1"
      else
        remaining="$remaining $1"
      fi
      shift
    fi
  done
  if [ -n "$policy_override" ] && [ "$policy_override" != "auto" ] && [ "$policy_override" != "ask" ]; then
    printf 'atelier: --policy must be auto or ask, got: %s\n' "$policy_override" >&2
    return 1
  fi
  if ! project="$(atelier-task-resolve "$(pwd)")"; then
    return 1
  fi
  if ! cd "$project" 2>/dev/null; then
    printf 'atelier: project path no longer exists: %s\n' "$project" >&2
    return 1
  fi
  CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" \
    GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" \
    GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf" \
    ATELIER_POLICY_OVERRIDE="$policy_override" \
    ATELIER_ASK_FOR="$ask_for" \
    claude "/atelier:next-task $remaining"
}
# `atelier`: general-purpose entry point that opens a Claude Code session
# under atelier's isolated config root, optionally with arbitrary arguments
# passed through to `claude`. With explicit args it passes them through —
# `atelier /atelier:setup-project <path>` (M7.1 dogfood-3 first-project
# bootstrap), `atelier /atelier:doctor` (health check), or any other slash
# command the plugin ships (M7.1.F13). Bare `atelier` (no args) opens with
# `/atelier:orient` as its first message — a prioritized next-step for the cwd
# (TASK_016); `atelier --no-orient` opens a plain exploration session. Same
# CLAUDE_CONFIG_DIR + GH_CONFIG_DIR + GIT_CONFIG_GLOBAL env chain as `task`
# so the loaded plugin sees the atelier-managed marketplace and the right
# identities — agents/skills/commands behave consistently across both
# entry points.
atelier() {
  # M7.1.F34: --help intercept. The help text lives in
  # $ATELIER_CONFIG_DIR/atelier-help.txt (written by install.sh,
  # rewritten on every re-run so it always matches the installed
  # version). Storing the text in a file rather than a HEREDOC inside
  # this function avoids the nested-HEREDOC bash-3.2 parser bug:
  # placing `cat <<EOF ... EOF` inside the outer `$(cat <<BLOCK ...)`
  # substitution that ships this whole block confuses bash 3.2's
  # delimiter tracking even when both delimiters are quoted.
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    local help_file="$ATELIER_CONFIG_DIR/atelier-help.txt"
    if [ -r "$help_file" ]; then
      cat "$help_file"
    else
      printf 'atelier --help: help file missing at %s\n' "$help_file" >&2
      printf 'Re-run install.sh to regenerate it.\n' >&2
      return 1
    fi
    return 0
  fi
  # TASK_016: bare `atelier` (no args) opens the session with /atelier:orient as
  # its first message — a prioritized "what to do next" for the cwd. `atelier
  # --no-orient` opens a plain session; explicit args / slash commands pass through.
  local _noorient=0
  if [ "${1:-}" = "--no-orient" ]; then _noorient=1; shift; fi
  if [ "$#" -eq 0 ] && [ "$_noorient" -eq 0 ]; then
    set -- "/atelier:orient"
  fi
  CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" \
    GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" \
    GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf" \
    claude "$@"
}
# `task-status`: list atelier-author's open PRs across all repos. Prefixed with
# GH_CONFIG_DIR so it runs under the atelier-isolated identity (M5.0.1) — the
# operator's primary ~/.config/gh/ is not touched by install.sh, so a plain
# `gh pr list` here would fail with "not authenticated".
alias task-status='GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh pr list --author @me --state open'
# <<< atelier hooks (managed by install.sh) <<<
BLOCK
)
  # Bake the resolved config dir into the placeholder. Bash native string
  # substitution (no sed needed — the placeholder has no glob chars).
  block="${block//__ATELIER_CONFIG_DIR__/$ATELIER_CONFIG_DIR}"

  # Pick which rc file(s) to inject into. Default shell is what `$SHELL`
  # reports. If neither zsh nor bash, write to both so the operator gets the
  # hooks no matter which shell they end up using.
  local files=()
  case "${SHELL:-}" in
    */zsh)  files+=("${HOME}/.zshrc") ;;
    */bash) files+=("${HOME}/.bashrc") ;;
    *)      files+=("${HOME}/.zshrc" "${HOME}/.bashrc") ;;
  esac

  for f in "${files[@]}"; do
    if [ ! -e "$f" ]; then
      if ! touch "$f" 2>/dev/null; then
        warn "could not create $f (permission denied) — skipping atelier hooks for this file"
        warn "to fix, ensure $f is writable by $USER and re-run install.sh"
        continue
      fi
      sublog "created $f"
    fi
    if [ ! -w "$f" ]; then
      # Common cause on macOS: $f is owned by root:wheel (e.g. an earlier
      # `sudo` accidentally rewrote it). install.sh never tries to chown for
      # the operator — that requires their password. We point at the fix and
      # keep going so the rest of Phase C.1 doesn't block.
      warn "$f is not writable by $USER — skipping atelier hooks for this file"
      warn "to fix: sudo chown $USER:staff $f && chmod u+w $f, then re-run install.sh"
      continue
    fi
    if ! grep -qF "$sentinel_start" "$f"; then
      # No atelier block present — fresh injection.
      printf '\n%s\n' "$block" >> "$f"
      sublog "appended atelier hooks to $(basename "$f") (v$current_version)"
      continue
    fi
    # Block present — refuse to touch when the end sentinel is missing.
    # Corrupted state where stripping "start sentinel onward" could remove
    # more than intended; operator must repair manually.
    if ! grep -qF "$sentinel_end" "$f"; then
      warn "$(basename "$f") has the atelier start sentinel but no matching end sentinel — leaving alone"
      warn "to fix: remove the orphaned start line + everything below it that belongs to atelier, then re-run install.sh"
      continue
    fi
    # Read the existing version line from inside the block. Absent → 0, which
    # forces a refresh (covers operators upgrading from pre-F7c installs).
    local existing_version
    existing_version=$(awk -v s="$sentinel_start" -v e="$sentinel_end" '
      index($0, s) { in_block=1; next }
      index($0, e) { in_block=0 }
      in_block && /^# atelier-hooks-version:[[:space:]]*[0-9]+/ {
        sub(/^# atelier-hooks-version:[[:space:]]*/, "")
        sub(/[^0-9].*/, "")
        print; exit
      }
    ' "$f")
    existing_version=${existing_version:-0}
    if [ "$existing_version" = "$current_version" ]; then
      step_skip "atelier hooks already present in $(basename "$f") (v$current_version)"
      continue
    fi
    if [ "$existing_version" -gt "$current_version" ] 2>/dev/null; then
      warn "atelier hooks in $(basename "$f") are v$existing_version, newer than install.sh's v$current_version — leaving alone"
      continue
    fi
    # Older or missing version → strip the existing block in place + append the
    # current heredoc. Atomic via tempfile-then-mv so a crash mid-edit cannot
    # leave the rc file half-written.
    sublog "→ refreshing atelier shellrc block (v$existing_version → v$current_version) in $(basename "$f")"
    local tmp
    if ! tmp=$(mktemp "${f}.atelier.XXXXXX"); then
      warn "could not create temp file for $f — skipping refresh"
      continue
    fi
    awk -v s="$sentinel_start" -v e="$sentinel_end" '
      index($0, s) { skip=1 }
      !skip
      index($0, e) { skip=0; next }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
    printf '\n%s\n' "$block" >> "$f"
  done
}

# M7.1.F34: write the help text that `atelier --help` will cat at
# runtime. Living in $ATELIER_CONFIG_DIR/atelier-help.txt rather than
# embedded inside the shellrc hook block sidesteps a bash-3.2 parser
# bug with nested HEREDOCs inside `$(cat <<'BLOCK' ...)`. Re-written on
# every install run so the help text always reflects the installed
# version's command surface.
phase_c_1_atelier_help_file() {
  local dest="$ATELIER_CONFIG_DIR/atelier-help.txt"
  cat > "$dest" <<'ATELIER_HELP_TXT'
atelier — AI-operated workstation managed via Claude Code

USAGE
  atelier [args...]       Launch Claude Code under atelier's config dir
                          (CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR, plus
                          GH_CONFIG_DIR + GIT_CONFIG_GLOBAL scoped to
                          atelier's auth + git identity). Plugins,
                          agents, skills and slash commands from the
                          akalab-tech marketplace are loaded.
  atelier --help, -h      Show this help (intercepted by the shell
                          function; never forwarded to claude).

TERMINAL HELPERS (run directly, no `atelier` prefix needed)
  atelier-doctor [--fix]            Health check; --fix auto-applies
                                    runnable fixes
  atelier-update                    Pull latest atelier + refresh
                                    instantiated templates + refresh
                                    plugin cache
  atelier-setup-project [<path>]    Bootstrap a project for atelier
                                    (defaults to cwd)
  atelier-remove-project <path>     Deconfigure ONE project; default
                                    preserves operator content,
                                    --purge for full clean slate
  atelier-list-projects [--json]    List every project registered with
                                    atelier; per-project on-disk status
  atelier-uninstall [--purge]       Remove atelier from the WHOLE
                                    system (not per-project — use
                                    atelier-remove-project for that)
  atelier-pr-size-check             Per-PR size budget check (used by
                                    pr-author + reviewer + auto-merge)
  atelier-measure-merge-rate        Sample N most-recently-merged PRs,
                                    measure autonomous merge rate
  atelier-task-resolve              Resolve which registered project
                                    owns the current cwd

INSIDE CLAUDE CODE — slash commands (use within an atelier session)
  /atelier:doctor [--fix]           Same as atelier-doctor
  /atelier:next-task                Pick + start the next ROADMAP task
  /atelier:resume-task <id>         Resume an interrupted / blocked task
  /atelier:finish-task              Wrap up the active task: close PR,
                                    move tracking, clean worktree
  /atelier:status                   Dashboard of in-progress + blocked
  /atelier:setup-project [...]      Bootstrap from inside Claude Code
  /atelier:list-projects            Same as atelier-list-projects
  /atelier:remove-project [...]     Deconfigure cwd; same flags as the
                                    terminal helper
  /atelier:update [--dry-run]       Same as atelier-update; permission
                                    prompt on settings.template.json
                                    changes
  /atelier:validate [--full]        Run lint + typecheck + tests;
                                    --full adds e2e + screenshots
  /atelier:slice-task <id>          Decompose a large ROADMAP task into
                                    sub-tasks (epic format, M4.24)

NOTES
  - `atelier` runs claude under $ATELIER_CONFIG_DIR (separate from your
    personal ~/.claude/) so atelier's plugins + agents don't interfere
    with non-atelier sessions. Run `claude` directly for a personal
    (non-atelier) session.
  - For full documentation: https://github.com/AkaLab-Tech/atelier
ATELIER_HELP_TXT
  sublog "wrote $dest"
}

# M2.8: enable Claude Code's native `auto` permission mode for atelier-launched
# sessions by writing { "permissions": { "defaultMode": "auto" } } into
# $ATELIER_CONFIG_DIR/settings.json. Empirically validated in M2.7 (docs/research/
# permission-layer-3.md addendum) that defaultMode: "auto" is honored from
# $CLAUDE_CONFIG_DIR/settings.json (the docs' literal ~/.claude/ reference is
# shorthand for "the active user-level config dir"). The setting only takes
# effect inside atelier sessions because atelier's shell wrapper sets
# CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR; the operator's personal ~/.claude/ is
# untouched.
#
# The merge is via jq, preserving existing keys (enabledPlugins,
# extraKnownMarketplaces, theme, etc.) and only ensuring
# .permissions.defaultMode == "auto". Idempotent: re-runs are a no-op when the
# setting is already in place.
phase_c_1_atelier_auto_mode() {
  local target="$ATELIER_CONFIG_DIR/settings.json"
  local existing="{}"
  if [ -f "$target" ]; then
    existing=$(cat "$target")
    if ! printf '%s' "$existing" | jq empty >/dev/null 2>&1; then
      warn "$target is not valid JSON — leaving alone (operator must repair manually)"
      return
    fi
  fi
  # Already set? Skip silently.
  if printf '%s' "$existing" | jq -e '.permissions.defaultMode == "auto"' >/dev/null 2>&1; then
    step_skip "auto-mode already enabled in $target"
    return
  fi
  local tmp
  if ! tmp=$(mktemp "${target}.atelier.XXXXXX"); then
    warn "could not create temp file for $target — skipping auto-mode write"
    return
  fi
  printf '%s' "$existing" \
    | jq '.permissions = (.permissions // {}) | .permissions.defaultMode = "auto"' \
    > "$tmp" \
    && mv "$tmp" "$target" \
    || { rm -f "$tmp"; warn "failed to write auto-mode to $target"; return; }
  sublog "enabled auto-mode in $target (permissions.defaultMode = \"auto\")"
}

# #41: reconcile the Notification hook entry in $ATELIER_CONFIG_DIR/settings.json
# against the operator's .notification.enabled preference (operator.json),
# at install time — so the FIRST session already has the hook if the
# operator (or a prior install) already opted in, without waiting for the
# SessionStart hook to fire once. Shares the exact same reconcile logic as
# the SessionStart hook (hooks/sync-notification-hook.sh) and
# atelier-set-notification's own post-write reconcile: all three call sites
# invoke the identical script, so install-time and session-time behavior
# can never drift apart. Runs from $ATELIER_SOURCE_ROOT (not the runtime
# dir) since hooks/ is intentionally not part of the runtime-dir payload
# (see _runtime_copy_payload) but IS present in the source/cache checkout
# install.sh itself runs from.
phase_c_1_atelier_notification_hook() {
  local sync_script="$ATELIER_SOURCE_ROOT/hooks/sync-notification-hook.sh"
  if [ ! -f "$sync_script" ]; then
    step_skip "notification hook reconcile skipped (sync-notification-hook.sh not found at $sync_script)"
    return
  fi
  ATELIER_CONFIG_DIR="$ATELIER_CONFIG_DIR" bash "$sync_script" \
    && step_ok "notification hook reconciled against operator preference" \
    || warn "notification hook reconcile failed — run atelier-set-notification later to retry"
}

# M4.29: offer to bring the operator's prior Claude Code conversation
# transcripts across from their personal ~/.claude into atelier's separate
# $ATELIER_CONFIG_DIR, so `claude --resume` inside an atelier session is not
# empty for someone who already used Claude Code. STRICTLY OPT-IN and
# FAIL-OPEN: only prompts when a TTY is present AND there is something to
# import; defaults to "no"; any failure warns and continues (never blocks the
# install). The heavy lifting (enumeration, picker, non-destructive copy of
# *.jsonl only) lives in scripts/atelier-import-conversations.
phase_c_1_import_conversations() {
  local bin="$ATELIER_SOURCE_ROOT/scripts/atelier-import-conversations"

  # Non-interactive install (CI / piped): never prompt. The operator can run
  # `/atelier:import-conversations` or the helper later.
  if [ ! -t 0 ]; then
    step_skip "skipping conversation import (no TTY) — run atelier-import-conversations later"
    return 0
  fi
  if [ ! -x "$bin" ]; then
    step_skip "skipping conversation import (helper not found at $bin)"
    return 0
  fi

  # Only prompt when there is at least one importable project, so a fresh
  # machine with no prior history is never asked a pointless question.
  if ! "$bin" --list >/dev/null 2>&1 \
     || ! "$bin" --list 2>/dev/null | grep -q 'Importable projects'; then
    step_skip "no prior Claude Code conversations to import"
    return 0
  fi

  log "You already have Claude Code conversation history under ~/.claude."
  sublog "atelier keeps its own config root, so that history is invisible to atelier sessions."
  sublog "You can copy prior transcripts across (transcripts only — never your personal"
  sublog "CLAUDE.md, memory, or settings; your personal folder is left untouched)."
  printf '    Import prior conversations now? [y/N] '
  local reply=""
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES)
      # Interactive picker so the operator chooses which projects to bring
      # over. Fail-open: a non-zero exit here must not abort the install.
      "$bin" || warn "conversation import did not complete — run atelier-import-conversations later"
      ;;
    *)
      step_skip "skipped conversation import — run /atelier:import-conversations anytime to do it later"
      ;;
  esac
  return 0
}

phase_c_1() {
  phase "Phase C.1 — host-OS configuration"
  phase_c_1_claude_config_dir
  phase_c_1_instantiate_templates
  phase_c_1_git_wt
  phase_c_1_env_excludes
  phase_c_1_git_identity
  # #39 F2: materialize the versioned runtime dir BEFORE the helper
  # symlinks — they target $ATELIER_RUNTIME_BASE/current/scripts/.
  phase_c_1_runtime_dir
  phase_c_1_setup_project_helper
  phase_c_1_atelier_help_file
  phase_c_1_atelier_auto_mode
  phase_c_1_atelier_notification_hook
  phase_c_1_import_conversations
  phase_c_1_shellrc_hooks
  ok "Phase C.1 complete"
}

# ---------- phase C.2: plugin install ----------

# Plugins atelier installs from the shared AkaLab-Tech catalog. Listed here
# (not inlined below) so the manual-fallback message and the install loop
# stay in sync.
#
# M7.1.F9: this MUST be the full https://...git URL, not the org/repo
# shortcut. With the shortcut, `claude plugin marketplace add` defaults to
# SSH (git@github.com:...) and fails on a clean machine without SSH keys —
# a direct violation of PLAN.md §2 step 5 (HTTPS only, no SSH).
ATELIER_MARKETPLACE_SOURCE="https://github.com/AkaLab-Tech/claude-plugins.git"
ATELIER_MARKETPLACE_NAME="akalab-tech"
ATELIER_PLUGIN_IDS=("atelier@akalab-tech" "claude-roadmap-tools@akalab-tech")

phase_c_2_print_manual_commands() {
  warn "manual fallback — run these from a Claude Code session or terminal:"
  warn "  claude plugin marketplace add ${ATELIER_MARKETPLACE_SOURCE}"
  for id in "${ATELIER_PLUGIN_IDS[@]}"; do
    warn "  claude plugin install ${id}"
  done
}

phase_c_2_marketplace() {
  # Idempotency: marketplace list (--json) gives an array of registered
  # marketplaces. Skip if `akalab-tech` is already there. Wrong-repo edge
  # case (operator has an `akalab-tech` pointing somewhere else, e.g. from
  # the pre-PR #11 era when each plugin shipped its own marketplace.json) is
  # not auto-corrected — operator runs `claude plugin marketplace remove
  # akalab-tech` manually and re-runs install.sh.
  if claude plugin marketplace list --json 2>/dev/null \
      | jq -e --arg name "$ATELIER_MARKETPLACE_NAME" '.[] | select(.name == $name)' >/dev/null; then
    step_skip "marketplace $ATELIER_MARKETPLACE_NAME already added"
  else
    sublog "adding marketplace $ATELIER_MARKETPLACE_SOURCE"
    claude plugin marketplace add "$ATELIER_MARKETPLACE_SOURCE"
  fi
}

phase_c_2_install_plugin() {
  local plugin_id="$1"
  if claude plugin list --json 2>/dev/null \
      | jq -e --arg id "$plugin_id" '.[] | select(.id == $id)' >/dev/null; then
    step_skip "$plugin_id already installed"
  else
    sublog "installing $plugin_id"
    claude plugin install "$plugin_id"
  fi
}

phase_c_2() {
  phase "Phase C.2 — plugin install"

  # Guard: claude CLI must be on PATH (Phase A installs it) and authenticated
  # (Phase B handles this). If Phase B skipped because no TTY was available,
  # `claude auth status` will report not authenticated — we warn, print the
  # manual fallback, and return without installing. Same shape as the no-TTY
  # skip in Phase B; the rest of install.sh (final summary) still runs.
  if ! has claude; then
    warn "claude CLI not on PATH — skipping Phase C.2"
    phase_c_2_print_manual_commands
    return
  fi
  # M7.1.F42 — scope auth check to atelier's CLAUDE_CONFIG_DIR, not the
  # operator's personal ~/.claude/. Phase C.2 installs plugins under the
  # atelier config dir, so the auth that matters here is the atelier one.
  if ! CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth status >/dev/null 2>&1; then
    warn "atelier-scoped claude not authenticated — skipping Phase C.2"
    warn "Phase B should have authenticated; if it skipped (no TTY), re-run install.sh from a real terminal"
    phase_c_2_print_manual_commands
    return
  fi

  phase_c_2_marketplace
  for id in "${ATELIER_PLUGIN_IDS[@]}"; do
    phase_c_2_install_plugin "$id"
  done
  phase_c_2_coolify
  phase_c_2_vercel
  phase_c_2_neon
  ok "Phase C.2 complete"
}

# M4.23: optional Coolify integration. Off by default — most operators do not
# deploy to a VPS-hosted Coolify, so this is opt-in (default No). Yes installs
# the coolify-integration plugin and does the machine-wide setup (PATH +
# user-level allowlist); per-project token/URL is set later from each project's
# .env via /atelier:setup-coolify. Non-interactive (--yes / no TTY): skip with a
# pointer. Never aborts Phase C.2.
phase_c_2_coolify() {
  sublog "Optional: coolify-integration lets atelier deploy projects to a VPS-hosted Coolify instance."
  if [ "$NONINTERACTIVE" = true ] || [ ! -t 0 ]; then
    sublog "non-interactive — skipped. Enable anytime with /atelier:setup-coolify (or atelier-setup-coolify)."
    return
  fi
  local ans
  read -r -p "    Set up Coolify deployments now (installs the coolify-integration plugin)? [y/N]: " ans
  case "${ans:-N}" in
    [Yy]|[Yy][Ee][Ss])
      if "$ATELIER_SOURCE_ROOT/scripts/atelier-setup-coolify" --non-interactive; then
        COOLIFY_SET_UP=true
        ok "coolify-integration installed — add COOLIFY_BASE_URL + COOLIFY_API_TOKEN to a project's .env, or run /atelier:setup-coolify from it"
      else
        warn "Coolify setup did not complete — run it later with /atelier:setup-coolify"
      fi
      ;;
    *)
      sublog "skipped — set up anytime with /atelier:setup-coolify"
      ;;
  esac
}

# M4.27: optional Vercel integration. Off by default (opt-in). Same shape as
# phase_c_2_coolify. Per-project VERCEL_TOKEN is set later from each project's
# .env via /atelier:setup-vercel.
phase_c_2_vercel() {
  sublog "Optional: vercel-integration lets atelier deploy projects to Vercel (official Vercel CLI)."
  if [ "$NONINTERACTIVE" = true ] || [ ! -t 0 ]; then
    sublog "non-interactive — skipped. Enable anytime with /atelier:setup-vercel (or atelier-setup-vercel)."
    return
  fi
  local ans
  read -r -p "    Set up Vercel deployments now (installs the vercel-integration plugin)? [y/N]: " ans
  case "${ans:-N}" in
    [Yy]|[Yy][Ee][Ss])
      if "$ATELIER_SOURCE_ROOT/scripts/atelier-setup-vercel" --non-interactive; then
        VERCEL_SET_UP=true
        ok "vercel-integration installed — add VERCEL_TOKEN to a project's .env, or run /atelier:setup-vercel from it"
      else
        warn "Vercel setup did not complete — run it later with /atelier:setup-vercel"
      fi
      ;;
    *)
      sublog "skipped — set up anytime with /atelier:setup-vercel"
      ;;
  esac
}

# M4.28: optional Neon Postgres integration. Off by default (opt-in). Same shape
# as phase_c_2_coolify. Per-project NEON_API_KEY is set later from each project's
# .env via /atelier:setup-neon.
phase_c_2_neon() {
  sublog "Optional: neon-integration lets atelier manage Neon Postgres (branches, connection strings)."
  if [ "$NONINTERACTIVE" = true ] || [ ! -t 0 ]; then
    sublog "non-interactive — skipped. Enable anytime with /atelier:setup-neon (or atelier-setup-neon)."
    return
  fi
  local ans
  read -r -p "    Set up Neon Postgres now (installs the neon-integration plugin)? [y/N]: " ans
  case "${ans:-N}" in
    [Yy]|[Yy][Ee][Ss])
      if "$ATELIER_SOURCE_ROOT/scripts/atelier-setup-neon" --non-interactive; then
        NEON_SET_UP=true
        ok "neon-integration installed — add NEON_API_KEY to a project's .env, or run /atelier:setup-neon from it"
      else
        warn "Neon setup did not complete — run it later with /atelier:setup-neon"
      fi
      ;;
    *)
      sublog "skipped — set up anytime with /atelier:setup-neon"
      ;;
  esac
}

# ---------- final verification ----------

# Plain Unicode glyphs (not emojis) — match how `git-wt`'s installer reports.
# verify_cmd <label> <cmd...>
# Runs `cmd...` quietly; prints step_ok on exit 0, step_fail on non-zero.
# Never aborts the script — verification only reports state. M7.1.F2 routes
# the markers through the shared color/marker helpers so phase_verify's
# output matches the rest of the script.
verify_cmd() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    step_ok "$label"
  else
    step_fail "$label"
  fi
}

# verify_plugin <plugin_id>
# Checks that the given `<name>@<marketplace>` is in `claude plugin list --json`.
verify_plugin() {
  local plugin_id="$1"
  if claude plugin list --json 2>/dev/null \
      | jq -e --arg id "$plugin_id" '.[] | select(.id == $id)' >/dev/null; then
    step_ok "plugin: $plugin_id"
  else
    step_fail "plugin: $plugin_id"
  fi
}

phase_verify() {
  phase "Verification"
  verify_cmd    "claude --version"        claude --version
  # M7.1.F42 + F43 — verify the atelier-scoped auth (sessions launched by
  # the `atelier` wrapper use CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR). The
  # operator's personal ~/.claude/ is unrelated to whether atelier works.
  # `auth status` only reads the local file; F43 adds a real API ping via
  # `_phase_b_claude_api_ping` so an expired/revoked token surfaces here
  # instead of inside a future agent session as a 401.
  verify_cmd    "atelier claude auth status (local)" env CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth status
  if _phase_b_claude_api_ping; then
    step_ok "atelier claude auth (API ping)"
  else
    step_fail "atelier claude auth (API ping returned 401 — token expired or revoked, re-run install.sh)"
  fi
  # M5.0.1: verify both atelier-isolated gh identities. `env VAR=val cmd ...`
  # prefixes the env transparently for verify_cmd's "$@" passthrough.
  verify_cmd    "atelier gh auth (author)"   env GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"   gh auth status --hostname github.com
  verify_cmd    "atelier gh auth (reviewer)" env GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/reviewer" gh auth status --hostname github.com
  verify_cmd    "git wt help"             git wt help
  verify_plugin "atelier@akalab-tech"
  verify_plugin "claude-roadmap-tools@akalab-tech"
  sublog "(\`/doctor\` slash command lands with M1.6 / M2.x — not invoked here)"
}

# ---------- first-steps guide (M7.1.F12) ----------

# Prints the operator-facing "what to do next" block at the end of a
# successful install. Replaces the older one-line "install.sh done. Open a
# new terminal..." summary which left non-technical operators without a clear
# path forward. Numbered steps cover: reload shell, verify install, set up
# the first project, start the first task, find docs, undo the install.
# Commands are kept copy-pasteable (no embedded variables to substitute).
print_first_steps() {
  phase "Install complete"
  printf '\n'
  printf '  %sNext steps:%s\n\n' "$_C_BOLD" "$_C_RESET"

  printf '    1. %sReload your shell%s so the atelier hooks take effect:\n' "$_C_BOLD" "$_C_RESET"
  printf '         %ssource ~/.zshrc%s   # or ~/.bashrc\n\n' "$_C_CYAN" "$_C_RESET"

  printf '    2. %sVerify the install%s — run the atelier-managed doctor (M7.1.F13: `atelier` is the new shortcut that opens Claude Code under $ATELIER_CONFIG_DIR; bare `claude` would load your personal config and would NOT see atelier`s commands):\n' "$_C_BOLD" "$_C_RESET"
  printf '         %satelier /atelier:doctor%s\n\n' "$_C_CYAN" "$_C_RESET"

  printf '    3. %sSet up your first project%s — `cd` into the project then run setup-project:\n' "$_C_BOLD" "$_C_RESET"
  printf '         %scd <path-to-project>%s\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier /atelier:setup-project .%s\n\n' "$_C_CYAN" "$_C_RESET"

  if [ "$COOLIFY_SET_UP" = true ]; then
    printf '       %sCoolify%s — you enabled coolify-integration. For each project you deploy, wire its\n' "$_C_BOLD" "$_C_RESET"
    printf '       Coolify instance (writes COOLIFY_BASE_URL + COOLIFY_API_TOKEN to the project`s .env):\n'
    printf '         %scd <path-to-project> && atelier /atelier:setup-coolify%s\n\n' "$_C_CYAN" "$_C_RESET"
  fi

  if [ "$VERCEL_SET_UP" = true ]; then
    printf '       %sVercel%s — you enabled vercel-integration. For each project you deploy, wire its\n' "$_C_BOLD" "$_C_RESET"
    printf '       VERCEL_TOKEN into the project`s .env:\n'
    printf '         %scd <path-to-project> && atelier /atelier:setup-vercel%s\n\n' "$_C_CYAN" "$_C_RESET"
  fi

  if [ "$NEON_SET_UP" = true ]; then
    printf '       %sNeon%s — you enabled neon-integration. For each project that uses Neon, wire its\n' "$_C_BOLD" "$_C_RESET"
    printf '       NEON_API_KEY into the project`s .env:\n'
    printf '         %scd <path-to-project> && atelier /atelier:setup-neon%s\n\n' "$_C_CYAN" "$_C_RESET"
  fi

  printf '    4. %sStart your first task%s — `task` reads the next ROADMAP entry from the current project and runs the full task cycle:\n' "$_C_BOLD" "$_C_RESET"
  printf '         %stask%s\n\n' "$_C_CYAN" "$_C_RESET"

  printf '    5. %sExplore the full command surface%s (M7.1.F34):\n' "$_C_BOLD" "$_C_RESET"
  printf '         %satelier --help%s              # complete command reference: terminal helpers + slash commands\n' "$_C_CYAN" "$_C_RESET"
  printf '       Key helpers you should know about:\n'
  printf '         %satelier-doctor [--fix]%s      # health check; --fix auto-applies\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier-update%s              # pull latest atelier + refresh\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier-list-projects%s       # list every registered project\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier-remove-project <p>%s  # deconfigure ONE project\n\n' "$_C_CYAN" "$_C_RESET"

  printf '    6. %sDocs%s:\n' "$_C_BOLD" "$_C_RESET"
  printf '         - docs/operator-guide.md (Jr-friendly walkthrough — start here)\n'
  printf '         - docs/troubleshooting.md (symptom-indexed: when something does not work)\n'
  printf '         - README.md (overview + plugin-only install)\n'
  printf '         - PLAN.md §12 (architecture + milestone roadmap)\n'
  printf '         - docs/dogfood-guide.md (full-flow integration test)\n\n'

  printf '    7. %sUninstall safely%s — when you no longer need atelier:\n' "$_C_BOLD" "$_C_RESET"
  printf '         %satelier-remove-project <p>%s  # deconfigure ONE project (preserves atelier itself)\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier-uninstall%s             # whole-system uninstall, preserves chat history\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier-uninstall --purge%s     # also wipes $ATELIER_CONFIG_DIR\n\n' "$_C_CYAN" "$_C_RESET"
}

# ---------- entry point ----------

main() {
  parse_args "$@"
  resolve_config_dir
  # #39 F1: resolve the tree atelier installs FROM (clone, plugin cache, or
  # tarball) + how it is delivered. Behavior-neutral: every phase runs the
  # same in both modes; the mode is logged for the operator/doctor.
  resolve_source_root
  detect_source_mode

  # Pin every claude invocation in this script (Phase B auth, Phase C.2
  # marketplace + plugin install) to atelier's resolved config dir. Child
  # processes inherit the export; the operator's parent shell is
  # unaffected (this is a subshell export). The shellrc hook block
  # injected by Phase C.1 sets the same convention inline on the `task()`
  # function so the operator's interactive sessions also land here.
  export CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"

  # --refresh-shellrc: re-inject only the shellrc hook block and exit. No
  # preflight / deps / auth / plugin work — phase_c_1_shellrc_hooks is
  # self-contained (needs only $ATELIER_CONFIG_DIR + the log helpers). Lets
  # atelier-update propagate shellrc changes without a full re-install.
  if [ "$REFRESH_SHELLRC_ONLY" = true ]; then
    log "atelier install.sh — refreshing shellrc hook block only"
    sublog "atelier config dir: $ATELIER_CONFIG_DIR"
    phase_c_1_shellrc_hooks
    exit 0
  fi

  log "atelier install.sh starting (os=$(detect_os), arch=$(uname -m))"
  sublog "atelier config dir: $ATELIER_CONFIG_DIR"
  sublog "source root: $ATELIER_SOURCE_ROOT (mode: $SOURCE_MODE)"

  phase_0_preflight
  phase_a
  phase_b
  phase_c_1
  phase_c_2
  phase_verify
  # M7.1.F6: stamp the marker installStatus=complete only after every phase
  # succeeds. A crash before this point leaves installStatus=in_progress so
  # the next install.sh run offers a resume rather than treating the
  # partially-populated $ATELIER_CONFIG_DIR as an opaque collision.
  mark_install_complete
  print_first_steps
}

# Main-gate (#39 F1/F2): run main only when install.sh is executed, not when
# it is sourced. The hermetic tests (hooks/tests/install-*.test.sh) source
# this file to exercise individual phase functions (resolve_source_root,
# phase_c_1_runtime_dir, ...) without triggering a full install. The
# `return` probe succeeds only in a sourced context.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
