# TASK_019 — M9.2 — GitHubProjectBackend in claude-roadmap-tools

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** Implement a third `RoadmapBackend` (`listTasks`/`getTask`/`addTask`/`moveTask`/`appendHistoryEntry`/`isAvailable`) against **GitHub Projects v2** (GraphQL, custom Status field), mirroring `LinearBackend`. Auth via a **GitHub MCP** (OAuth), not `gh` (confirm the hosted-MCP endpoint, analogous to `claude mcp add … https://mcp.linear.app/mcp`).

**Scope (in `claude-roadmap-tools`):**
- `GitHubProjectBackend`: Projects v2 GraphQL; Status field ↔ the three buckets via `stateMap` (like Linear); `#id`/type/estimate as custom fields; `[ready]` as a dedicated `Ready` field; `blocked_by` as text (§16.3).
- Extend `/create-roadmap --backend github-project` and `/migrate-roadmap --to github-project`; teach `roadmap-tracking-flow` to route to it. Optional offline mirror + `backend`/`backendId` frontmatter, mirroring Linear.

**Acceptance:** a repo can be set to the `github-project` backend; tasks list / move / append-history via the Project; `.roadmap.json` records `backend: github-project`. Built on the 9.1 abstraction (second consumer, not a one-off).
