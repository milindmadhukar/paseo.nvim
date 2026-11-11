#!/usr/bin/env bash
# send.sh <agent-id> <prompt> [--until-permission]
#
# Prompt a test agent. --until-permission waits (up to 60s) for the daemon to
# hold a permission request for it, then 3s more for Neovim to react -- after
# that, probe.sh and screen.sh say what the user would see.
source "$(dirname "$0")/env.sh"
agent=$1; prompt=$2
paseo_cli send --no-wait "$agent" "$prompt" >/dev/null 2>&1 || { echo "send failed" >&2; exit 1; }
if [ "$3" = --until-permission ]; then
  for i in $(seq 1 60); do
    paseo_cli inspect --json "$agent" 2>/dev/null |
      python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("PendingPermissions") else 1)' && break
    sleep 1
  done
  echo "daemon holds a request after ${i}s"
  sleep 3
fi
