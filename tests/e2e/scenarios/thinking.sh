# Streamed reasoning renders as ONE block, not one per delta.
#
# The regression: live `thinking` events were appended block-per-event, so a
# thought arrived as `🧠 I'm` / `🧠 looking at what` / `🧠 the` … while a
# reopened chat (projected history) showed it whole.
source "$(dirname "$0")/../lib.sh"

repo_with_agent >/dev/null
open_chat
send_prompt "think slow"
wait_idle 30

# Everything after the last user message is this turn.
turn='[b["kind"] for b in s["blocks"][max(i for i,b in enumerate(s["blocks"]) if b["kind"]=="user")+1:]]'
kinds="$(q "$turn")"
[ "$(q "$turn.count(\"thinking\")")" = "1" ] || fail "thinking split: $kinds"
[ "$(q "$turn.count(\"text\")")" = "1" ] || fail "answer split: $kinds"
"$E" shot thinking >/dev/null

# Reopened, the same turn renders the same shape (history is projected).
"$E" keys q
"$E" wait 'not require("paseo.ui.float").chat()' 10 || fail "chat did not close"
open_chat
"$E" wait '#(require("paseo.ui.chat").current().order or {}) > 0' 20 || fail "history did not load"
[ "$(q "$turn")" = "$kinds" ] || fail "history $(q "$turn") != live $kinds"
