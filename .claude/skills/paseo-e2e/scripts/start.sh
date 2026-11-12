#!/usr/bin/env bash
# start.sh <agent-id> [float|buffer|sidebar]
#
# A fresh Neovim in tmux (session paseo-e2e, 140x40) running THIS checkout's
# plugin, with the chat open on <agent-id>. Run it from the checkout you are
# testing, or set PASEO_NVIM_TREE.
source "$(dirname "$0")/env.sh"
TREE=$E2E_TREE
"$(dirname "$0")/sandbox.sh" >/dev/null
tmux kill-session -t "$E2E_SESSION" 2>/dev/null
# A socket PER RUN: the old Neovim unlinks its path on the way out, and a reused
# path is the new one's -- "connection refused" on a file that exists.
sock=$E2E_RUN/nvim-$$.sock
echo "$sock" > "$E2E_RUN/sock"
: > "$E2E_RUN/notify.log"
mkdir -p "$E2E_RUN/state"
tmux new-session -d -s "$E2E_SESSION" -x 140 -y 40 -c "$E2E_SANDBOX" \
  "PASEO_NVIM_TREE=$TREE E2E_SCRIPTS=$E2E_SCRIPTS E2E_STATE=$E2E_RUN/state E2E_LOG=$E2E_RUN/notify.log E2E_SCHEME=${E2E_SCHEME:-habamax} nvim --clean --listen $sock -u $E2E_SCRIPTS/init.lua; echo \"[nvim exited: \$?]\"; sleep 600"
for _ in $(seq 1 40); do nvim --server "$sock" --remote-expr 1 >/dev/null 2>&1 && break; sleep 0.25; done
[ -n "$1" ] && nvim --server "$sock" --remote-expr \
  "luaeval('require(\"paseo.e2e_probe\").open(_A[1], _A[2])', [\"$1\", \"${2:-}\"])" && echo
sleep 4   # history, settings and the agent directory land
