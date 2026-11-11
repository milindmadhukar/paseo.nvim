#!/usr/bin/env bash
# cleanup.sh : archive every test agent, stop the e2e Neovim, drop run files.
# The sandbox project stays -- it is reused.
source "$(dirname "$0")/env.sh"
# By LABEL, never by name: only what spawn.sh made is ever archived.
paseo_cli ls --json --global --label paseo-nvim-e2e=1 2>/dev/null | python3 -c '
import json, sys
for a in json.load(sys.stdin):
    print(a["id"])' | while read -r id; do
  paseo_cli archive "$id" >/dev/null 2>&1 && echo "archived $id"
done
tmux kill-session -t "$E2E_SESSION" 2>/dev/null && echo "stopped $E2E_SESSION"
rm -rf "$E2E_RUN"
