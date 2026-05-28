# Atelier Full Integrated Dogfood — Step-by-Step Guide (M7.1)

**Goal**: validate atelier end-to-end on your real machine + a real project, capturing friction at every step. Three stages: install → setup-project → task cycle. Each test case lists command + expected output + failure mode + what to capture.

**Atelier version**: v0.4.0 (post-#67 merge); test cases also cover the v0.5+ helpers (`atelier-update`, `atelier-list-projects`, `atelier-remove-project`, `atelier-doctor --fix`, `atelier --help`) introduced through M6.1 + M7.1.F32/F33/F34.
**Date**: 2026-05-23 (initial); revised 2026-05-28 for the M7.1.F35 documentation sweep.
**Expected wall time**: 2-3 hours, plus iteration on any friction found.

---

## Stage 0 — Pre-flight snapshot

Before touching anything, capture the current state so you can roll back cleanly if needed and so the findings log knows the baseline.

### TC-0.1 — Capture current shellrc state

```bash
cp ~/.zshrc ~/.zshrc.pre-atelier
echo "  ✓ shellrc backed up at ~/.zshrc.pre-atelier"
```

### TC-0.2 — Verify no existing atelier footprint

```bash
echo "=== existing atelier footprint ==="
ls ~/.local/bin/atelier-* 2>/dev/null || echo "  ✓ no atelier binaries on PATH (expected)"
ls -d ~/.claude-work 2>/dev/null && echo "  ⚠ ~/.claude-work already exists" || echo "  ✓ ~/.claude-work does not exist (expected)"
ls ~/.local/state/atelier/ 2>/dev/null && echo "  ⚠ ~/.local/state/atelier/ exists (pre-existing files: see above)" || echo "  ✓ ~/.local/state/atelier/ does not exist"
grep -q ">>> atelier hooks" ~/.zshrc 2>/dev/null && echo "  ⚠ shellrc already has atelier block (will refresh on install)" || echo "  ✓ shellrc clean of atelier hooks"
```

**Expected**: mostly `✓` lines. If `⚠`, note it — install.sh handles re-runs idempotently but you should know the start state.

### TC-0.3 — Verify deps available (install.sh Phase A will skip what's already there)

```bash
echo "=== deps (Phase A targets) ==="
for cmd in pnpm fnm gh node; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✓ $cmd ($(${cmd} --version 2>&1 | head -1))"
  else
    echo "  ✗ $cmd missing — Phase A will install"
  fi
done
echo ""
docker info >/dev/null 2>&1 && echo "  ✓ docker daemon reachable" || echo "  ⚠ docker daemon NOT reachable (Phase A skips runtime install per policy; start Colima/Docker before docker-env tasks)"
docker compose version >/dev/null 2>&1 && echo "  ✓ docker compose v2 plugin" || echo "  ⚠ docker compose v2 not reachable (install.sh phase_a_docker_compose_optional will offer install)"
```

### TC-0.4 — Capture target install location

Decide `$ATELIER_CONFIG_DIR`. The default is `~/.claude-work/`, but you currently have `~/.claude-personal/` set in your shellrc. Decision:

- **Option A** (recommended for first dogfood): use the default `~/.claude-work/`. Keeps the dogfood-installed atelier isolated from your `~/.claude-personal/` (which has chat history, other plugins). After dogfood, `atelier-uninstall` can wipe `~/.claude-work/` cleanly.
- **Option B**: override via `--config-dir /custom/path` flag (if `install.sh` supports it — check `install.sh --help`).

Record your choice in the findings log: `Chosen ATELIER_CONFIG_DIR: ~/.claude-work/`.

---

## Stage 1 — Run install.sh

Run from inside the atelier checkout. The script is in the repo root.

### TC-1.1 — Locate the atelier checkout

```bash
cd /Users/mike/Work/work-setup/dotfiles
ls install.sh && echo "  ✓ install.sh present at $(pwd)/install.sh"
```

### TC-1.2 — Read `install.sh --help` if available

```bash
./install.sh --help 2>&1 | head -30
```

Capture: what flags exist (e.g. `--yes`, `--config-dir`), what defaults the script uses.

### TC-1.3 — Run install.sh interactively (first time)

```bash
./install.sh
```

**Expected progress** (in order):

1. **Phase A — base dependencies + Claude Code**
   - `pnpm`, `fnm`, `gh` installed via brew if missing (skipped if already present)
   - `claude` CLI installed
   - Chrome detection (prompt to install via brew if missing)
   - **NEW (M4.17)**: `docker compose` v2 plugin check — will prompt to `brew install docker-compose` + symlink if missing
2. **Phase B — authentication**
   - `claude` login check (browser opens if not logged in)
   - `gh auth status` for default identity
   - **NEW (M5.0.1)**: `gh auth login` for atelier-author identity under `$ATELIER_CONFIG_DIR/gh/author/`
   - Same for atelier-reviewer identity under `$ATELIER_CONFIG_DIR/gh/reviewer/`
   - **Capture**: identity equality warning if both auths resolve to the same GitHub user (single-developer mode — `auto-merge` will hold PRs needing human review)
3. **Phase C.1 — host config**
   - `$ATELIER_CONFIG_DIR` directory created
   - Templates instantiated under `$ATELIER_CONFIG_DIR/templates/` (M5.0.2)
   - `git-wt` cloned + installed
   - `.env*` added to git's global excludes
   - `~/.local/bin/atelier-setup-project` symlink
   - **NEW (M5.0.3)**: `~/.local/bin/atelier-uninstall` symlink
   - shellrc hooks block injected
4. **Phase C.2 — marketplace + plugins**
   - `claude plugin marketplace add akalab-tech`
   - `claude plugin install atelier@akalab-tech`
   - `claude plugin install claude-roadmap-tools@akalab-tech`

**Failure modes to capture:**

- Any `brew install` failure (network, permission, etc.) → capture the exact error
- `claude login` browser-open issues
- `gh auth login` flow for the second/third identity (does it pick the right GH_CONFIG_DIR?)
- Any prompt that hangs or asks something unexpected

### TC-1.4 — Post-install: source the new shellrc + verify env

```bash
exec zsh  # or source ~/.zshrc in current shell
echo "=== env post-install ==="
echo "  ATELIER_CONFIG_DIR: $ATELIER_CONFIG_DIR"
echo "  PATH includes ~/.local/bin?  $(echo "$PATH" | grep -q "$HOME/.local/bin" && echo yes || echo no)"
which atelier-setup-project
which atelier-uninstall
which git-wt
which task 2>/dev/null && echo "  ✓ 'task' shell function defined"
```

**Expected**: all binaries on PATH, `$ATELIER_CONFIG_DIR` set, `task` function defined.

### TC-1.5 — Verify `$ATELIER_CONFIG_DIR` structure

```bash
ls -la "$ATELIER_CONFIG_DIR" | head -10
ls "$ATELIER_CONFIG_DIR/templates/" | head -5
ls "$ATELIER_CONFIG_DIR/gh/" 2>/dev/null
ls "$ATELIER_CONFIG_DIR/plugins/" 2>/dev/null | head -5
test -f "$ATELIER_CONFIG_DIR/atelier-help.txt" && echo "  ✓ atelier-help.txt written (F34)" || echo "  ✗ atelier-help.txt missing — run atelier-update"
```

**Expected**: `templates/` with `settings.template.json`, `project-claude.md.template`, `project-claude-root.md.template`. `gh/` with `author/` + `reviewer/` subdirs. `plugins/` with installed atelier + claude-roadmap-tools. `atelier-help.txt` present (added by `phase_c_1_atelier_help_file`, M7.1.F34).

### TC-1.6 — Verify the v0.5+ helper surface

```bash
echo "=== atelier-* helpers on PATH ==="
for cmd in atelier-setup-project atelier-uninstall atelier-doctor atelier-task-resolve \
          atelier-measure-merge-rate atelier-update atelier-list-projects \
          atelier-remove-project atelier-permission-diff atelier-pr-size-check; do
  command -v "$cmd" >/dev/null 2>&1 && echo "  ✓ $cmd" || echo "  ✗ $cmd missing"
done
echo ""
atelier --help | head -20
```

**Expected**: every helper present. `atelier --help` prints the cheatsheet from `$ATELIER_CONFIG_DIR/atelier-help.txt`. If any helper is missing, `atelier-doctor --fix` re-creates the `~/.local/bin/atelier-*` symlinks.

---

## Stage 2 — `/atelier:doctor` (verify integrated state)

This is the most important post-install validation. `/doctor` checks 3 plugin updates + git-wt SHA + 6 auxiliary host checks (now includes docker compose v2 plugin per M4.17).

### TC-2.1 — Open a Claude Code session against `$ATELIER_CONFIG_DIR`

```bash
CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude
```

Inside the session:

```
/atelier:doctor
```

**Expected output** (full health check):

```
atelier /doctor — health check

Plugins (compared against AkaLab-Tech/claude-plugins marketplace)
    ✓ atelier 0.4.0
    ✓ claude-roadmap-tools <current>

External tooling
    ✓ git-wt <short-sha> (up to date)

Host checks
    ✓ no legacy atelier hooks in ~/.claude/settings.json
    ✓ git-wt on PATH
    ✓ atelier shellrc hooks active
    – project .npmrc guardrails (skipped: not in a project)
    ✓ ~/.claude/.atelier-config.json consistent (or – if no per-project config yet)
    ✓ system Chrome detected
    ✓ docker compose v2 plugin detected
```

**Failure modes to capture:**

- Plugin version mismatch (drift). Note current + expected.
- Any `✗` line. The `/doctor` output gives the exact fix command — try it, capture if it works.
- Any `–` (skipped) that you DIDN'T expect to be skipped.

### TC-2.2 — Exercise `--fix` and `atelier-update`

Outside the Claude session (from a regular shell):

```bash
atelier-doctor --fix       # apply auto-repair for templates/symlink/shellrc/marketplace
atelier-doctor             # confirm a clean run
atelier-update             # no-op the first time; capture the version delta line
```

**Expected**:
- `atelier-doctor --fix` reports `n auto-fixed` (or `0` if there's nothing to repair) and no longer has `✗` lines for the auto-fixable checks (templates symlink, shellrc block, marketplace registration, helper symlinks under `~/.local/bin/`).
- `atelier-update` reports the installed version and the latest release tag side-by-side. On a fresh install they match — capture the exact line so the M7.1 entry has a baseline.

If `atelier-update` reports `already up to date` but `atelier-doctor` still flags drift, re-run with `atelier-update --force` (this is the M7.1.F31 dogfood finding — see [troubleshooting → atelier-update says "already up to date"](troubleshooting.md#atelier-update-says-already-up-to-date-but-the-doctor-still-warns-about-a-stale-version)).

---

## Stage 3 — Real project setup

Now atelier is installed. Pick a real project and bootstrap it.

### TC-3.1 — Choose a project

**Criteria**: a project you can experiment with (commit history isn't sacred, you can run a real task end-to-end). Recommendations:

1. A small repo of yours with `package.json` + tests (Node/TS) — quick scan, fast tests
2. A new empty repo specifically for the dogfood (`mkdir ~/Work/atelier-dogfood-5 && cd && git init` — fresh start, `new` mode triggers the interview branch)

**Decision**: which project? Record in findings log.

### TC-3.2 — Run `/atelier:setup-project`

From inside a Claude Code session with the chosen project as cwd:

```bash
cd <chosen-project>
claude   # opens session in that cwd
```

Inside the session:

```
/atelier:setup-project .
```

**Expected behavior**:

- **Phase 1 (bash helper)** prints progress: `.claude/settings.json: created`, ROADMAP/IN_PROGRESS/HISTORY created (or preserved if existing), `.npmrc` created/appended, `.gitignore` appended
- Two marker lines emitted: `atelier-detected-mode=...` and `atelier-root-claude-md=missing`
- **Phase 2** dispatches `project-profiler` agent
- `existing` mode: agent scans + returns drafted content + slash command Writes root `CLAUDE.md`
- `new` mode: slash command asks the open question ("What is this project about?") via `AskUserQuestion`, then dispatches agent with the answer, then Writes
- Final status: `Root CLAUDE.md written` or `kept-existing`

**Capture**:
- Time spent on Phase 1 (should be < 5s)
- Time spent on Phase 2 dispatch (agent run, typically 30-90s)
- The drafted `CLAUDE.md` — copy it into the findings log
- Any prompts that hung or surprising behaviors

### TC-3.3 — Verify the artifacts

```bash
cd <chosen-project>
ls -la .claude/
cat CLAUDE.md | head -40    # verify drafted content makes sense
cat .claude/settings.json | jq '.permissions | keys'   # allow/deny/ask + additionalDirectories
grep -E "ignore-scripts|minimum-release-age|audit-level" .npmrc
cat .gitignore | head -10
```

**Expected**: all files present + readable; settings.json has substituted `<worktree>` correctly; .npmrc has the 3 guardrails; .gitignore has `.task-log/` etc.

### TC-3.4 — Edge case: re-run `/atelier:setup-project` (idempotency)

```
/atelier:setup-project .
```

**Expected**: bash helper detects "already configured" and either re-asks (interactive) or refuses with exit 2 (`--yes`). If you say yes to reconfigure: existing files preserved, NOT overwritten. Root `CLAUDE.md` preserved (Phase 2 detects `present` and skips).

---

## Stage 4 — First real task cycle

This is the autonomous chain. The most likely place to surface friction.

### TC-4.1 — Define a task in ROADMAP.md

Edit `<chosen-project>/ROADMAP.md`. Add under P1:

```markdown
- [ ] feat add <something small and well-defined> [#1] [~15min]
```

**Recommendation**: a small additive change with clear acceptance criteria. Examples:

- `add a utility function with unit test` (similar to what we did with dogfood-4 task #1)
- `add a CLI flag --version that prints the package.json version`
- `add a README section "Installation"`

Avoid: tasks that touch `package.json` / `pnpm-lock.yaml` / `Dockerfile` / `.github/workflows/**` — those fall back to human review per PLAN.md §6 and will block the autonomous chain at the auto-merge gate.

### TC-4.2 — Run `/atelier:next-task`

```bash
cd <chosen-project>
task #1   # uses the shell function from shellrc — or:
claude '/next-task #1'
```

**Expected chain**:

1. `/next-task` sanity check, IN_PROGRESS empty
2. Task #1 picked, summary shown
3. Worktree created at `<project>-worktrees/task-1-<slug>/`
4. ROADMAP → IN_PROGRESS move (commit `chore(tracking): start task #1`)
5. M4.16 helper writes `.claude/settings.json` in the worktree
6. Handoff to `task-orchestrator`
7. Orchestrator dispatches `implementer`
8. (M4.17) If task mentions `postgres`/etc., `docker-runner` first
9. `implementer` writes code, returns
10. (M4.14) `/validate` runs (fast layer); if fails → retry with logs
11. `tester` writes tests, returns
12. `e2e-runner` if UI surface, else skip
13. `/validate --full` (fast + slow)
14. `pr-author` opens PR + ROADMAP IN_PROGRESS → HISTORY move
15. `reviewer` posts review
16. `auto-merge` evaluates 6 PLAN.md §6 guardrails

**Capture per step**:
- Did the agent dispatch correctly?
- Time to completion of each agent
- Any prompts/blockers
- The PR URL when it lands
- Auto-merge: did it merge? Did it fall back to human with reasons?

### TC-4.3 — Single-developer caveat (likely)

Because your `gh/author` and `gh/reviewer` resolve to the same GitHub identity (Miguelslo27), GitHub silently downgrades the reviewer's approve to a comment. The auto-merge skill will hold the PR per PLAN.md §6 guardrail #2 (review status).

**Expected**: auto-merge reports `held — reviewer approval not recorded (same-identity downgrade)`. PR stays open. Operator manually merges.

**This is documented behavior** (M6.4 troubleshooting doc captures it). Capture as confirmation.

---

## Stage 5 — Capture findings + post-dogfood

### TC-5.1 — Update HISTORY.md M7.1 entry

Once the task cycle completes (or you hit a hard blocker), open atelier's own `HISTORY.md` and draft an entry for M7.1 with:

- Date + atelier version dogfood-ed
- Project chosen (path, language, size)
- Each stage's wall time
- Friction surfaced (numbered list, one per surprise/blocker)
- Per-friction: what happened, what the operator did to work around, what atelier should change

### TC-5.2 — Capture follow-ups

For each friction item that requires a code change, add a new ROADMAP entry (likely Low Priority unless it blocks the chain entirely).

### TC-5.3 — Decide: keep installed or roll back?

If atelier is going to stay installed:

```bash
atelier-list-projects          # snapshot which projects you registered during the dogfood
```

If you want to retire only the dogfood project (keep atelier active for others):

```bash
atelier-remove-project <dogfood-project-path>           # deregister; keep files
atelier-remove-project <dogfood-project-path> --purge   # also strip atelier's .gitignore + .npmrc additions
```

If rolling back atelier entirely for now (preserving chat history):

```bash
atelier-uninstall              # default mode: removes shellrc + symlinks + plugins; preserves $ATELIER_CONFIG_DIR
```

For a fully clean wipe (destroys chat history under $ATELIER_CONFIG_DIR):

```bash
atelier-uninstall --purge      # interactive prompt requires typing "PURGE"
```

---

## Specific test cases (referenced by the stages above)

This section catalogs the exact behaviors to validate and what to record. Use it as a checklist.

### Install path (`install.sh`)

| TC | What | Expected | Capture |
| --- | --- | --- | --- |
| INS-1 | Phase A: pnpm + fnm + gh + node installed | All present, versions logged | versions, any brew failures |
| INS-2 | Phase A: Chrome detection | `✓` or interactive prompt | which path triggered |
| INS-3 | Phase A: docker compose v2 detection | `✓` (already symlinked) or prompt | exit path |
| INS-4 | Phase B: Claude login | Browser opens if not logged in | success/fail |
| INS-5 | Phase B: gh dual-id setup | 2 separate `gh auth login` flows | both identities recorded |
| INS-6 | Phase B: identity-equality warning | warning if both same user | did you see it? |
| INS-7 | Phase C.1: shellrc block injected | sentinel comments + `task()` function | sentinel found in `~/.zshrc` |
| INS-8 | Phase C.1: `~/.local/bin/*` symlinks | symlinks for every `scripts/atelier-*` helper (`setup-project`, `uninstall`, `doctor`, `task-resolve`, `measure-merge-rate`, `update`, `list-projects`, `remove-project`, `permission-diff`, `pr-size-check`) | full list present |
| INS-8a | Phase C.1: `atelier-help.txt` (M7.1.F34) | `$ATELIER_CONFIG_DIR/atelier-help.txt` written | file present + `atelier --help` prints it |
| INS-9 | Phase C.1: `$ATELIER_CONFIG_DIR/templates/` instantiated | settings template + project-claude template + project-claude-root template | all 3 present, `<atelier-config-dir>` substituted |
| INS-10 | Phase C.2: marketplace + plugins installed | atelier@akalab-tech + claude-roadmap-tools@akalab-tech | both present in `/plugin list` |

### `/atelier:doctor` path

| TC | What | Expected | Capture |
| --- | --- | --- | --- |
| DOC-1 | Plugin drift: atelier | `✓ atelier 0.4.0` | actual version |
| DOC-2 | Plugin drift: claude-roadmap-tools | `✓ <version>` | actual version |
| DOC-3 | git-wt SHA drift | `✓ <sha> (up to date)` | sha |
| DOC-4 | Legacy hooks in ~/.claude/settings.json | `✓ no legacy` | yes/no |
| DOC-5 | git-wt on PATH | `✓` | path |
| DOC-6 | shellrc hooks active | `✓` | sentinel found |
| DOC-7 | `.npmrc` guardrails | `✓` or `–` (no project) | |
| DOC-8 | `.atelier-config.json` consistent | `✓` or `–` | |
| DOC-9 | system Chrome | `✓` | |
| DOC-10 | docker compose v2 | `✓` | |

### Project setup path (`/atelier:setup-project`)

| TC | What | Expected | Capture |
| --- | --- | --- | --- |
| SP-1 | Phase 1 bash helper output | progress lines + 2 marker lines | exact mode detected |
| SP-2 | Phase 2 dispatch decision | dispatches project-profiler in detected mode | which mode |
| SP-3 | `existing` mode scan | agent reads manifests + src + README | which files scanned |
| SP-4 | `new` mode interview | AskUserQuestion fires; operator answers | answer text |
| SP-5 | Drafted CLAUDE.md content quality | accurate Stack/Architecture/Conventions; TBDs for gaps | copy full content |
| SP-6 | Write succeeds | `<project>/CLAUDE.md` exists post-run | size + sha |
| SP-7 | Re-run with existing CLAUDE.md | helper emits `present`, slash command skips | confirmed |
| SP-8 | `--mode=new` override | forces new mode even on populated repo | confirmed |

### Task cycle path (`/atelier:next-task`)

| TC | What | Expected | Capture |
| --- | --- | --- | --- |
| NT-1 | Sanity check passes | `IN_PROGRESS.md` empty, branch is base | step output |
| NT-2 | Task picked | task summary shown | id + title |
| NT-3 | Worktree created | dir at `<project>-worktrees/task-<n>-<slug>/` | path |
| NT-4 | ROADMAP → IN_PROGRESS move | commit on task branch | commit sha |
| NT-5 | Per-task `.claude/settings.json` (M4.16) | settings.json in worktree with correct path | additionalDirectories[0] matches |
| NT-6 | Orchestrator handoff (M4.20) | subagent uses worktree path correctly | no cwd errors |
| NT-7 | implementer attempt | code written | files changed |
| NT-8 | /validate fast layer (M4.14) | pass/fail report | inner-loop iterations count |
| NT-9 | tester attempt | tests written + pass | test files |
| NT-10 | e2e-runner (if UI) or skip | screenshots or `skipped` | which |
| NT-11 | /validate --full | pass | |
| NT-12 | pr-author opens PR | PR URL | url |
| NT-13 | IN_PROGRESS → HISTORY commit | commit on task branch | sha |
| NT-14 | reviewer review | approve / request-changes | which + count of findings |
| NT-15 | auto-merge | merged / held with reasons | reason if held |

### Known-good outcomes (no friction = success)

If the task cycle reaches NT-15 with `held — same-identity reviewer downgrade`, that's a **success** (the chain ran end-to-end and the only blocker is the documented single-developer limitation). Manually merge the PR and the dogfood completes.

If the task cycle reaches NT-15 with `merged`, that's an **exceptional success** — the dual-identity flow is working as designed.

### Known-likely friction surfaces

Per M4.20's known-issues note and the running dogfood-4 work pre-deletion, expect potential friction at:

- **NT-5 / NT-6**: subagent cwd inheritance (M4.20 nominally fixed, but the empirical fix was via system-prompt rules — surfacing in a real chain is itself the validation)
- **NT-8 / inner loop**: M4.14's inner loop is unproven in real use; observe how many iterations it takes and whether iteration N+1 actually has prior log context
- **NT-11 / Playwright e2e**: needs reachable dev server in the project; if there isn't one, e2e is `skipped (no UI surface)` per the agent's design
- **NT-12 / pr-author**: pushes to `origin task/<id>-<slug>` — if the project's GitHub remote doesn't accept the dual-identity author's push (permissions, branch protection), this is where it surfaces

---

## What to bring back

When done (success or stop), the findings should let me write the M7.1 HISTORY entry with:

1. The drafted CLAUDE.md from SP-5 (verbatim).
2. A 1-line summary of each TC's outcome (passed / failed-with-reason / skipped-with-reason).
3. A friction log: per friction item, what happened + what atelier should change.
4. Any new ROADMAP entries that should be captured (likely Low Priority).
5. A go/no-go recommendation: is atelier production-ready for the operator's normal workflow, or are there blockers that need fixing first?
