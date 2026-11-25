#!/usr/bin/env bash
# Run the end-to-end scenarios against a throwaway daemon.
#
#   tests/e2e/run.sh              every scenario
#   tests/e2e/run.sh thinking     only scenarios whose name matches
#
# Each scenario is a script in scenarios/ that gets a fresh Neovim (and the
# shared daemon), asserts on `nvim.sh state` and the daemon's own CLI, and may
# leave a screenshot in $PASEO_E2E_ROOT/shots for a human to look at. The
# daemon is started if it is not up and left running for the next run: it is
# yours, isolated, and `daemon.sh stop` takes it down.
set -uo pipefail
# Not as an agent: see lib.sh. The daemon this starts should not inherit it.
unset PASEO_WORKSPACE_ID PASEO_AGENT_ID PASEO_AGENT_CWD

here="$(cd "$(dirname "$0")" && pwd)"
filter="${1:-}"
"$here/daemon.sh" start >/dev/null || exit 1

failed=0
passed=0
for scenario in "$here"/scenarios/*.sh; do
  name="$(basename "$scenario" .sh)"
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
    continue
  fi
  # The LAST scenario's Neovim saves its new-session drafts as it quits, and
  # the next one would restore them onto its row: new-folder.sh ends on a
  # refused start that keeps its prompt, and native, rail-sessions and sticky
  # then counted a draft they never made. Stop it, then forget them. A
  # scenario that tests drafts across a restart (drafts.sh) does its own.
  "$here/nvim.sh" stop
  rm -f "$(eval "$("$here/daemon.sh" env)"; echo "$PASEO_E2E_ROOT")/xdg/state/nvim/paseo/drafts.json"
  if "$here/nvim.sh" start && bash "$scenario"; then
    echo "ok    $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    failed=$((failed + 1))
  fi
done
"$here/nvim.sh" stop

echo
echo "e2e: $passed passed, $failed failed (screenshots: $("$here/daemon.sh" env | sed -n "s/.*ROOT='\(.*\)'/\1/p")/shots)"
[ "$failed" -eq 0 ]
