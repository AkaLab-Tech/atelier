# TASK_021 — M9.4 — Two-way migration: files ↔ github-project (+ generalized backend → files)

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** Extend `/migrate-roadmap` for `files ↔ github-project` **both** directions, and implement the **generalized `backend → files` reverse path** (which also finally unlocks `linear → files`, currently "not yet implemented") — §16.6.

**Acceptance:** migrate a `files` project to `github-project` and back losslessly (tasks, buckets, ids, history preserved per the field mapping); `linear → files` also works via the generalized reverse path. Orphan/partial-migration guards mirror the existing `files → linear` safety rules.
