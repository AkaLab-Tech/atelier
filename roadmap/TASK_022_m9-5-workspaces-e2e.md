# TASK_022 — M9.5 — Workspaces + end-to-end validation

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** One backend per repo in v1 (§16.7); a workspace may mix backends across members. Cross-repo `blocked_by:<token>#id` reads the sibling member's state **through its backend** (not assuming files).

**Acceptance:** a workspace with mixed-backend members aggregates status and resolves cross-repo `blocked_by` via each member's backend; a full autonomous cycle (claim → implement → PR → merge → state move) runs end-to-end on a `github-project`-backed member. Closes M9.
