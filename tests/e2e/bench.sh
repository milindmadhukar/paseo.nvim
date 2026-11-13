#!/usr/bin/env bash
# The UI benchmark: real windows, a real (throwaway) daemon, timed inside
# Neovim. Numbers, not pass/fail.
#
#   tests/e2e/bench.sh [label]     seed if needed, run, print the table
#
# Its own root, port and tmux session -- never the scenarios' (another session
# may be running those) and never the live daemon:
#   PASEO_BENCH_ROOT  default $TMPDIR/paseo-bench-e2e
#   PASEO_BENCH_PORT  default 6798
#   BENCH_COLD        fresh Neovims to run the sequence in (default 3)
#   BENCH_WORKSPACES  worktree workspaces to seed (default 20), two agents each
#   BENCH_LOAD        seconds of the streaming load test (default 10; 0 skips)
#
# Results: $PASEO_BENCH_ROOT/bench/<label>.json, and a table on stdout.
# Compare two with: python3 -I tests/bench/compare.py a.json b.json
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
export PASEO_E2E_ROOT="${PASEO_BENCH_ROOT:-${TMPDIR:-$HOME/.cache/claude/tmp}/paseo-bench-e2e}"
export PASEO_E2E_PORT="${PASEO_BENCH_PORT:-6798}"
export PASEO_E2E_SESSION="${PASEO_BENCH_SESSION:-paseo-bench}"
label="${1:-$(git -C "$repo_root" rev-parse --short HEAD)}"
cold="${BENCH_COLD:-3}"
nws="${BENCH_WORKSPACES:-20}"
load="${BENCH_LOAD:-10}"

D="$here/daemon.sh"
E="$here/nvim.sh"
"$D" start >/dev/null || exit 1
fixture="$PASEO_E2E_ROOT/repo"
out_dir="$PASEO_E2E_ROOT/bench"
mkdir -p "$out_dir"

# ---------------------------------------------------------------- seeding
# Once per root: worktree workspaces with two agents each, and two agents on
# the main checkout. A marker records how many, so a bigger BENCH_WORKSPACES
# seeds the difference.
marker="$PASEO_E2E_ROOT/seeded"
have="$(cat "$marker" 2>/dev/null || echo 0)"
seed_one() {
  local i="$1" out ws
  out="$("$D" paseo run --provider fake/scripted --cwd "$fixture" --new-workspace worktree \
    --worktree-slug "bench-$i" --title "bench $i" "echo seed $i" 2>&1)"
  ws="$(printf '%s\n' "$out" | sed -n 's/^Created workspace \(wks_[0-9a-f]*\).*/\1/p' | head -1)"
  [ -n "$ws" ] && "$D" paseo run --provider fake/scripted --workspace "$ws" \
    --title "bench $i second" "echo second $i" >/dev/null 2>&1
}
if [ "$have" -lt "$nws" ]; then
  echo "seeding workspaces $((have + 1))..$nws (two agents each)…"
  if [ "$have" -eq 0 ]; then
    "$D" paseo run --provider fake/scripted --cwd "$fixture" --title "main one" "echo main" >/dev/null 2>&1
    "$D" paseo run --provider fake/scripted --cwd "$fixture" --title "main two" "think then echo main" >/dev/null 2>&1
  fi
  i=$((have + 1))
  while [ "$i" -le "$nws" ]; do
    for j in 0 1 2 3; do
      [ $((i + j)) -le "$nws" ] && seed_one $((i + j)) &
    done
    wait
    i=$((i + 4))
  done
  echo "$nws" >"$marker"
fi

# -------------------------------------------------------------- the runs
runs=()
for n in $(seq 1 "$cold"); do
  result="$out_dir/$label.run$n.json"
  rm -f "$result"
  "$E" stop
  PASEO_PERF=1 "$E" start "$fixture" || exit 1
  "$E" lua "dofile(\"$here/bench.lua\") and 1" >/dev/null
  "$E" lua "_G.paseo_bench.run(\"$result\") or 1" >/dev/null
  for _ in $(seq 1 600); do
    [ -s "$result" ] && break
    sleep 0.2
  done
  [ -s "$result" ] || { echo "run $n never finished" >&2; "$E" shot "bench-stuck-$n" >&2; exit 1; }
  runs+=("$result")
  echo "run $n done"
done

# ------------------------------------------------------------ load test
# Four agents streaming at once with the rail open beside the chat: the
# steady-state cost of watching work happen.
load_result=""
if [ "$load" -gt 0 ]; then
  load_result="$out_dir/$label.load.json"
  rm -f "$load_result"
  "$E" stop
  PASEO_PERF=1 "$E" start "$fixture" || exit 1
  "$E" lua "dofile(\"$here/bench.lua\") and 1" >/dev/null
  "$E" keys ':Paseo chat' Enter
  "$E" wait 'require("paseo.ui.chat").current() ~= nil and require("paseo.ui.rail").win() ~= nil' 30 || exit 1
  sleep 2
  for k in 1 2 3 4; do
    "$D" paseo run --provider fake/scripted --cwd "$fixture" --no-wait --title "load $k" "long slow tool think $k" >/dev/null 2>&1 &
  done
  wait
  sleep 2
  "$E" lua "_G.paseo_bench.load(\"$load_result\", $load) or 1" >/dev/null
  for _ in $(seq 1 $((load * 5 + 100))); do
    [ -s "$load_result" ] && break
    sleep 0.2
  done
  # The load agents are noise for the next run's rail; archive them.
  for id in $("$D" paseo ls --json 2>/dev/null | python3 -I -c 'import json,sys; print(" ".join(a["id"] for a in json.load(sys.stdin) if a.get("name","").startswith("load ")))'); do
    "$D" paseo archive "$id" >/dev/null 2>&1 || true
  done
fi
"$E" stop

python3 -I "$repo_root/tests/bench/compare.py" --ui "$out_dir/$label.json" "${runs[@]}" ${load_result:+--load "$load_result"}
