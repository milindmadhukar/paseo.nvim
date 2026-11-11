# `P` on the rail pins a workspace: it leads the list, with a pin, and the
# daemon has it pinned (so the app's sidebar agrees).
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
# Two workspaces in one project: every `paseo run` makes one.
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo first" >/dev/null 2>&1 || fail "seed 1"
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo second" >/dev/null 2>&1 || fail "seed 2"

"$E" stop
"$E" start "$repo"
open_chat
rail='(function() for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype == "paseo-rail" then return b end end end)()'
"$E" wait "$rail ~= nil and #require(\"paseo.ui.rail\").lines(40) >= 4" 15 || fail "no rail with two workspaces"
"$E" wait '#(select(1, require("paseo.ui.rail").lines(40))) >= 4' 15 || fail "the rail never listed both"

# Into the rail, onto the SECOND workspace, and pin it.
"$E" lua '(function() local r = require("paseo.ui.rail"); vim.api.nvim_set_current_win(r.win()); local _, rows = r.lines(40); local last = 0; for line in pairs(rows) do last = math.max(last, line) end; vim.api.nvim_win_set_cursor(r.win(), { last, 0 }); return 1 end)()' >/dev/null
second="$("$E" lua 'require("paseo.ui.rail").current().id')"
"$E" keys P
"$E" wait "(function() local _, rows = require(\"paseo.ui.rail\").lines(40); local first; for line, ws in pairs(rows) do if not first or line < first.line then first = { line = line, ws = ws } end end; return first and first.ws.id == \"$second\" and first.ws.pinned end)()" 15 \
  || fail "the pinned workspace does not lead the rail"
"$E" shot rail-pin >/dev/null
