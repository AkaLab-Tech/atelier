#!/usr/bin/env bash
#
# Regression test for task #770 section B — `git add|commit
# --pathspec-from-file` in hooks/block-env-commit.sh and hooks/scan-git-add.sh,
# plus the shared helpers in hooks/lib/env-names.sh (env_pathspec_file_opt,
# env_pathspec_nul_opt, env_pathspec_entries, env_dirty_env_files).
#
# A readable pathspec file contributes its entries like command-line pathspecs
# (a protected entry blocks, a template entry goes through the template secret
# scan, a staged deletion is allowed). stdin, /dev/stdin, process
# substitution, a missing/unreadable/non-regular file cannot be inspected, so
# the hooks refuse whenever an env file is untracked (ignored ones included),
# modified or staged, and allow when none is.
#
# Hermetic: throwaway repos under `mktemp -d`. Every repo sets
# `core.excludesFile` to a file holding `.env*` (the shape install.sh Phase
# C.1 produces) so untracked env fixtures are IGNORED, the case a plain
# `ls-files --exclude-standard` listing would miss. No test reads a fixture's
# contents. Requires git + jq.
#
# Run:  hooks/tests/env-pathspec-from-file.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # test commands are literal text; no expansion wanted

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT_HOOK="$REPO_ROOT/hooks/block-env-commit.sh"
SCAN_HOOK="$REPO_ROOT/hooks/scan-git-add.sh"
LIB="$REPO_ROOT/hooks/lib/env-names.sh"

TMP="$(mktemp -d)"
trap 'chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Isolate git config from the host, then give every fixture repo the
# production shape: a global-style excludes file with `.env*`.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$XDG_CONFIG_HOME"
EXCLUDES="$TMP/global-excludes"
printf '.env*\n' > "$EXCLUDES"

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

PLACEHOLDER_BODY=$'# template\nAPI_KEY=your_api_key_here\nPORT=3000\n'
SECRET_BODY_COMMIT="$(printf 'DB_PASSWORD=%s\n' "hunter2-real-prod-pw-9f3a")"
SECRET_BODY_SCAN="$(printf 'REGION=eu\nACCESS_ID=%s%s\n' "AKI""A" "QWERTYUIOPASDFGH")"

# run_hook <hook> <cwd> <command> -> exit code
run_hook() {
  local hook="$1" cwd="$2" cmd="$3" payload
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$hook" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

# expect <label> <want> <hook> <cwd> <cmd>
expect() {
  local label="$1" want="$2" code
  code="$(run_hook "$3" "$4" "$5")"
  if [ "$code" = "$want" ]; then pass "$label"
  else fail "$label (expected exit $want, got $code)"; fi
}

# both <label> <want> <cwd> <cmd>: same expectation from both hooks.
both() {
  expect "block-env-commit: $1" "$2" "$COMMIT_HOOK" "$3" "$4"
  expect "scan-git-add: $1" "$2" "$SCAN_HOOK" "$3" "$4"
}

# make_repo <state>: a committed repo (README.md, src/a.txt) with one env
# state on top. Echoes its path. States:
#   clean      no env file anywhere
#   untracked  .env.prod untracked and ignored by the global .env* exclude
#   subdir     sub/.env.local untracked and ignored
#   modified   .env.tracked committed (force-added), then edited
#   staged     .env.staged force-added, not committed
#   template   only an untracked .env.example (placeholder content)
#   stagedel   .env.old committed, then `git rm`-ed (staged deletion)
make_repo() {
  local state="$1" d="$TMP/r-$1"
  mkdir -p "$d/src"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" config core.excludesFile "$EXCLUDES"
  printf '# fixture\n' > "$d/README.md"
  printf 'one\n' > "$d/src/a.txt"
  printf 'two\n' > "$d/src/b.txt"
  case "$state" in
    modified) printf 'K=v\n' > "$d/.env.tracked" ;;
    stagedel) printf 'K=v\n' > "$d/.env.stagedel" ;;
  esac
  git -C "$d" add -A
  case "$state" in
    modified) git -C "$d" add -f .env.tracked ;;
    stagedel) git -C "$d" add -f .env.stagedel ;;
  esac
  git -C "$d" commit -qm init
  case "$state" in
    untracked) printf 'K=v\n' > "$d/.env.prod" ;;
    subdir) mkdir -p "$d/sub"; printf 'K=v\n' > "$d/sub/.env.local" ;;
    modified) printf 'K=changed\n' >> "$d/.env.tracked" ;;
    staged) printf 'K=v\n' > "$d/.env.staged"; git -C "$d" add -f .env.staged ;;
    template) printf '%s' "$PLACEHOLDER_BODY" > "$d/.env.example" ;;
    stagedel) git -C "$d" rm -q -f .env.stagedel ;;
  esac
  echo "$d"
}

