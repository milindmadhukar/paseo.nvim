#!/usr/bin/env bash
# Build fixtures, run the spec in a real Neovim, exit non-zero on failure.
#
#   tests/run.sh            everything, including the sidecar's own tests
#   tests/run.sh git        only the suites whose name matches `git`
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
filter="${1:-}"

fixtures="${PASEO_FIXTURES:-${TMPDIR:-/tmp}/paseo-nvim-tests}"
deps="${PASEO_TEST_DEPS:-${XDG_CACHE_HOME:-$HOME/.cache}/paseo-nvim/test-deps}"

"$here/fixtures.sh" "$fixtures" >/dev/null
"$here/deps.sh" "$deps" >/dev/null

# `-u` and nothing else: no user configuration, no plugin manager, no shada.
# See tests/minimal_init.lua. VIMRUNTIME goes with it: an inherited one belongs
# to whichever Neovim was installed last, and the suite is only meaningful
# against the runtime of the binary actually running it.
unset VIMRUNTIME
cd "$root"
PASEO_FIXTURES="$fixtures" PASEO_TEST_DEPS="$deps" PASEO_TEST_FILTER="$filter" \
  nvim --headless -i NONE -u tests/minimal_init.lua \
  -c 'lua local failed = require("tests.spec").run(vim.env.PASEO_TEST_FILTER); vim.cmd(failed > 0 and "cq" or "qa!")' \
  2>&1
status=$?

# A filtered run is someone iterating on one suite; the TypeScript half is not
# what they are waiting on.
if [ -n "$filter" ]; then
  echo
  [ $status -eq 0 ] && echo "PASS ($filter)" || echo "FAIL ($filter, exit $status)"
  exit $status
fi

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
