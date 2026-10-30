#!/usr/bin/env bash
#
# Regression test for #648 — hooks/block-github-mcp-write.sh must block
# any GitHub MCP write tool call that runs under the operator's personal
# identity, under bare (mcp__github__*) and plugin-namespaced
# (mcp__plugin_*github*) tool names. Read tools, non-GitHub tools, and
# calls with verified identity (ATELIER_GITHUB_MCP_IDENTITY=author|reviewer)
# must pass. When jq is missing, the hook must fail open (exit 0) with a warning.
#
# Hermetic: pure string/JSON evaluation; CLAUDE_PROJECT_DIR is pinned to a
# temp dir so log_decision never touches real state.
#
# Run:  hooks/tests/block-github-mcp-write.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-github-mcp-write.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/logs" "$TMP/bin-no-jq"

# Set up a bin dir without jq for degraded tests
for b in bash cat dirname mkdir date sed; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$TMP/bin-no-jq/$b"
done

fails=0
blocked_n=0
allowed_n=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# run_hook <tool_name> <tool_input_json> [VAR=val ...] -> echoes exit code
run_hook() {
  local tool_name="$1"
  local tool_input="${2:-{\}}"
  [ "$#" -ge 2 ] && shift 2 || shift "$#"
  local payload
  payload="$(jq -cn --arg t "$tool_name" --argjson i "$tool_input" '{tool_name:$t, tool_input:$i}')"
  (
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      env -u ATELIER_GITHUB_MCP_IDENTITY "$@" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/stderr"
  )
  echo "$?"
}

assert_block() {
  local name="$1" tool="$2" input="${3:-{\}}"
  [ "$#" -ge 3 ] && shift 3 || shift "$#"
  blocked_n=$((blocked_n + 1))
  local rc; rc="$(run_hook "$tool" "$input" "$@")"
  if [ "$rc" = "2" ] && grep -q 'atelier:block-github-mcp-write BLOCKED' "$TMP/stderr"; then
    pass "block: $name"
  else
    fail "block: $name (exit=$rc, stderr: $(cat "$TMP/stderr" 2>/dev/null))"
  fi
}

assert_allow() {
  local name="$1" tool="$2" input="${3:-{\}}"
  [ "$#" -ge 3 ] && shift 3 || shift "$#"
  allowed_n=$((allowed_n + 1))
  local rc; rc="$(run_hook "$tool" "$input" "$@")"
  if [ "$rc" = "0" ]; then
    pass "allow: $name"
  else
    fail "allow: $name (exit=$rc, stderr: $(cat "$TMP/stderr" 2>/dev/null))"
  fi
}

# =============================================================================
# SECTION A: Bare write tools are blocked
# =============================================================================
echo "== Section A: Bare GitHub write tools are blocked =="
assert_block "add_issue_comment"                    "mcp__github__add_issue_comment" '{"issue_number":1,"body":"test"}'
assert_block "pull_request_review_write"            "mcp__github__pull_request_review_write" '{"pull_number":1,"event":"APPROVE"}'
assert_block "create_pull_request"                  "mcp__github__create_pull_request" '{"title":"feat","head":"task","base":"main"}'
assert_block "delete_file"                          "mcp__github__delete_file" '{"path":"file.txt"}'
assert_block "merge_pull_request"                   "mcp__github__merge_pull_request" '{"pull_number":1}'
assert_block "mark_all_notifications_read"          "mcp__github__mark_all_notifications_read" '{}'
assert_block "projects_write"                       "mcp__github__projects_write" '{"project_id":"1"}'
assert_block "create_branch"                        "mcp__github__create_branch" '{"branch":"feature"}'
assert_block "create_gist"                          "mcp__github__create_gist" '{"description":"gist"}'
assert_block "create_or_update_file"                "mcp__github__create_or_update_file" '{"path":"f"}'
assert_block "create_repository"                    "mcp__github__create_repository" '{"name":"repo"}'
assert_block "create_repository_ruleset"            "mcp__github__create_repository_ruleset" '{"name":"ruleset"}'
assert_block "create_automation"                    "mcp__github__create_automation" '{}'
assert_block "create_automation_group"              "mcp__github__create_automation_group" '{}'
assert_block "delete_repository"                    "mcp__github__delete_repository" '{"repo":"repo"}'
assert_block "delete_automation"                    "mcp__github__delete_automation" '{}'
assert_block "fork_repository"                      "mcp__github__fork_repository" '{"repo":"repo"}'
assert_block "push_files"                           "mcp__github__push_files" '{"branch":"main"}'
assert_block "star_repository"                      "mcp__github__star_repository" '{"repo":"repo"}'
assert_block "unstar_repository"                    "mcp__github__unstar_repository" '{"repo":"repo"}'
assert_block "actions_run_trigger"                  "mcp__github__actions_run_trigger" '{}'
assert_block "dismiss_notification"                 "mcp__github__dismiss_notification" '{"thread_id":"1"}'
assert_block "discussion_comment_write"             "mcp__github__discussion_comment_write" '{}'
assert_block "add_reply_to_pull_request_comment"    "mcp__github__add_reply_to_pull_request_comment" '{}'
assert_block "add_comment_to_pending_review"        "mcp__github__add_comment_to_pending_review" '{}'
assert_block "issue_write"                          "mcp__github__issue_write" '{"title":"issue"}'
assert_block "sub_issue_write"                      "mcp__github__sub_issue_write" '{}'
assert_block "label_write"                          "mcp__github__label_write" '{"name":"bug"}'
assert_block "custom_properties_write"              "mcp__github__custom_properties_write" '{}'
assert_block "update_gist"                          "mcp__github__update_gist" '{"gist_id":"1"}'
assert_block "update_issue_comment"                 "mcp__github__update_issue_comment" '{"comment_id":1}'
assert_block "update_pull_request"                  "mcp__github__update_pull_request" '{"pull_number":1}'
assert_block "update_pull_request_branch"           "mcp__github__update_pull_request_branch" '{"pull_number":1}'
assert_block "update_automation"                    "mcp__github__update_automation" '{}'
assert_block "remove_automation_from_group"         "mcp__github__remove_automation_from_group" '{}'
assert_block "manage_notification_subscription"     "mcp__github__manage_notification_subscription" '{}'
assert_block "manage_repo_notification_sub"         "mcp__github__manage_repository_notification_subscription" '{}'
assert_block "request_copilot_review"               "mcp__github__request_copilot_review" '{"pull_number":1}'
assert_block "run_automation"                       "mcp__github__run_automation" '{}'
assert_block "run_secret_scanning"                  "mcp__github__run_secret_scanning" '{}'

