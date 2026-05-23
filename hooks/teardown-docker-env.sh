#!/usr/bin/env bash
#
# atelier — Stop hook that tears down the per-task Docker Compose stack
# when the session ends (i.e., the agent turn that triggered the Stop
# event is finishing).
#
# Compose project name convention (per skills/docker-env/SKILL.md):
#   project_name = <branch>  with "task/" prefix stripped
#
# Safety guards:
#   1. Probe the cwd's branch; if it does not match `^task/<id>-<slug>$`,
#      this is not an atelier task session — exit 0 (no-op).
#   2. Probe `docker info`; if the daemon is unreachable, exit 0 (no-op
#      with a one-line stderr note — there is nothing to tear down).
#   3. Probe `docker compose -p <project> ps -q`; if no containers exist
#      for the project, exit 0 (no-op, idempotent).
#
# Only when ALL three guards pass do we issue
# `docker compose -p <project> down --volumes --remove-orphans`. Named
# volumes prefixed with the project name are wiped — that is the whole
# point of this hook: no orphan state on session end.
#
# The hook fails soft (exit 0 on every recoverable error) so an
# unrelated session never blocks on Docker. Hard-failing would lock
# the operator out of every session that happens to have a docker
# command in scope.

set -uo pipefail
# NOTE: deliberately NOT using `set -e` — we want every guard to be
# explicit and the hook to never block the session on a recoverable
# failure.

# ---------- guard 1: cwd is an atelier task worktree ----------
branch=""
if command -v git >/dev/null 2>&1; then
  branch="$(git -C "$(pwd)" branch --show-current 2>/dev/null || true)"
fi

case "$branch" in
  task/*)
    # Strip "task/" prefix to get the compose project name.
    project="${branch#task/}"
    ;;
  *)
    # Not an atelier task session — silently exit. The Stop hook fires
    # on EVERY session end, including the operator's regular Claude
    # sessions where no docker-env stack exists.
    exit 0
    ;;
esac

# ---------- guard 2: docker daemon reachable ----------
if ! docker info >/dev/null 2>&1; then
  printf '!! atelier teardown-docker-env: docker daemon not reachable; nothing to tear down\n' >&2
  exit 0
fi

# ---------- guard 3: at least one container exists for this project ----------
container_ids="$(docker compose -p "$project" ps -q 2>/dev/null || true)"
if [ -z "$container_ids" ]; then
  # No containers for this project; idempotent no-op.
  exit 0
fi

# ---------- teardown ----------
# `down --volumes --remove-orphans`:
#   - stops + removes containers
#   - removes named volumes prefixed with $project (the per-task data)
#   - removes orphan containers (left over from compose-file iterations)
#
# Run with --file detection: if a docker-compose.yml exists in the
# current directory, compose picks it up automatically. If not, the
# `-p <project>` is enough for the volume/network cleanup — orphans
# are matched by label, not by file.
docker compose -p "$project" down --volumes --remove-orphans >/dev/null 2>&1 || {
  printf '!! atelier teardown-docker-env: tear-down for project %s failed (non-fatal)\n' "$project" >&2
  exit 0
}

printf 'atelier teardown-docker-env: tore down compose project %s (volumes + orphans)\n' "$project" >&2
exit 0
