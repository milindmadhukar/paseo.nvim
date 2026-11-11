# <Up>/<Down> in an empty composer walk what you have sent this agent.
source "$(dirname "$0")/../lib.sh"

repo_with_agent >/dev/null
open_chat
send_prompt "echo two"
wait_idle 30

box='table.concat(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().composer, 0, -1, false), "\n")'
"$E" lua '(function() vim.api.nvim_set_current_win(require("paseo.ui.chat").current().win_composer); return 1 end)()' >/dev/null
expect() {
  "$E" wait "$box == \"$1\"" 3 || fail "after $2 the box holds \"$("$E" lua "$box")\", not \"$1\""
}
"$E" keys Up;   expect "echo two" "<Up>"
"$E" keys Up;   expect "echo seed" "<Up><Up>"
"$E" keys Up;   expect "echo seed" "<Up> past the oldest"
"$E" keys Down; expect "echo two" "<Down>"
"$E" keys Down; expect "" "<Down> past the newest"

# A prompt being written is not replaced: the arrows are arrows there.
"$E" keys i "draft line one" Enter "line two" Escape
"$E" keys Up
expect "draft line one\nline two" "<Up> in a draft"
