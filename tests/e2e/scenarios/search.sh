# The search finds everything: an archived chat is found by its title, and a
# prompt sent long ago is found by what it said and opens its chat AT that
# message -- older than the sixty items a chat loads, so history has to page
# back to reach it.
source "$(dirname "$0")/../lib.sh"

lazy="${PASEO_E2E_LAZY:-$HOME/.local/share/nvim/lazy}"
if [ ! -d "$lazy/telescope.nvim" ] || [ ! -d "$lazy/plenary.nvim" ]; then
  echo "  skip: telescope.nvim and plenary.nvim are not in $lazy (PASEO_E2E_LAZY)" >&2
  exit 0
fi

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "kept chat" "echo first-kept-question" >/dev/null 2>&1 \
  || fail "seed the kept chat"
kept="$("$D" paseo ls 2>/dev/null | awk '/kept chat/ { print $1; exit }')"
[ -n "$kept" ] || fail "the kept chat is not listed"
# Seventy more items, so the first prompt is past the first page of history.
for i in $(seq 1 35); do
  "$D" paseo send "$kept" "echo filler-$i" >/dev/null 2>&1 || fail "filler $i"
done
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "gone chat" "echo archived-question" >/dev/null 2>&1 \
  || fail "seed the archived chat"
gone="$("$D" paseo ls 2>/dev/null | awk '/gone chat/ { print $1; exit }')"
"$D" paseo archive "$gone" >/dev/null 2>&1 || fail "archive it"

"$E" stop
PASEO_E2E_RTP="$lazy/plenary.nvim:$lazy/telescope.nvim" "$E" start "$repo"
"$E" keys ':Paseo' Enter
"$E" wait 'require("paseo.ui.native").chat() ~= nil and require("paseo.ui.chat").current().initialised' 20 \
  || fail "no Paseo tab"

# No default key since <C-k> went back to being window-up: a config maps the
# search globally, as this one does, on <Plug>(paseo-search).
"$E" lua 'vim.keymap.set("n", "<F5>", "<Plug>(paseo-search)")'

selected='(require("telescope.actions.state").get_selected_entry() or { value = {} }).value'
search() {
  "$E" keys Escape
  "$E" keys F5
  "$E" wait 'vim.bo.filetype == "TelescopePrompt"' 10 || fail "the global search key did not open the search"
  "$E" keys "$1"
}

# AN ARCHIVED CHAT, by its title, with its conversation in the preview.
search 'gone chat'
"$E" wait "$selected.kind == \"archived\"" 15 || fail "the archived chat is not in the search"
"$E" wait 'vim.iter(vim.api.nvim_list_bufs()):any(function(b) return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("You said: echo archived%-question") ~= nil end)' 10 \
  || fail "its preview never drew the conversation"
"$E" shot search-archived >/dev/null
# Telescope's first <Esc> is normal mode; the second closes it.
"$E" keys Escape
sleep 0.3
"$E" keys Escape
"$E" wait 'vim.bo.filetype ~= "TelescopePrompt"' 5 || fail "<Esc> did not close it"

# A PROMPT, by what it said: Enter opens its chat with that message on top.
search 'first-kept'
"$E" wait "$selected.kind == \"prompt\"" 15 || fail "the first prompt is not in the search"
"$E" shot search-prompt >/dev/null
"$E" keys Enter
# By the DIRECTORY's title: the chat `:Paseo` opened is this one, and a chat
# opened by directory never had a title handed to it.
"$E" wait '(require("paseo.agents").get(require("paseo.ui.chat").current().agent_id) or {}).title == "kept chat" and require("paseo.ui.chat").current().initialised and require("paseo.ui.chat").current().at == nil' 15 \
  || fail "Enter did not open the chat"
[ "$("$E" lua '#require("paseo.ui.chat").current().order > 60')" = "true" ] \
  || fail "history was not paged back past the first sixty items"
"$E" wait '(function() local c = require("paseo.ui.chat").current(); local r = vim.api.nvim_win_get_cursor(c.win_conversation)[1]; return table.concat(vim.api.nvim_buf_get_lines(c.conversation, r - 1, r + 2, false), "\n"):find("first%-kept%-question") ~= nil end)()' 5 \
  || fail "the cursor is not on the prompt"
[ "$("$E" lua 'require("paseo.ui.chat").current().sticky')" = "false" ] || fail "the chat still follows the end"
"$E" shot search-opened >/dev/null
