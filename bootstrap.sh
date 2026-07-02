#!/usr/bin/env bash
#
# atelier bootstrap.sh — repo-less one-line installer (#39 F3).
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/AkaLab-Tech/atelier/main/bootstrap.sh | bash
#
# Prefer to inspect before running (two-step):
#   curl -fsSLO https://raw.githubusercontent.com/AkaLab-Tech/atelier/main/bootstrap.sh
#   less bootstrap.sh    # audit it — this file is the ONLY curl|bash artifact
#   bash bootstrap.sh
#
# What it does (and nothing more):
#   1. checks the minimal deps (git, jq, curl) — prints per-OS install hints,
#      never runs sudo on your behalf
#   2. resolves $ATELIER_CONFIG_DIR (env override, default ~/.claude-work)
#   3. installs Claude Code if missing (the same official Anthropic installer
#      install.sh Phase A uses)
#   4. registers the akalab-tech plugin marketplace (idempotent)
#   5. installs the atelier plugin — Claude Code's plugin cache then holds the
#      full atelier tree, including the real installer
#   6. hands over: exec <plugin-cache>/install.sh --from-cache [your args...]
#
# The full phased install (deps, auth, runtime dir, plugin config) lives in
# install.sh; this file stays tiny so an operator can audit it in one screen.
#
# Env:
#   ATELIER_CONFIG_DIR          override the config root (default ~/.claude-work)
#   ATELIER_BOOTSTRAP_NO_EXEC   =1 → stop after step 5 without exec'ing the
#                               cached install.sh (used by the hermetic tests)

set -euo pipefail
IFS=$'\n\t'

# ---------- tiny local helpers (mirrors install.sh's style; intentionally
# ---------- not sourced from it — install.sh is not on disk yet) ----------
msg()  { printf '==> %s\n' "$*"; }
sub()  { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '!!  ERROR: %s\n' "$*" >&2; exit 1; }

# Same identifiers as install.sh Phase C.2. Full HTTPS URL, not the org/repo
# shortcut — the shortcut defaults to SSH and fails on a clean machine with
# no SSH keys (install.sh M7.1.F9; PLAN.md §2 step 5: HTTPS only).
MARKETPLACE_SOURCE="https://github.com/AkaLab-Tech/claude-plugins.git"
MARKETPLACE_NAME="akalab-tech"
PLUGIN_ID="atelier@akalab-tech"

# ---------- 1) minimal deps ----------
missing=()
for dep in git jq curl; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [ ${#missing[@]} -gt 0 ]; then
  warn "missing required tools: ${missing[*]}"
  case "${OSTYPE:-}" in
    darwin*) warn "install them with:  brew install ${missing[*]}    (Homebrew: https://brew.sh)" ;;
    linux*)  warn "install them with:  sudo apt-get update && sudo apt-get install -y ${missing[*]}" ;;
    *)       warn "install them with your OS package manager" ;;
  esac
  die "re-run bootstrap.sh once they are installed (bootstrap never runs sudo for you)"
fi

# ---------- 2) config dir (same resolution as install.sh: env > default) ----------
# Resolved before anything touches the claude CLI so EVERY claude invocation
# below is pinned to atelier's isolated config root — never ~/.claude.
ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-${HOME}/.claude-work}"
ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR/#\~/$HOME}"
export ATELIER_CONFIG_DIR
mkdir -p "$ATELIER_CONFIG_DIR"
msg "atelier config dir: $ATELIER_CONFIG_DIR"

# ---------- 3) Claude Code ----------
if command -v claude >/dev/null 2>&1; then
  msg "Claude Code already installed ($(CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude --version </dev/null 2>/dev/null || echo unknown))"
else
  # Exactly the installer install.sh phase_a_claude_code uses: hosted by
  # Anthropic, lands a GPG-signed binary — see
  # https://code.claude.com/docs/en/setup ("Native Install").
  msg "installing Claude Code via the official native installer"
  curl -fsSL https://claude.ai/install.sh | bash
  # The native installer targets ~/.local/bin, which may not be on PATH yet
  # in this (fresh-machine) shell.
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) : ;;
    *) PATH="${HOME}/.local/bin:${PATH}" ;;
  esac
  command -v claude >/dev/null 2>&1 \
    || die "claude CLI not on PATH after install — open a new terminal and re-run bootstrap.sh"
fi

# ---------- 4) marketplace (idempotent — mirrors phase_c_2_marketplace) ----------
if CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin marketplace list --json </dev/null 2>/dev/null \
    | jq -e --arg name "$MARKETPLACE_NAME" '.[] | select(.name == $name)' >/dev/null; then
  sub "marketplace $MARKETPLACE_NAME already added — skipping"
else
  msg "adding marketplace $MARKETPLACE_SOURCE"
  # </dev/null: keeps any CLI prompt from eating the piped script stream
  # under `curl | bash` (same guard as scripts/atelier-* plugin calls).
  CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin marketplace add "$MARKETPLACE_SOURCE" </dev/null
fi

# ---------- 5) plugin install (idempotent — mirrors phase_c_2_install_plugin) ----------
if CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin list --json </dev/null 2>/dev/null \
    | jq -e --arg id "$PLUGIN_ID" '.[] | select(.id == $id)' >/dev/null; then
  sub "$PLUGIN_ID already installed — skipping"
else
  msg "installing $PLUGIN_ID"
  CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin install "$PLUGIN_ID" </dev/null
fi

# ---------- 6) delegate to the cached install.sh ----------
# Resolve the ACTIVE version's cache dir via installed_plugins.json — the
# claude CLI's own pointer file — never by globbing version dirs (multiple
# versions may coexist in the cache; the pointer says which one is live).
manifest="$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
[ -f "$manifest" ] \
  || die "$manifest not found after plugin install — Claude Code plugin layout changed?"
install_path="$(jq -r --arg id "$PLUGIN_ID" '.plugins[$id][0].installPath // empty' "$manifest" 2>/dev/null || true)"
[ -n "$install_path" ] || die "no installPath recorded for $PLUGIN_ID in $manifest"
install_path="${install_path/#\~/$HOME}"
[ -f "$install_path/install.sh" ] \
  || die "cached plugin at $install_path does not ship install.sh — cannot delegate"

msg "handing over to the cached installer: $install_path/install.sh --from-cache"
if [ "${ATELIER_BOOTSTRAP_NO_EXEC:-}" = "1" ]; then
  sub "ATELIER_BOOTSTRAP_NO_EXEC=1 — stopping before exec (target printed above)"
  exit 0
fi
exec bash "$install_path/install.sh" --from-cache "$@"
