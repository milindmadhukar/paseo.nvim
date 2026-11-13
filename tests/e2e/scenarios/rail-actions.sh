# `.` on a rail row is what you can do to it, as a menu; `f` forks the agent
# under the cursor into the fork menu (here, or a new worktree).
source "$(dirname "$0")/../lib.sh"

repo="$(repo_with_agent)"
# The hidden/shown rail is remembered across runs; a scenario before this one
# may have hidden it.
"$E" lua 'require("paseo.ui.rail").set_visible(true) or 1' >/dev/null
open_chat
"$E" wait 'require("paseo.ui.rail").win() ~= nil' 15 || fail "no rail"
"$E" keys Escape C-s
"$E" wait 'vim.bo.filetype == "paseo-rail"' 5 || fail "<C-s> did not land in the rail"
"$E" wait '(function() local n = require("paseo.ui.rail").current_session(); return n ~= nil and n.kind == "agent" end)()' 15 \
  || fail "the cursor is not on an agent"

"$E" keys .
sleep 0.5
"$E" shot rail-actions-agent >/dev/null
"$E" keys Escape
sleep 0.3

"$E" keys f
"$E" wait 'vim.fn.mode() ~= "n" or #vim.api.nvim_list_wins() > 3' 15 || true
sleep 0.5
"$E" shot rail-actions-fork >/dev/null

# Into a new session beside it: the first prompt, then a second agent on the
# rail under the same workspace.
count='(function() local _, _, s = require("paseo.ui.rail").lines(32); return vim.tbl_count(s) end)()'
"$E" keys 1 Enter
"$E" wait 'vim.bo.filetype ~= "paseo-rail"' 10 || fail "no first-prompt box for the fork"
"$E" keys 'echo forked' Escape Enter
"$E" wait "$count == 2" 30 || fail "the fork is not on the rail beside its source: $("$E" lua "$count")"
"$E" shot rail-actions-forked >/dev/null
