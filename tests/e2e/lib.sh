# Sourced by scenarios. Small assertions over `nvim.sh state` and the CLI.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E="$here/nvim.sh"
D="$here/daemon.sh"
eval "$("$D" env)"

fail() {
  echo "  $*" >&2
  "$E" shot "fail-$(basename "$0" .sh)" >/dev/null 2>&1 || true
  exit 1
}

# `jq`-free: a Python one-liner over the state JSON.
#   q '<python expr over s>'
q() {
  "$E" state | python3 -I -c "import json,sys; s=json.load(sys.stdin); print($1)"
}

# Open the chat on the fixture repo and wait until an agent is bound.
open_chat() {
  "$E" keys ':Paseo chat' Enter
  "$E" wait 'require("paseo.ui.chat").current() ~= nil' 20 || fail "no chat opened"
  settle
}

# The transcript has stopped changing: history fetched and drawn. Sending
# before this races the history fetch, and a test then reads the PREVIOUS turn.
settle() {
  local last="" now="" same=0
  for _ in $(seq 1 100); do
    now="$("$E" lua '_G.paseo_e2e.users() .. ":" .. #((require("paseo.ui.chat").current() or {}).order or {})')"
    if [ "$now" = "$last" ] && [ "$now" != "0:0" -o "$same" -gt 8 ]; then
      same=$((same + 1))
      [ "$same" -ge 4 ] && return 0
    else
      same=0
    fi
    last="$now"
    sleep 0.25
  done
  fail "transcript never settled ($now)"
}

# Type a prompt into the composer and send it (normal-mode <CR> sends).
# Remembers how many user messages were on screen, so `wait_idle` waits for
# THIS turn rather than returning on the idle state before it started.
send_prompt() {
  users_before="$("$E" lua '_G.paseo_e2e.users()')"
  "$E" keys i "$1" Escape Enter
}

# The turn sent last is on screen, finished, and has an answer below it.
wait_idle() {
  "$E" wait "_G.paseo_e2e.turn_done(${users_before:-0})" "${1:-30}" \
    || fail "turn did not finish"
}

# A repository of this scenario's own: one commit, one README, on `main`.
# Shared fixtures meant a scenario opened whatever agent the last one left.
fresh_repo() {
  local repo="$PASEO_E2E_ROOT/repos/$(basename "$0" .sh)-$$-$RANDOM"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  echo "# fixture" >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name="paseo tests" -c user.email=tests@paseo.invalid \
    -c commit.gpgsign=false commit -qm init
  echo "$repo"
}

# A repository with one finished agent in it, and Neovim open there.
# Prints the repo path.
repo_with_agent() {
  local repo
  repo="$(fresh_repo)"
  "$D" paseo run --provider fake/scripted --cwd "$repo" "echo seed" >/dev/null 2>&1 \
    || fail "could not seed an agent in $repo"
  "$E" stop
  "$E" start "$repo"
  echo "$repo"
}

# Press `c` on the new-agent screen until it takes. The screen ignores it
# while the model's features are still loading (its footer says so), and how
# long that takes is the provider's business, not something to sleep for.
#   create_from_review '<lua expr true once created>'
create_from_review() {
  # The review itself, not just "a float": the chat has floats too, and a
  # `c` that lands in the composer is the change operator.
  "$E" wait 'vim.bo.filetype == "paseo-create"' 20 || fail "the new-agent screen never opened"
  for _ in $(seq 1 15); do
    if [ "$("$E" lua 'vim.bo.filetype')" = "paseo-create" ]; then
      "$E" keys c
    fi
    "$E" wait "$1" 2 2>/dev/null && return 0
  done
  fail "the new-agent screen never took \`c\`"
}
