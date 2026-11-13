# Asking about code: a chip in the sidebar, beside the code.
#
# `:Paseo ask` used to take the question in a floating box and send it to
# wherever the chat last was -- the Paseo tab, usually -- so the hunk you
# asked about left the screen. Now the chat opens in the sidebar with the
# reference as a chip in its composer, you write the question there, and the
# agent gets what the chip points at ahead of the question.
source "$(dirname "$0")/../lib.sh"

repo="$(repo_with_agent)"
printf 'one\ntwo\nthree\nfour\nfive\n' >"$repo/a.txt"

composer='table.concat(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().composer, 0, -1, false), " ")'

"$E" keys ":edit $repo/a.txt" Enter
"$E" keys ':vnoremap <buffer> <F5> <cmd>Paseo ask visual<cr>' Enter
# Lines 2-4, by a real visual selection and a mapped key -- as you would.
"$E" keys 2G V 2j F5
"$E" wait 'require("paseo.ui.chat").current() ~= nil' 20 || fail "no chat opened"
"$E" wait "($composer):find(\"@a.txt:2-4\", 1, true) ~= nil" 20 || fail "no chip: $("$E" lua "$composer")"
settle

[ "$(q "s['mount']")" = "sidebar" ] || fail "asked onto $(q "s['mount']"), not the sidebar"
[ "$(q "s['tabpages']")" = "1" ] || fail "asking opened a tab page"
"$E" wait 'vim.api.nvim_get_current_win() == require("paseo.ui.chat").current().win_composer' 5 \
  || fail "not left in the composer"
"$E" wait 'vim.fn.mode() == "i"' 5 || fail "not in insert mode: $("$E" lua 'vim.fn.mode()')"
"$E" wait '#vim.api.nvim_buf_get_extmarks(require("paseo.ui.chat").current().composer, vim.api.nvim_get_namespaces()["paseo.composer.chips"], 0, -1, {}) == 1' 5 \
  || fail "the chip is not painted"

# A second chip, from the code: back there, the cursor line this time.
"$E" keys Escape C-w p
"$E" keys ':nnoremap <buffer> <F6> <cmd>Paseo ask cursor<cr>' Enter
"$E" keys 5G F6
"$E" wait "($composer):find(\"@a.txt:5\", 1, true) ~= nil" 10 || fail "no second chip: $("$E" lua "$composer")"
[ "$(q "s['mount']")" = "sidebar" ] || fail "the second chip moved the chat"
"$E" shot ask-sidebar-chips >/dev/null

"$E" keys "echo what are these?" Escape Enter
"$E" wait '_G.paseo_e2e.users() >= 2' 30 || fail "the question never reached the agent"
"$E" wait "($composer) == \"\"" 10 || fail "the composer kept the prompt: $("$E" lua "$composer")"
sent="$("$E" lua 'require("paseo.ui.chat").current() and table.concat(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().conversation, 0, -1, false), "\n")')"
# As one line: the transcript wraps at the pane's width, and quotes your turn
# behind a bar.
flat="$(printf '%s' "$sent" | sed 's/▌//g' | tr '\n' ' ' | tr -s ' ')"
[[ "$flat" == *"Read lines 2-4 of $repo/a.txt"* ]] || fail "the first chip did not go: $flat"
[[ "$flat" == *"Read line 5 of $repo/a.txt"* ]] || fail "the second chip did not go: $flat"
[[ "$flat" == *"Read line 5 of"*"what are these?"* ]] || fail "the references were not ahead of the question: $flat"
"$E" shot ask-sidebar-sent >/dev/null

# Full screen, and back beside the code: <C-f> both ways.
"$E" lua '(function() vim.api.nvim_set_current_win(require("paseo.ui.chat").current().win_composer); return 1 end)()' >/dev/null
"$E" keys C-f
"$E" wait 'require("paseo.ui.native").has(require("paseo.ui.chat").current())' 10 || fail "<C-f> did not go full screen"
"$E" keys C-f
"$E" wait 'require("paseo.ui.chat").current().surface == "sidebar" and require("paseo.ui.sidebar").is_open(require("paseo.ui.chat").current())' 10 \
  || fail "<C-f> on the Paseo tab did not come back to the sidebar: $(q "s['mount']")"
[ "$(q "s['tabpages']")" = "1" ] || fail "coming back left a tab page: $(q "s['tabpages']")"

# Full screen, and you ask from the code: the chat comes to you.
"$E" keys C-f
"$E" wait 'require("paseo.ui.native").has(require("paseo.ui.chat").current())' 10 || fail "<C-f> again did not go full screen"
"$E" lua '(function() require("paseo.ui.native").leave(); return 1 end)()' >/dev/null
"$E" keys 1G F6
"$E" wait "($composer):find(\"@a.txt:1\", 1, true) ~= nil" 10 || fail "no chip from a full-screen chat"
"$E" wait 'require("paseo.ui.sidebar").is_open(require("paseo.ui.chat").current()) and not require("paseo.ui.native").has(require("paseo.ui.chat").current())' 10 \
  || fail "the full-screen chat did not come beside the code"

# NO AGENT YET: the new-task screen, in the sidebar, holding the chip.
"$E" keys Escape
bare="$(fresh_repo)"
printf 'x\n' >"$bare/b.txt"
"$E" stop
"$E" start "$bare"
"$E" keys ":edit $bare/b.txt" Enter
"$E" keys ':nnoremap <buffer> <F6> <cmd>Paseo ask cursor<cr>' Enter
"$E" keys 1G F6
"$E" wait '(function() local c = require("paseo.ui.chat").current(); return c ~= nil and c.draft ~= nil end)()' 20 \
  || fail "no new-task screen for a repository with no agent"
"$E" wait "($composer):find(\"@b.txt:1\", 1, true) ~= nil" 10 || fail "the new-task screen dropped the chip: $("$E" lua "$composer")"
[ "$(q "s['mount']")" = "sidebar" ] || fail "the new-task screen opened on $(q "s['mount']")"
"$E" shot ask-sidebar-draft >/dev/null
