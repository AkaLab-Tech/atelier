#!/usr/bin/env bash
#
# Regression test for #497 — scripts/atelier-ci-coverage tells "CI not
# reported yet" from "no workflow runs on PRs into this base".
#
# Each case builds a throwaway repo (a work clone plus a bare origin under
# mktemp -d), publishes the workflow files to origin/main and origin/stage,
# and runs the helper against a base:
#
#   covered    some workflow runs on PRs into the base
#   uncovered  workflows exist, none triggers on PRs into the base
#   unknown    cannot be classified with certainty (fail closed)
#   none       no workflow files on the base ref
#
# Groups: A usage / shape of the output, B covered shapes, C uncovered
# shapes, D none, E fail-closed (unknown) triggers, F multi-file sets,
# G missing ref.
#
# Hermetic: local git only, no network. A git identity is set locally in
# every throwaway repo (CI has none) and the default branch name is never
# assumed (work branch is created explicitly, origin gets explicit refs).
#
# Run:  hooks/tests/ci-coverage.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# Literal strings legitimately contain ${{ ... }}; nothing should expand.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-ci-coverage"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate from the operator's git config (signing, hooks, templates).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# mkrepo [file=content ...] — echoes the work-repo path. Each argument is
# <workflow-file-name>=<content> (written under .github/workflows/). With
# no arguments the repo has a README only (no workflows dir). The tree is
# published to origin as both `main` and `stage`.
mkrepo() {
  # Runs in a command-substitution subshell, so a counter would not persist:
  # every case gets its own mktemp directory instead.
  local d arg name content
  d=$(mktemp -d "$TMP/case.XXXXXX")
  mkdir -p "$d/work"
  git init -q --bare "$d/origin.git"
  git -C "$d/work" init -q
  git -C "$d/work" config user.email "test@example.invalid"
  git -C "$d/work" config user.name "Test"
  git -C "$d/work" config commit.gpgsign false
  git -C "$d/work" checkout -q -b work
  printf 'readme\n' >"$d/work/README.md"
  for arg in "$@"; do
    name=${arg%%=*}
    content=${arg#*=}
    mkdir -p "$d/work/.github/workflows"
    printf '%s\n' "$content" >"$d/work/.github/workflows/$name"
  done
  git -C "$d/work" add -A
  git -C "$d/work" commit -q -m "fixture"
  git -C "$d/work" remote add origin "$d/origin.git"
  git -C "$d/work" push -q origin work:refs/heads/main work:refs/heads/stage
  printf '%s\n' "$d/work"
}

# expect <label> <want-coverage> <base> <repo> — runs the helper and checks
# exit 0, the coverage= line, and a non-empty reason= line.
expect() {
  local label="$1" want="$2" base="$3" repo="$4" out rc cov reason
  out=$("$HELPER" "$repo" "$base" 2>/dev/null)
  rc=$?
  cov=$(printf '%s\n' "$out" | sed -n 's/^coverage=//p')
  reason=$(printf '%s\n' "$out" | sed -n 's/^reason=//p')
  if [ "$rc" -ne 0 ]; then
    fail "$label — exit $rc (want 0)"
  elif [ "$cov" != "$want" ]; then
    fail "$label — coverage '$cov' (want '$want'); reason: $reason"
  elif [ -z "$reason" ]; then
    fail "$label — empty reason= line"
  else
    pass "$label"
  fi
}

# one <label> <want> <base> <content> — single ci.yml case.
one() {
  local repo
  repo=$(mkrepo "ci.yml=$4")
  expect "$1" "$2" "$3" "$repo"
}

if [ ! -x "$HELPER" ]; then
  fail "helper exists and is executable: $HELPER"
  echo "1 assertion(s) failed."
  exit 1
fi

echo "Group A — usage and output shape"
"$HELPER" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "no arguments -> exit 2"; else fail "no arguments -> exit $rc (want 2)"; fi
"$HELPER" /tmp >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "one argument -> exit 2"; else fail "one argument -> exit $rc (want 2)"; fi
"$HELPER" "" main >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "empty project_root -> exit 2"; else fail "empty project_root -> exit $rc (want 2)"; fi
"$HELPER" /tmp main extra >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "three arguments -> exit 2"; else fail "three arguments -> exit $rc (want 2)"; fi
expect "project root that is not a directory -> unknown" unknown main "$TMP/does-not-exist"

PALABRIUM='name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
repo=$(mkrepo "ci.yml=$PALABRIUM")
out=$("$HELPER" "$repo" stage 2>/dev/null)
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ] \
  && printf '%s\n' "$out" | sed -n 1p | grep -q '^coverage=' \
  && printf '%s\n' "$out" | sed -n 2p | grep -q '^reason='; then
  pass "output is exactly two lines: coverage= then reason="
