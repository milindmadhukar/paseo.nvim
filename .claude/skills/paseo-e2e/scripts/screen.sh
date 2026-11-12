#!/usr/bin/env bash
# screen.sh [--color] : what is on the e2e Neovim's screen right now.
# --color keeps the ANSI escapes, for ansi2html / a screenshot.
source "$(dirname "$0")/env.sh"
if [ "$1" = --color ]; then
  tmux capture-pane -t "$E2E_SESSION" -e -p
else
  tmux capture-pane -t "$E2E_SESSION" -p | grep -v '^~ *$'
fi
