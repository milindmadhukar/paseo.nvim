# Attaching an image leaves the surface where it was.
#
# The regression: on the buffer mount (`:Paseo buf`), `:Paseo image` looked
# the chat up by directory, missed it (chats are keyed by agent once one is
# bound), built a second one, and the round trip that followed landed you in
# the float.
source "$(dirname "$0")/../lib.sh"

python3 -I - "$PASEO_E2E_ROOT/pic.png" <<'PY'
import sys, zlib, struct
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\x00" + b"\xff\x00\x00" * 4 for _ in range(4))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

shape="(s['mount'], s['tabpages'], len(s['wins']))"
composer='table.concat(vim.api.nvim_buf_get_lines(require("paseo.ui.chat").current().composer, 0, -1, false), " ")'

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 || fail "no seed agent"

for surface in buffer float; do
  "$E" stop
  "$E" start "$repo"
  if [ "$surface" = buffer ]; then
    "$E" keys ':Paseo buf' Enter
  else
    "$E" keys ':Paseo dash' Enter
  fi
  "$E" wait 'require("paseo.ui.chat").current() ~= nil' 20 || fail "$surface: no chat"
  settle
  "$E" keys Escape
  before="$(q "$shape")"
  [[ "$before" == *"'$surface'"* ]] || fail "$surface: opened on $before"

  # The command, from wherever you are.
  "$E" keys ":Paseo image $PASEO_E2E_ROOT/pic.png" Enter
  "$E" wait "($composer):find(\"[Image #1]\", 1, true) ~= nil" 10 || fail "$surface: :Paseo image attached nothing"
  [ "$(q "$shape")" = "$before" ] || fail "$surface: :Paseo image moved the surface: $before -> $(q "$shape")"

  # And `p` in the composer, with a picture on the (stubbed) clipboard.
  "$E" lua "(function() local i = require(\"paseo.image\"); i.from_clipboard = function() return i.from_file(\"$PASEO_E2E_ROOT/pic.png\") end; return 1 end)()" >/dev/null
  "$E" lua '(function() vim.api.nvim_set_current_win(require("paseo.ui.chat").current().win_composer); return 1 end)()' >/dev/null
  "$E" keys p
  "$E" wait "($composer):find(\"[Image #2]\", 1, true) ~= nil" 10 || fail "$surface: composer p attached nothing"
  [ "$(q "$shape")" = "$before" ] || fail "$surface: composer p moved the surface: $before -> $(q "$shape")"
  "$E" shot "paste-$surface" >/dev/null
done
