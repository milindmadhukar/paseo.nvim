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
  "$here/nvim.sh" stop
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
