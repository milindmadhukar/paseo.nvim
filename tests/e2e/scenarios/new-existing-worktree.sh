# `:Paseo new existing` (Paseo 0.17's "Existing worktree"): a session in a
# git worktree the project already has, whoever made it. The new-session
# screen offers it only when there is one, lists it by branch, and the
# session it makes is AT the worktree's path, inside the project.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
wt="$repo-feature"
git -C "$repo" worktree add -q -b feature "$wt" >/dev/null 2>&1 || fail "could not add a worktree"
# The project exists on the daemon: one session on the checkout.
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 || fail "seed"

"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo' Enter
"$E" wait 'require("paseo.ui.chat").current() ~= nil and require("paseo.ui.chat").current().initialised' 20 || fail "no chat"

"$E" keys Escape ':Paseo new existing' Enter
new_task_ready
"$E" wait '(function() local t = require("paseo.ui.newtask").task(require("paseo.ui.chat").current()); return t and t.worktrees ~= nil and #t.worktrees > 0 end)()' 20 \
  || fail "the daemon never listed the worktree"
screen='(function() local c = require("paseo.ui.chat").current(); return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(c.win_conversation), 0, -1, false), "\n") end)()'
"$E" wait "$screen:find(\"Existing worktree\", 1, true) ~= nil and $screen:find(\"feature\", 1, true) ~= nil" 10 \
  || fail "the screen does not offer the worktree"
"$E" shot new-existing-worktree >/dev/null

"$E" keys 'Work in the feature worktree' Escape Enter
"$E" wait '(function() local c = require("paseo.ui.chat").current(); return c and c.agent_id ~= nil and not c.draft end)()' 30 \
  || fail "the session's chat never opened"
agent="$("$E" lua 'require("paseo.ui.chat").current().agent_id')"
"$E" wait "require(\"paseo.agents\").get(\"$agent\") ~= nil" 15 || fail "the new agent never reached the directory"
cwd="$("$E" lua "require(\"paseo.agents\").get(\"$agent\").cwd")"
[ "$(realpath "$cwd" 2>/dev/null)" = "$(realpath "$wt")" ] || fail "the agent runs in '$cwd', not the worktree $wt"
"$E" shot new-existing-worktree-open >/dev/null
