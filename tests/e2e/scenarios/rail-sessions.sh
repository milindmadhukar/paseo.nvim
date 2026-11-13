# The rail nests each workspace's sessions under it: the workspace on screen
# opens with its agent under it, `<C-n>` starts a second agent there as a
# draft, its first message puts it on the rail, and `<C-s>`, k, <CR> go back
# to the first.
source "$(dirname "$0")/../lib.sh"

repo="$(repo_with_agent)"
open_chat

rail='require("paseo.ui.rail")'
# How many session rows the rail draws.
sessions="(function() local _, _, s = $rail.lines(32); return vim.tbl_count(s) end)()"
"$E" wait "$rail.win() ~= nil" 15 || fail "no rail"
"$E" wait "$sessions == 1" 15 || fail "the rail does not nest the agent under its workspace"
"$E" shot rail-sessions >/dev/null

# No Sessions panel: the rail is the session list.
[ "$("$E" lua 'vim.tbl_contains(require("paseo.ui.native").PANELS, "Sessions") and 1 or 0')" = "0" ] \
  || fail "there is a Sessions panel"

# <C-n> from the composer's normal mode: the new-task screen, on a chat here.
"$E" keys Escape C-n
new_task_ready

users_before=0
"$E" keys 'echo second agent' Escape Enter
wait_idle 40
"$E" wait "$sessions == 2" 20 || fail "the second agent is not under the workspace: $("$E" lua "$sessions")"

# The agent on screen is the one marked, and <C-s> lands on it.
"$E" keys C-s
"$E" wait "vim.bo.filetype == \"paseo-rail\"" 5 || fail "<C-s> did not land in the rail"
"$E" wait "$rail.current_session() and $rail.current_session().item.id == require(\"paseo.ui.native\").chat().agent_id" 5 \
  || fail "the rail is not on the agent on screen"
"$E" shot rail-sessions-two >/dev/null

# k, <CR>: back to the first agent.
first="$("$E" lua "(function() local _, _, s = $rail.lines(32); local best; for line, n in pairs(s) do if not best or line < best[1] then best = { line, n.item.id } end end; return best[2] end)()")"
"$E" keys k Enter
"$E" wait "require(\"paseo.ui.native\").chat().agent_id == \"$first\"" 15 \
  || fail "<CR> on the first agent did not open it"
