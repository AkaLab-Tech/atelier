---
backend: github-project
backendId: PVTI_lADOCSHEDc4Bbr7mzgw4diA
---
# TASK_005 — Idea — `/setup-project` detects CI/CD and offers to scaffold it per stack

`/atelier:setup-project` should check whether the project has CI/CD configured (e.g. `.github/workflows/**`, or other providers) and, when absent, **proactively offer to create a baseline pipeline** inferred from the detected stack (lint + typecheck + test, matching the package manager / language already detected for `/validate`). Today a freshly-onboarded project with no CI means the push/PR gates have no automated backstop on the remote. Read-only detection + an opt-in offer (never write workflows without confirmation — and recall agents never edit `.github/workflows/**` autonomously, so this is an explicit operator-confirmed scaffold at setup time, not a per-task action). Identified while onboarding deminut.
