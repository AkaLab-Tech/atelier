#!/usr/bin/env bash
#
# Regression test for #809 — `--plugin-root` / $ATELIER_PLUGIN_ROOT on the
# allow-listed helpers (atelier-update, atelier-setup-project).
#
# Both helpers sit behind broad allow rules (`Bash(atelier-update:*)`,
# `Bash(atelier-setup-project:*)`), and both used to accept any directory as
# the plugin root, so an agent Bash call could point them at a tree it wrote
# and get that tree's code installed/executed. The fix has three layers, all
# covered here:
#
#   1. Script boundary: a root given through the flag or the env var is
#      accepted only when it canonicalises (cd -P) to the helper's own source
#      root, the managed runtime dir (`current` or a version child) or the
#      marketplace install ($ATELIER_CONFIG_DIR/plugins/*/atelier). Anything
#      else is refused when stdin is not a TTY, BEFORE any side effect.
#   2. Template deny list: the flag on both helpers, and the pseudo-terminal
#      wrappers (script / unbuffer / expect) that could fake the TTY, are in
#      permissions.deny.
#   3. atelier-permission-diff describes every new deny entry.
#
# Plus: clone-mode advisory warning when the origin repo name is not
# atelier / atelier-*.
#
# Hermetic: fake $HOME, $ATELIER_CONFIG_DIR and $ATELIER_RUNTIME_DIR under
# mktemp; local git repos only; claude/gh shimmed; no network; stdin is
# /dev/null (never a TTY) unless a case says otherwise.
#
# Run:  hooks/tests/helper-plugin-root-restriction.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE_SRC="$REPO_ROOT/scripts/atelier-update"
SETUP_SRC="$REPO_ROOT/scripts/atelier-setup-project"
PDIFF="$REPO_ROOT/scripts/atelier-permission-diff"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"; trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); fails=$((fails + 1)); printf '  FAIL: %s\n' "$1"; }
skip() { printf '  SKIP: %s\n' "$1"; }

echo "helper --plugin-root restriction (#809)"

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
FH="$TMP/home"            # fake $HOME
CFG="$TMP/cfg"            # fake $ATELIER_CONFIG_DIR
RT="$TMP/runtime"         # fake $ATELIER_RUNTIME_DIR
SHIM="$TMP/shim"          # claude / gh shims
CWD="$TMP/cwd"            # default cwd of every helper run
EVIL="$TMP/evil"          # untrusted trees
SENT="$TMP/SENTINEL"      # written by any untrusted code that gets executed
PROJ="$TMP/project"       # setup-project normal-mode target
WTS="$TMP/wts"            # per-task worktrees
mkdir -p "$FH/.local/bin" "$CFG/templates" "$RT" "$SHIM" "$CWD" "$EVIL" "$PROJ" "$WTS"

for c in claude gh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done

# Instantiated settings template (what install.sh leaves under the config dir).
sed "s|<atelier-config-dir>|$CFG|g" "$TEMPLATE" > "$CFG/templates/settings.template.json"

# mk_shaped <dir> — a tree that passes BOTH helpers' shape checks: a git repo
# on `main` (atelier-update) with templates/settings.template.json and
# .claude-plugin/plugin.json (atelier-setup-project) and an install.sh that
# drops the sentinel if anything ever runs it.
mk_shaped() {
  local d="$1"
  mkdir -p "$d/scripts" "$d/templates" "$d/.claude-plugin"
  printf '{ "name": "atelier", "version": "9.9.9" }\n' > "$d/.claude-plugin/plugin.json"
  printf '{ "permissions": { "allow": [], "deny": [], "ask": [] } }\n' > "$d/templates/settings.template.json"
  printf '#!/usr/bin/env bash\necho ran > "%s"\n' "$SENT" > "$d/install.sh"
  chmod +x "$d/install.sh"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" checkout -q -b main 2>/dev/null || true; }
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m init
}

# mk_dirty <dir> — an untracked file makes atelier-update's clone-mode flow
# stop at "commit or stash" right after the trust gate and the remote report,
# so a case that PASSES the gate still has no side effect.
mk_dirty() { printf 'x\n' > "$1/DIRTY"; }

# Origin for a foreign clone: a bare repo that is one commit ahead, whose new
# commit carries an install.sh that would write the sentinel.
mk_origin() {
  local d="$1" bare="$2" tmpc="$TMP/origin-work-$$"
  git clone -q --bare "$d" "$bare"
  git clone -q "$bare" "$tmpc"
  printf 'payload\n' > "$tmpc/payload"
  git -C "$tmpc" add -A
  git -C "$tmpc" -c user.name=t -c user.email=t@t commit -q -m payload
  git -C "$tmpc" push -q origin HEAD:main
  rm -rf "$tmpc"
  git -C "$d" remote add origin "$bare"
}