# clone_repo <src> <name>: a copy (own state) of a fixture repo; echoes its path.
clone_repo() { cp -R "$1" "$TMP/c-$2"; echo "$TMP/c-$2"; }

LISTS="$TMP/lists"; mkdir -p "$LISTS"
# list <name> <printf-format> [args...] -> absolute path of the list file.
list() {
  local name="$1"; shift
  # shellcheck disable=SC2059  # the caller passes the printf format
  printf "$@" > "$LISTS/$name"
  echo "$LISTS/$name"
}

R_CLEAN="$(make_repo clean)"
R_UNTRACKED="$(make_repo untracked)"
R_SUBDIR="$(make_repo subdir)"
R_MODIFIED="$(make_repo modified)"
R_STAGED="$(make_repo staged)"
R_TEMPLATE="$(make_repo template)"
R_STAGEDEL="$(make_repo stagedel)"
ALL_DIRTY=("$R_UNTRACKED" "$R_SUBDIR" "$R_MODIFIED" "$R_STAGED")

# Sanity: the fixtures really are in the states the cases assume, including
# "ignored" for the untracked one (the global exclude hides it from
# `--exclude-standard`).
if [ -z "$(git -C "$R_UNTRACKED" ls-files --others --exclude-standard -- .env.prod)" ] \
   && [ -n "$(git -C "$R_UNTRACKED" ls-files --others -- .env.prod)" ]; then
  pass "fixture: .env.prod is untracked and ignored by the global .env* exclude"
else
  fail "fixture: .env.prod is not untracked+ignored as assumed"
fi

# =============================================================================
echo "lib helpers — env_pathspec_file_opt / env_pathspec_nul_opt"
# shellcheck source=../lib/env-names.sh
# shellcheck disable=SC1091  # not followed without -x
source "$LIB"

chk_opt() { # <label> <want-rc> <want-out> <word> [next]
  local out rc
  out="$(env_pathspec_file_opt "$4" "${5-}")"; rc=$?
  if [ "$rc" = "$2" ] && [ "$out" = "$3" ]; then pass "file_opt: $1"
  else fail "file_opt: $1 (want rc=$2 out='$3', got rc=$rc out='$out')"; fi
}
chk_opt "=value inline -> 0" 0 "L.txt" "--pathspec-from-file=L.txt"
chk_opt "stdin value inline -> 0" 0 "-" "--pathspec-from-file=-"
chk_opt "value is the next word -> 2" 2 "L.txt" "--pathspec-from-file" "L.txt"
chk_opt "abbreviation --pathspec-from=value -> 0" 0 "L.txt" "--pathspec-from=L.txt"
chk_opt "abbreviation --pathspec-fr value -> 2" 2 "L.txt" "--pathspec-fr" "L.txt"
chk_opt "empty inline value -> 0 (empty)" 0 "" "--pathspec-from-file="
chk_opt "--pathspec-file-nul is not this option -> 1" 1 "" "--pathspec-file-nul"
chk_opt "--pathspec-f is ambiguous -> 1" 1 "" "--pathspec-f"
chk_opt "--pathspec-from-files (longer than the name) -> 1" 1 "" "--pathspec-from-files=x"
chk_opt "unrelated flag -> 1" 1 "" "--patch"
chk_opt "plain path -> 1" 1 "" "src/a.txt"

