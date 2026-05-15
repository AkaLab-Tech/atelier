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

# ---------- phase stubs (implemented in later sub-PRs) ----------

phase_c_1() { log "Phase C.1 — host-OS configuration"; sublog "(not yet implemented; tracked in M1.3)"; }
phase_c_2() { log "Phase C.2 — plugin install";        sublog "(not yet implemented; tracked in M1.3)"; }

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