# =============================================================================
# SECTION B: Plugin-namespaced write tools are blocked
# =============================================================================
echo "== Section B: Plugin-namespaced GitHub write tools are blocked =="
assert_block "plugin atelier add_issue_comment"     "mcp__plugin_atelier_github__add_issue_comment" '{"issue_number":1}'
assert_block "plugin github create_pull_request"    "mcp__plugin_github__create_pull_request" '{"title":"feat"}'
assert_block "plugin atelier delete_file"           "mcp__plugin_atelier_github__delete_file" '{"path":"file.txt"}'
assert_block "plugin github merge_pull_request"     "mcp__plugin_github__merge_pull_request" '{"pull_number":1}'
assert_block "plugin atelier pr_review_write"       "mcp__plugin_atelier_github__pull_request_review_write" '{"pull_number":1}'
assert_block "plugin github mark_all_notifs_read"   "mcp__plugin_github__mark_all_notifications_read" '{}'
assert_block "plugin custom projects_write"         "mcp__plugin_custom_github__projects_write" '{"project_id":"1"}'
assert_block "plugin test push_files"               "mcp__plugin_test_github__push_files" '{"branch":"main"}'

# =============================================================================
# SECTION C: Read tools are allowed
# =============================================================================
echo "== Section C: GitHub read tools pass =="
assert_allow "get_issue"                            "mcp__github__get_issue" '{"issue_number":1}'
assert_allow "list_issues"                          "mcp__github__list_issues" '{}'
assert_allow "search_code"                          "mcp__github__search_code" '{"query":"func"}'
assert_allow "issue_read"                           "mcp__github__issue_read" '{"issue_number":1}'
assert_allow "pull_request_read"                    "mcp__github__pull_request_read" '{"pull_number":1}'
assert_allow "check_dep_vulnerabilities"            "mcp__github__check_dependency_vulnerabilities" '{}'
assert_allow "semantic_issue_similarity_search"     "mcp__github__semantic_issue_similarity_search" '{"query":"bug"}'
assert_allow "actions_get"                          "mcp__github__actions_get" '{}'
assert_allow "actions_list"                         "mcp__github__actions_list" '{}'
assert_allow "get_commit"                           "mcp__github__get_commit" '{"commit_sha":"abc"}'
assert_allow "get_file_contents"                    "mcp__github__get_file_contents" '{"path":"README.md"}'
assert_allow "get_repository_tree"                  "mcp__github__get_repository_tree" '{}'
assert_allow "list_pull_requests"                   "mcp__github__list_pull_requests" '{}'
assert_allow "projects_get"                         "mcp__github__projects_get" '{"project_id":"1"}'
assert_allow "projects_list"                        "mcp__github__projects_list" '{}'
assert_allow "custom_properties_read"               "mcp__github__custom_properties_read" '{}'
assert_allow "repository_ruleset_read"              "mcp__github__repository_ruleset_read" '{}'
assert_allow "github_support_docs_search"           "mcp__github__github_support_docs_search" '{"query":"api"}'
assert_allow "plugin atelier get_issue"             "mcp__plugin_atelier_github__get_issue" '{"issue_number":1}'
assert_allow "plugin github search_code"            "mcp__plugin_github__search_code" '{"query":"search"}'

