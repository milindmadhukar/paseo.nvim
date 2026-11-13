# The transcript keeps its place: scrolled up, it stays put through new
# output, another agent in the middle and a trip to another tab; `G` to the
# bottom and it follows again; following while off screen, it comes back at
# the NEW end. Scrolling is real keypresses, so `WinScrolled` comes from the
# main loop the way it does for you.
source "$(dirname "$0")/../lib.sh"

C='require("paseo.ui.chat").current()'
top="vim.fn.line(\"w0\", $C.win_conversation)"
bottom="(vim.fn.line(\"w\$\", $C.win_conversation) >= vim.api.nvim_buf_line_count($C.conversation))"
conv() { "$E" keys Escape; "$E" lua "vim.api.nvim_set_current_win($C.win_conversation)" >/dev/null; }
box() { "$E" lua "vim.api.nvim_set_current_win($C.win_composer)" >/dev/null; }

repo="$(fresh_repo)"
tall="$(printf 'echo\n\n'; for i in $(seq 1 120); do printf -- '- line %d\n' "$i"; done)"
"$D" paseo run --provider fake/scripted --cwd "$repo" --title "first" "$tall" >/dev/null 2>&1 || fail "seed first"
"$E" stop
"$E" start "$repo"

"$E" keys ':Paseo' Enter
"$E" wait 'require("paseo.ui.native").chat() ~= nil' 20 || fail "no Paseo tab"
settle
first="$("$E" lua "$C.agent_id")"
[ "$("$E" lua "$bottom")" = "true" ] || fail "a chat does not open at its end"

# SCROLLED UP, IT STAYS: through a turn of its own.
conv
"$E" keys g g
"$E" wait "$C.sticky == false and $top == 1" 5 || fail "gg did not stop following ($("$E" lua "$top"))"
box
send_prompt "echo while scrolled up"
wait_idle 30
[ "$("$E" lua "$top")" = "1" ] || fail "a turn dragged a scrolled-up chat down to $("$E" lua "$top")"
"$E" shot sticky-up >/dev/null

# ANOTHER AGENT IN THE MIDDLE, AND BACK.
wsid="$("$E" lua "require(\"paseo.agents\").get($C.agent_id).workspaceId")"
"$D" paseo run --provider fake/scripted --cwd "$repo" --workspace "$wsid" --title "second" "echo second" >/dev/null 2>&1 \
  || fail "seed second"
"$E" wait 'vim.iter(require("paseo.agents").all()):any(function(a) return a.title == "second" end)' 15 \
  || fail "the second agent never reached Neovim"
"$E" lua '(function() for _, a in ipairs(require("paseo.agents").all()) do
    if a.title == "second" then require("paseo.ui.native").show_session { kind = "agent", id = a.id }; return a.id end
  end end)()' >/dev/null
"$E" wait "$C.agent_id ~= \"$first\"" 15 || fail "the second agent did not take the middle"
settle
conv
"$E" keys ':bprevious' Enter
"$E" wait "$C.agent_id == \"$first\"" 15 || fail ":bprevious did not go back to the first agent"
sleep 0.5
[ "$("$E" lua "$top")" = "1" ] || fail "back from another agent at line $("$E" lua "$top"), not where it was left"

# ANOTHER TAB, AND BACK through :Paseo native.
"$E" keys Escape ':tabprevious' Enter
"$E" wait 'not require("paseo.ui.native").on_tab()' 5 || fail "did not leave the Paseo tab"
"$E" keys ':Paseo' Enter
"$E" wait 'require("paseo.ui.native").on_tab()' 10 || fail "did not come back to the Paseo tab"
sleep 0.5
[ "$("$E" lua "$top")" = "1" ] || fail "back from another tab at line $("$E" lua "$top"), not where it was left"

# G, AND IT FOLLOWS.
conv
"$E" keys G
"$E" wait "$C.sticky == true" 5 || fail "G did not turn following back on"
box
send_prompt "echo after G"
wait_idle 30
"$E" wait "$bottom" 5 || fail "after G, a turn did not scroll into view"
"$E" shot sticky-following >/dev/null

# FOLLOWING WHILE OFF SCREEN: the new end, not the old one.
conv
"$E" keys ':bnext' Enter
"$E" wait "$C.agent_id ~= \"$first\"" 15 || fail ":bnext did not leave the first agent"
"$D" paseo send "$first" "$tall" >/dev/null 2>&1 || fail "could not send to the first agent"
sleep 1
conv
"$E" keys ':bprevious' Enter
"$E" wait "$C.agent_id == \"$first\"" 15 || fail ":bprevious did not go back to the first agent"
"$E" wait "$bottom" 5 || fail "a followed chat came back short of its new end"
"$E" shot sticky-back >/dev/null
