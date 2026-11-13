# An agent archived from ANYWHERE -- here the CLI, standing in for the app or
# another agent -- takes its buffer off the row: the one on screen hands the
# middle to its neighbour, one in the background just goes, and the last one
# takes the Paseo tab with it.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "keeper" "echo keep" >/dev/null 2>&1 || fail "seed 1"
"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo native' Enter
"$E" wait 'require("paseo.ui.native").chat() ~= nil and require("paseo.ui.chat").current().initialised' 20 || fail "no Paseo tab"
keeper="$("$E" lua 'require("paseo.ui.chat").current().agent_id')"
wsid="$("$E" lua "require(\"paseo.agents\").get(\"$keeper\").workspaceId")"

# Two more in the same workspace, both opened onto the row.
for t in doomed background; do
  "$D" paseo run --provider fake/scripted --cwd "$repo" --workspace "$wsid" --title "$t" "echo $t" >/dev/null 2>&1 || fail "seed $t"
done
"$E" wait 'vim.iter(require("paseo.agents").all()):any(function(a) return a.title == "background" end)' 15 \
  || fail "the seeded agents never reached Neovim"
id_of() { "$E" lua "(function() for _, a in ipairs(require(\"paseo.agents\").all()) do if a.title == \"$1\" then return a.id end end end)()"; }
doomed="$(id_of doomed)"
background="$(id_of background)"
for id in "$background" "$doomed"; do
  "$E" lua "require(\"paseo.ui.native\").show_session { kind = \"agent\", id = \"$id\" } or 1" >/dev/null
  "$E" wait "require(\"paseo.ui.chat\").current().agent_id == \"$id\" and require(\"paseo.ui.chat\").current().initialised" 15 \
    || fail "could not open $id"
done
[ "$("$E" lua '#require("paseo.ui.native").listed()')" = "3" ] || fail "three agents are not on the row"
doomed_buf="$("$E" lua 'require("paseo.ui.chat").current().conversation')"

# The one ON SCREEN, archived elsewhere.
"$D" paseo archive "$doomed" >/dev/null 2>&1 || fail "archive doomed"
"$E" wait '#require("paseo.ui.native").listed() == 2' 10 || fail "the archived agent's buffer stayed on the row"
"$E" wait "not vim.api.nvim_buf_is_valid($doomed_buf)" 5 || fail "its buffer was not wiped"
[ "$("$E" lua "require(\"paseo.ui.chat\").current().agent_id ~= \"$doomed\"")" = "true" ] \
  || fail "the middle still shows the archived agent"
[ "$("$E" lua '#vim.api.nvim_list_tabpages()')" = "2" ] || fail "the Paseo tab went with one of three"
"$E" shot archive-onscreen >/dev/null

# One in the BACKGROUND -- whichever of the two is not in the middle now: it
# just goes, and the middle is untouched.
here="$("$E" lua 'require("paseo.ui.chat").current().agent_id')"
if [ "$here" = "$keeper" ]; then other="$background"; else other="$keeper"; fi
"$D" paseo archive "$other" >/dev/null 2>&1 || fail "archive the background one"
"$E" wait '#require("paseo.ui.native").listed() == 1' 10 || fail "the background agent's buffer stayed"
[ "$("$E" lua 'require("paseo.ui.chat").current().agent_id')" = "$here" ] || fail "the middle moved for a background archive"

# The LAST one: the Paseo tab goes with it, as the last :bdelete does.
"$D" paseo archive "$here" >/dev/null 2>&1 || fail "archive the last one"
"$E" wait '#vim.api.nvim_list_tabpages() == 1' 10 || fail "the Paseo tab outlived its last agent"
