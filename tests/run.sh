#!/usr/bin/env bash
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
export PATH="$bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
work="$here/.work"
rm -rf "$work"
mkdir -p "$work"
failures=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi; }
shared() { filefrag -v "$1" | grep -q shared; }
clean() { [[ -z $(git -C "$1" status --porcelain) ]]; }
has_content() { [[ $(cat "$1") == "$2" ]]; }

new_repo() {
  local r="$work/$1"
  git init -q -b main "$r"
  head -c 4M /dev/urandom >"$r/big.bin"
  echo v1 >"$r/f.txt"
  printf 'target/\n.claude/worktrees/\n' >"$r/.gitignore"
  git -C "$r" add -A
  git -C "$r" commit -qm c1
  mkdir "$r/target"
  head -c 4M /dev/urandom >"$r/target/cache"
  echo "$r"
}

r=$(new_repo basic)
git -C "$r" branch old
echo v2 >"$r/f.txt"
echo later >"$r/later.txt"
git -C "$r" add -A
git -C "$r" commit -qm c2
echo stray >"$r/stray.txt"
echo dirty >"$r/f.txt"

(cd "$r" && git cow-worktree feat "$work/basic-feat")
check "new branch: status clean" clean "$work/basic-feat"
check "new branch: tracked file reflinked" shared "$work/basic-feat/big.bin"
check "new branch: ignored file reflinked" shared "$work/basic-feat/target/cache"
check "new branch: dirty edit not carried over" has_content "$work/basic-feat/f.txt" v2
refute "new branch: untracked file not copied" test -e "$work/basic-feat/stray.txt"

(cd "$r" && git cow-worktree old "$work/basic-old")
check "existing branch: checks out its commit" has_content "$work/basic-old/f.txt" v1
refute "existing branch: files absent from it are removed" test -e "$work/basic-old/later.txt"
check "existing branch: status clean" clean "$work/basic-old"

(cd "$r" && git cow-worktree from-old "$work/basic-start" old)
check "start point: new branch starts there" has_content "$work/basic-start/f.txt" v1

(cd "$r" && git cow-worktree x "$work/basic-feat")
check "existing path: refused" test $? -ne 0

(cd "$r" && git cow-worktree cross /dev/shm/git-cow-worktree-test-$$) 2>/dev/null
check "cross-device: fails" test $? -ne 0
refute "cross-device: worktree removed" test -e /dev/shm/git-cow-worktree-test-$$
refute "cross-device: created branch deleted" git -C "$r" show-ref --verify refs/heads/cross

r=$(new_repo deleted)
rm "$r/f.txt"
(cd "$r" && git cow-worktree d "$work/deleted-wt")
check "deleted in source: worktree still has the file" has_content "$work/deleted-wt/f.txt" v1

r=$(new_repo sub)
inner=$(new_repo sub-inner)
git -C "$r" -c protocol.file.allow=always submodule add -q "$inner" inner
git -C "$r" commit -qm sub
(cd "$r" && git cow-worktree s "$work/sub-wt")
check "submodule: worktree created" test -d "$work/sub-wt"
refute "submodule: gitlink pointer not copied" test -e "$work/sub-wt/inner/.git"

r=$(new_repo hook)
git -C "$r" clone -q --bare "$r" "$work/hook-origin.git"
git -C "$r" remote add origin "$work/hook-origin.git"
git -C "$r" fetch -q origin
git -C "$r" remote set-head origin main
echo local >"$r/local.txt"
git -C "$r" add -A
git -C "$r" commit -qm unpushed

out=$(jq -n --arg cwd "$r" '{cwd: $cwd, name: "alpha", hook_event_name: "WorktreeCreate"}' | claude-cow-worktree-create)
alpha="$r/.claude/worktrees/alpha"
check "hook create: prints path" test "$out" = "$alpha"
check "hook create: branch worktree-alpha" test "$(git -C "$alpha" branch --show-current)" = worktree-alpha
refute "hook create: branch has no upstream" git -C "$alpha" rev-parse --abbrev-ref '@{u}'
refute "hook create: fresh base excludes unpushed commit" test -e "$alpha/local.txt"
check "hook create: ignored file reflinked" shared "$alpha/target/cache"

out=$(jq -n --arg cwd "$r" '{cwd: $cwd, name: "beta"}' | claude-cow-worktree-create)
beta="$r/.claude/worktrees/beta"
refute "hook create: sibling worktree not copied in" test -e "$beta/.claude/worktrees/alpha"

out=$(jq -n --arg cwd "$r" '{cwd: $cwd, name: "alpha"}' | claude-cow-worktree-create)
check "hook create: existing worktree reused" test "$out" = "$alpha"

jq -n --arg cwd "$r" '{cwd: $cwd, name: "../escape"}' | claude-cow-worktree-create 2>/dev/null
check "hook create: path-like name refused" test $? -ne 0

jq -n --arg cwd "$r" '{cwd: $cwd, name: "a/b"}' | claude-cow-worktree-create 2>/dev/null
check "hook create: nested name refused" test $? -ne 0
refute "hook create: nested name creates no branch" git -C "$r" show-ref --verify refs/heads/worktree-a/b

mkdir -p "$r/.claude"
echo '{"worktree": {"baseRef": "head"}}' >"$r/.claude/settings.local.json"
jq -n --arg cwd "$r" '{cwd: $cwd, name: "gamma"}' | claude-cow-worktree-create >/dev/null
check "hook create: baseRef head includes unpushed commit" test -e "$r/.claude/worktrees/gamma/local.txt"

jq -n --arg p "$alpha" '{worktree_path: $p}' | claude-cow-worktree-remove
refute "hook remove: directory gone" test -e "$alpha"
refute "hook remove: branch gone" git -C "$r" show-ref --verify refs/heads/worktree-alpha

jq -n --arg p "$work" '{worktree_path: $p}' | claude-cow-worktree-remove 2>/dev/null
check "hook remove: non-worktree path refused" test $? -ne 0
check "hook remove: non-worktree path untouched" test -d "$work/basic"

rm -rf "$work"
echo "$failures failure(s)"
[[ $failures -eq 0 ]]
