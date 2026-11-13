# The "thinking…" line under the transcript while the agent works.
#
# The regression: with the rail shut, the wait after a first message showed
# nothing in the conversation -- the only spinner was on the composer bar --
# and on a NEW WORKTREE not even that, because the chat opened onto an agent
# whose `turn_started` had fired before it subscribed.
source "$(dirname "$0")/../lib.sh"

# How many pending lines the current chat's conversation carries, and on which
# row relative to its last line (0 = under the last line).
marks='(function() local c = require("paseo.ui.chat").current(); if not (c and c.conversation) then return -1 end; return #vim.api.nvim_buf_get_extmarks(c.conversation, require("paseo.ui.hl").ns_pending, 0, -1, {}) end)()'
at_end='(function() local c = require("paseo.ui.chat").current(); local m = vim.api.nvim_buf_get_extmarks(c.conversation, require("paseo.ui.hl").ns_pending, 0, -1, {})[1]; return m ~= nil and m[2] == vim.api.nvim_buf_line_count(c.conversation) - 1 end)()'

# --- a chat here: the line from the moment it is sent ----------------------
repo="$(fresh_repo)"
"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo' Enter
new_task_ready
users_before=0
"$E" keys 'long slow answer please' Escape Enter
"$E" wait "$marks == 1" 20 || fail "no pending line while the first turn runs ($("$E" lua "$marks"))"
"$E" wait "$at_end" 5 || fail "the pending line is not under the last line"
"$E" shot pending-here >/dev/null
wait_idle 90
"$E" wait "$marks == 0" 10 || fail "the pending line outlived the turn ($("$E" lua "$marks"))"
"$E" shot pending-here-done >/dev/null

# --- a new worktree: the chat opened onto an agent already working ---------
repo="$(fresh_repo)"
"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo new worktree' Enter
new_task_ready
"$E" keys 'long slow answer for the worktree' Escape Enter
"$E" wait 'require("paseo.ui.chat").current() and require("paseo.ui.chat").current().agent_id ~= nil' 60 \
  || fail "no agent was opened"
"$E" wait "$marks == 1" 20 || fail "no pending line in the new worktree's chat ($("$E" lua "$marks"))"
"$E" shot pending-worktree >/dev/null
users_before=0
wait_idle 90
"$E" wait "$marks == 0" 15 || fail "the worktree's pending line outlived the turn ($("$E" lua "$marks"))"
