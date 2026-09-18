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

import { createPaseoClient } from "@getpaseo/client";

type Request = { id?: number; op: string; [key: string]: unknown };

let client: ReturnType<typeof createPaseoClient> | null = null;
const timelines = new Map<string, { release?: () => Promise<void> } & (() => void)>();
let directory: {
  subscription?: { release: () => Promise<void> };
  localUnsubscribe?: (() => void) | null;
} | null = null;

function write(payload: unknown): void {
  process.stdout.write(JSON.stringify(payload) + "\n");
}

function emit(event: string, extra: Record<string, unknown> = {}): void {
  write({ event, ...extra });
}

function log(...parts: unknown[]): void {
  process.stderr.write(parts.map(String).join(" ") + "\n");
}

function need<T>(value: T | null | undefined, what: string): T {
  if (value === null || value === undefined) throw new Error(`${what} is required`);
  return value;
}

function connected() {
  if (!client) throw new Error("not connected; send {op:'connect'} first");
  return client;
}

const ops: Record<string, (req: Request) => Promise<unknown>> = {
  async connect(req) {
    if (client) await client.close().catch(() => {});
    client = createPaseoClient({
      url: String(need(req.url, "url")),
      ...(req.password ? { password: String(req.password) } : {}),
    });
    await client.connect();
    return { connected: true };
  },

  async close() {
    if (directory) {
      const held = directory;
      directory = null;
      held.localUnsubscribe?.();
      await held.subscription?.release().catch(() => {});
    }
    for (const [, unsubscribe] of timelines) {
      try {
        await (unsubscribe.release?.() ?? unsubscribe());
      } catch {
        /* teardown is best-effort */
      }
    }
    timelines.clear();
    if (client) await client.close();
    client = null;
    return { closed: true };
  },

  /** Providers the daemon actually has, so the caller never hardcodes a model. */
  async providers() {
    const snapshot = await connected().providers.snapshot({});
    return {
      entries: (snapshot.entries ?? []).map((entry: any) => ({
        provider: entry.provider,
        status: entry.status,
        models: (entry.models ?? []).map((model: any) => ({
          id: model.id,
          isDefault: model.isDefault ?? false,
        })),
      })),
    };
  },

  async "agents.list"(req) {
    const page = await connected().agents.list({
      filter: { includeArchived: false },
      page: { limit: Number(req.limit ?? 100) },
    });
    const entries = page.entries.map(({ agent }: any) => ({
      id: agent.id,
      title: agent.title ?? null,
      status: agent.status ?? null,
      cwd: agent.cwd ?? null,
      workspaceId: agent.workspaceId ?? null,
      provider: agent.runtimeInfo?.provider ?? null,
      requiresAttention: (agent.pendingPermissions?.length ?? 0) > 0,
    }));
    return { entries: req.cwd ? entries.filter((e) => e.cwd === req.cwd) : entries };
  },

  /**
   * The agent for a directory: reuse the live one, else make it.
   *
   * Reuse matters more than it looks. Creating a fresh agent per question
   * throws away the context that makes the second question cheap, and leaves a
   * trail of one-shot sessions in the Paseo app.
   */
  async "agent.ensure"(req) {
    const api = connected();
    const cwd = String(need(req.cwd, "cwd"));

    const page = await api.agents.list({
      filter: { includeArchived: false },
      page: { limit: 100 },
    });
    const existing = page.entries.find(
      ({ agent }: any) => agent.cwd === cwd && agent.labels?.["paseo.nvim"] === "review",
    );
    if (existing) return { id: existing.agent.id, created: false };

    let provider = req.provider ? String(req.provider) : null;
    if (!provider) {
      // Ask the daemon rather than guessing: installed providers and configured
      // models differ between hosts, and a hardcoded model id fails at create().
      const snapshot = await api.providers.waitForReady({ cwd, timeoutMs: 30_000 });
      const entry = (snapshot.entries ?? []).find((e: any) => e.status === "ready");
      const model =
        entry?.models?.find((m: any) => m.isDefault) ?? entry?.models?.[0] ?? null;
      if (!entry || !model) throw new Error("no provider model is ready on this daemon");
      provider = `${entry.provider}/${model.id}`;
    }

    const agent = await api.agents.create({
      config: { provider },
      cwd,
      title: req.title ? String(req.title) : "paseo.nvim review",
      // Namespaced, per the SDK's own guidance: several tools may manage agents
      // on one daemon, and this is how we find ours again.
      labels: { "paseo.nvim": "review" },
    });
    return { id: agent.id, created: true, provider };
  },

  /**
   * Fire and forget. Resolves when the daemon accepts the prompt.
   *
   * `agentId`, never `id`: `id` is the protocol's request-correlation field and
   * the Lua client sets it last, so an agent passed as `id` is silently
   * replaced by the request number. The daemon then prefix-matched "4" against
   * every agent whose id starts with 4 and rejected it as ambiguous.
   */
  async "agent.send"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    await agent.send(String(need(req.prompt, "prompt")));
    return { sent: true };
  },

  /** Send and wait for the turn. */
  async "agent.run"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    const result = await agent.run(String(need(req.prompt, "prompt")), {
      timeoutMs: Number(req.timeoutMs ?? 10 * 60_000),
    });
    return {
      status: result.status,
      lastMessage: result.lastMessage ?? null,
      error: result.error ?? null,
    };
  },

  /**
   * Stream one agent's timeline.
   *
   * Assistant text arrives in PIECES, so the consumer concatenates. Turn
   * completion comes from `turn_completed`/`turn_failed`/`turn_canceled` and
   * never from a status transition to idle.
   */
  async "timeline.subscribe"(req) {
    const id = String(need(req.agentId, "agentId"));
    if (timelines.has(id)) return { subscribed: true, already: true };

    const agent = connected().agents.ref(id);
    const unsubscribe = agent.timeline.subscribe((update: any) => {
      const event = update?.event;
      if (!event) return;

      switch (event.type) {
        case "timeline":
          if (event.item?.type === "assistant_message") {
            emit("text", { agentId: id, text: event.item.text ?? "" });
          }
          break;
        case "turn_completed":
        case "turn_failed":
        case "turn_canceled":
          emit("turn", { agentId: id, outcome: event.type });
          break;
        case "subscription_restored":
          // Reconnected. Nothing is replayed; the consumer decides whether to
          // ask for history.
          emit("restored", { agentId: id });
          break;
        case "replacement":
          // The previous epoch is invalid; anything already rendered is stale.
          emit("replaced", { agentId: id });
          break;
        case "error":
          emit("stream_error", { agentId: id, error: String(event.error ?? "") });
          break;
      }
    });

    timelines.set(id, unsubscribe as any);
    await (unsubscribe as any).ready;
    return { subscribed: true };
  },

  /**
   * Follow the agent directory and push every change.
   *
   * This is what makes the workspace picker's status column live rather than
   * polled -- at 2.4s per CLI call a polled column is unobtainable, and that
   * column is the entire reason for the sidecar.
   *
   * The snapshot is delivered BEFORE updates, so the consumer renders from it
   * and then applies upserts and removes. On reconnect the subscription gets a
   * new ID and a new snapshot; nothing is replayed.
   */
  async "agents.subscribe"() {
    if (directory) return { subscribed: true, already: true };

    const api = connected();
    const describe = (agent: any) => ({
      id: agent.id,
      title: agent.title ?? null,
      status: agent.status ?? null,
      cwd: agent.cwd ?? null,
      workspaceId: agent.workspaceId ?? null,
      provider: agent.runtimeInfo?.provider ?? null,
      requiresAttention: (agent.pendingPermissions?.length ?? 0) > 0,
    });

    const applyUpdate = (message: any) => {
      // Both shapes reach here: the wire message, and the bare update the
      // local listener is handed.
      const payload = message?.type === "agent_update" ? message.payload : message;
      if (!payload?.kind) return;
      if (payload.kind === "upsert") {
        emit("agents", { kind: "upsert", agent: describe(payload.agent) });
      } else if (payload.kind === "remove") {
        emit("agents", { kind: "remove", id: payload.agentId });
      }
    };

    // TWO SDK GENERATIONS, and the installed one is the older.
    //
    // 0.9+ returns an owned `subscription` from list({ subscribe: {} }) whose
    // snapshot callback fires before updates. 0.8 has no such object:
    // `agents.subscribe(handler)` registers a LOCAL listener and the list call
    // is what asks the daemon to start streaming. Writing only the documented
    // 0.9 form failed at runtime with "undefined is not an object
    // (evaluating 'result.subscription.subscribe')", so both are handled and
    // the difference is confined here.
    let localUnsubscribe: (() => void) | null = null;
    if (typeof (api.agents as any).subscribe === "function") {
      localUnsubscribe = (api.agents as any).subscribe(applyUpdate);
    }

    const result: any = await api.agents.list({
      filter: { includeArchived: false },
      subscribe: {},
    });

    if (result?.subscription?.subscribe) {
      // 0.9+: the owned subscription supersedes the local listener, and
      // delivers its own snapshot first.
      localUnsubscribe?.();
      localUnsubscribe = null;
      result.subscription.subscribe({
        snapshot: ({ entries }: any) =>
          emit("agents", { kind: "snapshot", entries: entries.map((e: any) => describe(e.agent)) }),
        update: applyUpdate,
        error: (error: unknown) => emit("agents", { kind: "error", error: String(error) }),
      });
    } else {
      // 0.8: the list result IS the snapshot.
      emit("agents", {
        kind: "snapshot",
        entries: (result.entries ?? []).map((e: any) => describe(e.agent)),
      });
    }

    directory = { subscription: result?.subscription, localUnsubscribe };
    return { subscribed: true, subscriptionId: result?.subscriptionId ?? null };
  },

  async "agents.unsubscribe"() {
    if (!directory) return { unsubscribed: false };
    const held = directory;
    directory = null;
    held.localUnsubscribe?.();
    await held.subscription?.release();
    return { unsubscribed: true };
  },

  /** Archive an agent. Only ever our own -- see the label filter in ensure. */
  async "agent.archive"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    const result = await agent.archive();
    return { archivedAt: result?.archivedAt ?? null };
  },

  async "timeline.unsubscribe"(req) {
    const id = String(need(req.agentId, "agentId"));
    const unsubscribe = timelines.get(id);
    if (!unsubscribe) return { unsubscribed: false };
    timelines.delete(id);
    await ((unsubscribe as any).release?.() ?? unsubscribe());
    return { unsubscribed: true };
  },
};

async function dispatch(req: Request): Promise<void> {
  const op = ops[req.op];
  if (!op) {
    write({ id: req.id, ok: false, error: `unknown op: ${req.op}` });
    return;
  }
  try {
    write({ id: req.id, ok: true, result: await op(req) });
  } catch (error) {
    write({ id: req.id, ok: false, error: error instanceof Error ? error.message : String(error) });
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

  queue = queue.then(async () => {
    if (CONCURRENT.has(req.op)) {
      void dispatch(req);
      return;
    }
    await dispatch(req);
  });
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
// End of stdin means Neovim went away. Drain the queue FIRST: exiting straight
// into close() killed the process while `connect` was still in flight, and
// every queued read came back against a client that no longer existed --
// which looked exactly like a daemon that was down.
process.stdin.on("end", () => {
  queue = queue
    .then(() => ops.close({ op: "close" }))
    .catch(() => {})
    .finally(() => process.exit(0));
});

process.on("uncaughtException", (error) => {
  log("uncaught:", error);
  emit("protocol_error", { error: String(error) });
});

emit("ready", { pid: process.pid });
