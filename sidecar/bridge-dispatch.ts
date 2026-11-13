/**
 * The order requests run in.
 *
 * IT USED TO BE ONE CHAIN: every op waited for every op before it. That made
 * `connect` safely first -- the reason it was done -- and it also put a
 * `providers` call, which waits up to fifteen seconds for a directory's
 * discovery, in front of the conversation you had just opened, the keys you
 * were typing into a terminal, and the permission you were answering.
 *
 * Now there are three rules, and only three, because they are the orderings
 * a caller actually relies on:
 *
 *  1. `connect` and `close` are BARRIERS. Each waits for what was already
 *     running, and everything after it waits for it. "connect, providers,
 *     close all started at once and close won" stays impossible.
 *  2. Requests about the same THING keep their order: one terminal's input
 *     and resizes, one agent's subscribe and history and sends, one
 *     dictation stream's chunks. That is a LANE, keyed by the id the request
 *     names.
 *  3. Everything else runs at once.
 *
 * `agent.run` (a turn, which can take ten minutes) and the dictation stream's
 * chunks and finish are released the moment the barrier allows, as before:
 * they are neither waited for by a later barrier nor held behind an earlier
 * request in their lane.
 */

import type { Request } from "./bridge-io.ts";

/** Released at once, never waited on: see the module comment. */
export const IMMEDIATE = new Set([
  "agent.run",
  "dictation.chunk",
  "dictation.finish",
]);

export const BARRIERS = new Set(["connect", "close"]);

/**
 * Ops that may CREATE a workspace for a directory: each looks for one first
 * and makes it if there is none, so two at once on the same directory would
 * both find none and make two. One at a time per directory.
 */
const MAKES_WORKSPACES = new Set([
  "workspace.open",
  "workspace.create",
  "agent.start",
  "agent.create",
  "agent.ensure",
]);

/** The thing a request is about, if it names one. */
export function laneOf(req: Request): string | null {
  if (req.terminalId != null) return `terminal:${String(req.terminalId)}`;
  if (req.agentId != null) return `agent:${String(req.agentId)}`;
  if (req.dictationId != null) return `dictation:${String(req.dictationId)}`;
  if (MAKES_WORKSPACES.has(req.op) && req.cwd != null)
    return `cwd:${String(req.cwd)}`;
  return null;
}

export type Run = (req: Request, arrived: number) => Promise<void>;

/**
 * Build the scheduler around `run`, which must not reject (dispatch has its
 * own catch). Returns the function each parsed request is handed to.
 */
export function createScheduler(
  run: Run,
  onError: (error: unknown) => void = () => {},
  now: () => number = () => performance.now(),
): (req: Request) => Promise<void> {
  let barrier: Promise<void> = Promise.resolve();
  const inflight = new Set<Promise<void>>();
  const lanes = new Map<string, Promise<void>>();

  // A REJECTED CHAIN IS A DEAF SIDECAR: everything appended to it is skipped,
  // silently, for the rest of the session. `run` is not expected to reject;
  // "not expected" is exactly when this was missing.
  const safely = (req: Request, arrived: number) =>
    run(req, arrived).catch(onError);

  return function schedule(req: Request): Promise<void> {
    const arrived = now();

    if (BARRIERS.has(req.op)) {
      const pending = [...inflight];
      const done = barrier
        .then(() => Promise.allSettled(pending))
        .then(() => safely(req, arrived));
      barrier = done;
      return done;
    }

    if (IMMEDIATE.has(req.op)) {
      // Started in arrival order -- `then` callbacks run in the order they
      // were added -- which is what keeps a dictation stream's chunks in
      // sequence without making each wait for the last one's reply.
      return barrier.then(() => {
        void safely(req, arrived);
      });
    }

    const lane = laneOf(req);
    const before = lane ? lanes.get(lane) : undefined;
    const gate = before ? Promise.all([barrier, before]) : barrier;
    const job = gate.then(() => safely(req, arrived));
    inflight.add(job);
    if (lane) lanes.set(lane, job);
    void job.finally(() => {
      inflight.delete(job);
      if (lane && lanes.get(lane) === job) lanes.delete(lane);
    });
    return job;
  };
}