# Own source root: a complete copy of the helpers' tree. Helpers run from here
# so "own root" is a plain git clone (the repo under test may itself be a git
# worktree whose .git is a file).
OWN="$TMP/own"
mk_shaped "$OWN"
cp "$UPDATE_SRC" "$OWN/scripts/atelier-update"
cp "$SETUP_SRC" "$OWN/scripts/atelier-setup-project"
chmod +x "$OWN/scripts/"*
git -C "$OWN" add -A; git -C "$OWN" -c user.name=t -c user.email=t@t commit -q -m scripts
mk_dirty "$OWN"
git -C "$OWN" remote add origin "https://example.invalid/AkaLab-Tech/atelier.git"
OWN_UPDATE="$OWN/scripts/atelier-update"
OWN_SETUP="$OWN/scripts/atelier-setup-project"

# Untrusted trees (each shaped for both helpers).
mk_shaped "$EVIL/foreign";   mk_origin "$EVIL/foreign" "$EVIL/foreign-origin.git"
mk_shaped "$EVIL/spoof";     mk_origin "$EVIL/spoof"   "$EVIL/spoof-origin/atelier.git"
mk_shaped "${RT}-evil";      mk_origin "${RT}-evil"    "$EVIL/lookalike-rt-origin.git"
mk_shaped "$EVIL/lookalike-mk"
mk_shaped "$OWN/vendor/nested"
for d in "$EVIL/foreign" "$EVIL/spoof" "${RT}-evil" "$EVIL/lookalike-mk" "$OWN/vendor/nested"; do mk_dirty "$d"; done
# Lookalike marketplace root: wrong repo-dir name / sibling config dir.
mkdir -p "$CFG/plugins/mk"
mk_shaped "$CFG/plugins/mk/other";         mk_dirty "$CFG/plugins/mk/other"
mk_shaped "$CFG/plugins/mk/atelier-evil";  mk_dirty "$CFG/plugins/mk/atelier-evil"
ln -s "$EVIL/foreign" "$TMP/link-foreign"

# Trusted trees.
mk_shaped "$RT/0.1.0"; mk_dirty "$RT/0.1.0"
git -C "$RT/0.1.0" remote add origin "https://example.invalid/AkaLab-Tech/atelier.git"
ln -s 0.1.0 "$RT/current"
mk_shaped "$CFG/plugins/mk/atelier"; mk_dirty "$CFG/plugins/mk/atelier"
git -C "$CFG/plugins/mk/atelier" remote add origin "https://example.invalid/AkaLab-Tech/atelier.git"
ln -s "$RT/current" "$TMP/alias-runtime"

# Refused classes: <label>|<path as passed on the command line>
# (neutral class names; the concrete shapes are the point of the fixtures)
CLASSES=(
  "foreign clone|$EVIL/foreign"
  "foreign clone with a spoofed repo name|$EVIL/spoof"
  "sibling that merely prefixes the runtime dir|${RT}-evil"
  "dot-dot traversal out of a trusted root|$RT/0.1.0/../../evil/foreign"
  "symlink to a foreign tree|$TMP/link-foreign"
  "relative path to a foreign tree|../evil/foreign"
  "subdirectory of the own root|$OWN/vendor/nested"
  "marketplace dir with a different repo name|$CFG/plugins/mk/other"
  "marketplace dir that merely prefixes the repo name|$CFG/plugins/mk/atelier-evil"
)

# ---------------------------------------------------------------------------
# Runner + snapshot
# ---------------------------------------------------------------------------
# run_helper <cwd> <VAR=value> <script> [args...]
# Stdin is /dev/null. The caller env's ATELIER_* knobs are scrubbed first.
run_helper() {
  local cwd="$1" envset="$2" script="$3"; shift 3
  ( cd "$cwd" && env -u ATELIER_PLUGIN_ROOT -u ATELIER_AUTO -u CLAUDE_PLUGIN_ROOT \
      -u ATELIER_TEST_FORCE_TTY -u CLAUDE_CONFIG_DIR \
      "$envset" HOME="$FH" ATELIER_CONFIG_DIR="$CFG" ATELIER_RUNTIME_DIR="$RT" \
      PATH="$SHIM:$PATH" NO_COLOR=1 SHELL=/bin/zsh \
      "$script" "$@" </dev/null 2>&1 )
}

