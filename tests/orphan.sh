#!/usr/bin/env bash
# Does the sidecar die when Neovim does?
#
# Sixteen of them did not. They sat at 90% of a core for a day each, on a
# machine whose editor had closed hours earlier, because the handler for "the
# pipe is broken" reported the problem by writing to the pipe.
#
# Two ways for the editor to go, and the sidecar has to survive neither:
#
#   severed  the READ ends close and stdin stays open. Nothing can rescue this
#            but handling the write failure -- which is the regression.
#   orphan   everything closes at once, the ordinary :qa or crash.
#
# Usage: tests/orphan.sh [path/to/paseo-bridge.ts]
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="${1:-$root/sidecar/paseo-bridge.ts}"

# The same choice lua/paseo/bridge.lua:50 makes, and PASEO_RUNTIME to force the
# other one -- the two runtimes exit by DIFFERENT routes (node on the stdout
# error, bun on the watchdog), so a pass under one proves little about the other.
runtime="${PASEO_RUNTIME:-}"
if [ -z "$runtime" ]; then
  if command -v bun >/dev/null 2>&1; then runtime=bun; else runtime=node; fi
fi
case "$runtime" in
  bun) child=(bun run "$script") ;;
  node) child=(node --experimental-strip-types "$script") ;;
  *) echo "orphan: unknown runtime $runtime" >&2; exit 2 ;;
esac
command -v "$runtime" >/dev/null 2>&1 || { echo "orphan: $runtime is not installed" >&2; exit 2; }
echo "runtime: $runtime"

if [ ! -d "$root/sidecar/node_modules/@getpaseo" ]; then
  echo "orphan: installing the sidecar's dependencies…"
  if command -v bun >/dev/null 2>&1; then
    (cd "$root/sidecar" && bun install >/dev/null) || exit 2
  else
    (cd "$root/sidecar" && npm install --no-package-lock >/dev/null) || exit 2
  fi
fi

status=0

echo "== severed: the read ends close, stdin stays open"
if node "$here/orphan.mjs" severed "${child[@]}"; then
  echo "   PASS"
else
  echo "   FAIL"
  status=1
fi

echo "== orphan: the parent dies, taking every pipe with it"
pid="$(node "$here/orphan.mjs" orphan "${child[@]}")"
if [ -z "$pid" ]; then
  echo "   FAIL: the harness never reported a pid"
  status=1
else
  # 2s watchdog inside the sidecar, plus room for a slow machine.
  deadline=$((SECONDS + 6))
  while [ -d "/proc/$pid" ] && [ $SECONDS -lt $deadline ]; do sleep 0.05; done
  if [ -d "/proc/$pid" ]; then
    echo "   FAIL: pid $pid outlived its parent by 6s"
    awk '{printf "     state=%s ppid=%s cpu=%.2fs\n", $3, $4, ($14+$15)/100}' "/proc/$pid/stat"
    grep -E 'syscw|wchar' "/proc/$pid/io" | sed 's/^/     /'
    kill -9 "$pid" 2>/dev/null
    status=1
  else
    echo "   PASS"
  fi
fi

echo
if [ $status -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit $status
