# Background work (Paseo 0.16+, heartbeats 0.17+): a heartbeat aimed at the
# agent is the daemon's own background work -- no real provider needed. The
# rail counts it on the agent's row (`&1`, dim: a heartbeat waits, it does not
# run), the composer bar counts it, `gb` lists it, and `x` -- after asking,
# because it deletes the schedule -- stops it, live, on the daemon too.
source "$(dirname "$0")/../lib.sh"

repo_with_agent >/dev/null
open_chat
agent="$("$E" lua 'require("paseo.ui.chat").current().agent_id')"
[ -n "$agent" ] || fail "no agent in the chat"

# Heartbeats are background work from 0.17 on (PASEO_BIN can point the
# throwaway daemon at one when the installed paseo is older).
echo "  daemon $("$D" paseo --version 2>/dev/null || true)"

PASEO_AGENT_ID="$agent" "$D" paseo heartbeat create --cron '0 3 * * *' --name 'nightly check' "check in" \
  >/dev/null 2>&1 || fail "could not create a heartbeat on $agent"

# The agent's summary (the directory) and the live list (the stream) both hear it.
"$E" wait "(function() local a = require(\"paseo.agents\").get(\"$agent\"); return a and a.backgroundWork and a.backgroundWork.count == 1 end)()" 20 \
  || fail "the agent's summary never counted the heartbeat"
"$E" wait "select(2, require(\"paseo.background\").counts(\"$agent\")) == 1" 20 \
  || fail "the live list never had the heartbeat"

# A heartbeat counts and does not run: the row does not spin.
[ "$("$E" lua "require(\"paseo.agents\").bucket(require(\"paseo.agents\").get(\"$agent\"))")" != "running" ] \
  || fail "a heartbeat alone made the agent look busy"

# The composer bar says so.
"$E" wait '(function() local c = require("paseo.ui.chat").current(); return c.win_composer and vim.api.nvim_win_is_valid(c.win_composer) and vim.wo[c.win_composer].winbar:find("1 background", 1, true) ~= nil end)()' 10 \
  || fail "the composer bar does not count it"

# The rail ends the agent's row with &1.
rail_text='(function() for _, w in ipairs(vim.api.nvim_list_wins()) do local b = vim.api.nvim_win_get_buf(w); if vim.bo[b].filetype == "paseo-rail" then return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") end end return "" end)()'
"$E" wait "$rail_text:find(\"&1\", 1, true) ~= nil" 10 || fail "the rail row has no &1"
"$E" shot background-counted >/dev/null

# `gb` from the conversation: a real key in the conversation window.
"$E" lua '(function() local c = require("paseo.ui.chat").current(); vim.api.nvim_set_current_win(vim.fn.bufwinid(c.conversation)); return 1 end)()' >/dev/null
"$E" keys Escape
"$E" keys g b
"$E" wait 'require("paseo.ui.background").is_open()' 10 || fail "gb opened nothing"
"$E" wait '(function() local i = require("paseo.ui.background").current(); return i ~= nil and i.kind == "heartbeat" end)()' 10 \
  || fail "the list does not show the heartbeat"
"$E" shot background-list >/dev/null

# `x` asks first; the second choice deletes it.
"$E" keys x
"$E" wait 'vim.bo.filetype == "paseo-choose" and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Delete the heartbeat", 1, true) ~= nil' 10 \
  || fail "x on a heartbeat did not ask"
"$E" shot background-confirm >/dev/null
"$E" keys 2
"$E" wait "select(2, require(\"paseo.background\").counts(\"$agent\")) == 0" 20 \
  || fail "the heartbeat never left the list"
"$E" wait "(function() local a = require(\"paseo.agents\").get(\"$agent\"); return not (a.backgroundWork and a.backgroundWork.count > 0) end)()" 20 \
  || fail "the agent's summary still counts it"
"$E" wait "$rail_text:find(\"&1\", 1, true) == nil" 10 || fail "the rail still shows &1"

# And on the daemon: the schedule is gone, not paused.
if "$D" paseo schedule ls --json 2>/dev/null | grep -q 'nightly check'; then
  fail "the heartbeat schedule is still on the daemon"
fi
"$E" shot background-stopped >/dev/null
