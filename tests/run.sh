#!/usr/bin/env bash
# Build fixtures, run the spec in a real Neovim, exit non-zero on failure.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="${PASEO_FIXTURES:-${TMPDIR:-/tmp}/paseo-nvim-tests}"

"$here/fixtures.sh" "$fixtures" >/dev/null

PASEO_FIXTURES="$fixtures" nvim --headless \
  -c 'lua require("lazy").load({ plugins = { "paseo.nvim" } })' \
  -c 'lua local failed = require("tests.spec").run(); vim.cmd(failed > 0 and "cq" or "qa!")' \
  2>&1
status=$?

echo
if [ $status -eq 0 ]; then echo "PASS"; else echo "FAIL (exit $status)"; fi
exit $status