chk_nul() { # <label> <want-rc> <word>
  env_pathspec_nul_opt "$3"; local rc=$?
  if [ "$rc" = "$2" ]; then pass "nul_opt: $1"
  else fail "nul_opt: $1 (want rc=$2, got rc=$rc)"; fi
}
chk_nul "--pathspec-file-nul -> 0" 0 "--pathspec-file-nul"
chk_nul "abbreviation --pathspec-file -> 0" 0 "--pathspec-file"
chk_nul "abbreviation --pathspec-fi -> 0" 0 "--pathspec-fi"
chk_nul "--pathspec-from-file is not the NUL flag -> 1" 1 "--pathspec-from-file"
chk_nul "--pathspec-fr is not the NUL flag -> 1" 1 "--pathspec-fr"
chk_nul "plain word -> 1" 1 "src/a.txt"

# =============================================================================
echo "lib helpers — env_pathspec_entries"
D="$TMP/entries"; mkdir -p "$D"
printf 'a.txt\n\nsrc/b.txt\r\n' > "$D/plain"
chk_entries() { # <label> <want-rc> <want-out> <dir> <file> [nul]
  local out rc
  out="$(env_pathspec_entries "$4" "$5" "${6:-0}")"; rc=$?
  if [ "$rc" = "$2" ] && [ "$out" = "$3" ]; then pass "entries: $1"
  else fail "entries: $1 (want rc=$2 out='$3', got rc=$rc out='$out')"; fi
}
chk_entries "relative file resolves against the dir; blank line dropped; CR stripped" 0 $'a.txt\nsrc/b.txt' "$D" plain
chk_entries "absolute file ignores the dir" 0 $'a.txt\nsrc/b.txt' "$TMP" "$D/plain"
printf '"a b.txt"\n"caf\\303\\251.txt"\nplain.txt\n' > "$D/quoted"
chk_entries "C-style quotes removed, octal escapes decoded" 0 $'a b.txt\ncafé.txt\nplain.txt' "$D" quoted
printf 'x.txt\0y z.txt\0' > "$D/nul"
chk_entries "NUL mode splits on NUL, keeps spaces" 0 $'x.txt\ny z.txt' "$D" nul 1
printf '"not-quoted-in-nul"\0' > "$D/nulq"
chk_entries "NUL mode does not unquote" 0 '"not-quoted-in-nul"' "$D" nulq 1
printf 'last-no-newline' > "$D/nonl"
chk_entries "final line without newline kept" 0 'last-no-newline' "$D" nonl
chk_entries "stdin '-' unresolvable" 1 "" "$D" "-"
chk_entries "/dev/stdin unresolvable" 1 "" "$D" "/dev/stdin"
chk_entries "/dev/fd/N unresolvable" 1 "" "$D" "/dev/fd/63"
chk_entries "process substitution text unresolvable" 1 "" "$D" '<(printf x)'
chk_entries "value with a variable unresolvable" 1 "" "$D" '$LIST'
chk_entries "value with a backtick unresolvable" 1 "" "$D" '`echo plain`'
chk_entries "value with a glob unresolvable" 1 "" "$D" 'pl*'
chk_entries "empty value unresolvable" 1 "" "$D" ""
chk_entries "missing file unresolvable" 1 "" "$D" "nope"
chk_entries "directory (non-regular) unresolvable" 1 "" "$D" "."
printf 'x\n' > "$D/.env.list"
chk_entries "env-named list file unresolvable" 1 "" "$D" ".env.list"
mkfifo "$D/fifo" 2>/dev/null && chk_entries "FIFO unresolvable (never blocks on open)" 1 "" "$D" fifo
if [ "$(id -u)" != 0 ]; then
  printf 'x\n' > "$D/noread"; chmod 000 "$D/noread"
  chk_entries "unreadable file unresolvable" 1 "" "$D" noread
fi

