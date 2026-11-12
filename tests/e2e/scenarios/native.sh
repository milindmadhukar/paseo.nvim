# The native surface, against a real daemon: a tab per agent, the spinner
# while a turn runs, markdown prose, the panels, and a second agent in a
# second tab. Run with PASEO_E2E_NOVOLT=1 to prove it needs no volt.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "first" \
  "$(printf 'echo\n\n## Plan\n\n- one\n- two\n\n```lua\nlocal x = 1\n```\n')" >/dev/null 2>&1 || fail "seed 1"
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "second" "echo second" >/dev/null 2>&1 || fail "seed 2"
"$E" stop
"$E" start "$repo"

"$E" keys ':Paseo native' Enter
"$E" wait 'require("paseo.ui.native").chat() ~= nil' 20 || fail "no native tab"
settle
[ "$("$E" lua '#vim.api.nvim_tabpage_list_wins(0)')" = "3" ] || fail "rail, conversation, composer"

# A turn: the spinner is on the conversation's winbar while it runs.
send_prompt "long"
"$E" wait 'vim.wo[require("paseo.ui.chat").current().win_conversation].winbar:find("%ds") ~= nil' 10 \
  || fail "no elapsed count on the winbar"
"$E" shot native-turn >/dev/null
wait_idle 60

# Every agent gets a tab of its own.
before="$("$E" lua '#vim.api.nvim_list_tabpages()')"
"$E" lua '(function() local me = require("paseo.ui.chat").current().agent_id
  for _, a in ipairs(require("paseo.agents").all()) do
    if a.id ~= me and a.cwd and a.cwd:find(vim.fn.getcwd(), 1, true) then
      require("paseo.ui.native").show_session { kind = "agent", id = a.id }; return a.id
    end
  end end)()' >/dev/null
"$E" wait "#vim.api.nvim_list_tabpages() == $before + 1" 15 || fail "the second agent did not get a tab"
settle

# Markdown, raw: the heading and the fence are real lines.
"$E" wait 'vim.tbl_contains(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().conversation, 0, -1, false), "## Plan")
  or vim.tbl_contains(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().conversation, 0, -1, false), "echo second")' 10 \
  || fail "the conversation is not raw markdown"

# The panels.
"$E" keys Escape C-p
"$E" wait 'vim.iter(vim.api.nvim_tabpage_list_wins(0)):any(function(w) return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "paseo-panel" end)' 10 \
  || fail "no panel"
"$E" shot native-panel >/dev/null
