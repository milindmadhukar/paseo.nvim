#!/usr/bin/env bun
/**
 * paseo-bridge — one WebSocket to the Paseo daemon, newline-delimited JSON to
 * Neovim over stdio.
 *
 * Why this exists rather than the CLI: `paseo … --json` boots Electron per
 * invocation and costs ~2.4 s. The WebSocket is ~1–10 ms. Nothing interactive
 * can be built on the former.
 *
 * Why this exists rather than raw WebSocket in Lua: the frame codec is the easy
 * part. The actual surface is subscriptions with server-issued IDs,
 * snapshot-then-update ordering, timeline epochs and cursors, `replacement`
 * invalidation and `subscription_restored` after reconnect. Reimplementing that
 * in Lua is where the integration rots.
 *
 * PROTOCOL
 *   in   {"id": <n>, "op": "<name>", ...args}     one JSON object per line
 *   out  {"id": <n>, "ok": true,  "result": ...}
 *        {"id": <n>, "ok": false, "error": "..."}
 *        {"event": "<name>", ...}                 unsolicited
 *
 * STDOUT IS THE PROTOCOL. Every diagnostic goes to stderr; a stray console.log
 * corrupts the stream and Lua sees a parse error rather than a reply.
 */

import {
  write,
  emit,
  log,
  bail,
  setShutdown,
  installExitHandlers,
  type Request,
  type Ops,
} from "./bridge-io.ts";
import { BridgeConnection, connectionOps } from "./bridge-connection.ts";
import { providerOps } from "./bridge-providers.ts";
import { agentOps } from "./bridge-agents.ts";
import { workspaceOps } from "./bridge-workspaces.ts";
import { timelineOps } from "./bridge-timeline.ts";
import { terminalOps } from "./bridge-terminals.ts";

const ctx = new BridgeConnection();
const ops: Ops = {
  ...connectionOps(ctx),
  ...providerOps(ctx),
  ...agentOps(ctx),
  ...workspaceOps(ctx),
  ...timelineOps(ctx),
  ...terminalOps(ctx),
};
setShutdown(() => ops.close({ op: "close" }));

async function dispatch(req: Request): Promise<void> {
  const op = ops[req.op];
  if (!op) {
    write({ id: req.id, ok: false, error: `unknown op: ${req.op}` });
    return;
  }
  try {
    write({ id: req.id, ok: true, result: await op(req) });
  } catch (error) {
    write({
      id: req.id,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/**
 * Ops run IN ORDER, on one chain.
 *
 * Dispatching each line as it arrived looked fine and was not: `connect`,
 * `providers` and `close` all started at once and `close` won, so the two reads
 * came back "Daemon client closed" against a daemon that was up. Anything
 * stateful -- and `connect` is the whole state -- needs the ordering the caller
 * already assumes it has.
 *
 * A turn can take ten minutes, so `agent.run` is released from the chain once
 * it reaches the front: it still cannot start before an earlier `connect`, but
 * it does not hold up everything behind it.
 */
const CONCURRENT = new Set(["agent.run"]);
let queue: Promise<void> = Promise.resolve();

function handle(line: string): void {
  let req: Request;
  try {
    req = JSON.parse(line);
  } catch (error) {
    emit("protocol_error", { error: String(error) });
    return;
  }

  queue = queue
    .then(async () => {
      if (CONCURRENT.has(req.op)) {
        void dispatch(req);
        return;
      }
      await dispatch(req);
    })
    // A REJECTED QUEUE IS A DEAF SIDECAR. `queue` is the chain every later
    // request is appended to, and once it rejects every `.then` after it is
    // skipped -- silently, and for the rest of the session. dispatch has its
    // own catch, so nothing is expected here; "nothing is expected" is exactly
    // the condition under which this was missing.
    .catch((error) => log("queue:", error));
}

// Line-buffered stdin. Chunks split anywhere, so a partial line is held over
// rather than parsed as truncated JSON.
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  buffer += chunk;
  let index: number;
  while ((index = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (line) handle(line);
  }
});
// Neovim went away, by every route the news can arrive on. bun fires 'end'
// and then 'close'; node fires only 'end'. A socketpair peer that dies hard
// delivers the news as an 'error' instead -- and an 'error' with no listener
// is an uncaughtException, which used to be the start of the loop.
//
// bail() is idempotent, so all of these are free. It releases the daemon's
// subscriptions on the way out, which is why this was never just an exit() --
// though unlike the old version it does not WAIT on the request queue to do
// it. A reply that would have come back against a closing client has nowhere
// to arrive: the editor that asked for it is already gone.
installExitHandlers();
emit("ready", { pid: process.pid });
