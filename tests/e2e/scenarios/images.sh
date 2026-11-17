# Pictures in the transcript: what you pasted, a link the agent wrote, a file
# it read -- each a chip that <CR> opens full size in a float, and the pasted
# one found again after a restart by the id its message was sent with.
#
# Twice: without snacks.nvim (chips, and a float that describes the file),
# and with it, told it is in Ghostty, where each picture is also a snacks
# placement hung under its row. Kitty graphics never reach a tmux capture, so
# the second pass counts placements and the placeholder cells they draw.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
mkdir -p "$repo/shots"
python3 -I - "$repo/shots/pic.png" <<'PY'
import sys, zlib, struct
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
w = h = 80
raw = b"".join(b"\x00" + b"".join(bytes([x * 3, y * 3, 128]) for x in range(w)) for y in range(h))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 || fail "no seed agent"

helpers="$PASEO_E2E_ROOT/images-helpers.lua"
cat >"$helpers" <<'LUA'
local api = vim.api
local function chat()
  return require("paseo.ui.native").chat() or require("paseo.ui.chat").current()
end
_G.img = {}
function img.chips()
  local c = chat()
  return c and #api.nvim_buf_get_extmarks(c.conversation, require("paseo.ui.images").ns, 0, -1, {}) or 0
end
function img.with_id()
  local c, n = chat(), 0
  for _, id in ipairs(c and c.order or {}) do
    local b = c.blocks[id]
    if b.item.kind == "user" and b.item.clientMessageId then
      n = n + #require("paseo.image").stored(b.item.clientMessageId)
    end
  end
  return n
end
-- The cursor onto the first entry of `kind`, in the conversation window.
function img.cursor_to(kind)
  local c = chat()
  local images, transcript = require "paseo.ui.images", require "paseo.ui.transcript"
  for i = #c.order, 1, -1 do
    local b = c.blocks[c.order[i]]
    local row = transcript.row_of(c, b)
    local lines = api.nvim_buf_get_lines(c.conversation, row, row + b.height, false)
    for _, e in ipairs(images.entries(c, b, lines)) do
      if e.kind == kind then
        api.nvim_set_current_win(c.win_conversation)
        api.nvim_win_set_cursor(c.win_conversation, { row + (e.line or e.row) + 1, e.s or 0 })
        return 1
      end
    end
  end
  return 0
end
function img.float()
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative == "" then
    return ""
  end
  return vim.bo[api.nvim_win_get_buf(win)].filetype .. ":" .. vim.fn.tabpagenr("$")
end
function img.placements()
  local c = chat()
  local ok, p = pcall(require, "snacks.image.placement")
  if not ok then
    return -1
  end
  local n = 0
  for _, m in ipairs(api.nvim_buf_get_extmarks(c.conversation, p.ns, 0, -1, { details = true })) do
    local rows = #(m[4].virt_lines or {})
    if rows > 0 and rows <= 12 then
      n = n + 1
    end
  end
  return n
end
LUA

composer='table.concat(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().composer, 0, -1, false), " ")'

run_pass() {
  local pass="$1"
  "$E" stop
  "$E" start "$repo"
  open_chat
  "$E" keys ":luafile $helpers" Enter
  local tabs
  tabs="$("$E" lua 'vim.fn.tabpagenr("$")')"

  if [ "$pass" = plain ]; then
    "$E" keys ":lua require('paseo').paste_image('$repo/shots/pic.png')" Enter
    "$E" wait "($composer):find(\"[Image #1]\", 1, true) ~= nil" 10 || fail "$pass: nothing attached"
    "$E" lua '(function() local c = require("paseo.ui.chat").current(); vim.api.nvim_buf_set_lines(c.composer, 0, -1, false, { "echo picture [Image #1] and ![pic](shots/pic.png)" }); return 1 end)()' >/dev/null
    local before
    before="$("$E" lua '_G.paseo_e2e.users()')"
    "$E" lua '(function() vim.api.nvim_set_current_win(require("paseo.ui.chat").current().win_composer); return 1 end)()' >/dev/null
    "$E" keys Escape Enter
    "$E" wait "_G.paseo_e2e.turn_done($before)" 30 || fail "$pass: the turn never finished"
    "$E" wait "img.with_id() == 1" 10 || fail "$pass: the pasted image did not come back with its message"
  fi

  # [Image #1] and the link in your message, and the link the agent echoed.
  "$E" wait "img.chips() >= 3" 10 || fail "$pass: chips: $("$E" lua 'img.chips()')"

  for kind in pasted link read; do
    [ "$("$E" lua "img.cursor_to(\"$kind\")")" = 1 ] || fail "$pass: no $kind entry"
    "$E" keys Enter
    local want="paseo_image"
    [ "$pass" = snacks ] && want="image"
    "$E" wait "img.float() == \"$want:$tabs\"" 10 || fail "$pass: <CR> on $kind opened: $("$E" lua 'img.float()')"
    "$E" keys q
    "$E" wait 'img.float() == ""' 5 || fail "$pass: q left the float up"
  done

  if [ "$pass" = snacks ]; then
    "$E" wait "img.placements() >= 3" 15 || fail "snacks: placements: $("$E" lua 'img.placements()')"
    tmux capture-pane -p -t "${PASEO_E2E_SESSION:-paseo-e2e}" | grep -q $'\xf4\x8e\xbb\xae' \
      || fail "snacks: no placeholder cells on screen"
  fi
  "$E" shot "images-$pass" >/dev/null
}

run_pass plain
# A restart: the pasted image is found again from history, by its id.
"$E" stop
"$E" start "$repo"
open_chat
"$E" keys ":luafile $helpers" Enter
"$E" wait "img.with_id() == 1" 15 || fail "restart: the pasted image did not come back"

snacks_dir="$HOME/.local/share/nvim/lazy/snacks.nvim"
if [ -d "$snacks_dir" ] && command -v magick >/dev/null; then
  PASEO_E2E_RTP="$snacks_dir" SNACKS_GHOSTTY=1 run_pass snacks
fi
