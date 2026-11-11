# Reattaching to a terminal shows its scrollback.
#
# SDK 0.15 delivers the scrollback replay as `replay` begin/data/end events
# where 0.9 sent one `restore`; a sidecar that only knew `restore` drew a blank
# terminal on attach until the next byte of new output.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 || fail "no seed agent"
id="$("$D" paseo terminal create --cwd "$repo" --name replay --json 2>/dev/null |
  python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("terminalId") or d.get("terminal",{}).get("id"))')"
[ -n "$id" ] && [ "$id" != "None" ] || fail "could not create a terminal"

"$E" stop
"$E" start "$repo"

attach='(function()
  require("paseo.bridge").ensure(function() end)
  vim.defer_fn(function()
    local t = require("paseo.ui.terminal")
    local view = t.ensure({ id = "'"$id"'" }, vim.api.nvim_get_current_win())
    t.show(view, vim.api.nvim_get_current_win())
  end, 1500)
  return 1
end)()'
has='(function(needle)
  local view = require("paseo.ui.terminal").view("'"$id"'")
  if not (view and vim.api.nvim_buf_is_valid(view.buf)) then return false end
  return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n"):find(needle, 1, true) ~= nil
end)'

"$E" lua "$attach" >/dev/null
"$E" wait 'require("paseo.ui.terminal").view("'"$id"'") ~= nil' 15 || fail "no terminal view"
sleep 1
"$E" lua '(function() local v = require("paseo.ui.terminal").view("'"$id"'"); vim.api.nvim_chan_send(v.chan, ""); require("paseo.bridge").request("terminals.input", { terminalId = "'"$id"'", data = vim.base64.encode("seq 1 120 | sed s/^/line-/\r") }, function() end); return 1 end)()' >/dev/null
"$E" wait "$has(\"line-120\")" 15 || fail "the command's output never arrived"

# Detach, drop the view, and attach again: everything on screen now came from
# the daemon's replay, not from live output.
"$E" lua '(function() require("paseo.ui.terminal").detach("'"$id"'"); return 1 end)()' >/dev/null
"$E" wait 'require("paseo.ui.terminal").view("'"$id"'") == nil' 10 || fail "detach left the view"
"$E" lua "$attach" >/dev/null
"$E" wait "$has(\"line-120\")" 15 || fail "reattached terminal is blank: the replay was dropped"
"$E" shot terminal-replay >/dev/null
