# A chat in a NEW WORKTREE, from the new-task screen: no name asked, and the
# first message is sent WITH the workspace, so the daemon names all of it --
# the worktree's directory and branch (`frail-squid`) and the title (from the
# prompt).
#
# The regressions: the workspace was created bare and the agent after it, so
# its name was a slug for good; and before that, a name had to be typed for
# a directory and branch the daemon can name itself.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
git -C "$repo" branch dev
count_workspaces() {
  "$D" paseo workspace ls --json 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))'
}
before="$(count_workspaces)"

"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo wcreate' Enter
new_task_ready
[ "$("$E" lua 'require("paseo.ui.newtask").task(require("paseo.ui.chat").current()).where')" = "worktree" ] \
  || fail "wcreate did not open the screen on a new worktree"
[ "$("$E" lua 'vim.fn.mode()')" = "i" ] || fail "the composer is not ready to type in"
# Nothing created by opening the screen.
[ "$(count_workspaces)" = "$before" ] || fail "the screen created a workspace"
"$E" shot start-workspace-draft >/dev/null

# Off `dev`, picked on the Base card: <Tab> up to the choices, `b`, `l`, <CR>.
"$E" keys Escape Tab b l Enter
"$E" wait 'require("paseo.ui.newtask").task(require("paseo.ui.chat").current()).base == "dev"' 10 \
  || fail "the base did not change: $("$E" lua 'tostring(require("paseo.ui.newtask").task(require("paseo.ui.chat").current()).base)')"
"$E" keys i 'Fix the invoice rounding in billing' Escape Enter

"$E" wait 'require("paseo.ui.chat").current() and require("paseo.ui.chat").current().agent_id ~= nil' 60 \
  || fail "no agent was opened"

# A worktree the daemon named, off dev.
wt="$(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | grep -v "^$repo\$" | head -1)"
[ -n "$wt" ] || fail "no worktree was cut"
branch="$(git -C "$wt" branch --show-current)"
echo "  worktree: $(basename "$wt") on $branch"
[ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$repo" rev-parse dev)" ] || fail "not cut from dev"
case "$branch" in ws/*) fail "named by the plugin, not the daemon: $branch" ;; esac

# The agent's tab is in the worktree.
[ "$("$E" lua 'vim.fn.getcwd()')" = "$wt" ] || fail "the agent's tab is not in the worktree: $("$E" lua 'vim.fn.getcwd()')"
"$E" shot start-workspace >/dev/null
