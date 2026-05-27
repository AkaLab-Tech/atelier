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

# Absolute path of the atelier checkout this install.sh lives in. Phase C.1
# symlinks scripts/atelier-setup-project from here into ~/.local/bin so the
# slash command can call it from inside Claude (and the operator from their
# terminal). Computed once at script load; doesn't follow symlinks because
# the operator's clone is the canonical source.
ATELIER_REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  --yes, -y             Non-interactive mode. The preflight collision
                        check refuses (rather than prompts) if the target
                        config dir already has unrelated content.
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
      --yes|-y)
        NONINTERACTIVE=true; shift ;;
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

phase_b_claude_login() {
  # `claude auth status` exits 0 if authenticated, non-0 otherwise. This is
  # the idempotency hinge — re-runs of install.sh on an already-logged-in
  # machine short-circuit here without touching the browser.
  if claude auth status >/dev/null 2>&1; then
    # M7.1.F4: offer to switch accounts. Skip the prompt in non-interactive
    # mode (--yes / no TTY) — keep the existing account silently.
    if $NONINTERACTIVE || [ ! -t 0 ]; then
      step_skip "Claude Code already authenticated (keeping existing account)"
      return
    fi
    local current=""
    current="$(claude auth status 2>&1 | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | head -1 || true)"
    if [ -n "$current" ]; then
      printf '    Claude Code already authenticated as %s%s%s. Keep (Y) or switch to another account (s)? [Y/s]: ' "$_C_BOLD" "$current" "$_C_RESET"
    else
      printf '    Claude Code already authenticated. Keep current account (Y) or switch (s)? [Y/s]: '
    fi
    local switch_choice=""
    read -r switch_choice
    case "$switch_choice" in
      s|S|switch|SWITCH)
        sublog "logging out current Claude account, fresh login coming up"
        claude auth logout 2>/dev/null || true
        sublog "starting Claude Code login (a browser tab will open)"
        claude auth login
        ;;
      *)
        step_skip "Claude Code already authenticated (keeping existing account)"
        ;;
    esac
    return
  fi
  sublog "starting Claude Code login (a browser tab will open)"
  claude auth login
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
    warn "  claude auth login"
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
  local src_dir="$ATELIER_REPO_ROOT/templates"
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

  # Fully provisioned: git-wt on PATH and a SHA is on file. Skip clone +
  # install + re-record.
  if has git-wt && [ -s "$sha_file" ]; then
    step_skip "git-wt already installed (recorded SHA: $(head -c 12 "$sha_file"))"
    return
  fi

  # Either git-wt is missing, or the SHA file is missing (operator may have
  # installed git-wt manually before atelier started tracking it). Clone the
  # current upstream HEAD; install only when git-wt is not on PATH; always
  # record the SHA. /doctor (M1.6) compares this value against
  # `gh api repos/AkaLab-Tech/git-wt/commits/main`. When recording on a
  # backfill (git-wt was already installed), the recorded SHA reflects
  # upstream HEAD at install.sh runtime — close enough for v1 drift
  # detection; the next install.sh run will refresh it.
  sublog "cloning AkaLab-Tech/git-wt into /tmp/git-wt"
  rm -rf /tmp/git-wt
  git clone --depth 1 https://github.com/AkaLab-Tech/git-wt.git /tmp/git-wt

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

