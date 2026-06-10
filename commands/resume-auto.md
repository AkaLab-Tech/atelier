---
description: Clear the decision-broker panic flag set by `/atelier:abort-auto`. Returns control of strategic decisions in the current task worktree to the broker, which will then honor `.atelier.json`'s `decisionPolicy` configuration as usual (auto / ask / fixed option per category). Use this when the operator has resolved whatever made them invoke `/atelier:abort-auto` and wants the broker autonomous again.
allowed-tools: Bash(git rev-parse:*), Bash(test:*), Bash(rm:*), Read
---

You are running the `/atelier:resume-auto` slash command. Your job is to remove the panic flag at `<worktree>/.atelier-abort-auto.flag` and report back. You do **not** modify task state, you do **not** invoke any specialist agent, you do **not** read the catalog. Single-purpose command, complementary to `/atelier:abort-auto`.

## What to do

1. **Resolve the worktree root** with `Bash(git rev-parse --show-toplevel)`. If the command fails (not a git worktree), surface clearly: *"Not inside a git worktree. `/atelier:resume-auto` only makes sense inside an active task worktree."* and stop.

2. **Check if the flag exists.** Run `Bash(test -f "<worktree>/.atelier-abort-auto.flag" && echo exists || echo absent)`. If `absent`, report idempotently: *"Panic switch was not active for `<worktree>`. The broker has been routing decisions per `.atelier.json` all along; no change needed."* and stop.

3. **Optionally read the flag content for audit context.** Use `Read` to capture the `ts:` and `reason:` fields if the flag is well-formed. The data is useful for the operator-facing report — it tells them how long the panic switch was active and why. If the flag is malformed (older formats are tolerated but not parsed), skip the parse silently.

4. **Remove the flag** with `Bash(rm "<worktree>/.atelier-abort-auto.flag")`. **Never** use `rm -f` or `rm -rf` — the file existence was already verified in step 2, and using `-f` would mask a permission error that the operator should see.

5. **Report back.** Print exactly:

   ```text
   ✓ panic switch CLEARED for <worktree>

   The decision broker will now resume honoring .atelier.json's
   decisionPolicy. Strategic decisions in this worktree will be
   resolved per the per-category settings (or default = "ask"
   when the project has not been configured).
   ```

   When the flag had a `ts:` field, append: *"Panic was active for <duration> (since <iso-ts>)."* — operator-readable.

## Hard refusals

- **Never** touch any other file. `.atelier-abort-auto.flag` is the only file this command removes.
- **Never** invoke `task-orchestrator`, `pr-author`, the broker skill, or any specialist agent. Same scope contract as `/atelier:abort-auto`.
- **Never** use `rm -f` or `rm -r*`. The flag is one file at a known path; the existence check in step 2 already covers the "not present" case.
- **Never** disable or modify the broker's resolution algorithm from this command. `/atelier:resume-auto` is just the flag-removal surface.

## Edge cases

- **Operator calls `/atelier:resume-auto` from a worktree where the flag was never set**: report the idempotent message and exit cleanly. No-op is the right outcome.
- **Operator calls it twice in quick succession**: second call hits the "flag absent" path; reports idempotently. Same outcome as a single call.
- **Flag exists but the file is read-only or in an unexpected state**: surface the `rm` error verbatim; do not retry, do not fall back to `chmod`. The operator inspects manually.
