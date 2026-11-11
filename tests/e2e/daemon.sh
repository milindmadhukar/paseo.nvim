#!/usr/bin/env bash
# A throwaway Paseo daemon for end-to-end checks.
#
#   tests/e2e/daemon.sh start    start one, print its env (idempotent)
#   tests/e2e/daemon.sh env      print PASEO_E2E_* for `eval`
#   tests/e2e/daemon.sh stop     stop the one THIS script started
#   tests/e2e/daemon.sh paseo …  run the paseo CLI against it
#
# NEVER the live daemon. Everything lives under $PASEO_E2E_ROOT (default
# $TMPDIR/paseo-e2e): its own PASEO_HOME, its own port, relay off. The pid it
# records is the pid it spawned, and `stop` signals that pid and nothing else --
# a pattern kill here once took down the real daemon.
#
# The provider the scenarios use is `fake`: tests/e2e/fake-acp.mjs, a scripted
# ACP agent that streams reasoning, a tool call and an answer with no model
# behind it and no cost. (Paseo's own dev `mock` provider is stripped from the
# packaged daemon, so PASEO_NODE_ENV cannot reach it.) Real providers still
# work here too, for the one check that needs a model: workspace title
# generation. Those are billed like any other session.
set -euo pipefail

root="${PASEO_E2E_ROOT:-${TMPDIR:-$HOME/.cache/claude/tmp}/paseo-e2e}"
home="$root/.paseo"
port="${PASEO_E2E_PORT:-6797}"
pidfile="$root/daemon.pid"
log="$root/daemon.out"
bin="${PASEO_BIN:-paseo}"

running() {
  [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

print_env() {
  echo "export PASEO_E2E_ROOT='$root'"
  echo "export PASEO_E2E_HOME='$home'"
  echo "export PASEO_E2E_PORT='$port'"
  echo "export PASEO_E2E_URL='ws://127.0.0.1:$port/ws'"
}

ready() {
  # The daemon answers HTTP on the same port the WebSocket lives on.
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/" 2>/dev/null
}

case "${1:-}" in
  start)
    mkdir -p "$home"
    # The scripted ACP agent in this directory is the provider the scenarios
    # drive. Rewritten every start so a moved checkout cannot leave a stale
    # path behind.
    here="$(cd "$(dirname "$0")" && pwd)"
    cat >"$home/config.json" <<JSON
{
  "version": 1,
  "agents": {
    "providers": {
      "fake": {
        "extends": "acp",
        "label": "Fake (e2e)",
        "command": ["node", "$here/fake-acp.mjs"],
        "options": { "supportsMcpServers": false }
      }
    }
  }
}
JSON
    # The project the scenarios open: one commit, one README, on `main`. The
    # same fixture convention as tests/fixtures.sh -- nobody's work, unsigned.
    fixture="$root/repo"
    if [ ! -d "$fixture/.git" ]; then
      mkdir -p "$fixture"
      git -C "$fixture" init -q -b main
      echo "# fixture" >"$fixture/README.md"
      git -C "$fixture" add README.md
      git -C "$fixture" -c user.name="paseo tests" -c user.email=tests@paseo.invalid \
        -c commit.gpgsign=false commit -qm init
    fi
    if running; then
      print_env
      exit 0
    fi
    if ready; then
      echo "port $port is taken by something this script did not start" >&2
      exit 1
    fi
    PASEO_HOME="$home" \
      PASEO_LISTEN="127.0.0.1:$port" \
      PASEO_RELAY_ENABLED=false \
      PASEO_WEB_UI_ENABLED=false \
      setsid "$bin" daemon run --home "$home" >"$log" 2>&1 </dev/null &
    echo $! >"$pidfile"
    for _ in $(seq 1 120); do
      if ready; then
        print_env
        exit 0
      fi
      if ! running; then
        echo "daemon exited during startup; see $log" >&2
        tail -20 "$log" >&2
        exit 1
      fi
      sleep 0.5
    done
    echo "daemon did not become ready in 60s; see $log" >&2
    exit 1
    ;;
  env)
    print_env
    ;;
  stop)
    if running; then
      pid="$(cat "$pidfile")"
      # The process GROUP setsid made -- the supervisor and its worker -- and
      # only that group.
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
      for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
    fi
    rm -f "$pidfile"
    ;;
  paseo)
    shift
    exec "$bin" --host "127.0.0.1:$port" "$@"
    ;;
  *)
    sed -n '2,7p' "$0" >&2
    exit 2
    ;;
esac