# =============================================================================
echo "lib helpers — env_dirty_env_files under a global .env* exclude"
dirty() { env_dirty_env_files "$1" | sort | tr '\n' ' '; }
chk_dirty() { # <label> <want> <repo>
  local got; got="$(dirty "$3")"
  if [ "$got" = "$2" ]; then pass "dirty: $1"
  else fail "dirty: $1 (want '$2', got '$got')"; fi
}
chk_dirty "clean repo lists nothing" "" "$R_CLEAN"
chk_dirty "untracked ignored .env.prod is listed" ".env.prod " "$R_UNTRACKED"
chk_dirty "untracked ignored nested sub/.env.local is listed" "sub/.env.local " "$R_SUBDIR"
chk_dirty "modified tracked env is listed" ".env.tracked " "$R_MODIFIED"
chk_dirty "staged env is listed" ".env.staged " "$R_STAGED"
chk_dirty "untracked template is listed (the hook exempts it later)" ".env.example " "$R_TEMPLATE"
chk_dirty "staged deletion is not listed" "" "$R_STAGEDEL"
RU="$(clone_repo "$R_CLEAN" upper)"; printf 'K=v\n' > "$RU/.ENV.Prod"
chk_dirty "uppercase .ENV.Prod is listed (icase)" ".ENV.Prod " "$RU"
chk_dirty "a non-git directory lists nothing" "" "$TMP/entries"

# =============================================================================
echo "readable list file, every spelling — a protected entry blocks both hooks"
L_PROT="$(list prot '.env.prod\n')"
for spelling in \
  "--pathspec-from-file=$L_PROT" \
  "--pathspec-from-file $L_PROT" \
  "--pathspec-from-file=\"$L_PROT\"" \
  "--pathspec-from-file='$L_PROT'" \
  "--pathspec-from=$L_PROT" \
  "--pathspec-fr=$L_PROT" \
  "--pathspec-fr $L_PROT" \
  "--pathspec-from-fi $L_PROT" ; do
  both "git add $spelling" 2 "$R_UNTRACKED" "git add $spelling"
done
both "git add -f --pathspec-from-file=<list>" 2 "$R_UNTRACKED" "git add -f --pathspec-from-file=$L_PROT"
both "git add --pathspec-from-file=<list> --verbose (flag after)" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_PROT --verbose"
both "git add -v --pathspec-from-file <list> (flag before)" 2 "$R_UNTRACKED" "git add -v --pathspec-from-file $L_PROT"
both "git add --pathspec-from-file=<list> && echo done" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_PROT && echo done"

echo "readable list file — NUL-separated"
L_NUL_PROT="$(list nulprot '.env.prod\0src/a.txt\0')"
L_NUL_OK="$(list nulok 'src/a.txt\0src/b.txt\0')"
for nulflag in --pathspec-file-nul --pathspec-file --pathspec-fi; do
  both "git add --pathspec-from-file=<nul list> $nulflag, protected entry" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_NUL_PROT $nulflag"
  both "git add $nulflag --pathspec-from-file <nul list>, protected entry" 2 "$R_UNTRACKED" "git add $nulflag --pathspec-from-file $L_NUL_PROT"
  both "git add --pathspec-from-file=<nul list> $nulflag, no env entry (env file only on disk)" 0 "$R_UNTRACKED" "git add --pathspec-from-file=$L_NUL_OK $nulflag"
done

echo "readable list file — entry kinds"
L_NESTED="$(list nested 'src/a.txt\nsub/.env.local\n')"
both "nested protected entry sub/.env.local" 2 "$R_SUBDIR" "git add --pathspec-from-file=$L_NESTED"
L_QUOTED="$(list quoted '"src/a.txt"\n".env.prod"\n')"
both "C-style quoted protected entry" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_QUOTED"
L_CRLF="$(list crlf 'src/a.txt\r\n.env.prod\r\n')"
both "CRLF list with a protected entry" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_CRLF"
L_BLANKS="$(list blanks '\n\n.env.prod\n\n')"
both "blank lines around a protected entry" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_BLANKS"
L_LAST="$(list last 'src/a.txt\n.env.prod')"
both "protected entry on the last line without a newline" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_LAST"
L_MIX="$(list mix 'src/a.txt\nsrc/b.txt\n.env.prod\n')"
both "protected entry after non-env entries" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_MIX"
L_DOT="$(list dot '.\n')"
both "entry '.' stages every change, modified tracked env present" 2 "$R_MODIFIED" "git add --pathspec-from-file=$L_DOT"
both "entry '.' with only an ignored untracked env: git add . skips it, as without a list" 0 "$R_UNTRACKED" "git add --pathspec-from-file=$L_DOT"
both "entry '.' in a clean repo" 0 "$R_CLEAN" "git add --pathspec-from-file=$L_DOT"
L_OK="$(list ok 'src/a.txt\nsrc/b.txt\n')"
both "non-env entries only, env file on disk (untracked)" 0 "$R_UNTRACKED" "git add --pathspec-from-file=$L_OK"
both "non-env entries only, env file modified" 0 "$R_MODIFIED" "git add --pathspec-from-file=$L_OK"
both "non-env entries only, env file staged" 0 "$R_STAGED" "git add --pathspec-from-file=$L_OK"
both "non-env entries only, clean repo" 0 "$R_CLEAN" "git add --pathspec-from-file=$L_OK"
L_EMPTY="$(list empty '')"
both "empty list file" 0 "$R_UNTRACKED" "git add --pathspec-from-file=$L_EMPTY"
L_MODENT="$(list modent '.env.tracked\n')"
both "modified tracked env named in the list" 2 "$R_MODIFIED" "git add --pathspec-from-file=$L_MODENT"
L_STAGEDENT="$(list stagedent '.env.staged\n')"
both "staged env named in the list" 2 "$R_STAGED" "git add --pathspec-from-file=$L_STAGEDENT"

