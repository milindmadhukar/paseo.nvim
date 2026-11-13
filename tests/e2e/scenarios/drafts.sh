# New-session DRAFTS: several on the go, each where you left it, and kept
# across a restart.
#
#   :Paseo, type, :Paseo settings mode   the draft's own mode list, at once
#   <C-n>, type                          a second draft; both are rail rows
#   :bprevious                           the first, on its choices, as left
#   :qa, start again, :Paseo             both drafts back, text and mode intact
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
store="$PASEO_E2E_ROOT/xdg/state/nvim/paseo/drafts.json"
rm -f "$store"
trap 'rm -f "$store"' EXIT

# The draft on screen: its first composer line, its mode, and whether its
# choices are what the middle window shows.
on_screen() {
  "$E" lua '(function() local c = require("paseo.ui.native").chat(); local t = c and require("paseo.ui.newtask").task(c); if not t then return "none" end; local mid = vim.api.nvim_win_get_buf(c.win_conversation); return (vim.api.nvim_buf_get_lines(c.composer, 0, 1, false)[1] or "") .. "|" .. tostring(t.draft and t.draft.modeId) .. "|" .. tostring(mid == t.buf) end)()'
}

rail_has() {
  "$E" wait "vim.iter(vim.api.nvim_list_bufs()):any(function(b) return vim.bo[b].filetype == \"paseo-rail\" and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), \" \"):find(\"$1\", 1, true) ~= nil end)" 10
}

"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo' Enter
new_task_ready
"$E" keys 'first draft fix the invoice' Escape
first_mode="$("$E" lua 'require("paseo.ui.newtask").task(require("paseo.ui.native").chat()).draft.modeId')"

# The mode, straight from the command: a picker, no card first.
"$E" keys ':Paseo settings mode' Enter
"$E" wait 'vim.iter(vim.api.nvim_tabpage_list_wins(0)):any(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end)' 10 \
  || fail ":Paseo settings mode on a draft opened no picker"
"$E" shot drafts-mode-picker >/dev/null
"$E" keys j Enter
"$E" wait "require(\"paseo.ui.newtask\").task(require(\"paseo.ui.native\").chat()).draft.modeId ~= \"$first_mode\"" 10 \
  || fail "picking a mode on the draft did not take"
picked_mode="$("$E" lua 'require("paseo.ui.newtask").task(require("paseo.ui.native").chat()).draft.modeId')"

# A second draft beside it.
"$E" keys C-n
"$E" wait '#vim.tbl_filter(function(c) return c.draft ~= nil end, require("paseo.ui.native").listed()) == 2' 10 \
  || fail "<C-n> did not open a second draft"
new_task_ready
"$E" keys 'second draft list the files' Escape
rail_has "first draft" || fail "the first draft has no rail row once it is off screen"
rail_has "second draft" || fail "the second draft has no rail row"
"$E" shot drafts-two >/dev/null

# Back to the first: its choices, its words, its mode.
"$E" keys ':bprevious' Enter
"$E" wait '(function() local c = require("paseo.ui.native").chat(); return c and c.draft ~= nil and vim.api.nvim_buf_get_lines(c.composer, 0, 1, false)[1] == "first draft fix the invoice" end)()' 10 \
  || fail ":bprevious did not go back to the first draft"
[ "$(on_screen)" = "first draft fix the invoice|$picked_mode|true" ] \
  || fail "the first draft came back as $(on_screen), want its words, $picked_mode, and its choices shown"
"$E" shot drafts-back >/dev/null

# QUIT, and start again: both come back.
"$E" stop
[ -s "$store" ] || fail "quitting left no drafts on disk"
"$E" start "$repo"
"$E" keys ':Paseo' Enter
"$E" wait '#vim.tbl_filter(function(c) return c.draft ~= nil and vim.api.nvim_buf_get_lines(c.composer, 0, 1, false)[1] ~= "" end, require("paseo.ui.native").listed()) == 2' 20 \
  || fail "the two drafts did not come back after a restart"
rail_has "first draft" || fail "the first draft is not on the rail after a restart"
rail_has "second draft" || fail "the second draft is not on the rail after a restart"
"$E" wait "vim.iter(require(\"paseo.ui.native\").listed()):any(function(c) local t = require(\"paseo.ui.newtask\").task(c); return t and t.draft and t.draft.modeId == \"$picked_mode\" and vim.api.nvim_buf_get_lines(c.composer, 0, 1, false)[1] == \"first draft fix the invoice\" end)" 20 \
  || fail "the first draft came back without the mode picked"
"$E" shot drafts-restored >/dev/null