else
  fail "output shape: $out"
fi

echo "Group B — covered shapes"
expect "palabrium shape: base main -> covered" covered main "$repo"
expect "palabrium shape: base stage -> uncovered" uncovered stage "$repo"
one "bare 'on: pull_request' -> covered" covered stage 'on: pull_request
jobs: {}'
one "flow list 'on: [push, pull_request]' -> covered" covered stage 'on: [push, pull_request]
jobs: {}'
one "block list of events -> covered" covered stage 'on:
  - push
  - pull_request
jobs: {}'
one "pull_request with only types (no branch filter) -> covered" covered stage 'on:
  pull_request:
    types: [opened, synchronize]
jobs: {}'
one "flow branches list naming the base -> covered" covered stage 'on:
  pull_request:
    branches: [main, stage]
jobs: {}'
one "block-sequence branches naming the base -> covered" covered stage 'on:
  pull_request:
    branches:
      - main
      - stage
jobs: {}'
one "quoted branch entry naming the base -> covered" covered stage "on:
  pull_request:
    branches:
      - 'stage'
jobs: {}"
one "pull_request_target without a filter -> covered" covered stage 'on:
  pull_request_target:
jobs: {}'
repo=$(mkrepo "ci.yaml=on: pull_request")
expect "ci.yaml file -> covered" covered stage "$repo"

echo "Group C — uncovered shapes"
one "push-only (block) -> uncovered" uncovered stage 'on:
  push:
    branches: [main]
jobs: {}'
one "bare 'on: push' -> covered" covered stage 'on: push
jobs: {}'
one "schedule + workflow_dispatch only -> uncovered" uncovered stage 'on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch:
jobs: {}'
one "pull_request branches [main], base stage (flow) -> uncovered" uncovered stage 'on:
  pull_request:
    branches: [main]
jobs: {}'
one "pull_request branches block [main], base stage -> uncovered" uncovered stage 'on:
  pull_request:
    branches:
      - main
jobs: {}'
one "comment lines inside on: are ignored -> uncovered" uncovered stage 'on:
  # only pushes
  push:
    branches: [main]
jobs: {}'

echo "Group D — none"
repo=$(mkrepo)
expect "no .github/workflows dir -> none" none main "$repo"
repo=$(mkrepo "notes.txt=on: pull_request")
expect "only a non-yaml file in workflows -> none" none stage "$repo"

echo "Group E — fail-closed triggers (unknown)"
one "expression in on: -> unknown" unknown stage 'on:
  pull_request:
    branches: ["${{ vars.BASE }}"]
jobs: {}'
one "expression on the on: line -> unknown" unknown stage 'on: ${{ vars.EVENTS }}
jobs: {}'
one "workflow_call -> unknown" unknown stage 'on:
  workflow_call:
jobs: {}'
one "workflow_run -> unknown" unknown stage 'on:
  workflow_run:
    workflows: [CI]
jobs: {}'
one "workflow_call in a flow list -> unknown" unknown stage 'on: [push, workflow_call]
jobs: {}'
one "branches-ignore -> unknown" unknown stage 'on:
  pull_request:
    branches-ignore: [main]
jobs: {}'
one "paths under pull_request -> unknown" unknown stage 'on:
  pull_request:
    branches: [stage]
    paths: ["src/**"]
jobs: {}'
one "paths-ignore under pull_request -> unknown" unknown stage 'on:
  pull_request:
    paths-ignore: ["docs/**"]
jobs: {}'
one "glob in a block branch entry -> unknown" unknown stage 'on:
  pull_request:
    branches:
      - "release/*"
jobs: {}'
one "glob in a flow branch entry -> unknown" unknown stage 'on:
  pull_request:
    branches: ["st**"]
jobs: {}'
one "anchor in on: -> unknown" unknown stage 'on:
  pull_request: &pr
    branches: [stage]
jobs: {}'
one "alias in on: -> unknown" unknown stage 'x: &b [stage]
on:
  pull_request:
    branches: *b
