#!/usr/bin/env bash
# Build fixtures, run the spec in a real Neovim, exit non-zero on failure.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="${PASEO_FIXTURES:-${TMPDIR:-/tmp}/paseo-nvim-tests}"

"$here/fixtures.sh" "$fixtures" >/dev/null

# Test the tree you are STANDING IN, not the one lazy.nvim has on its rtp.
#
# The lazy spec loads paseo.nvim with `dev = true` out of ~/Code/paseo.nvim, so
# running this from a worktree loaded spec.lua from the worktree and every
# module under test from the main checkout -- a suite that passes while testing
# none of your changes. Prepending cwd makes `require` find this tree first.
PASEO_FIXTURES="$fixtures" nvim --headless \
  -c "lua vim.opt.runtimepath:prepend('$(cd "$here/.." && pwd)')" \
  -c 'lua require("lazy").load({ plugins = { "paseo.nvim" } })' \
  -c "lua vim.opt.runtimepath:prepend('$(cd "$here/.." && pwd)')" \
  -c 'lua local failed = require("tests.spec").run(); vim.cmd(failed > 0 and "cq" or "qa!")' \
  2>&1
status=$?

sidecar="$here/../sidecar"
if [ ! -d "$sidecar/node_modules/typescript" ]; then
  echo "SETUP: install sidecar dependencies with bun install or npm install in sidecar/" >&2
  status=2
elif command -v bun >/dev/null 2>&1; then
  (cd "$sidecar" && bun run typecheck && bun test)
  [ $? -eq 0 ] || status=1
elif command -v npx >/dev/null 2>&1; then
  (cd "$sidecar" && npx --no-install tsc --noEmit && node --experimental-strip-types --test *.test.ts)
  [ $? -eq 0 ] || status=1
else
  echo "SETUP: typecheck needs bun or npx (TypeScript is installed locally)" >&2
  status=2
fi

echo
if [ $status -eq 0 ]; then echo "PASS"; else echo "FAIL (exit $status)"; fi
exit $status
