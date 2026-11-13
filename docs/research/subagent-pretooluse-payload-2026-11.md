# Does a subagent's PreToolUse (Bash) payload carry `agent_id` / `agent_type`? (#710)

Date: 2026-11-13. Claude Code 2.1.323, `claude -p --permission-mode auto`, direct run, status: **verified** (live probe, n=3).

Question: `hooks/block-subagent-memory-write.sh` blocked top-level sessions too, because it treated `CLAUDE_CODE_CHILD_SESSION=1` as a subagent signal. Can the payload's `agent_id` / `agent_type` alone tell a top-level session from a subagent on a `PreToolUse` Bash hook?

Method (same harness shape as `agent-input-hooks-2026-11.md`): a scratch dir from `mktemp -d` holding a throwaway `--settings` file with one `PreToolUse` hook (matcher `Bash`). The hook logged only the payload's top-level key names, the `agent_id` / `agent_type` values and the `CLAUDE_CODE_CHILD_SESSION` env value, for the commands `echo main` and `echo sub`. Prompt: run `echo main` in the session itself, then dispatch one `general-purpose` subagent that runs `echo sub`. Three runs. No project or user setting edited, `atelier-memory` never run, `ATELIER_CONFIG_DIR` not touched. Scratch files are outside the repo.

| Context | Keys in payload | `agent_id` | `agent_type` | `CLAUDE_CODE_CHILD_SESSION` | Runs |
|---------|-----------------|------------|--------------|-----------------------------|------|
| Top-level session (`echo main`) | `cwd, effort, hook_event_name, permission_mode, prompt_id, session_id, tool_input, tool_name, tool_use_id, transcript_path` | absent | absent | `1` | 3 of 3 |
| `general-purpose` subagent (`echo sub`) | the same plus `agent_id, agent_type` | present (e.g. `a3511b0d27db21c40`) | `general-purpose` | `1` | 3 of 3 |

Result: `agent_id` and `agent_type` are present only in the subagent's payload, and `CLAUDE_CODE_CHILD_SESSION` is `1` in both contexts, so the env var cannot discriminate. The hook uses the payload fields only.
