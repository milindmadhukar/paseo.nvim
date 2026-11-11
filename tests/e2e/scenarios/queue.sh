# A message queued behind a running turn is sent when that turn ends.
#
# Mid-turn, `<CR>` steers (the app's default; the daemon's own default is to
# interrupt, which is what sending mid-turn used to do from here) and `g<CR>`
# queues: held in the editor, counted on the bar, delivered after the turn.
source "$(dirname "$0")/../lib.sh"

repo_with_agent >/dev/null
open_chat
send_prompt "long think"
"$E" wait 'require("paseo.ui.chat").current().streaming' 10 || fail "the turn never started"
sleep 2
tmux capture-pane -t paseo-e2e -p | grep -q "steer" || fail "the bar does not say what <CR> does mid-turn"

"$E" keys i "echo after the turn" Escape g Enter
"$E" wait '#(require("paseo.ui.chat").current().queued or {}) == 1' 5 || fail "nothing was queued"
tmux capture-pane -t paseo-e2e -p | grep -q "1 queued" || fail "the bar does not count the queue"
"$E" shot queue >/dev/null

# Delivered after the long turn finishes, by itself.
"$E" wait '#(require("paseo.ui.chat").current().queued or {}) == 0' 60 || fail "the queue was never sent"
users_before=2
wait_idle 30
last_user='[b.get("text") for b in s["blocks"] if b["kind"]=="user"][-1]'
[ "$(q "$last_user")" = "echo after the turn" ] || fail "the queued message is not the last thing said: $(q "$last_user")"
# And the long turn finished rather than being cut short by it.
[ "$(q '[b["kind"] for b in s["blocks"]].count("text")')" -ge 3 ] || fail "the running turn was interrupted"
