#!/usr/bin/env bash
# spawn.sh <title> <prompt> [--parent <agent-id>] [--mode <mode>] [--wait]
#
# A cheap test agent in the sandbox, labelled paseo-nvim-e2e so cleanup.sh can
# find it. Prints the agent id. --parent makes it a PASEO subagent of that
# agent (the `paseo.parent-agent-id` label). Default mode is `default` --
# "Always Ask" -- so every first tool use raises a permission request.
source "$(dirname "$0")/env.sh"
title=$1; prompt=$2; shift 2
mode=default; parent=; wait=--no-wait
while [ $# -gt 0 ]; do
  case $1 in
    --parent) parent=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --wait) wait=; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
"$(dirname "$0")/sandbox.sh" >/dev/null
args=(run --json $wait --mode "$mode" --provider claude/claude-haiku-5-5 --thinking low
      --title "e2e: $title" --label paseo-nvim-e2e=1 --cwd "$E2E_SANDBOX")
# ONE workspace for the sandbox: without --workspace every run registers
# another `main` row for the same directory.
[ -s "$E2E_RUN/workspace" ] && args+=(--workspace "$(cat "$E2E_RUN/workspace")")
[ -n "$parent" ] && args+=(--label "paseo.parent-agent-id=$parent")
out=$(cd "$E2E_SANDBOX" && paseo_cli "${args[@]}" "$prompt" 2>&1)
ws=$(printf '%s\n' "$out" | sed -n 's/^Created workspace \(wks_[a-z0-9]*\).*/\1/p')
[ -n "$ws" ] && echo "$ws" > "$E2E_RUN/workspace"
id=$(printf '%s\n' "$out" | sed -n 's/.*"agentId": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$id" ] && { printf '%s\n' "$out" >&2; exit 1; }
echo "$id"