# snap — deterministic digest of every watched tree: dirs, file checksums,
# symlink targets. Equal before/after means the run touched nothing.
snap() {
  local -a dirs=()
  local p
  for p in "$FH" "$CFG" "$RT" "${RT}-evil" "$EVIL" "$PROJ" "$WTS" "$OWN"; do
    [ -e "$p" ] && dirs+=("$p")
  done
  {
    find "${dirs[@]}" -type d
    find "${dirs[@]}" -type f -exec cksum {} +
    find "${dirs[@]}" -type l -exec sh -c 'for l; do printf "%s -> %s\n" "$l" "$(readlink "$l")"; done' _ {} +
    [ -e "$SENT" ] && echo "SENTINEL PRESENT"
  } 2>/dev/null | sort | cksum
}

NOTRUST='not a trusted atelier root'

# expect_refused <case-name> <cwd> <VAR=value> <script> [args...]
expect_refused() {
  local name="$1" cwd="$2" envset="$3"; shift 3
  local before after out rc
  rm -f "$SENT"
  before="$(snap)"
  out="$(run_helper "$cwd" "$envset" "$@")"; rc=$?
  after="$(snap)"
  if [ "$rc" -eq 1 ] && grep -q "$NOTRUST" <<<"$out" \
     && [ ! -e "$SENT" ] && [ "$before" = "$after" ]; then
    pass "$name: refused (rc=1, '$NOTRUST', no side effect)"
  else
    fail "$name: rc=$rc sentinel=$([ -e "$SENT" ] && echo yes || echo no) unchanged=$([ "$before" = "$after" ] && echo yes || echo no) out: $(printf '%s' "$out" | head -5 | tr '\n' '|')"
  fi
}

# expect_gate_open_update <case-name> <cwd> <VAR=value> <script> [args...]
# The trust gate accepted the root: no refusal, and the run got as far as the
# clone-mode dirty-tree stop.
expect_gate_open_update() {
  local name="$1" cwd="$2" envset="$3"; shift 3
  local out rc
  out="$(run_helper "$cwd" "$envset" "$@")"; rc=$?
  if ! grep -q "$NOTRUST" <<<"$out" && grep -q 'commit or stash' <<<"$out"; then
    pass "$name: accepted (passed the trust gate)"
  else
    fail "$name: expected the gate to pass; rc=$rc out: $(printf '%s' "$out" | head -5 | tr '\n' '|')"
  fi
}

new_wt() { mktemp -d "$WTS/wt.XXXXXX"; }

# ===========================================================================
# 1. atelier-update: every refused class x {flag, flag=, env} x modes
# ===========================================================================
echo "atelier-update: refusal outside an interactive terminal"
UPD_MODES=("" "--dry-run" "--yes")
for entry in "${CLASSES[@]}"; do
  label="${entry%%|*}"; path="${entry#*|}"
  for mode in "${UPD_MODES[@]}"; do
    m="${mode:-default}"
    # shellcheck disable=SC2086  # $mode is empty or one flag
    expect_refused "update [$label] flag, $m"   "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$path" $mode
    # shellcheck disable=SC2086
    expect_refused "update [$label] flag=, $m"  "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root="$path" $mode
    # shellcheck disable=SC2086
    expect_refused "update [$label] env, $m"    "$CWD" "ATELIER_PLUGIN_ROOT=$path" "$OWN_UPDATE" $mode
  done
done

# The flag wins over the env var; a refused flag is refused even with a good env.
expect_refused "update: untrusted flag is refused even when the env root is trusted" \
  "$CWD" "ATELIER_PLUGIN_ROOT=$OWN" "$OWN_UPDATE" --plugin-root "$EVIL/foreign"

# The shipped script itself (not only the copy) refuses.
expect_refused "update: repo script refuses a foreign flag root" \
  "$CWD" ATELIER_T=1 "$UPDATE_SRC" --plugin-root "$EVIL/foreign"

# Existing shape checks still run first and still fail hard.
out="$(run_helper "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$TMP/not-a-repo")"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'is not a git repo' <<<"$out"; } \
  && pass "update: non-repo root keeps the 'is not a git repo' failure (shape check first)" \
  || fail "update: non-repo root rc=$rc out: $out"

