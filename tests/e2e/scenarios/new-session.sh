# A new SESSION and a new AGENT IN A SESSION are two things, as in the app.
#
# The regression: "Local" on the new-task screen meant "an agent in the
# workspace on screen", so <C-n> (and the rail's `a`) put one more tab in the
# session you were looking at instead of starting a session of its own.
#
#   :Paseo, first message      one session on the checkout
#   <C-n>, Local, message      a SECOND session on the same checkout
#   :Paseo new agent, message  still two sessions; the one on screen has two agents
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"

# Sessions on this checkout, as the daemon has them.
sessions() {
  "$D" paseo workspace ls --json 2>/dev/null |
    python3 -I -c "import json,os,sys; r=os.path.realpath(sys.argv[1]); print(len([w for w in json.load(sys.stdin) if os.path.realpath(w.get('cwd') or '') == r]))" "$repo"
}

scope() {
  "$E" lua '(function() local c = _G.paseo_e2e.chat(); local t = c and require("paseo.ui.newtask").task(c); return t and t.scope or "none" end)()'
}

# Agents in the workspace of the chat on screen.
agents_on_screen() {
  "$E" lua '(function() local c = _G.paseo_e2e.chat(); local a = c and c.agent_id and require("paseo.agents").get(c.agent_id, c.host_id); if not a then return -1 end; local n = 0; for _, x in ipairs(require("paseo.agents").all(c.host_id)) do if x.workspaceId == a.workspaceId then n = n + 1 end end; return n end)()'
}

wait_for() { # <shell expr> <seconds>
  for _ in $(seq 1 $(( $2 * 2 ))); do
    eval "$1" && return 0
    sleep 0.5
  done
  return 1
}

"$E" stop
"$E" start "$repo"
# What is on screen: the Paseo tab's chat, else the last one used.
"$E" lua '(function() _G.paseo_e2e.chat = function() return require("paseo.ui.native").chat() or require("paseo.ui.chat").current() end; return true end)()' >/dev/null
"$E" keys ':Paseo' Enter
new_task_ready
[ "$(scope)" = "session" ] || fail "an empty directory should offer a new session, got $(scope)"
"$E" keys 'First session: read the README' Escape Enter
wait_for '[ "$(sessions)" = 1 ]' 30 || fail "expected one session, got $(sessions)"
"$E" wait '_G.paseo_e2e.chat() and _G.paseo_e2e.chat().agent_id ~= nil and not _G.paseo_e2e.chat().draft' 30 \
  || fail "the first session's chat never opened"
first="$("$E" lua '_G.paseo_e2e.chat().agent_id')"

# <C-n> from that chat: a NEW session, Local -- not a tab in this one.
"$E" keys Escape C-n
new_task_ready
[ "$(scope)" = "session" ] || fail "<C-n> should be a new session, got $(scope)"
"$E" keys 'Second session: list the files' Escape Enter
wait_for '[ "$(sessions)" = 2 ]' 30 || fail "<C-n> + Local should make a second session, got $(sessions)"
"$E" wait "_G.paseo_e2e.chat() and _G.paseo_e2e.chat().agent_id ~= nil and _G.paseo_e2e.chat().agent_id ~= \"$first\" and not _G.paseo_e2e.chat().draft" 30 \
  || fail "the second session's chat never opened"
"$E" shot new-session-second >/dev/null
[ "$(agents_on_screen)" = 1 ] || fail "the new session should hold one agent, has $(agents_on_screen)"

# :Paseo new agent: one more agent in the session on screen, no new session.
"$E" keys Escape ':Paseo new agent' Enter
new_task_ready
[ "$(scope)" = "agent" ] || fail ":Paseo new agent should be an agent in this session, got $(scope)"
# The rail draws the draft under THAT session, not the first one on the same
# directory -- both sessions share it.
"$E" wait '(function() local c = _G.paseo_e2e.chat(); return c.workspace_id ~= nil and require("paseo.ui.rail").showing().id == c.workspace_id end)()' 10 \
  || fail "the rail does not mark the session the agent goes into"
"$E" wait 'vim.iter(vim.api.nvim_list_bufs()):any(function(b) return vim.bo[b].filetype == "paseo-rail" and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " "):find("new agent", 1, true) ~= nil end)' 10 \
  || fail "the rail does not show the draft as a new agent"
"$E" shot new-session-agent-screen >/dev/null
"$E" keys 'Third: an agent beside the second' Escape Enter
wait_for '[ "$(agents_on_screen)" = 2 ]' 30 || fail "the session on screen should now hold two agents, has $(agents_on_screen)"
[ "$(sessions)" = 2 ] || fail "an agent in a session must not make a session, now $(sessions)"
"$E" shot new-session-agent >/dev/null
