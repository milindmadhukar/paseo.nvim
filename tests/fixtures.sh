#!/usr/bin/env bash
# Build the git fixtures the spec runs against.
#
# Every shape here exists because it broke something: paths with spaces and
# non-ASCII (diff header quoting), a rename (the porcelain-v2 two-field record),
# a beginning-of-file and an end-of-file deletion (the `+c,0` line number), a
# whole-file deletion (cannot be staged through gitsigns at all), an untracked
# file, and a multi-hunk file (partial staging).
set -euo pipefail

root="${1:?usage: fixtures.sh <dir>}"
rm -rf "$root"
mkdir -p "$root"

git_init() { git -C "$1" init -q -b main .; }
commit()   { git -C "$1" add -A && git -C "$1" -c commit.gpgsign=false commit -qm "${2:-wip}"; }

# ---------------------------------------------------------------- single repo
solo="$root/solo"
mkdir -p "$solo" && git_init "$solo"
printf 'one\ntwo\nthree\nfour\nfive\nsix\n'      > "$solo/bof.txt"
printf 'alpha\nbeta\n'                            > "$solo/eof.txt"
printf 'gone1\ngone2\ngone3\ngone4\n'             > "$solo/deleted-file.txt"
printf 'x\ny\nz\n'                                > "$solo/old-name.txt"
mkdir -p "$solo/dir with space"
printf 'q\n'                                      > "$solo/dir with space/odd name.txt"
printf 'h\n'                                      > "$solo/ünïcode ✓.txt"
seq 1 20                                          > "$solo/many-hunks.txt"
commit "$solo" init

printf 'two\nthree\nfour\nfive\nsix\n'            > "$solo/bof.txt"   # BOF delete
printf 'alpha\n'                                   > "$solo/eof.txt"   # EOF delete
rm "$solo/deleted-file.txt"                                            # whole file
git -C "$solo" mv old-name.txt new-name.txt                            # pure rename
printf 'q\nq2\n'                                   > "$solo/dir with space/odd name.txt"
printf 'h\nh2\n'                                   > "$solo/ünïcode ✓.txt"
printf 'fresh\n'                                   > "$solo/untracked.txt"
python3 - "$solo/many-hunks.txt" <<'PY'
import sys
lines = [str(i) for i in range(1, 21)]
lines[1] = "TWO-CHANGED"   # change at line 2
del lines[9:12]            # delete lines 10-12
lines.append("APPENDED")   # add at the end
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY

# --------------------------------------------- multi-repo, non-git parent
multi="$root/multi"
mkdir -p "$multi"
for name in clm clm_api; do
  mkdir -p "$multi/$name" && git_init "$multi/$name"
  printf 'base\n' > "$multi/$name/f.txt"
  commit "$multi/$name" init
done
mkdir -p "$multi/.workspaces"
for name in clm clm_api; do
  git -C "$multi/$name" worktree add -q -b ws/otp "$multi/.workspaces/otp/$name"
done
printf 'base\nchanged\n' > "$multi/.workspaces/otp/clm/f.txt"
printf 'rewritten\n'     > "$multi/.workspaces/otp/clm_api/f.txt"
printf 'new\n'           > "$multi/.workspaces/otp/clm_api/added.txt"
mkdir -p "$multi/.workspaces/otp/Docs"          # a non-repo sibling; must be ignored

# ------------------------------------- single-repo workspace (worktree IS the ws)
# A single-repo project puts its worktrees INSIDE the repo, so git sees them as
# untracked. .git/info/exclude is the right place to hide them: it is local and
# uncommitted, so it never touches a shared .gitignore.
echo '/.workspaces/' >> "$solo/.git/info/exclude"
git -C "$solo" worktree add -q -b ws/solo "$solo/.workspaces/inner" 2>/dev/null

# ---------------------------------------------------------------- not a repo
mkdir -p "$root/plain"

echo "$root"
