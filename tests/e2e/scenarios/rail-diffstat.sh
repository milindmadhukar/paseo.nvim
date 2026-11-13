# The rail draws what the app's sidebar row does: a workspace that has
# changed lines ends with `+N -M`. The daemon computes it and pushes the
# workspace; the sidecar forwards it whole and the rail patches the row in
# place -- this is the whole path, from a file written on disk to the stat on
# the row.
source "$(dirname "$0")/../lib.sh"

# ON A BRANCH: the daemon measures lines changed against the base branch, so
# a checkout standing on `main` with no `origin/main` has no stat at all --
# by design, as in the app.
repo="$(fresh_repo)"
git -C "$repo" checkout -q -b rail-diffstat
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 || fail "seed"
"$E" stop
"$E" start "$repo"
open_chat

rail='require("paseo.ui.rail")'
"$E" wait "$rail.win() ~= nil" 15 || fail "no rail"
stat="(function() local _, rows = $rail.lines(40); for _, ws in pairs(rows) do if ws.diffStat and (ws.diffStat.additions or 0) > 0 then return ws.diffStat.additions end end return 0 end)()"
[ "$("$E" lua "$stat")" = "0" ] || fail "a fresh repo already has lines changed"

# Three lines, written behind the agent's back, and a refetch (`r`): a
# checkout's FIRST snapshot is the daemon's to schedule, behind a queue of
# every other workspace it has, and a fetch is what moves it up.
printf 'one\ntwo\nthree\n' >>"$repo/README.md"
"$E" lua "$rail.load()" >/dev/null
"$E" wait "$stat >= 3" 60 || fail "the rail never showed the lines changed: $("$E" lua "$stat")"

# Now the push alone: the daemon is watching the checkout, so two more lines
# reach the row as a workspace update, patched in place -- no refetch.
"$E" lua "(function() _G.rail_loads = 0; local r = $rail; local load = r.load; r.load = function(...) _G.rail_loads = _G.rail_loads + 1; return load(...) end; return 1 end)()" >/dev/null
printf 'four\nfive\n' >>"$repo/README.md"
"$E" wait "$stat >= 5" 45 || fail "the push never moved the stat: $("$E" lua "$stat")"
[ "$("$E" lua '_G.rail_loads')" = "0" ] || fail "the stat came by refetch, not by the push"

# On the row, right-aligned, as the app writes it.
"$E" wait "(function() local b = vim.api.nvim_win_get_buf($rail.win()); for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do local d = m[4]; if d.virt_text_pos == \"right_align\" and d.virt_text[1][1]:sub(1, 1) == \"+\" then return true end end return false end)()" 5 \
  || fail "the stat is not drawn on the row"
"$E" shot rail-diffstat >/dev/null
