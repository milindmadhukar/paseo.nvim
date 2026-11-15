# <C-g> in the composer: the prompt in a .md buffer in the box's window, grown;
# `:wq` puts it back in the box, `<C-g>` again comes back written, `<M-CR>`
# from the editor sends it.
source "$(dirname "$0")/../lib.sh"

repo_with_agent >/dev/null
open_chat

chat='require("paseo.ui.chat").current()'
box="table.concat(vim.api.nvim_buf_get_lines($chat.composer, 0, -1, false), \"\\n\")"
"$E" lua "(function() vim.api.nvim_set_current_win($chat.win_composer); return 1 end)()" >/dev/null

"$E" keys i "echo one" Escape
"$E" keys C-g
"$E" wait "$chat.editing ~= nil" 3 || fail "<C-g> opened no editor"
"$E" wait "vim.bo.filetype == \"markdown\" and vim.api.nvim_buf_get_name(0):match(\"%.md$\") ~= nil" 3 \
  || fail "the editor is not a .md buffer: $("$E" lua 'vim.api.nvim_buf_get_name(0)')"
"$E" wait "vim.api.nvim_win_get_height($chat.win_composer) > 10" 3 \
  || fail "the box did not grow: $("$E" lua "vim.api.nvim_win_get_height($chat.win_composer)") rows"
"$E" shot editor-open >/dev/null

"$E" keys o "and two" Escape
"$E" keys ':wq' Enter
"$E" wait "$chat.editing == nil and vim.api.nvim_get_current_buf() == $chat.composer" 3 \
  || fail ":wq did not come back to the box"
"$E" wait "$box == \"echo one\\nand two\"" 3 || fail "after :wq the box holds \"$("$E" lua "$box")\""
"$E" wait "require(\"paseo.ui.native\").on_tab()" 3 || fail ":wq took the Paseo tab down"
"$E" shot editor-back >/dev/null

# Back in, and <M-CR> sends what it holds.
users_before="$("$E" lua '_G.paseo_e2e.users()')"
"$E" keys C-g
"$E" wait "$chat.editing ~= nil" 3 || fail "<C-g> did not open it again"
"$E" keys A " three" M-Enter
"$E" wait "$chat.editing == nil" 3 || fail "<M-CR> left the editor open"
wait_idle 30
"$E" wait "$box == \"\"" 3 || fail "after sending the box holds \"$("$E" lua "$box")\""