# =============================================================================
# SECTION D: Read tools with comment / review in name
# =============================================================================
echo "== Section D: Read tools with comment/review in name pass =="
assert_allow "get_discussion_comments"              "mcp__github__get_discussion_comments" '{"discussion_number":1}'
assert_allow "get_pull_request_comments"            "mcp__github__get_pull_request_comments" '{"pull_number":1}'
assert_allow "list_issue_comments"                  "mcp__github__list_issue_comments" '{"issue_number":1}'
assert_allow "get_comment_reactions"                "mcp__github__get_comment_reactions" '{"comment_id":1}'
assert_allow "list_pull_request_reviews"            "mcp__github__list_pull_request_reviews" '{"pull_number":1}'
assert_allow "plugin get_discussion_comments"       "mcp__plugin_atelier_github__get_discussion_comments" '{}'
assert_allow "plugin list_issue_comments"           "mcp__plugin_github__list_issue_comments" '{}'

# =============================================================================
# SECTION E: Non-GitHub tools pass
# =============================================================================
echo "== Section E: Non-GitHub tools pass =="
assert_allow "claude-in-chrome navigate"            "mcp__claude-in-chrome__navigate" '{"url":"https://github.com"}'
assert_allow "playwright browser_click"             "mcp__plugin_atelier_playwright__browser_click" '{"selector":"#btn"}'
assert_allow "Bash command"                         "Bash" '{"command":"gh pr list"}'
assert_allow "Edit command"                         "Edit" '{"file_path":"test.txt"}'
assert_allow "Write command"                        "Write" '{"file_path":"test.txt"}'
assert_allow "context-mode ctx_execute"             "mcp__context-mode__ctx_execute" '{"code":"print(1)"}'
assert_allow "supabase list_tables"                 "mcp__supabase_mcp__list_tables" '{}'
assert_allow "empty tool payload"                   "" '{}'

# =============================================================================
# SECTION F: Identity verification override (author / reviewer)
# =============================================================================
echo "== Section F: Identity verification override =="
assert_allow "author identity allows add_issue_comment" \
  "mcp__github__add_issue_comment" '{"body":"ok"}' \
  ATELIER_GITHUB_MCP_IDENTITY=author

assert_allow "author identity allows pull_request_review_write" \
  "mcp__github__pull_request_review_write" '{"event":"APPROVE"}' \
  ATELIER_GITHUB_MCP_IDENTITY=author

assert_allow "author identity allows delete_file" \
  "mcp__github__delete_file" '{"path":"file.txt"}' \
  ATELIER_GITHUB_MCP_IDENTITY=author

assert_allow "author identity allows plugin merge_pull_request" \
  "mcp__plugin_atelier_github__merge_pull_request" '{"pull_number":1}' \
  ATELIER_GITHUB_MCP_IDENTITY=author

assert_allow "reviewer identity allows add_issue_comment" \
  "mcp__github__add_issue_comment" '{"body":"ok"}' \
  ATELIER_GITHUB_MCP_IDENTITY=reviewer

assert_allow "reviewer identity allows pull_request_review_write" \
  "mcp__github__pull_request_review_write" '{"event":"APPROVE"}' \
  ATELIER_GITHUB_MCP_IDENTITY=reviewer

assert_allow "reviewer identity allows delete_file" \
  "mcp__github__delete_file" '{"path":"file.txt"}' \
  ATELIER_GITHUB_MCP_IDENTITY=reviewer

assert_allow "reviewer identity allows plugin merge_pull_request" \
  "mcp__plugin_atelier_github__merge_pull_request" '{"pull_number":1}' \
  ATELIER_GITHUB_MCP_IDENTITY=reviewer

assert_block "personal identity does NOT bypass block" \
  "mcp__github__add_issue_comment" '{"body":"fail"}' \
  ATELIER_GITHUB_MCP_IDENTITY=personal

assert_block "operator identity does NOT bypass block" \
  "mcp__github__delete_file" '{"path":"fail.txt"}' \
  ATELIER_GITHUB_MCP_IDENTITY=operator

# =============================================================================
# SECTION G: Degraded jq fallback
# =============================================================================
echo "== Section G: Degraded jq fallback fails open =="
allowed_n=$((allowed_n + 1))
rc_jq="$(run_hook "mcp__github__delete_file" '{"path":"file.txt"}' PATH="$TMP/bin-no-jq")"
if [ "$rc_jq" = "0" ] && grep -q 'jq missing; hook safety layer degraded, failing open' "$TMP/stderr"; then
  pass "degraded jq fails open with warning"
else
  fail "degraded jq fallback (exit=$rc_jq, stderr: $(cat "$TMP/stderr" 2>/dev/null))"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "blocked cases: $blocked_n, allowed cases: $allowed_n"
total=$((blocked_n + allowed_n))
if [ "$fails" -eq 0 ]; then
  echo "block-github-mcp-write: all $total assertions passed"
  exit 0
fi
echo "block-github-mcp-write: $fails of $total assertions FAILED"
exit 1