# ===========================================================================
# 2. atelier-update: legitimate uses keep working
# ===========================================================================
echo "atelier-update: trusted roots are accepted"
expect_gate_open_update "update: no flag, own root"                       "$CWD" ATELIER_T=1 "$OWN_UPDATE"
expect_gate_open_update "update: flag equal to own root"                  "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$OWN"
expect_gate_open_update "update: flag=own root, trailing slash"           "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root="$OWN/"
expect_gate_open_update "update: env equal to own root"                   "$CWD" "ATELIER_PLUGIN_ROOT=$OWN" "$OWN_UPDATE"
expect_gate_open_update "update: own root via dot-dot spelling"           "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$OWN/scripts/.."
expect_gate_open_update "update: managed runtime 'current' via flag"      "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$RT/current"
expect_gate_open_update "update: managed runtime 'current/' via env"      "$CWD" "ATELIER_PLUGIN_ROOT=$RT/current/" "$OWN_UPDATE"
expect_gate_open_update "update: managed runtime version child via flag"  "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$RT/0.1.0"
expect_gate_open_update "update: managed runtime version child via env"   "$CWD" "ATELIER_PLUGIN_ROOT=$RT/0.1.0" "$OWN_UPDATE"
expect_gate_open_update "update: symlink that resolves to the runtime"    "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$TMP/alias-runtime"
expect_gate_open_update "update: marketplace install via flag"            "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$CFG/plugins/mk/atelier"
expect_gate_open_update "update: marketplace install via env"             "$CWD" "ATELIER_PLUGIN_ROOT=$CFG/plugins/mk/atelier" "$OWN_UPDATE"
expect_gate_open_update "update: relative spelling of the own root"       "$OWN/scripts" ATELIER_T=1 "$OWN_UPDATE" --plugin-root ".."
expect_gate_open_update "update: empty env var falls back to own root"    "$CWD" "ATELIER_PLUGIN_ROOT=" "$OWN_UPDATE"

# Symlinked helper (how ~/.local/bin installs it): own root resolves through it.
ln -s "$OWN_UPDATE" "$FH/.local/bin/atelier-update"
expect_gate_open_update "update: flag=own root through the ~/.local/bin symlink" \
  "$CWD" ATELIER_T=1 "$FH/.local/bin/atelier-update" --plugin-root "$OWN"
expect_refused "update: foreign flag root refused through the ~/.local/bin symlink" \
  "$CWD" ATELIER_T=1 "$FH/.local/bin/atelier-update" --plugin-root "$EVIL/foreign"

# Empty --plugin-root value on atelier-update is still a hard error.
out="$(run_helper "$CWD" ATELIER_T=1 "$OWN_UPDATE" --plugin-root "")"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q -- '--plugin-root requires a value' <<<"$out"; } \
  && pass "update: empty --plugin-root value still dies with 'requires a value'" \
  || fail "update: empty --plugin-root rc=$rc out: $out"

# ===========================================================================
# 3. atelier-update clone mode: advisory origin-name warning
# ===========================================================================
echo "atelier-update: origin repository name advisory"
WARN='does not look like the atelier repository'
mk_origin_case() { # <idx> <url> -> prints the clone dir
  local d="$TMP/origin-case-$1"
  mkdir -p "$d/scripts"
  cp "$UPDATE_SRC" "$d/scripts/atelier-update"; chmod +x "$d/scripts/atelier-update"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/install.sh"
  printf '{ "version": "1.0.0" }\n' > "$d/plugin.json"
  git -C "$d" init -q -b main 2>/dev/null || git -C "$d" init -q
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m i
  mk_dirty "$d"
  git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}
i=0
for url in \
  "https://github.com/AkaLab-Tech/atelier.git" \
  "https://github.com/AkaLab-Tech/atelier" \
  "https://github.com/AkaLab-Tech/Atelier.git/" \
  "git@github.com:AkaLab-Tech/atelier.git" \
  "https://github.com/someone/atelier-fork.git" \
  "/srv/git/atelier.git"; do
  i=$((i + 1)); d="$(mk_origin_case "ok$i" "$url")"
  out="$(run_helper "$CWD" ATELIER_T=1 "$d/scripts/atelier-update")"
  if ! grep -q "$WARN" <<<"$out" && grep -q 'commit or stash' <<<"$out"; then
    pass "origin '$url': no advisory warning"
  else
    fail "origin '$url': unexpected warning or early exit: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
done
for url in \
  "https://github.com/evil/payload.git" \
  "https://github.com/evil/not-atelier.git" \
  "https://github.com/evil/atelierx.git" \
  "https://evil.example/atelier/payload" \
  "https://github.com/evil/atelier.git/payload"; do
  i=$((i + 1)); d="$(mk_origin_case "warn$i" "$url")"
  out="$(run_helper "$CWD" ATELIER_T=1 "$d/scripts/atelier-update")"
  if grep -q "$WARN" <<<"$out" && grep -q 'commit or stash' <<<"$out"; then
    pass "origin '$url': advisory warning printed, run not blocked by it"
  else
    fail "origin '$url': warning missing or run blocked: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
done