jobs: {}'
one "multi-document file -> unknown" unknown stage 'on: pull_request
jobs: {}
---
on: push
jobs: {}'
one "leading document marker then a second one -> unknown" unknown stage '---
on: pull_request
jobs: {}
---
on: push'
one "document end marker -> unknown" unknown stage 'on: pull_request
...'
TAB=$(printf '\t')
one "tab indentation in on: -> unknown" unknown stage "on:
${TAB}pull_request:
jobs: {}"
one "unrecognised quoted top-level key -> unknown" unknown stage '"weird key!": 1
on: pull_request
jobs: {}'
one "unclassifiable line under pull_request -> unknown" unknown stage 'on:
  pull_request:
    branches: [stage]
    this is not yaml
jobs: {}'
one "unclassifiable item in on: block -> unknown" unknown stage 'on:
  - push: {}
jobs: {}'
one "flow mapping on the on: line -> unknown" unknown stage 'on: {pull_request: {}}
jobs: {}'
one "no top-level on: key -> unknown" unknown stage 'name: CI
jobs: {}'
one "empty branches list -> unknown" unknown stage 'on:
  pull_request:
    branches: []
jobs: {}'

echo "Group F — multi-file sets"
repo=$(mkrepo \
  "ci.yml=on:
  pull_request:
    branches: [main]" \
  "release.yml=on:
  workflow_call:")
expect "uncovered + unknown -> unknown" unknown stage "$repo"
repo=$(mkrepo \
  "ci.yml=on:
  pull_request:
    branches: [main]" \
  "lint.yml=on: pull_request" \
  "deploy.yml=on:
  workflow_run:
    workflows: [CI]")
expect "uncovered + covered + unknown -> covered" covered stage "$repo"
repo=$(mkrepo \
  "ci.yml=on:
  pull_request:
    branches: [main]" \
  "nightly.yml=on:
  schedule:
    - cron: \"0 0 * * *\"")
expect "uncovered + uncovered -> uncovered" uncovered stage "$repo"
repo=$(mkrepo \
  "a.yml=on: schedule" \
  "b.yml=on:
  pull_request:
    branches: [stage]")
expect "uncovered + covered -> covered" covered stage "$repo"

echo "Group I — push triggers"
one "flow list 'on: [push]' -> covered" covered stage 'on: [push]
jobs: {}'
one "push: with no children -> covered" covered stage 'on:
  push:
jobs: {}'
one "push: {} -> covered" covered stage 'on:
  push: {}
jobs: {}'
one "push: null -> covered" covered stage 'on:
  push: null
jobs: {}'
one "push: ~ -> covered" covered stage 'on:
  push: ~
jobs: {}'
one "push branches [main] block form, base stage -> uncovered" uncovered stage 'on:
  push:
    branches: [main]
jobs: {}'
one "push branches [main] block form, base main -> uncovered" uncovered main 'on:
  push:
    branches: [main]
jobs: {}'
one "push branches block-sequence names, base stage -> uncovered" uncovered stage 'on:
  push:
    branches:
      - main
jobs: {}'
one "push with branches-ignore -> unknown" unknown stage 'on:
  push:
    branches-ignore: [main]
jobs: {}'
one "push with tags -> unknown" unknown stage 'on:
  push:
    tags: ["v1.0.0"]
jobs: {}'
one "push with paths -> unknown" unknown stage 'on:
  push:
    paths: ["src/**"]
jobs: {}'
one "push with a glob branch -> unknown" unknown stage 'on:
  push:
    branches: ["release/*"]
jobs: {}'
one "push with an empty branches list -> unknown" unknown stage 'on:
  push:
    branches: []
jobs: {}'
repo=$(mkrepo \
  "a.yml=on:
  push:
    branches: [main]" \
  "b.yml=on:
  pull_request:
    branches: [stage]")
expect "push-branches-only file + covering pull_request file -> covered" covered stage "$repo"

echo "Group G — missing ref"
repo=$(mkrepo "ci.yml=on: pull_request")
expect "base with no origin ref -> unknown" unknown no-such-branch "$repo"
plain=$(mktemp -d "$TMP/plain.XXXXXX")
git -C "$plain" init -q
expect "repo without an origin remote -> unknown" unknown main "$plain"

echo "Group H — read-only: the working tree is never consulted"
repo=$(mkrepo "ci.yml=on:
  pull_request:
    branches: [main]")
printf 'on: pull_request\n' >"$repo/.github/workflows/ci.yml"
expect "uncommitted local edit is ignored (reads origin/<base>) -> uncovered" uncovered stage "$repo"

if [ "$fails" -eq 0 ]; then
  echo "All assertions passed."
  exit 0
fi
echo "$fails assertion(s) failed."
exit 1
