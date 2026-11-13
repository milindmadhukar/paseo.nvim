# The native surface, against a real daemon: ONE Paseo tab, every agent you
# open a listed buffer in it -- from any workspace, nothing opened or closed
# for you -- the spinner while a turn runs, markdown prose, the panels,
# `:bnext` between agents, and a changed file opening with your code rather
# than in a tab.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "first" \
  "$(printf 'echo\n\n## Plan\n\n- one\n- two\n\n```lua\nlocal x = 1\n```\n')" >/dev/null 2>&1 || fail "seed 1"
other="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$other" --title "elsewhere" "echo elsewhere" >/dev/null 2>&1 || fail "seed 3"
"$E" stop
"$E" start "$repo"

"$E" keys ':Paseo native' Enter
"$E" wait 'require("paseo.ui.native").chat() ~= nil' 20 || fail "no Paseo tab"
settle
[ "$("$E" lua '#vim.api.nvim_tabpage_list_wins(0)')" = "3" ] || fail "rail, conversation, composer"
[ "$("$E" lua '#vim.api.nvim_list_tabpages()')" = "2" ] || fail "Paseo is not exactly one more tab"

# A turn: the spinner is on the conversation's winbar while it runs.
send_prompt "long"
"$E" wait 'vim.wo[require("paseo.ui.chat").current().win_conversation].winbar:find("%ds") ~= nil' 10 \
  || fail "no elapsed count on the winbar"
"$E" shot native-turn >/dev/null
wait_idle 60

# A second agent IN THE SAME WORKSPACE -- the app's `+` -- started outside
# Neovim. It is on the rail, NOT on the row: nothing opens by itself.
wsid="$("$E" lua 'require("paseo.agents").get(require("paseo.ui.chat").current().agent_id).workspaceId')"
[ -n "$wsid" ] && [ "$wsid" != "vim.NIL" ] || fail "the agent has no workspace id"
"$D" paseo run --provider fake/scripted --cwd "$repo" --workspace "$wsid" --title "second" "echo second" >/dev/null 2>&1 \
  || fail "seed 2"
"$E" wait 'vim.iter(require("paseo.agents").all()):any(function(a) return a.title == "second" end)' 15 \
  || fail "the second agent never reached Neovim"
sleep 1
[ "$("$E" lua '#require("paseo.ui.native").listed()')" = "1" ] || fail "an agent opened by itself"

# Opening it is what puts it on the row, named after it.
"$E" lua '(function() for _, a in ipairs(require("paseo.agents").all()) do
    if a.title == "second" then require("paseo.ui.native").show_session { kind = "agent", id = a.id }; return a.id end
  end end)()' >/dev/null
"$E" wait '#require("paseo.ui.native").listed() == 2' 15 || fail "opening the second agent did not add it to the row"
names="$("$E" lua 'table.concat(vim.tbl_map(function(c) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(c.conversation), ":t") end, require("paseo.ui.native").listed()), ",")')"
case "$names" in *first*second*) ;; *) fail "buffers not named after their agents, in the order opened: $names" ;; esac
[ "$("$E" lua 'vim.iter(require("paseo.ui.native").listed()):all(function(c) return vim.bo[c.conversation].buflisted end)')" = "true" ] \
  || fail "the agents are not listed"
settle

# A buffer command in the middle window: the other agent, its composer under it, and
# still the one tab.
before="$("$E" lua 'require("paseo.ui.chat").current().agent_id')"
"$E" keys Escape
"$E" lua 'vim.api.nvim_set_current_win(require("paseo.ui.chat").current().win_conversation)' >/dev/null
# (`:bprevious`: plain `:bnext` from the newest buffer wraps to this Neovim's
# own empty buffer. A per-tab bufferline's next/prev never leaves the row.)
"$E" keys ':bprevious' Enter
"$E" wait "require(\"paseo.ui.chat\").current().agent_id ~= \"$before\"" 15 || fail ":bprevious did not move to the other agent"
"$E" wait 'vim.api.nvim_win_get_buf(require("paseo.ui.chat").current().win_composer) == require("paseo.ui.chat").current().composer' 10 \
  || fail "the composer did not follow the agent"
[ "$("$E" lua '#vim.api.nvim_list_tabpages()')" = "2" ] || fail "moving between agents made a tab"
settle

# Markdown, raw: the heading and the fence are real lines.
"$E" wait 'vim.tbl_contains(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().conversation, 0, -1, false), "## Plan")
  or vim.tbl_contains(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().conversation, 0, -1, false), "echo second")' 10 \
  || fail "the conversation is not raw markdown"
"$E" shot native-buffers >/dev/null

# The panels.
"$E" keys Escape C-p
"$E" wait 'vim.iter(vim.api.nvim_tabpage_list_wins(0)):any(function(w) return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "paseo-panel" end)' 10 \
  || fail "no panel"
"$E" shot native-panel >/dev/null

# A CHANGED FILE OPENS WITH YOUR CODE: on the other tab, as a buffer there.
echo "changed" >>"$repo/README.md"
"$E" keys 2
"$E" wait 'vim.iter(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)):any(function(l) return l:find("README", 1, true) ~= nil end)' 15 \
  || fail "the Changes panel does not list README.md"
"$E" lua '(function() for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do if l:find("README", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }); return end end end)()' >/dev/null
"$E" keys Enter
"$E" wait 'vim.fn.expand("%:t") == "README.md"' 10 || fail "the file did not open"
[ "$("$E" lua 'vim.api.nvim_get_current_tabpage() ~= require("paseo.ui.native").tab()')" = "true" ] \
  || fail "the file opened on the Paseo tab"
[ "$("$E" lua '#vim.api.nvim_list_tabpages()')" = "2" ] || fail "the file got a tab of its own"
[ "$("$E" lua 'vim.iter(require("paseo.ui.native").listed()):any(function(c) return vim.bo[c.conversation].buflisted end)')" = "false" ] \
  || fail "the agents are still listed on your code's tab"

# Back in, and an agent of ANOTHER WORKSPACE: it joins the row, nothing is
# closed for it, and the tab stands where it works.
"$E" keys ':Paseo native' Enter
"$E" wait 'require("paseo.ui.native").chat() ~= nil' 10 || fail "did not come back to the Paseo tab"
"$E" lua "(function() for _, a in ipairs(require(\"paseo.agents\").all()) do
    if a.cwd == \"$other\" then require(\"paseo.ui.native\").show_session { kind = \"agent\", id = a.id }; return a.id end
  end end)()" >/dev/null
"$E" wait "require(\"paseo.ui.chat\").current().root == \"$other\"" 15 || fail "the other workspace's agent did not open"
"$E" wait '#require("paseo.ui.native").listed() == 3' 10 || fail "the row is not all three: $("$E" lua '#require("paseo.ui.native").listed()')"
[ "$("$E" lua 'vim.fn.getcwd()')" = "$other" ] || fail "the Paseo tab did not follow: $("$E" lua 'vim.fn.getcwd()')"
[ "$("$E" lua '#vim.api.nvim_list_tabpages()')" = "2" ] || fail "another workspace made a tab"
settle
"$E" shot native-mixed >/dev/null
