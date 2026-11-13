#!/usr/bin/env bash
# Benchmarks. Numbers, not pass/fail.
#
#   tests/bench/run.sh micro            main-loop work, stubbed bridge, headless
#   tests/bench/run.sh micro out.json   ... and keep the results
#   tests/bench/run.sh ui               real windows against the e2e daemon
#                                       (tests/e2e/bench.sh)
#
# Compare two saved runs with: python3 -I tests/bench/compare.py a.json b.json
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
kind="${1:-micro}"
out="${2:-}"

case "$kind" in
micro)
  deps="${PASEO_TEST_DEPS:-${XDG_CACHE_HOME:-$HOME/.cache}/paseo-nvim/test-deps}"
  "$root/tests/deps.sh" "$deps" >/dev/null
  unset VIMRUNTIME
  cd "$root"
  log="$(mktemp "${TMPDIR:-/tmp}/paseo-bench.XXXXXX")"
  PASEO_PERF=1 PASEO_TEST_DEPS="$deps" PASEO_FIXTURES="${PASEO_FIXTURES:-${TMPDIR:-/tmp}/paseo-nvim-tests}" \
    nvim --headless -i NONE -u tests/minimal_init.lua \
    -c 'lua local ok, err = pcall(dofile, "tests/bench/micro.lua"); if not ok then io.stdout:write("BENCH FAILED: " .. tostring(err) .. "\n") end; vim.cmd(ok and "qa!" or "cq")' \
    2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  if [ -n "$out" ]; then
    sed -n 's/^JSON //p' "$log" >"$out"
    echo "saved $out"
  fi
  rm -f "$log"
  exit "$status"
  ;;
ui)
  exec "$root/tests/e2e/bench.sh" "${@:2}"
  ;;
*)
  echo "usage: $0 micro|ui [out.json]" >&2
  exit 2
  ;;
esac
