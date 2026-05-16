#!/usr/bin/env bash
#
# atelier install.sh — single entry-point installer.
#
# Phases (per PLAN.md §2):
#   A    base deps (git, gh, fnm, pnpm, jq, fzf) + Claude Code
#   B    Claude + GitHub auth                              [not yet implemented]
#   C.1  git-wt, .env* excludes, git identity, shellrc     [not yet implemented]
#   C.2  drive Claude Code to install the atelier plugin   [not yet implemented]
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
# Auto-switch Node version per-project via .nvmrc.
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi
# `task`: open a Claude session for the next roadmap task in this project.
# Wired by M2.3 once `/next-task` lands; the alias ships here so the operator
# does not need to re-run install.sh after M2.3.
task() { claude "/next-task $*"; }
# `task-status`: list the operator's open PRs across all repos they own.
alias task-status='gh pr list --author @me --state open'
# <<< atelier hooks (managed by install.sh) <<<
BLOCK
)

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
  phase_c_1_git_wt
  phase_c_1_env_excludes
  phase_c_1_git_identity
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

# ---------- entry point ----------

main() {
  log "atelier install.sh starting (os=$(detect_os), arch=$(uname -m))"
  phase_a
  phase_b
  phase_c_1
  phase_c_2
  log "install.sh done. Subsequent phases will ship in follow-up sub-PRs of M1.3."
}

main "$@"