_phase_c_1_symlink_helper() {
  # Helper that symlinks one of atelier's bin scripts into ~/.local/bin.
  # Idempotent: re-link if the existing symlink points elsewhere; leave
  # plain files alone (operator may have pinned a manual copy).
  local helper_name="$1"
  local src="$ATELIER_REPO_ROOT/scripts/$helper_name"
  local bin_dir="${HOME}/.local/bin"
  local dest="$bin_dir/$helper_name"

  if [ ! -f "$src" ]; then
    warn "expected $src — skipping $helper_name install"
    warn "this likely means install.sh is being run from outside the atelier checkout"
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
  # Why a symlink and not a copy: the operator already has the atelier
  # checkout (from `git clone`), and `install.sh` is re-run when atelier is
  # updated. A symlink ensures every script change is picked up without a
  # separate "copy step". The link target is absolute so it survives the
  # operator's cwd changing between install runs.
  local bin_dir="${HOME}/.local/bin"
  mkdir -p "$bin_dir"

  _phase_c_1_symlink_helper atelier-setup-project
  _phase_c_1_symlink_helper atelier-uninstall
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
  local current_version=2

  # Heredoc is single-quoted: `$(fnm env --use-on-cd)`, `$*`, and the alias
  # body are written as literal text, expanded later when the shell sources
  # the rc file (not now, while install.sh runs).
  local block
  block=$(cat <<'BLOCK'
# >>> atelier hooks (managed by install.sh) >>>
# atelier-hooks-version: 2
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
  local project
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
    claude "/next-task $*"
}
# `atelier`: general-purpose entry point that opens a Claude Code session
# under atelier's isolated config root, optionally with arbitrary arguments
# passed through to `claude`. Unlike `task`, this does NOT auto-invoke a
# slash command — operators use it for `atelier /atelier:setup-project
# <path>` (M7.1 dogfood-3 first-project bootstrap), `atelier /atelier:doctor`
# (health check), `atelier` (bare — interactive exploration under atelier
# config), or any other slash command the plugin ships (M7.1.F13). Same
# CLAUDE_CONFIG_DIR + GH_CONFIG_DIR + GIT_CONFIG_GLOBAL env chain as `task`
# so the loaded plugin sees the atelier-managed marketplace and the right
# identities — agents/skills/commands behave consistently across both
# entry points.
atelier() {
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

phase_c_1() {
  phase "Phase C.1 — host-OS configuration"
  phase_c_1_claude_config_dir
  phase_c_1_instantiate_templates
  phase_c_1_git_wt
  phase_c_1_env_excludes
  phase_c_1_git_identity
  phase_c_1_setup_project_helper
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
  if ! claude auth status >/dev/null 2>&1; then
    warn "claude not authenticated — skipping Phase C.2"
    warn "Phase B should have authenticated; if it skipped (no TTY), re-run install.sh from a real terminal"
    phase_c_2_print_manual_commands
    return
  fi

  phase_c_2_marketplace
  for id in "${ATELIER_PLUGIN_IDS[@]}"; do
    phase_c_2_install_plugin "$id"
  done
  ok "Phase C.2 complete"
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
  verify_cmd    "claude auth status"      claude auth status
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

  printf '    4. %sStart your first task%s — `task` reads the next ROADMAP entry from the current project and runs the full task cycle:\n' "$_C_BOLD" "$_C_RESET"
  printf '         %stask%s\n\n' "$_C_CYAN" "$_C_RESET"

  printf '    5. %sDocs%s:\n' "$_C_BOLD" "$_C_RESET"
  printf '         - docs/operator-guide.md (Jr-friendly walkthrough — start here)\n'
  printf '         - docs/troubleshooting.md (symptom-indexed: when something does not work)\n'
  printf '         - README.md (overview + plugin-only install)\n'
  printf '         - PLAN.md §12 (architecture + milestone roadmap)\n'
  printf '         - docs/dogfood-guide.md (full-flow integration test)\n\n'

  printf '    6. %sUninstall safely%s — when you no longer need atelier:\n' "$_C_BOLD" "$_C_RESET"
  printf '         %satelier-uninstall%s             # preserves chat history\n' "$_C_CYAN" "$_C_RESET"
  printf '         %satelier-uninstall --purge%s     # also wipes $ATELIER_CONFIG_DIR\n\n' "$_C_CYAN" "$_C_RESET"
}

# ---------- entry point ----------

main() {
  parse_args "$@"
  resolve_config_dir

  # Pin every claude invocation in this script (Phase B auth, Phase C.2
  # marketplace + plugin install) to atelier's resolved config dir. Child
  # processes inherit the export; the operator's parent shell is
  # unaffected (this is a subshell export). The shellrc hook block
  # injected by Phase C.1 sets the same convention inline on the `task()`
  # function so the operator's interactive sessions also land here.
  export CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"

  log "atelier install.sh starting (os=$(detect_os), arch=$(uname -m))"
  sublog "atelier config dir: $ATELIER_CONFIG_DIR"

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

main "$@"
