# A rail dragged narrower lays its rows out again. Names are cut to the width
# when the rows are built, and only opening and closing built them: resized,
# the full name stayed and the right-aligned `+N -M` was painted over its end.
source "$(dirname "$0")/../lib.sh"

# A long branch, so the workspace's name is what has to give.
repo="$(fresh_repo)"
git -C "$repo" checkout -q -b a-rather-long-branch-for-the-rail
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 || fail "seed"
"$E" stop
"$E" start "$repo"
open_chat

rail='require("paseo.ui.rail")'
"$E" wait "$rail.win() ~= nil" 15 || fail "no rail"
printf 'one\ntwo\nthree\n' >>"$repo/README.md"
"$E" lua "$rail.load()" >/dev/null

# The workspace row and its stat, as drawn: "<text>|<stat>|<window width>".
row="(function() local w = $rail.win(); local b = vim.api.nvim_win_get_buf(w); for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do local d = m[4]; if d.virt_text_pos == \"right_align\" and d.virt_text[1][1]:sub(1, 1) == \"+\" then local stat = \"\"; for _, c in ipairs(d.virt_text) do stat = stat .. c[1] end; return vim.api.nvim_buf_get_lines(b, m[2], m[2] + 1, false)[1] .. \"|\" .. stat .. \"|\" .. vim.api.nvim_win_get_width(w) end end return \"\" end)()"
"$E" wait "($row) ~= \"\"" 60 || fail "the stat never reached the row"
# Wider first: the whole name comes back, so the resize does lay rows out.
"$E" lua "vim.api.nvim_win_set_width($rail.win(), 60)" >/dev/null
"$E" wait "($row):find(\"a-rather-long-branch-for-the-rail\", 1, true) ~= nil" 5 \
  || fail "widened, the whole name did not come back: $("$E" lua "$row")"

# Narrower, by the window's own size rather than a call into the rail: what
# reacts is the WinResized a drag fires.
"$E" lua "vim.api.nvim_win_set_width($rail.win(), 26)" >/dev/null
"$E" wait "vim.api.nvim_win_get_width($rail.win()) == 26 and ($row):find(\"…\", 1, true) ~= nil" 5 \
  || fail "resized, the name was not cut: $("$E" lua "$row")"
narrow="$("$E" lua "$row")"
"$E" shot rail-resize >/dev/null
python3 -I - "$narrow" <<'EOF' || fail "the name runs into the stat: $narrow"
import sys, unicodedata
text, stat, width = sys.argv[1].rsplit("|", 2)
cells = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
# One clear cell between the end of the name and the stat.
sys.exit(0 if cells(text.rstrip()) + 1 + cells(stat) <= int(width) else 1)
EOF