echo "readable list file — templates and staged deletions stay allowed"
L_TPL="$(list tpl '.env.example\n')"
both "placeholder template entry" 0 "$R_TEMPLATE" "git add --pathspec-from-file=$L_TPL"
L_TPL_MIX="$(list tplmix 'src/a.txt\n.env.example\n')"
both "placeholder template entry among others" 0 "$R_TEMPLATE" "git add --pathspec-from-file=$L_TPL_MIX"
L_DEL="$(list del '.env.stagedel\n')"
both "staged deletion entry" 0 "$R_STAGEDEL" "git add --pathspec-from-file=$L_DEL"
L_DEL_NUL="$(list delnul '.env.stagedel\0')"
both "staged deletion entry (NUL list)" 0 "$R_STAGEDEL" "git add --pathspec-from-file=$L_DEL_NUL --pathspec-file-nul"
L_DEL_PROT="$(list delprot '.env.stagedel\n.env.prod\n')"
R_DELPROD="$(clone_repo "$R_STAGEDEL" delprod)"; printf 'K=v\n' > "$R_DELPROD/.env.prod"
both "staged deletion entry plus a protected entry" 2 "$R_DELPROD" "git add --pathspec-from-file=$L_DEL_PROT"

L_DIST="$(list dist '.env.dist\n')"
R_TSEC_C="$(clone_repo "$R_CLEAN" tsec-c)"; printf '%s' "$SECRET_BODY_COMMIT" > "$R_TSEC_C/.env.dist"
R_TSEC_S="$(clone_repo "$R_CLEAN" tsec-s)"; printf '%s' "$SECRET_BODY_SCAN" > "$R_TSEC_S/.env.dist"
expect "block-env-commit: template entry with a real secret is scanned and blocked" 2 "$COMMIT_HOOK" "$R_TSEC_C" "git add --pathspec-from-file=$L_DIST"
expect "scan-git-add: template entry with a real secret is scanned and blocked" 2 "$SCAN_HOOK" "$R_TSEC_S" "git add --pathspec-from-file=$L_DIST"
expect "scan-git-add: same entry as a command-line pathspec (parity)" 2 "$SCAN_HOOK" "$R_TSEC_S" "git add .env.dist"
expect "block-env-commit: same entry as a command-line pathspec (parity)" 2 "$COMMIT_HOOK" "$R_TSEC_C" "git add .env.dist"

