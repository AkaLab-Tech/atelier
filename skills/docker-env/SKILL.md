---
name: docker-env
description: >-
  Operate the lifecycle of the per-task Docker Compose stack: `up`, `down`,
  `logs <service>`, `ps`, `teardown`. The compose project name is derived
  from the worktree's branch (`<task-id>-<slug>`) so parallel tasks
  isolate their networks and volumes. ALWAYS load this skill when about
  to run any `docker compose` command in the agent chain, when the
  `docker-runner` agent finishes scaffolding `docker-compose.yml`, when
  the `implementer` / `tester` needs to bring containerized services up
  for integration testing, or when the operator says "start the docker",
  "spin up postgres", "tear down the containers". The skill carries the
  runtime-detection and compose-project-name conventions that
  `operator-rules.md` and other skills do not. Refuses to run against a
  worktree without a `docker-compose.yml`. Refuses to invoke a runtime
  install (`brew install --cask docker`, `colima start`) — that is the
  operator's choice. Trigger even when keywords are absent — any phrasing
  about bringing up / tearing down a task's containers belongs here.
---

# docker-env

Lifecycle commands for the per-task Docker Compose stack. The `docker-runner` agent authors the compose file; this skill operates against it. The two are deliberately split: authoring is a judgment call (which image, which tag, which healthcheck) and lives in an agent; lifecycle is mechanical and lives in a skill.

## Preconditions

The skill assumes:

- The current worktree has `docker-compose.yml` at its root (authored by `docker-runner` or pre-existing). The skill **refuses to run against a worktree without a compose file** — there is no `up` semantics without one.
- The operator has a Docker-compatible runtime installed and running (Docker Desktop, Colima, OrbStack, Rancher Desktop). The skill probes `docker info` at first use and **stops with a clear actionable message** if the daemon is unreachable — it does **not** install a runtime ([install.sh](install.sh) deliberately leaves that to the operator).
- The current branch is `task/<id>-<slug>` (set by `git-wt`). The compose project name is derived from the branch with the `task/` prefix stripped.

If any precondition is missing, **stop and report**.

## Compose project name convention

```text
project_name = <branch>  with  "task/" prefix stripped
```

Examples:
- branch `task/42-add-csv-export` → project `42-add-csv-export`
- branch `task/56-add-rate-limit` → project `56-add-rate-limit`

Every `docker compose ...` command this skill issues uses `-p <project_name>` explicitly. **Never** rely on the directory-name default — `docker compose` would silently pick the worktree directory name, which for `task-m4.17-docker-env`-style worktrees would collide with other tasks running on the same operator host. Explicit `-p` is the isolation mechanism.

The skill also passes `--file <worktree>/docker-compose.yml` explicitly so it does not depend on cwd being inside the worktree (per `operator-rules.md` § *Operating against the task worktree*).

## How to run

The skill exposes five operations. The orchestrator / implementer passes the operation name and any operation-specific args.

### `up`

Bring all services up, wait for healthchecks to pass, then return.

```bash
# Probe runtime first
docker info >/dev/null 2>&1 || {
  echo "✗ Docker daemon not reachable. Start your runtime (Docker Desktop, Colima, OrbStack) and re-run." >&2
  echo "  macOS examples:  brew install --cask docker    OR    brew install colima && colima start" >&2
  echo "  Linux examples:  systemctl start docker        OR    rootless-docker setup per distro docs" >&2
  exit 2
}

# Bring up
docker compose -p "<project_name>" --file "<worktree>/docker-compose.yml" up -d --wait
```

`--wait` makes the command block until every service with a `healthcheck:` reports `healthy`. Without it, services with slow start (Postgres takes ~3-5 seconds to accept connections) would silently fail the next step's connection.

On success: report each service's status (`<name>: healthy`) and the host port(s) exposed.

On failure: report the failing service + the last 20 lines of its container logs. Do **not** auto-retry — the implementer / tester decides whether to fix the compose file (back to `docker-runner`) or proceed with what works.

### `down`

Stop all services, remove containers, but **keep volumes** (so `up` after `down` recovers the state).

```bash
docker compose -p "<project_name>" --file "<worktree>/docker-compose.yml" down
```

### `teardown` (destructive — removes volumes)

Same as `down` plus removes named volumes prefixed with the project name. This is what the `Stop` hook calls at session end and what `auto-merge` calls after a successful merge.

```bash
docker compose -p "<project_name>" --file "<worktree>/docker-compose.yml" down --volumes --remove-orphans
```

`--remove-orphans` cleans up containers that match the compose project name but are not in the current compose file (e.g., a service removed between iterations). Idempotent — running on an already-empty project name is a no-op.

### `logs <service> [--tail N]`

Tail logs from one service. Default `--tail 50` so the output is bounded; `--follow` is **not** supported by this skill — agents should not block on streaming logs.

```bash
docker compose -p "<project_name>" --file "<worktree>/docker-compose.yml" logs --tail "${tail:-50}" "<service>"
```

### `ps`

List services in the compose project with health + port info.

```bash
docker compose -p "<project_name>" --file "<worktree>/docker-compose.yml" ps --format json
```

The JSON output is what the orchestrator parses to verify which services are running before proceeding to the next step in the chain. The skill returns it verbatim.

## Decision rules

- **Never** install a Docker runtime. If `docker info` fails, report the install command and stop. This is the operator's choice per [install.sh](install.sh)'s deliberate non-policy.
- **Never** run `docker compose` without `-p <project_name>` and `--file <worktree>/docker-compose.yml` explicitly set. The default-cwd behavior is the wrong isolation model for atelier's multi-worktree layout.
- **Never** invoke `down --volumes` (i.e., `teardown`) outside the `auto-merge` / `unblocker` / `Stop` hook paths. The implementer / tester iterating mid-task uses `down` (preserving volumes) so the next `up` recovers state.
- **Never** silently retry `up` on healthcheck failure. Surface the failing service + logs to the orchestrator. The decision to retry / fix / abandon is the orchestrator's, not the skill's.
- **Never** run commands against a `docker-compose.yml` that does not exist. Refuse and report — the agent / implementer should have invoked `docker-runner` first.

## Hard refusals

- **Never** modify `docker-compose.yml`. The skill is read-only against the compose file; edits are `docker-runner`'s responsibility.
- **Never** invoke `docker login` / `docker push` / `docker pull` for non-listed images. The skill operates against the images named in the compose file; pulling extra images is out of scope.
- **Never** run privileged containers or mount host paths outside the worktree. The compose file authored by `docker-runner` already excludes these patterns; the skill is defensive against them via inspection of the compose file before `up`.