# ===========================================================================
# 4. atelier-setup-project: every refused class x {flag, flag=, env} x modes
# ===========================================================================
echo "atelier-setup-project: refusal outside an interactive terminal"
for entry in "${CLASSES[@]}"; do
  label="${entry%%|*}"; path="${entry#*|}"
  # normal mode
  expect_refused "setup [$label] flag, normal"  "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root "$path" "$PROJ"
  expect_refused "setup [$label] flag=, normal" "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root="$path" "$PROJ"
  expect_refused "setup [$label] env, normal"   "$CWD" "ATELIER_PLUGIN_ROOT=$path" "$OWN_SETUP" "$PROJ"
  # normal mode with the allow-listed headless flags
  expect_refused "setup [$label] flag, --reconfigure --override --yes" \
    "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root "$path" --reconfigure --override --yes "$PROJ"
  expect_refused "setup [$label] env, --reconfigure --override --yes" \
    "$CWD" "ATELIER_PLUGIN_ROOT=$path" "$OWN_SETUP" --reconfigure --override --yes "$PROJ"
  # per-task mode
  wt="$(new_wt)"
  expect_refused "setup [$label] flag, --per-task-settings"  "$CWD" ATELIER_T=1 "$OWN_SETUP" --per-task-settings "$wt" --plugin-root "$path"
  expect_refused "setup [$label] flag=, --per-task-settings" "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root="$path" --per-task-settings "$wt"
  expect_refused "setup [$label] env, --per-task-settings"   "$CWD" "ATELIER_PLUGIN_ROOT=$path" "$OWN_SETUP" --per-task-settings "$wt"
  [ ! -e "$wt/.claude" ] \
    && pass "setup [$label]: refused per-task run left no .claude/ in the worktree" \
    || fail "setup [$label]: .claude/ appeared in $wt"
done

expect_refused "setup: untrusted flag is refused even when the env root is trusted" \
  "$CWD" "ATELIER_PLUGIN_ROOT=$OWN" "$OWN_SETUP" --plugin-root "$EVIL/foreign" "$PROJ"
expect_refused "setup: repo script refuses a foreign flag root" \
  "$CWD" ATELIER_T=1 "$SETUP_SRC" --plugin-root "$EVIL/foreign" "$PROJ"

# Existing shape check still comes first.
out="$(run_helper "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root "$TMP/not-a-repo" "$PROJ")"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'is not an atelier checkout' <<<"$out"; } \
  && pass "setup: non-atelier root keeps the 'is not an atelier checkout' failure (shape check first)" \
  || fail "setup: non-atelier root rc=$rc out: $out"

# ===========================================================================
# 5. atelier-setup-project: legitimate uses keep working
# ===========================================================================
echo "atelier-setup-project: trusted roots and empty values are accepted"

# expect_setup_ok <case-name> <VAR=value> <script> [args...]  — per-task run in
# a fresh worktree; the settings file must be created.
expect_setup_ok() {
  local name="$1" envset="$2" script="$3"; shift 3
  local wt out rc
  wt="$(new_wt)"
  out="$(run_helper "$CWD" "$envset" "$script" --per-task-settings "$wt" "$@")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$wt/.claude/settings.json" ] && ! grep -q "$NOTRUST" <<<"$out"; then
    pass "$name: accepted, settings.json created"
  else
    fail "$name: rc=$rc out: $(printf '%s' "$out" | head -5 | tr '\n' '|')"
  fi
}
expect_setup_ok "setup: no flag, own root"                    ATELIER_T=1 "$OWN_SETUP"
expect_setup_ok "setup: flag equal to own root"               ATELIER_T=1 "$OWN_SETUP" --plugin-root "$OWN"
expect_setup_ok "setup: flag=own root"                        ATELIER_T=1 "$OWN_SETUP" --plugin-root="$OWN"
expect_setup_ok "setup: env equal to own root"                "ATELIER_PLUGIN_ROOT=$OWN" "$OWN_SETUP"
expect_setup_ok "setup: shipped repo root through the repo script" ATELIER_T=1 "$SETUP_SRC" --plugin-root "$REPO_ROOT"
expect_setup_ok "setup: managed runtime 'current' via flag"   ATELIER_T=1 "$OWN_SETUP" --plugin-root "$RT/current"
expect_setup_ok "setup: managed runtime 'current' via env"    "ATELIER_PLUGIN_ROOT=$RT/current" "$OWN_SETUP"
expect_setup_ok "setup: managed runtime version child"        ATELIER_T=1 "$OWN_SETUP" --plugin-root "$RT/0.1.0"
expect_setup_ok "setup: symlink that resolves to the runtime" ATELIER_T=1 "$OWN_SETUP" --plugin-root "$TMP/alias-runtime"
expect_setup_ok "setup: marketplace install via flag"         ATELIER_T=1 "$OWN_SETUP" --plugin-root "$CFG/plugins/mk/atelier"
expect_setup_ok "setup: marketplace install via env"          "ATELIER_PLUGIN_ROOT=$CFG/plugins/mk/atelier" "$OWN_SETUP"
expect_setup_ok "setup: empty --plugin-root \"\" is tolerated"  ATELIER_T=1 "$OWN_SETUP" --plugin-root ""
expect_setup_ok "setup: empty --plugin-root= is tolerated"      ATELIER_T=1 "$OWN_SETUP" --plugin-root=
expect_setup_ok "setup: empty env var is tolerated"             "ATELIER_PLUGIN_ROOT=" "$OWN_SETUP"