echo "readable list file — relative file behind -C <dir> and cd <dir> &&"
printf '.env.prod\n' > "$R_UNTRACKED/plist.txt"
printf 'src/a.txt\n' > "$R_UNTRACKED/oklist.txt"
both "git -C <dir> add --pathspec-from-file=plist.txt (resolved against -C)" 2 "$TMP" "git -C $R_UNTRACKED add --pathspec-from-file=plist.txt"
both "git -C <dir> add --pathspec-from-file plist.txt (separate word)" 2 "$TMP" "git -C $R_UNTRACKED add --pathspec-from-file plist.txt"
both "cd <dir> && git add --pathspec-from-file=plist.txt" 2 "$TMP" "cd $R_UNTRACKED && git add --pathspec-from-file=plist.txt"
both "cd <dir> && git add --pathspec-from-file plist.txt" 2 "$TMP" "cd $R_UNTRACKED && git add --pathspec-from-file plist.txt"
both "cwd = repo, relative plist.txt" 2 "$R_UNTRACKED" "git add --pathspec-from-file=plist.txt"
both "git -C <dir> add --pathspec-from-file=oklist.txt (no env entry)" 0 "$TMP" "git -C $R_UNTRACKED add --pathspec-from-file=oklist.txt"
both "cd <dir> && git add --pathspec-from-file=oklist.txt (no env entry)" 0 "$TMP" "cd $R_UNTRACKED && git add --pathspec-from-file=oklist.txt"

# =============================================================================
echo "stdin / process substitution / missing / unreadable — refused when env is dirty"
UNRESOLVED=(
  "git add --pathspec-from-file=-"
  "git add --pathspec-from-file -"
  "git add --pathspec-from=-"
  "git add --pathspec-fr -"
  "git add --pathspec-from-file=- --pathspec-file-nul"
  "git add -v --pathspec-from-file=-"
  "printf 'src/a.txt\\n' | git add --pathspec-from-file=-"
  "printf '.env.prod\\n' | git add --pathspec-from-file=-"
  "printf '.env.prod\\n' | git add --pathspec-from-file=- --pathspec-file-nul"
  "git add --pathspec-from-file=- <<< src/a.txt"
  "git add --pathspec-from-file=- < $L_OK"
  "git add --pathspec-from-file=/dev/stdin < $L_OK"
  "git add --pathspec-from-file=/dev/stdin"
  "git add --pathspec-from-file=/dev/fd/0"
  "git add --pathspec-from-file=<(printf 'src/a.txt\\n')"
  "git add --pathspec-from-file <(printf 'src/a.txt\\n')"
  "git add --pathspec-from-file=nope-missing.txt"
  "git add --pathspec-from-file=$TMP/does/not/exist.txt"
  "git add --pathspec-from-file=\$LIST"
  "git add --pathspec-from-file=\"\$(mktemp)\""
  "git add --pathspec-from-file=$LISTS"
  "git add --pathspec-from-file=$LISTS/*"
)
for cmd in "${UNRESOLVED[@]}"; do
  for repo in "${ALL_DIRTY[@]}"; do
    both "[$(basename "$repo")] $cmd" 2 "$repo" "$cmd"
  done
done

echo "stdin / process substitution / missing — allowed when no env file is in any dirty state"
for cmd in "${UNRESOLVED[@]}"; do
  for repo in "$R_CLEAN" "$R_TEMPLATE" "$R_STAGEDEL"; do
    both "[$(basename "$repo")] $cmd" 0 "$repo" "$cmd"
  done
done

echo "stdin refused — behind -C <dir> and cd <dir> &&"
both "git -C <untracked> add --pathspec-from-file=-" 2 "$TMP" "git -C $R_UNTRACKED add --pathspec-from-file=-"
both "git -C <modified> add --pathspec-from-file=-" 2 "$TMP" "git -C $R_MODIFIED add --pathspec-from-file=-"
both "git -C <staged> add --pathspec-from-file=-" 2 "$TMP" "git -C $R_STAGED add --pathspec-from-file=-"
both "cd <untracked> && git add --pathspec-from-file=-" 2 "$TMP" "cd $R_UNTRACKED && git add --pathspec-from-file=-"
both "printf | git -C <untracked> add --pathspec-from-file=-" 2 "$TMP" "printf '.env.prod\\n' | git -C $R_UNTRACKED add --pathspec-from-file=-"
both "git -C <clean> add --pathspec-from-file=-" 0 "$TMP" "git -C $R_CLEAN add --pathspec-from-file=-"
both "cd <clean> && git add --pathspec-from-file=-" 0 "$TMP" "cd $R_CLEAN && git add --pathspec-from-file=-"
both "hook cwd is the clean repo but -C names the dirty one" 2 "$R_CLEAN" "git -C $R_UNTRACKED add --pathspec-from-file=-"
both "hook cwd is the dirty repo but -C names the clean one" 0 "$R_UNTRACKED" "git -C $R_CLEAN add --pathspec-from-file=-"

