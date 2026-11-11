# A message from another agent is drawn as a message, with its sender.
#
# It rides the timeline as a tool call carrying `agentMessage`; the sidecar
# dropped that field, so the chat drew an empty "Agent message" card.
source "$(dirname "$0")/../lib.sh"

repo="$(fresh_repo)"
id_of() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("agentId") or d.get("id"))'; }
receiver="$("$D" paseo run --json --provider fake/scripted --cwd "$repo" "echo receiver" 2>/dev/null | id_of)"
sender="$("$D" paseo run --json --provider fake/scripted --cwd "$repo" --title Planner "echo sender" 2>/dev/null | id_of)"
[ -n "$receiver" ] && [ -n "$sender" ] || fail "could not seed two agents"
# The CLI sends AS an agent when it runs inside one, which PASEO_AGENT_ID says.
PASEO_AGENT_ID="$sender" "$D" paseo send "$receiver" "the schema is ready for review" >/dev/null 2>&1 \
  || fail "the agent-to-agent send failed"

"$E" stop
"$E" start "$repo"
"$E" lua "(function() require(\"paseo.ui.chat\").open({ root = \"$repo\", agent_id = \"$receiver\" }); return 1 end)()" >/dev/null
settle

msg='[b for b in s["blocks"] if b["kind"] == "agent_message"]'
[ "$(q "len($msg)")" = "1" ] || fail "no agent_message block: $(q '[b["kind"] for b in s["blocks"]]')"
[ "$(q "$msg[0]['text']")" = "the schema is ready for review" ] || fail "the words were lost"
tmux capture-pane -t paseo-e2e -p | grep -q "from Planner" || fail "the sender is not named on screen"
"$E" shot agent-message >/dev/null