# Normal mode, trusted root: the root is accepted and the run reaches the
# project step (a missing project path dies there, after plugin-root
# resolution, with a project-path message instead of the trust refusal).
out="$(run_helper "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root "$OWN" "$TMP/no-such-project")"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q "$NOTRUST" <<<"$out" && ! grep -q 'is not an atelier checkout' <<<"$out"; then
  pass "setup: normal mode, flag=own root: passes the gate and fails later on the project path"
else
  fail "setup: normal mode own root rc=$rc out: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
fi
out="$(run_helper "$CWD" ATELIER_T=1 "$OWN_SETUP" --plugin-root "" "$TMP/no-such-project")"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q "$NOTRUST" <<<"$out"; then
  pass "setup: normal mode, empty --plugin-root is not refused"
else
  fail "setup: normal mode empty flag rc=$rc out: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
fi

# --help documents the restriction on both helpers.
for pair in "setup:$OWN_SETUP" "update:$OWN_UPDATE"; do
  nm="${pair%%:*}"; sc="${pair#*:}"
  helptxt="$("$sc" --help 2>&1 | tr '\n' ' ')"
  if grep -qi 'interactive *terminal' <<<"$helptxt"; then
    pass "$nm --help documents the interactive-terminal restriction"
  else
    fail "$nm --help does not mention the interactive-terminal restriction"
  fi
done