if [ "$(id -u)" != 0 ]; then
  echo "unreadable list file"
  L_NOREAD="$(list noread '.env.prod\n')"; chmod 000 "$L_NOREAD"
  both "unreadable list file, untracked env present" 2 "$R_UNTRACKED" "git add --pathspec-from-file=$L_NOREAD"
  both "unreadable list file, clean repo" 0 "$R_CLEAN" "git add --pathspec-from-file=$L_NOREAD"
fi
echo "env-named list file cannot be trusted"
both "list file named .env.list, untracked env present" 2 "$R_UNTRACKED" "git add --pathspec-from-file=.env.list"
both "list file named .env.list, clean repo" 0 "$R_CLEAN" "git add --pathspec-from-file=.env.list"

echo "wrapped forms fail closed through the raw-surplus fallback (block-env-commit)"
WRAPPED=(
  "sh -c 'git add --pathspec-from-file=-'"
  "bash -c \"git add --pathspec-from-file=-\""
  "eval \"git add --pathspec-from-file=-\""
  "eval 'git add --pathspec-from-file=-'"
  "sh -c 'git add --pathspec-fr -'"
  "sh -c 'printf x | git add --pathspec-from-file=-'"
  "sh -c 'git add --pathspec-from-file=$L_OK'"
)
for cmd in "${WRAPPED[@]}"; do
  for repo in "${ALL_DIRTY[@]}"; do
    expect "block-env-commit: [$(basename "$repo")] $cmd" 2 "$COMMIT_HOOK" "$repo" "$cmd"
  done
  for repo in "$R_CLEAN" "$R_TEMPLATE" "$R_STAGEDEL"; do
    expect "block-env-commit: [$(basename "$repo")] $cmd" 0 "$COMMIT_HOOK" "$repo" "$cmd"
  done
done
expect "block-env-commit: wrapped add naming a protected entry via a list file" 2 "$COMMIT_HOOK" "$R_UNTRACKED" "sh -c 'git add --pathspec-from-file=$L_PROT'"

# =============================================================================
echo "git commit --pathspec-from-file (block-env-commit)"
for spelling in "--pathspec-from-file=L" "--pathspec-from-file L" "--pathspec-from=L" "--pathspec-fr=L"; do
  s="${spelling//L/$L_OK}"
  expect "commit $spelling, tracked env modified -> block" 2 "$COMMIT_HOOK" "$R_MODIFIED" "git commit -m x $s"
  expect "commit $spelling, clean repo -> allow" 0 "$COMMIT_HOOK" "$R_CLEAN" "git commit -m x $s"
done
L_OK_TRACKED="$(list oktracked 'README.md\n')"
expect "commit list of non-env paths, tracked env modified, -C" 2 "$COMMIT_HOOK" "$TMP" "git -C $R_MODIFIED commit -m x --pathspec-from-file=$L_OK_TRACKED"
expect "commit list of non-env paths, tracked env modified, cd &&" 2 "$COMMIT_HOOK" "$TMP" "cd $R_MODIFIED && git commit -m x --pathspec-from-file=$L_OK_TRACKED"
expect "commit list of non-env paths, only an untracked ignored env: nothing to commit from it -> allow" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "git commit -m x --pathspec-from-file=$L_OK_TRACKED"
expect "commit list naming a modified tracked env file -> block" 2 "$COMMIT_HOOK" "$R_MODIFIED" "git commit -m x --pathspec-from-file=$L_MODENT"
expect "commit list naming an env file -> block" 2 "$COMMIT_HOOK" "$R_UNTRACKED" "git commit -m x --pathspec-from-file=$L_PROT"
expect "commit NUL list naming an env file -> block" 2 "$COMMIT_HOOK" "$R_UNTRACKED" "git commit -m x --pathspec-from-file=$L_NUL_PROT --pathspec-file-nul"
expect "commit NUL list of non-env paths, clean -> allow" 0 "$COMMIT_HOOK" "$R_CLEAN" "git commit -m x --pathspec-from-file=$L_NUL_OK --pathspec-file-nul"
expect "commit list naming a template -> allow" 0 "$COMMIT_HOOK" "$R_TEMPLATE" "git commit -m x --pathspec-from-file=$L_TPL"
expect "commit list naming a staged deletion -> allow" 0 "$COMMIT_HOOK" "$R_STAGEDEL" "git commit -m x --pathspec-from-file=$L_DEL"
for repo in "${ALL_DIRTY[@]}"; do
  expect "commit --pathspec-from-file=- [$(basename "$repo")] -> block" 2 "$COMMIT_HOOK" "$repo" "git commit -m x --pathspec-from-file=-"
  expect "commit --pathspec-from-file - (separate) [$(basename "$repo")] -> block" 2 "$COMMIT_HOOK" "$repo" "git commit -m x --pathspec-from-file -"
