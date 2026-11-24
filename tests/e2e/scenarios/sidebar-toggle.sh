# The sidebar's own toggle: one key opens the chat beside your code and the
# same key puts it away -- from the code, from inside the sidebar, and from the
# full screen, which it brings the chat back from.
source "$(dirname "$0")/../lib.sh"

repo="$(repo_with_agent)"
open='(function() local c = require("paseo.ui.chat").current(); return c ~= nil and require("paseo.ui.sidebar").is_open(c) end)()'

# A mapped key, as you would bind it -- not a call into the plugin.
"$E" keys ':nmap <F7> <Plug>(paseo-sidebar)' Enter
"$E" keys ':nmap <F8> <Plug>(paseo-native)' Enter
"$E" keys F7
"$E" wait "$open" 20 || fail "the key did not open the sidebar"
settle
[ "$(q "s['tabpages']")" = "1" ] || fail "the sidebar opened a tab page"

# Again, from inside it: away.
"$E" wait 'vim.api.nvim_get_current_win() == require("paseo.ui.chat").current().win_composer' 5 \
  || fail "not in the sidebar's composer"
"$E" keys Escape && sleep 0.3 && "$E" keys F7
"$E" wait "not $open" 5 || fail "a second press did not close it"

# Again, from the code: back.
"$E" keys F7
"$E" wait "$open" 10 || fail "a third press did not reopen it"
"$E" keys Escape C-w p && sleep 0.3 && "$E" keys F7
"$E" wait "not $open" 5 || fail "from the code, the key did not close it"

# From the full screen: the chat comes back beside the code, then goes.
# (The full screen's own toggle, as `<C-\>` is bound: `:Paseo` reopens the
# chat where it last was, which is the sidebar.)
agent="$("$E" lua 'require("paseo.ui.chat").current().agent_id')"
"$E" keys F8
"$E" wait 'require("paseo.ui.native").on_tab()' 10 || fail "no full screen"
"$E" keys Escape && sleep 0.3 && "$E" keys F7
"$E" wait "$open and not require(\"paseo.ui.native\").on_tab() and require(\"paseo.ui.chat\").current().agent_id == $(printf '"%s"' "$agent")" 10 \
  || fail "from the full screen, the key did not bring the chat beside the code"
"$E" wait 'vim.api.nvim_get_current_win() == require("paseo.ui.chat").current().win_composer' 5 \
  || fail "and you are not still in it"
"$E" shot sidebar-toggle >/dev/null
"$E" keys Escape && sleep 0.3 && "$E" keys F7
"$E" wait "not $open" 5 || fail "and then did not close it"
