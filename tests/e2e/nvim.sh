#!/usr/bin/env bash
# Drive a real Neovim, in tmux, against the throwaway daemon.
#
#   tests/e2e/nvim.sh start [cwd]     open Neovim in a detached tmux session
#   tests/e2e/nvim.sh keys <keys…>    tmux send-keys into it
#   tests/e2e/nvim.sh lua '<expr>'    evaluate a Lua expression, print the result
#   tests/e2e/nvim.sh state           what is on screen, as JSON (init.lua)
#   tests/e2e/nvim.sh wait '<expr>' [s]  poll a Lua expression until truthy
#   tests/e2e/nvim.sh shot <name>     capture the pane, in colour, to PNG
#   tests/e2e/nvim.sh stop            close that Neovim and its tmux session
#
# Its own XDG state and data: the plugin remembers things there (whether the
# rail is shown, for one), and a test Neovim reading and writing yours would
# both depend on and change how your editor opens.
#
# Why tmux and not --headless: the bugs worth catching are about windows --
# a float one row off, a surface that swapped, a block split in three -- and a
# headless Neovim has no screen for them to be wrong on. The screenshot is
# for looking at; the assertions are on `state`, which reads the same facts
# out of the running instance.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval "$("$here/daemon.sh" env)"
session="${PASEO_E2E_SESSION:-paseo-e2e}"
sock="$PASEO_E2E_ROOT/nvim.sock"
shots="$PASEO_E2E_ROOT/shots"
cols="${PASEO_E2E_COLS:-140}"
rows="${PASEO_E2E_ROWS:-42}"

remote() {
  nvim --server "$sock" --remote-expr "$1"
}

case "${1:-}" in
  start)
    cwd="${2:-$PASEO_E2E_ROOT/repo}"
    tmux kill-session -t "$session" 2>/dev/null || true
    rm -f "$sock"
    # What the new-task screen remembers is per scenario: one that started a
    # worktree must not open the next one's screen on Worktree.
    rm -f "$PASEO_E2E_ROOT/xdg/state/nvim/paseo/new.json"
    tmux new-session -d -s "$session" -x "$cols" -y "$rows" -c "$cwd" \
      "env PASEO_E2E_URL='$PASEO_E2E_URL' PASEO_E2E_HOME='$PASEO_E2E_HOME' \
       XDG_STATE_HOME='$PASEO_E2E_ROOT/xdg/state' XDG_DATA_HOME='$PASEO_E2E_ROOT/xdg/data' \
       PASEO_E2E_SURFACE='${PASEO_E2E_SURFACE:-native}' PASEO_E2E_UI_COLORS='${PASEO_E2E_UI_COLORS:-auto}' PASEO_E2E_COLORS='${PASEO_E2E_COLORS:-habamax}' \
       nvim --listen '$sock' -i NONE -u '$here/init.lua'"
    for _ in $(seq 1 50); do
      [ -S "$sock" ] && remote '1' >/dev/null 2>&1 && exit 0
      sleep 0.1
    done
    echo "nvim did not come up" >&2
    exit 1
    ;;
  keys)
    shift
    tmux send-keys -t "$session" "$@"
    ;;
  lua)
    remote "luaeval('$2')"
    ;;
  state)
    remote 'luaeval("_G.paseo_e2e.state()")'
    ;;
  wait)
    expr="$2"
    deadline=$(( $(date +%s) + ${3:-20} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if [ "$(remote "luaeval('(${expr}) and 1 or 0')" 2>/dev/null)" = "1" ]; then
        exit 0
      fi
      sleep 0.2
    done
    echo "timed out waiting for: $expr" >&2
    exit 1
    ;;
  shot)
    mkdir -p "$shots"
    name="${2:-shot}"
    tmux capture-pane -t "$session" -e -p >"$shots/$name.ansi"
    python3 -I "$here/ansi2html.py" "$shots/$name.ansi" "$shots/$name.html" "$cols"
    browser="$(command -v google-chrome-stable || command -v chromium || command -v brave || true)"
    if [ -n "$browser" ]; then
      "$browser" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --user-data-dir="$PASEO_E2E_ROOT/chrome" \
        --window-size="$((cols * 9)),$((rows * 19))" \
        --screenshot="$shots/$name.png" "file://$shots/$name.html" >/dev/null 2>&1 || true
    fi
    echo "$shots/$name.png"
    ;;
  stop)
    remote 'execute("qa!")' >/dev/null 2>&1 || true
    tmux kill-session -t "$session" 2>/dev/null || true
    rm -f "$sock"
    ;;
  *)
    sed -n '2,9p' "$0" >&2
    exit 2
    ;;
esac