done
for repo in "$R_CLEAN" "$R_TEMPLATE" "$R_STAGEDEL"; do
  expect "commit --pathspec-from-file=- [$(basename "$repo")] -> allow" 0 "$COMMIT_HOOK" "$repo" "git commit -m x --pathspec-from-file=-"
done
expect "commit with a missing list, untracked env -> block" 2 "$COMMIT_HOOK" "$R_UNTRACKED" "git commit -m x --pathspec-from-file=nope-missing.txt"
expect "commit with a missing list, clean -> allow" 0 "$COMMIT_HOOK" "$R_CLEAN" "git commit -m x --pathspec-from-file=nope-missing.txt"
expect "commit with process substitution, untracked env -> block" 2 "$COMMIT_HOOK" "$R_UNTRACKED" "git commit -m x --pathspec-from-file=<(printf 'a\\n')"
expect "commit with process substitution, clean -> allow" 0 "$COMMIT_HOOK" "$R_CLEAN" "git commit -m x --pathspec-from-file=<(printf 'a\\n')"
expect "commit, stdin behind -C, untracked env -> block" 2 "$COMMIT_HOOK" "$TMP" "git -C $R_UNTRACKED commit -m x --pathspec-from-file=-"
expect "commit, stdin behind -C, clean -> allow" 0 "$COMMIT_HOOK" "$TMP" "git -C $R_CLEAN commit -m x --pathspec-from-file=-"
expect "commit, wrapped sh -c stdin, untracked env -> block" 2 "$COMMIT_HOOK" "$R_UNTRACKED" "sh -c 'git commit -m x --pathspec-from-file=-'"
expect "commit, wrapped sh -c stdin, clean -> allow" 0 "$COMMIT_HOOK" "$R_CLEAN" "sh -c 'git commit -m x --pathspec-from-file=-'"
expect "scan-git-add ignores git commit --pathspec-from-file (not an add)" 0 "$SCAN_HOOK" "$R_UNTRACKED" "git commit -m x --pathspec-from-file=-"

# =============================================================================
echo "no false positives — #765 behaviour stays allowed"
for repo in "$R_UNTRACKED" "$R_MODIFIED" "$R_STAGEDEL"; do
  both "[$(basename "$repo")] git add src/a.txt (explicit non-env path)" 0 "$repo" "git add src/a.txt"
  both "[$(basename "$repo")] git add --pathspec-file-nul src/a.txt (the NUL flag alone is no list file)" 0 "$repo" "git add --pathspec-file-nul src/a.txt"
done
expect "block-env-commit: git status next to an untracked env file" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "git status --short"
expect "block-env-commit: ls of an env name (name-only)" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "ls -la .env.prod"
expect "block-env-commit: test -f on an env name (name-only)" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "test -f .env.prod && echo present"
expect "block-env-commit: echo naming a pathspec flag" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "echo 'use --pathspec-from-file=- carefully'"
expect "block-env-commit: git diff --pathspec-from-file=- is not an add" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "git diff --pathspec-from-file=-"
expect "block-env-commit: git add src/a.txt with the staged env present" 0 "$COMMIT_HOOK" "$R_UNTRACKED" "git add src/a.txt"
expect "block-env-commit: git commit of a staged deletion of an env file" 0 "$COMMIT_HOOK" "$R_STAGEDEL" "git commit -m x"

echo
echo "cases: $cases, failures: $fails"
[ "$fails" -eq 0 ] && exit 0 || exit 1
