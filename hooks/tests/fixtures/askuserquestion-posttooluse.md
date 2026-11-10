# AskUserQuestion PostToolUse spike (#735), 2026-11-10

Method: a throwaway `PostToolUse` hook (matcher `AskUserQuestion`) in the main checkout's `.claude/settings.local.json` copied stdin to a file. The operator answered selectors in the live main session (Claude Code 2.1.321, permission_mode auto, atelier v0.62.0 loaded). The hook was removed afterwards. The scrubbed captures are next to this note.

Findings:
1. `PostToolUse` fires for `AskUserQuestion` in the main session, with no reload needed after adding the hook to settings.
2. Payload top-level keys: `cwd, duration_ms, effort, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, tool_response, tool_use_id, transcript_path`. No `agent_id` / `agent_type` in a main-session payload.
3. The answer is in `tool_response.answers`, an object keyed by the full question text with the selected answer string as value. `tool_input.answers` carries the same object, and `tool_response.questions` repeats `tool_input.questions`. `annotations` is `{}`.
4. An option pick gives the option label verbatim (`askuserquestion-posttooluse-main.json`). A free-text "Other" answer gives the typed text verbatim, with no flag distinguishing it from a label (`askuserquestion-posttooluse-other.json`, answer `prueba libre`). So exact label matching is the only way to tell them apart; typed text identical to an affirmative label is indistinguishable and counts as the operator's own answer.
5. Pre-filled answers do not bypass the operator. The main session called `AskUserQuestion` with `answers` pre-filled to the affirmative label; the harness still showed the selector, the operator chose "No", and both `tool_input.answers` and `tool_response.answers` carried "No" (`askuserquestion-posttooluse-prefilled-overridden.json`). Read the answer from `tool_response.answers`.
6. Subagent case: the #735 implementer reported that subagents have no `AskUserQuestion` tool in this harness, so a subagent-shown selector cannot occur today. Keep the "non-empty `agent_id` → reject" check as defence in depth.
7. Multi-question selectors produce one `answers` entry per question (seen in an unrelated two-question capture).

Stop conditions: none holds. The hook fires, the answer is present, and main session vs subagent is decidable (subagents cannot call the tool; `agent_id` is absent in main).

Residual: in headless or SDK modes, whether pre-filled `answers` are honoured without a human was not tested. That stays in the PLAN.md residual-risk note (#737), and the chain never asks in non-interactive mode.