# ===========================================================================
# 6. TTY escape hatch (only where a pty can be faked hermetically)
# ===========================================================================
echo "interactive-terminal escape hatch"
# run_pty <VAR=value> <cmd...> — run the command with a pty as stdin/stdout.
run_pty() {
  local envset="$1"; shift
  ( cd "$CWD" && env -u ATELIER_PLUGIN_ROOT -u ATELIER_AUTO -u CLAUDE_PLUGIN_ROOT \
      -u ATELIER_TEST_FORCE_TTY -u CLAUDE_CONFIG_DIR \
      "$envset" HOME="$FH" ATELIER_CONFIG_DIR="$CFG" ATELIER_RUNTIME_DIR="$RT" \
      PATH="$SHIM:$PATH" NO_COLOR=1 SHELL=/bin/zsh \
      python3 -I -c 'import os,pty,sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@" </dev/null 2>&1 )
}
PTY_OK=false
if command -v python3 >/dev/null 2>&1; then
  probe="$(run_pty ATELIER_T=1 bash -c '[ -t 0 ] && echo PTY-YES || echo PTY-NO' 2>/dev/null)"
  grep -q 'PTY-YES' <<<"$probe" && PTY_OK=true
fi
if $PTY_OK; then
  # Untrusted root from a real terminal: accepted.
  wt="$(new_wt)"
  out="$(run_pty ATELIER_T=1 "$OWN_SETUP" --per-task-settings "$wt" --plugin-root "$EVIL/foreign")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$wt/.claude/settings.json" ] && ! grep -q "$NOTRUST" <<<"$out"; then
    pass "setup: untrusted --plugin-root accepted when stdin is a terminal"
  else
    fail "setup: tty untrusted flag rc=$rc out: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  wt="$(new_wt)"
  out="$(run_pty "ATELIER_PLUGIN_ROOT=$EVIL/foreign" "$OWN_SETUP" --per-task-settings "$wt")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$wt/.claude/settings.json" ] && ! grep -q "$NOTRUST" <<<"$out"; then
    pass "setup: untrusted \$ATELIER_PLUGIN_ROOT accepted when stdin is a terminal"
  else
    fail "setup: tty untrusted env rc=$rc out: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  out="$(run_pty ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$EVIL/foreign")"; rc=$?
  if ! grep -q "$NOTRUST" <<<"$out" && grep -q 'commit or stash' <<<"$out"; then
    pass "update: untrusted --plugin-root accepted when stdin is a terminal (stops at the dirty-tree check)"
  else
    fail "update: tty untrusted flag rc=$rc out: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  out="$(run_pty "ATELIER_PLUGIN_ROOT=$EVIL/foreign" "$OWN_UPDATE")"; rc=$?
  if ! grep -q "$NOTRUST" <<<"$out" && grep -q 'commit or stash' <<<"$out"; then
    pass "update: untrusted \$ATELIER_PLUGIN_ROOT accepted when stdin is a terminal"
  else
    fail "update: tty untrusted env rc=$rc out: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  # The shape checks still apply on a terminal.
  out="$(run_pty ATELIER_T=1 "$OWN_UPDATE" --plugin-root "$TMP/not-a-repo")"
  grep -q 'is not a git repo' <<<"$out" \
    && pass "update: a terminal does not bypass the shape check" \
    || fail "update: tty non-repo out: $out"
else
  skip "TTY escape hatch: no hermetic pty available here (python3 pty probe failed); the terminal-accepts cases are NOT verified by this run"
fi

# ===========================================================================
# 7. Template static matrix
# ===========================================================================
echo "settings template: deny entries"
PLUGIN_ROOT_DENY=(
  'Bash(atelier-update --plugin-root*)'
  'Bash(atelier-update * --plugin-root*)'
  'Bash(atelier-setup-project --plugin-root*)'
  'Bash(atelier-setup-project * --plugin-root*)'
)
PTY_DENY=(
  'Bash(script *)' 'Bash(script)' 'Bash(unbuffer *)' 'Bash(unbuffer)' 'Bash(expect *)' 'Bash(expect)'
  'Bash(/usr/bin/script *)' 'Bash(/usr/bin/expect *)'
  'Bash(* && script *)' 'Bash(* ; script *)' 'Bash(* | script *)' 'Bash(* || script *)'
  'Bash(env script *)' 'Bash(command script *)' 'Bash(exec script *)' 'Bash(nohup script *)' 'Bash(time script *)'
  'Bash(* && unbuffer *)' 'Bash(* ; unbuffer *)' 'Bash(* | unbuffer *)' 'Bash(* || unbuffer *)'
  'Bash(env unbuffer *)' 'Bash(command unbuffer *)' 'Bash(exec unbuffer *)' 'Bash(nohup unbuffer *)' 'Bash(time unbuffer *)'
  'Bash(* && expect *)' 'Bash(* ; expect *)' 'Bash(* | expect *)' 'Bash(* || expect *)'
  'Bash(env expect *)' 'Bash(command expect *)' 'Bash(exec expect *)' 'Bash(nohup expect *)' 'Bash(time expect *)'
)
ALL_NEW=("${PLUGIN_ROOT_DENY[@]}" "${PTY_DENY[@]}")

[ "${#PLUGIN_ROOT_DENY[@]}" -eq 4 ] && [ "${#PTY_DENY[@]}" -eq 35 ] \
  && pass "matrix size: 4 plugin-root + 35 pseudo-terminal entries" \
  || fail "matrix size: ${#PLUGIN_ROOT_DENY[@]} + ${#PTY_DENY[@]}"

jq empty "$TEMPLATE" 2>/dev/null && pass "settings.template.json is valid JSON" || fail "settings.template.json is not valid JSON"

for e in "${ALL_NEW[@]}"; do
  n_deny="$(jq --arg e "$e" '[.permissions.deny[] | select(. == $e)] | length' "$TEMPLATE")"
  n_other="$(jq --arg e "$e" '[(.permissions.allow + .permissions.ask)[] | select(. == $e)] | length' "$TEMPLATE")"
  if [ "$n_deny" = "1" ] && [ "$n_other" = "0" ]; then
    pass "deny has exactly one '$e' and allow/ask have none"
  else
    fail "'$e': deny count=$n_deny, allow/ask count=$n_other"
  fi
done

# Existing helper allow rules are unchanged, and no new entry leaked into allow.
for a in 'Bash(atelier-update:*)' 'Bash(atelier-setup-project:*)' 'Bash(atelier-setup-project --per-task-settings:*)'; do
  jq -e --arg a "$a" '.permissions.allow | index($a)' "$TEMPLATE" >/dev/null \
    && pass "allow still contains '$a'" || fail "allow lost '$a'"
done
leak="$(jq -r '.permissions.allow[] | select(test("plugin-root|(^|[( ])(script|unbuffer|expect)([ )]|$)"))' "$TEMPLATE")"
[ -z "$leak" ] && pass "no allow entry mentions --plugin-root or a pseudo-terminal wrapper" || fail "allow leak: $leak"

# Glob emulation: Claude Code's `Bash(<glob>)` prefix/suffix matching,
# reproduced with bash patterns (only `*` is special in these entries).
matches() { # <glob-entry> <command>
  local pat="$1" cmd="$2"
  pat="${pat#Bash(}"; pat="${pat%)}"
  # shellcheck disable=SC2053  # the unquoted right side is the point
  [[ "$cmd" == $pat ]]
}
any_new_matches() { local e; for e in "${ALL_NEW[@]}"; do matches "$e" "$1" && { printf '%s' "$e"; return 0; }; done; return 1; }

SHOULD_MATCH=(
  'atelier-update --plugin-root /x'
  'atelier-update --plugin-root=/x'
  'atelier-update --yes --plugin-root /x'
  'atelier-update --dry-run --plugin-root=/x'
  'atelier-setup-project --plugin-root /x /p'
  'atelier-setup-project /p --plugin-root=/x'
  'atelier-setup-project --reconfigure --override --yes --plugin-root /x /p'
  'script -q /dev/null atelier-update'
  'script'
  'unbuffer atelier-update'
  'unbuffer'
  'expect -c spawn'
  'expect'
  '/usr/bin/script -q /dev/null x'
  '/usr/bin/expect -f x'
  'cd /x && script -q y'
  'cd /x ; unbuffer y'
  'cat f | expect y'
  'false || script y'
  'env script x'
  'command unbuffer x'
  'exec expect x'
  'nohup script x'
  'time unbuffer x'
)
for c in "${SHOULD_MATCH[@]}"; do
  m="$(any_new_matches "$c")" && pass "'$c' is matched by a deny entry ($m)" || fail "'$c' is not matched by any new deny entry"
done

SHOULD_NOT_MATCH=(
  'atelier-update'
  'atelier-update --dry-run'
  'atelier-update --yes'
  'atelier-update --apply-automode'
  'atelier-setup-project /p'
  'atelier-setup-project --per-task-settings /w'
  'atelier-setup-project --reconfigure /p'
  'scripts/atelier-foo arg'
  'scriptfoo bar'
  'script-x run'
  'scripted run'
  'unbufferx run'
  'expectation run'
  'expected foo'
  'pnpm run script'
  'pnpm run unbuffer'
  'rg script file'
  'cat expect.txt'
  'echo script'
  'ls && scripts/x'
  'ls ; scripted run'
  'ls | expectation x'
  'git log --oneline'
)
for c in "${SHOULD_NOT_MATCH[@]}"; do
  m="$(any_new_matches "$c")" && fail "'$c' is wrongly matched by new deny entry $m" || pass "'$c' is not matched by any new deny entry"
done

# ===========================================================================
# 8. atelier-permission-diff describes every new entry
# ===========================================================================
echo "atelier-permission-diff: new entries are described"
OLD="$TMP/old.template.json"
jq 'del(.permissions.deny[] | select(test("plugin-root|^Bash\\((/usr/bin/)?(script|unbuffer|expect)[ )]|^Bash\\(\\* .* (script|unbuffer|expect) |^Bash\\((env|command|exec|nohup|time) (script|unbuffer|expect) ")))' "$TEMPLATE" > "$OLD" 2>/dev/null
removed="$(( $(jq '.permissions.deny | length' "$TEMPLATE") - $(jq '.permissions.deny | length' "$OLD") ))"
[ "$removed" -eq 39 ] && pass "fixture: the old template lacks exactly the 39 new entries" || fail "fixture: removed $removed entries instead of 39"

diff_out="$(bash "$PDIFF" --old "$OLD" --new "$TEMPLATE" --no-color 2>&1)"; drc=$?
[ "$drc" -eq 1 ] && pass "permission-diff exits 1 (changes detected)" || fail "permission-diff rc=$drc"
for e in "${PLUGIN_ROOT_DENY[@]}"; do
  line="$(printf '%s\n' "$diff_out" | grep -F -- "+ $e " | head -1)"
  case "$line" in
    *"→ BLOCKED: "*"root-override flag (terminal only)"*"[deny]") pass "diff reports '$e' with a root-override description" ;;
    *) fail "diff line for '$e': '$line'" ;;
  esac
done
for e in "${PTY_DENY[@]}"; do
  line="$(printf '%s\n' "$diff_out" | grep -F -- "+ $e " | head -1)"
  case "$line" in
    *"→ BLOCKED: pseudo-terminal wrapper"*"[deny]") pass "diff reports '$e' with a pseudo-terminal-wrapper description" ;;
    *) fail "diff line for '$e': '$line'" ;;
  esac
done
grep -q 'no description' <<<"$diff_out" \
  && fail "permission-diff printed '(no description)' for a new entry" \
  || pass "permission-diff has no '(no description)' row among the new entries"

echo ""
echo "helper-plugin-root-restriction: $cases cases"
if [ "$fails" -eq 0 ]; then
  echo "helper-plugin-root-restriction: all assertions passed."
  exit 0
else
  echo "helper-plugin-root-restriction: $fails assertion(s) failed."
  exit 1
fi
