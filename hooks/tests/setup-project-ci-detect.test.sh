#!/usr/bin/env bash
#
# Regression test for TASK_005 — setup-project CI/CD detection / marker.
# `scripts/atelier-setup-project`'s detect_ci_status() is a read-only probe
# for a recognised CI/CD config (GitHub Actions, GitLab CI, CircleCI, Azure
# Pipelines, Jenkins, Bitbucket Pipelines, Drone, Travis). It never writes a
# workflow file, and emits `atelier-ci-status=<present|absent>` in the
# marker block.
#
# Test strategy (mirrors setup-project-backend-marker.test.sh):
#   Extract detect_ci_status() and drive it directly against throwaway
#   project directories, covering the empty-file guard and at least one
#   non-GitHub provider. Hermetic: temp dirs only, no network, no real
#   project root.
#
# Run:  hooks/tests/setup-project-ci-detect.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ============================================================
# Extract detect_ci_status() from the real script and source it.
# ============================================================

FN_DETECT="$TMP/detect_ci_status.sh"
awk '/^detect_ci_status\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN_DETECT"
if ! grep -q 'workflows' "$FN_DETECT"; then
  echo "  FAIL: could not extract detect_ci_status() from $SCRIPT"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_DETECT"

# assert_ci <expected> <label> ; uses global PROJECT
assert_ci() {
  local expected="$1" label="$2" got
  got="$(detect_ci_status)"
  if [ "$got" = "$expected" ]; then
    pass "$label (=$got)"
  else
    fail "$label: expected '$expected', got '$got'"
  fi
}

mkproj() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# --- case 1: no CI config anywhere → absent -----------------------------
PROJECT="$(mkproj c1_none)"
assert_ci absent "no CI config in project → absent"

# --- case 2: non-empty .github/workflows/ci.yml → present ---------------
PROJECT="$(mkproj c2_gha)"
mkdir -p "$PROJECT/.github/workflows"
cat > "$PROJECT/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
assert_ci present "non-empty .github/workflows/ci.yml → present"

# --- case 3: EMPTY .github/workflows/*.yml (zero bytes) → absent --------
# The empty-file guard is a real branch: a zero-byte workflow file must not
# be treated as a recognised CI config.
PROJECT="$(mkproj c3_empty)"
mkdir -p "$PROJECT/.github/workflows"
: > "$PROJECT/.github/workflows/ci.yml"
assert_ci absent "empty (zero-byte) .github/workflows/ci.yml → absent"

# --- case 3b: empty .yml alongside no other config → absent, and the
# .github/workflows dir existing at all must not itself trip "present" -----
if [ ! -s "$PROJECT/.github/workflows/ci.yml" ]; then
  pass "fixture sanity: ci.yml in case 3 really is zero bytes"
else
  fail "fixture sanity: ci.yml in case 3 is NOT zero bytes (test fixture bug)"
fi

# --- case 4: non-GitHub provider — Jenkinsfile → present -----------------
PROJECT="$(mkproj c4_jenkins)"
printf 'pipeline { agent any }\n' > "$PROJECT/Jenkinsfile"
assert_ci present "Jenkinsfile (non-GitHub provider) → present"

# --- case 5: non-GitHub provider — .gitlab-ci.yml → present --------------
PROJECT="$(mkproj c5_gitlab)"
printf 'stages:\n  - test\n' > "$PROJECT/.gitlab-ci.yml"
assert_ci present ".gitlab-ci.yml (non-GitHub provider) → present"

# --- case 6: unrecognised file in .github/workflows (not .yml/.yaml) →
# absent, since only *.yml / *.yaml are recognised -------------------------
PROJECT="$(mkproj c6_notyaml)"
mkdir -p "$PROJECT/.github/workflows"
printf 'not a workflow\n' > "$PROJECT/.github/workflows/README.md"
assert_ci absent "non-yml file under .github/workflows (README.md) → absent"

# ============================================================
# Result
# ============================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project CI/CD detection (TASK_005): all assertions passed."
  exit 0
else
  echo "setup-project CI/CD detection (TASK_005): $fails assertion(s) failed."
  exit 1
fi
