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
#   - logging via log() / sublog() / warn() / die() / ok() helpers (ASCII-only,
#     to stay terminal-portable).
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

# Resolved by resolve_config_dir() in main() — must NOT be referenced before
# parse_args + resolve_config_dir have run.
ATELIER_CONFIG_DIR=""

# ---------- logging ----------

log()    { printf '==> %s\n' "$*"; }
sublog() { printf '    %s\n' "$*"; }
warn()   { printf '!!  %s\n' "$*" >&2; }
die()    { printf '!!  ERROR: %s\n' "$*" >&2; exit 1; }
ok()     { printf '    OK: %s\n' "$*"; }

# ---------- tiny utilities ----------

has() { command -v "$1" >/dev/null 2>&1; }

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

PREFLIGHT BEHAVIOUR (M5.0.2):
  Before any install step, install.sh inspects the resolved
  \$ATELIER_CONFIG_DIR:
    - empty / non-existent → proceed (will be created in Phase C.1)
    - contains the \`.atelier-managed\` marker or \`plugins/<*>/atelier/\`
      → recognised as a previous atelier install, proceed (idempotent)
    - contains other content → STOP. Interactive: prompt for an
      alternative path. Non-interactive: error out with the resolution
      options above.
EOF
}

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
  # Priority: --config-dir flag > $ATELIER_CONFIG_DIR env > default.
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

# ---------- phase 0: preflight (M5.0.2) ----------

# Return 0 if $1 (path) is safe to use as atelier's config dir; 1 otherwise.
# Safe states: doesn't exist, exists but empty, exists with atelier markers
# (the .atelier-managed file or plugins/<*>/atelier/). Unsafe state: exists
# with unrelated content.
preflight_check() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  [ -z "$(ls -A "$dir" 2>/dev/null)" ] && return 0
  [ -f "$dir/.atelier-managed" ] && return 0
  # Glob expands to nothing if no match; the nullglob behaviour is the
  # safe path. Wrap in a subshell so set -e + nullglob don't leak out.
  if ( shopt -s nullglob; matches=("$dir/plugins"/*/atelier); [ ${#matches[@]} -gt 0 ] ); then
    return 0
  fi
  return 1
}

phase_0_preflight() {
  log "Phase 0 — preflight: atelier config dir collision check"
  while true; do
    if preflight_check "$ATELIER_CONFIG_DIR"; then
      sublog "atelier config dir OK: $ATELIER_CONFIG_DIR"
      return 0
    fi

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
    printf "    pick an alternative path (e.g. ~/.claude-atelier/, ~/.atelier/): " >&2
    local answer=""
    read -r answer
    [ -n "$answer" ] || { warn "empty path, try again"; continue; }
    answer="${answer/#\~/$HOME}"
    ATELIER_CONFIG_DIR="$answer"
    export ATELIER_CONFIG_DIR
    sublog "trying $ATELIER_CONFIG_DIR ..."
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
      sublog "$f already installed"
    else
      missing+=("$f")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    sublog "installing via brew: ${missing[*]}"
    brew install "${missing[@]}"
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
      sublog "$p already installed"
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
    sublog "gh already installed"
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
    sublog "fnm already installed"
  else
    sublog "installing fnm via its official installer (no shellrc edit yet)"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
    # Make fnm available for the remainder of this script run.
    export PATH="${HOME}/.local/share/fnm:${PATH}"
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
    sublog "node already available ($(node --version))"
  fi

  if has pnpm; then
    sublog "pnpm already installed ($(pnpm --version))"
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
    sublog "Claude Code already installed ($v)"
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

phase_a() {
  log "Phase A — base dependencies + Claude Code"
  local os
  os="$(detect_os)"
  case "$os" in
    mac)   phase_a_mac_deps ;;
    linux) phase_a_linux_deps ;;
  esac
  phase_a_node_and_pnpm
  phase_a_claude_code
  ok "Phase A complete"
}

# ---------- phase B: authentication ----------

phase_b_claude_login() {
  # `claude auth status` exits 0 if authenticated, non-0 otherwise. This is
  # the idempotency hinge — re-runs of install.sh on an already-logged-in
  # machine short-circuit here without touching the browser.
  if claude auth status >/dev/null 2>&1; then
    sublog "Claude Code already authenticated"
    return
  fi
  sublog "starting Claude Code login (a browser tab will open)"
  claude auth login
}

phase_b_github_login() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    sublog "gh already authenticated for github.com"
  else
    sublog "starting GitHub login (browser-based OAuth; HTTPS only)"
    # --web              browser-based OAuth.
    # --git-protocol https  HTTPS only — atelier never uses SSH (PLAN.md §2 step 5).
    # --skip-ssh-key     defense-in-depth: even if a future flag combo would
    #                    suggest an SSH key prompt, skip it.
    # --scopes           per PLAN.md §2 step 5.
    gh auth login \
      --hostname github.com \
      --git-protocol https \
      --web \
      --skip-ssh-key \
      --scopes "repo,workflow,project,read:org"
  fi
  # Register gh as git credential helper for HTTPS. Idempotent.
  sublog "registering gh as git credential helper (HTTPS, idempotent)"
  gh auth setup-git
}

phase_b() {
  log "Phase B — authentication"

  # Phase B is the only interactive phase: it depends on browser-based OAuth
  # and a human at the keyboard. When install.sh runs without a TTY (CI, a
  # piped install, an `ssh host 'bash install.sh'` without -t), skip the
  # interactive flow with a clear message and let Phases C.1/C.2 continue.
  # The operator can complete auth later from a real terminal.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    warn "no TTY detected — skipping Phase B (interactive auth)"
    warn "to complete auth, re-run on a real terminal, or run these by hand:"
    warn "  claude auth login"
    warn "  gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes 'repo,workflow,project,read:org'"
    warn "  gh auth setup-git"
    return
  fi

  phase_b_claude_login
  phase_b_github_login
  ok "Phase B complete"
}

# ---------- phase C.1: host-OS configuration ----------

# Persistent state directory for atelier (XDG-compliant). /doctor (M1.6) reads
# the recorded git-wt SHA from here to detect drift against upstream.
ATELIER_STATE_DIR="${HOME}/.local/state/atelier"

phase_c_1_claude_config_dir() {
  # Create atelier's isolated config root if it does not yet exist (M5.0),
  # then write a small marker file so future preflight runs (M5.0.2) can
  # recognise this directory as atelier-managed without false-positive
  # collision warnings. The marker is refreshed on every install, so its
  # `installedAt` reflects the most recent install timestamp (not the
  # original — keep the install state observable but minimal).
  if [ ! -d "$ATELIER_CONFIG_DIR" ]; then
    mkdir -p "$ATELIER_CONFIG_DIR"
    sublog "created atelier config root: $ATELIER_CONFIG_DIR"
  else
    sublog "atelier config root already exists: $ATELIER_CONFIG_DIR"
  fi

  cat > "$ATELIER_CONFIG_DIR/.atelier-managed" <<MARKER
{
  "managedBy": "atelier",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "installerVersion": "0.1.0",
  "atelierConfigDir": "$ATELIER_CONFIG_DIR"
}
MARKER
  sublog "wrote $ATELIER_CONFIG_DIR/.atelier-managed marker"
}

phase_c_1_git_wt() {
  local sha_file="$ATELIER_STATE_DIR/git-wt.sha"

  # Fully provisioned: git-wt on PATH and a SHA is on file. Skip clone +
  # install + re-record.
  if has git-wt && [ -s "$sha_file" ]; then
    sublog "git-wt already installed (recorded SHA: $(head -c 12 "$sha_file"))"
    return
  fi

  # Either git-wt is missing, or the SHA file is missing (operator may have
  # installed git-wt manually before atelier started tracking it). Clone the
  # current upstream HEAD; install only when git-wt is not on PATH; always
  # record the SHA. /doctor (M1.6) compares this value against
  # `gh api repos/Miguelslo27/git-wt/commits/main`. When recording on a
  # backfill (git-wt was already installed), the recorded SHA reflects
  # upstream HEAD at install.sh runtime — close enough for v1 drift
  # detection; the next install.sh run will refresh it.
  sublog "cloning Miguelslo27/git-wt into /tmp/git-wt"
  rm -rf /tmp/git-wt
  git clone --depth 1 https://github.com/Miguelslo27/git-wt.git /tmp/git-wt

  if ! has git-wt; then
    sublog "running git-wt installer (--skill-for=claude)"
    /tmp/git-wt/install.sh --skill-for=claude
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

phase_c_1_setup_project_helper() {
  # Symlink scripts/atelier-setup-project into ~/.local/bin so:
  #   - the /atelier:setup-project slash command can invoke it via
  #     Bash(atelier-setup-project:*) from inside Claude Code;
  #   - the operator can also run it directly from any terminal.
  #
  # Why a symlink and not a copy: the operator already has the atelier
  # checkout (from `git clone`), and `install.sh` is re-run when atelier is
  # updated. A symlink ensures every script change is picked up without a
  # separate "copy step". The link target is absolute so it survives the
  # operator's cwd changing between install runs.
  local src="$ATELIER_REPO_ROOT/scripts/atelier-setup-project"
  local bin_dir="${HOME}/.local/bin"
  local dest="$bin_dir/atelier-setup-project"

  if [ ! -f "$src" ]; then
    warn "expected $src — skipping atelier-setup-project install"
    warn "this likely means install.sh is being run from outside the atelier checkout"
    return
  fi
  if [ ! -x "$src" ]; then
    warn "$src is not executable — chmoding +x"
    chmod +x "$src"
  fi

  mkdir -p "$bin_dir"

  if [ -L "$dest" ]; then
    local current
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      sublog "atelier-setup-project already symlinked ($dest -> $src)"
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

  # PATH check. The shellrc hook block below adds ~/.local/bin to PATH for
  # future shells, but the current install.sh run probably doesn't have it
  # yet. Warn rather than fail.
  case ":${PATH:-}:" in
    *":$bin_dir:"*) sublog "$bin_dir is on PATH"               ;;
    *) sublog "$bin_dir not on PATH for this shell — will be set by shellrc hook on next login" ;;
  esac
}

phase_c_1_shellrc_hooks() {
  # Idempotent injection via sentinel comments. On re-run, skip if the start
  # sentinel is already present. To refresh the block manually, remove
  # everything between the sentinels (inclusive) and re-run install.sh.
  local sentinel_start='# >>> atelier hooks (managed by install.sh) >>>'

  # Heredoc is single-quoted: `$(fnm env --use-on-cd)`, `$*`, and the alias
  # body are written as literal text, expanded later when the shell sources
  # the rc file (not now, while install.sh runs).
  local block
  block=$(cat <<'BLOCK'
# >>> atelier hooks (managed by install.sh) >>>
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
# `task`: open a Claude session for the next roadmap task in this project.
# CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR pins the session to atelier's
# config root — separate from the operator's personal Claude config so
# atelier's autonomous-mode rules don't conflict with personal rules.
task() { CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude "/next-task $*"; }
# `task-status`: list the operator's open PRs across all repos they own.
alias task-status='gh pr list --author @me --state open'
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
    if grep -qF "$sentinel_start" "$f"; then
      sublog "atelier hooks already present in $(basename "$f")"
    else
      printf '\n%s\n' "$block" >> "$f"
      sublog "appended atelier hooks to $(basename "$f")"
    fi
  done
}

phase_c_1() {
  log "Phase C.1 — host-OS configuration"
  phase_c_1_claude_config_dir
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
ATELIER_MARKETPLACE_SOURCE="AkaLab-Tech/claude-plugins"
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
    sublog "marketplace $ATELIER_MARKETPLACE_NAME already added"
  else
    sublog "adding marketplace $ATELIER_MARKETPLACE_SOURCE"
    claude plugin marketplace add "$ATELIER_MARKETPLACE_SOURCE"
  fi
}

phase_c_2_install_plugin() {
  local plugin_id="$1"
  if claude plugin list --json 2>/dev/null \
      | jq -e --arg id "$plugin_id" '.[] | select(.id == $id)' >/dev/null; then
    sublog "$plugin_id already installed"
  else
    sublog "installing $plugin_id"
    claude plugin install "$plugin_id"
  fi
}

phase_c_2() {
  log "Phase C.2 — plugin install"

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
VERIFY_OK='\xe2\x9c\x93'   # ✓
VERIFY_FAIL='\xe2\x9c\x97' # ✗

# verify_cmd <label> <cmd...>
# Runs `cmd...` quietly; prints ✓ on exit 0, ✗ on non-zero. Never aborts the
# script — verification only reports state.
verify_cmd() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "    ${VERIFY_OK} %s\n" "$label"
  else
    printf "    ${VERIFY_FAIL} %s\n" "$label" >&2
  fi
}

# verify_plugin <plugin_id>
# Checks that the given `<name>@<marketplace>` is in `claude plugin list --json`.
verify_plugin() {
  local plugin_id="$1"
  if claude plugin list --json 2>/dev/null \
      | jq -e --arg id "$plugin_id" '.[] | select(.id == $id)' >/dev/null; then
    printf "    ${VERIFY_OK} plugin: %s\n" "$plugin_id"
  else
    printf "    ${VERIFY_FAIL} plugin: %s\n" "$plugin_id" >&2
  fi
}

phase_verify() {
  log "Verification"
  verify_cmd    "claude --version"        claude --version
  verify_cmd    "claude auth status"      claude auth status
  verify_cmd    "gh auth status"          gh auth status
  verify_cmd    "git wt help"             git wt help
  verify_plugin "atelier@akalab-tech"
  verify_plugin "claude-roadmap-tools@akalab-tech"
  sublog "(\`/doctor\` slash command lands with M1.6 / M2.x — not invoked here)"
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
  log "install.sh done. Open a new terminal (or run \`source ~/.zshrc\`) to use \`task\` and \`task-status\`."
}

main "$@"
