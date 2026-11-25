# `d` archives a workspace from the rail; `u`, straight after, takes it back
# (Paseo 0.16's archive undo, the app's six-second toast): the daemon restores
# it and the row returns.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo first" >/dev/null 2>&1 || fail "seed 1"
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo second" >/dev/null 2>&1 || fail "seed 2"

"$E" stop
"$E" start "$repo"
open_chat
rail='(function() for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype == "paseo-rail" then return b end end end)()'
"$E" wait "$rail ~= nil" 15 || fail "no rail"
ws_ids='(function() local _, rows = require("paseo.ui.rail").lines(40); local ids = {}; for _, ws in pairs(rows) do ids[#ids + 1] = ws.id end; table.sort(ids); return table.concat(ids, ",") end)()'
"$E" wait "#(select(1, require(\"paseo.ui.rail\").lines(40))) >= 4 and select(2, $ws_ids:gsub(\",\", \"\")) == 1" 15 \
  || fail "the rail never listed both workspaces"

# Into the rail, onto the workspace that is NOT on screen: archiving the one
# whose chat is the only one open takes the Paseo tab with it (archive.sh).
"$E" lua '(function() local r = require("paseo.ui.rail"); local here = require("paseo.agents").get(require("paseo.ui.chat").current().agent_id).workspaceId; vim.api.nvim_set_current_win(r.win()); local _, rows = r.lines(40); for line, ws in pairs(rows) do if ws.id ~= here then vim.api.nvim_win_set_cursor(r.win(), { line, 0 }) end end; return 1 end)()' >/dev/null
doomed="$("$E" lua 'require("paseo.ui.rail").current().id')"
[ -n "$doomed" ] || fail "no workspace under the cursor"
[ "$doomed" != "$("$E" lua 'require("paseo.agents").get(require("paseo.ui.chat").current().agent_id).workspaceId')" ] \
  || fail "the cursor is on the workspace on screen"

"$E" keys d
"$E" wait 'vim.bo.filetype == "paseo-choose"' 10 || fail "d did not ask"
"$E" keys 2
"$E" wait "not $ws_ids:find(\"$doomed\", 1, true)" 30 || fail "the archived workspace stayed on the rail"
"$E" wait "require(\"paseo.workspaces\").archived ~= nil and require(\"paseo.workspaces\").archived.id == \"$doomed\"" 5 \
  || fail "the archive was not kept for undo"
"$E" shot rail-undo-archived >/dev/null

# Back in the rail (the question handed focus back), `u`.
"$E" wait 'vim.bo.filetype == "paseo-rail"' 5 || fail "focus did not come back to the rail"
"$E" keys u
"$E" wait "$ws_ids:find(\"$doomed\", 1, true) ~= nil" 30 || fail "u did not bring the workspace back"
# With its agent: the daemon restores the agents archived with it, and the
# row has to show them again, not an empty workspace.
"$E" wait "vim.iter(require(\"paseo.agents\").all()):any(function(a) return a.workspaceId == \"$doomed\" end)" 20 \
  || fail "the restored workspace's agent never came back to the rail"
"$E" shot rail-undo-restored >/dev/null

# Once only.
"$E" keys u
"$E" wait 'require("paseo.workspaces").archived == nil' 5 || fail "a second u still had something to undo"
