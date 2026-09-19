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

import { createPaseoApi } from "@getpaseo/client";
// DaemonClient is not on the package root -- only the typed API is. It lives on
// the `internal/` subpath, which is where the setters this needs live too.
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";

type Request = { id?: number; op: string; [key: string]: unknown };

// TWO HANDLES ON ONE CONNECTION.
//
// The typed API (`createPaseoApi`) is the documented surface and covers almost
// everything. But changing a running agent's mode, thinking level, model or
// feature toggles is not on it -- `availableModes` and `features` are readonly
// there -- and those live on the raw DaemonClient as setAgentMode,
// setAgentThinkingOption, setAgentModel and setAgentFeature. Building the API
// from an explicit DaemonClient keeps both on one socket instead of opening a
// second connection for four calls.
let daemon: DaemonClient | null = null;
let client: ReturnType<typeof createPaseoApi> | null = null;
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

function raw() {
  if (!daemon) throw new Error("not connected; send {op:'connect'} first");
  return daemon;
}

/**
 * Images carried with a prompt.
 *
 * The daemon takes BARE base64 plus a mimeType beside it, not a data URL --
 * and a data URL is exactly what anything else that handles images hands you,
 * so one is unwrapped here rather than at every call site.
 *
 * Returns undefined for "no images", so the caller can leave the field off the
 * request entirely: an empty array is still an array on the wire.
 */
function pictures(req: Request): Array<{ data: string; mimeType: string }> | undefined {
  const given = req.images;
  if (!Array.isArray(given) || given.length === 0) return undefined;
  return given.map((image: any, index: number) => {
    const data = String(need(image?.data, `images[${index}].data`));
    const url = /^data:([^;,]+);base64,(.*)$/s.exec(data);
    if (url) return { data: url[2]!, mimeType: url[1]! };
    return { data, mimeType: String(need(image?.mimeType, `images[${index}].mimeType`)) };
  });
}

const ops: Record<string, (req: Request) => Promise<unknown>> = {
  async connect(req) {
    if (daemon) await daemon.close().catch(() => {});
    daemon = new DaemonClient({
      url: String(need(req.url, "url")),
      clientId: `paseo.nvim-${process.pid}`,
      clientType: "cli",
      ...(req.password ? { password: String(req.password) } : {}),
    });
    await daemon.connect();
    client = createPaseoApi(daemon);
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
    if (daemon) await daemon.close();
    daemon = null;
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
    const images = pictures(req);
    await agent.send(String(need(req.prompt, "prompt")), images ? { images } : undefined);
    return { sent: true, images: images?.length ?? 0 };
  },

  /** Send and wait for the turn. */
  async "agent.run"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    const images = pictures(req);
    const result = await agent.run(String(need(req.prompt, "prompt")), {
      timeoutMs: Number(req.timeoutMs ?? 10 * 60_000),
      ...(images ? { images } : {}),
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

      // seq and epoch live on the UPDATE, not the event. They are what lets a
      // consumer tell a live message apart from the same message arriving in a
      // history fetch -- without them the two race and the message renders
      // twice.
      const at = { seq: update.seq ?? null, epoch: update.epoch ?? null };

      switch (event.type) {
        case "timeline":
          if (event.item?.type === "assistant_message") {
            emit("text", { agentId: id, text: event.item.text ?? "", ...at });
          } else if (event.item?.type === "user_message") {
            // TWO-WAY SYNC. The timeline carries user messages too, whoever
            // typed them -- the Paseo app, another client, or us. Dropping
            // them meant a prompt typed in the desktop never appeared here and
            // the conversation silently diverged.
            emit("user", { agentId: id, text: event.item.text ?? "", ...at });
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

  /**
   * Register an assembled directory as an ordinary LOCAL workspace.
   *
   * THE SEAM. `ws` builds a composite directory -- N worktrees plus the
   * untracked context they need -- and this hands it to the daemon as a plain
   * local workspace. Paseo never learns it is looking at six worktrees; it sees
   * a directory with agents in it. That is what makes a multi-repo project work
   * at all, since Paseo's own worktree isolation requires a git repository and
   * a project like ~/Code/openfin is a plain directory holding six of them.
   *
   * It lives here rather than in `ws` because the `paseo` CLI is the Electron
   * desktop binary: every invocation opens a window on the user's desktop and
   * writes startup logs to stdout, mixed into its own --json output.
   *
   * `open()` reuses the active workspace for that exact directory, so calling
   * this twice does not litter the app with duplicates.
   */
  async "workspace.open"(req) {
    const workspace = await connected().workspaces.open(String(need(req.cwd, "cwd")));
    return {
      id: workspace.id,
      directory: (workspace as any).directory ?? null,
      projectId: (workspace as any).projectId ?? null,
    };
  },

  /**
   * Paseo's workspaces -- the SOURCE OF TRUTH for what workspaces exist.
   *
   * A workspace made in the Paseo app, or by `paseo workspace create`, is just
   * as real as one this plugin assembled. Listing only our own registry meant
   * half of them were invisible.
   */
  async "workspaces.list"(req) {
    const page: any = await connected().workspaces.list({
      ...(req.query ? { filter: { query: String(req.query) } } : {}),
      page: { limit: Number(req.limit ?? 200) },
    });
    // Field names taken from the wire, not guessed: the directory is
    // `workspaceDirectory`, and `directory` does not exist.
    return {
      entries: (page.entries ?? []).map((ws: any) => ({
        id: ws.id,
        name: ws.name ?? ws.title ?? null,
        directory: ws.workspaceDirectory ?? ws.project?.checkout?.cwd ?? null,
        project: ws.projectDisplayName ?? ws.projectId ?? null,
        projectRoot: ws.projectRootPath ?? null,
        projectKind: ws.projectKind ?? null,
        kind: ws.workspaceKind ?? null,
        status: ws.status ?? null,
        branch: ws.project?.checkout?.currentBranch ?? null,
        // Whether PASEO owns the worktree, as opposed to it pointing at a
        // primary checkout -- the difference between isolated and not.
        ownedWorktree: ws.project?.checkout?.isPaseoOwnedWorktree ?? false,
        archivingAt: ws.archivingAt ?? null,
      })),
    };
  },

  /**
   * A FRESH workspace, as opposed to `workspace.open` which reuses the active
   * one for a directory.
   *
   * `source.kind` is "directory" for an existing checkout, or "worktree" to let
   * Paseo cut one. Worktree isolation requires a git repository -- a project
   * that is a plain directory holding several repos cannot use it, which is
   * what the assembly layer is for.
   */
  async "workspace.create"(req) {
    const source: any = req.worktree
      ? {
          kind: "worktree",
          cwd: String(need(req.cwd, "cwd")),
          action: "branch-off",
          refName: String(req.base ?? "main"),
          branchName: String(need(req.branch, "branch")),
        }
      : { kind: "directory", path: String(need(req.cwd, "cwd")) };

    const workspace: any = await connected().workspaces.create({
      source,
      ...(req.title ? { title: String(req.title) } : {}),
    });
    return {
      id: workspace.id,
      directory: workspace.directory ?? null,
      projectId: workspace.projectId ?? null,
    };
  },

  /**
   * A new SESSION in a workspace.
   *
   * Created through the workspace handle, so placement comes from the handle
   * rather than being repeated -- the SDK is explicit that this avoids
   * mismatched cwd/workspace arguments.
   */
  async "agent.create"(req) {
    const api = connected();
    const workspace: any = api.workspaces.ref(String(need(req.workspaceId, "workspaceId")));

    let provider = req.provider ? String(req.provider) : null;
    if (!provider) {
      const snapshot: any = await api.providers.waitForReady({ timeoutMs: 30_000 });
      const entry = (snapshot.entries ?? []).find((e: any) => e.status === "ready");
      const model = entry?.models?.find((m: any) => m.isDefault) ?? entry?.models?.[0] ?? null;
      if (!entry || !model) throw new Error("no provider model is ready on this daemon");
      provider = `${entry.provider}/${model.id}`;
    }

    const agent = await workspace.agents.create({
      config: { provider },
      ...(req.title ? { title: String(req.title) } : {}),
      ...(req.prompt ? { prompt: String(req.prompt) } : {}),
      labels: { "paseo.nvim": "session" },
    });
    return { id: agent.id, provider };
  },

  async "workspace.archive"(req) {
    const workspace = connected().workspaces.ref(String(need(req.workspaceId, "workspaceId")));
    const result = await workspace.archive();
    return { archivedAt: (result as any)?.archivedAt ?? null };
  },

  /** Archive an agent. Only ever our own -- see the label filter in ensure. */
  async "agent.archive"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    const result = await agent.archive();
    return { archivedAt: result?.archivedAt ?? null };
  },

  /**
   * A page of an agent's timeline.
   *
   * What makes a chat window a CONVERSATION rather than a transcript of
   * whatever happened while it was open: reopening a chat shows what was said
   * before, including from a previous Neovim session, because the agent lives
   * on the daemon and outlives the editor.
   *
   * Paging uses the returned cursors rather than invented offsets.
   */
  async "timeline.history"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    const page: any = await agent.timeline.refetch({
      direction: (req.direction as any) ?? "before",
      limit: Number(req.limit ?? 100),
      ...(req.cursor ? { cursor: req.cursor as any } : {}),
    });

    // Only the two kinds a chat window renders. Tool calls and internal
    // bookkeeping belong in the Paseo app, not here.
    //
    // Consecutive assistant items are MERGED: a reply is streamed as many
    // timeline items, one per chunk, so rendering them separately turns one
    // answer into a dozen "### agent" blocks.
    const items: { role: string; text: string }[] = [];
    for (const entry of page.entries ?? []) {
      const item = entry.item ?? {};
      const role =
        item.type === "assistant_message" ? "assistant" : item.type === "user_message" ? "user" : null;
      if (!role) continue;
      const last = items[items.length - 1];
      if (last && last.role === role && role === "assistant") {
        last.text += item.text ?? "";
      } else {
        items.push({ role, text: item.text ?? "" });
      }
    }

    return {
      items,
      hasOlder: page.hasOlder ?? false,
      hasNewer: page.hasNewer ?? false,
      startCursor: page.startCursor ?? null,
      endCursor: page.endCursor ?? null,
      epoch: page.epoch ?? null,
    };
  },

  /**
   * Everything adjustable about a running session, in one read.
   *
   * Modes are per PROVIDER (claude has plan/default/acceptEdits/auto/
   * bypassPermissions; codex has auto/auto-review/full-access). Thinking
   * options are per MODEL, not per provider -- they hang off the model entry
   * with its own default. Features are per AGENT and carry their current value;
   * `fast_mode` is the lightning bolt.
   */
  async "agent.config"(req) {
    const api = connected();
    const agent: any = api.agents.ref(String(need(req.agentId, "agentId")));
    await agent.refresh();
    const snap: any = agent.current();
    const runtime = snap?.runtimeInfo ?? {};

    // The model entry owns the thinking options, so the provider catalogue has
    // to be consulted for them -- the agent snapshot does not carry the list.
    let thinkingOptions: any[] = [];
    let models: any[] = [];
    try {
      const catalogue: any = await api.providers.snapshot({});
      const entry = (catalogue.entries ?? []).find((e: any) => e.provider === runtime.provider);
      models = (entry?.models ?? []).map((m: any) => ({ id: m.id, label: m.label, isDefault: !!m.isDefault }));
      const model = (entry?.models ?? []).find((m: any) => m.id === runtime.model);
      thinkingOptions = (model?.thinkingOptions ?? []).map((t: any) => ({
        id: t.id,
        label: t.label,
        isDefault: !!t.isDefault,
      }));
    } catch {
      /* the catalogue is a nicety; the modes and features below are not */
    }

    return {
      provider: runtime.provider ?? null,
      model: runtime.model ?? null,
      modeId: runtime.modeId ?? runtime.mode ?? null,
      thinkingOptionId: runtime.thinkingOptionId ?? null,
      availableModes: (snap?.availableModes ?? []).map((m: any) => ({
        id: m.id,
        label: m.label,
        description: m.description ?? null,
      })),
      thinkingOptions,
      models,
      features: (snap?.features ?? []).map((f: any) => ({
        id: f.id,
        type: f.type,
        label: f.label,
        description: f.description ?? null,
        value: f.value,
      })),
    };
  },

  async "agent.setMode"(req) {
    const notice = await raw().setAgentMode(
      String(need(req.agentId, "agentId")),
      String(need(req.modeId, "modeId")),
    );
    // A provider may accept the change and still have something to say about
    // it -- pass that through rather than swallowing it.
    return { modeId: req.modeId, notice: notice ?? null };
  },

  async "agent.setThinking"(req) {
    const notice = await raw().setAgentThinkingOption(
      String(need(req.agentId, "agentId")),
      req.thinkingOptionId === null ? null : String(req.thinkingOptionId),
    );
    return { thinkingOptionId: req.thinkingOptionId ?? null, notice: notice ?? null };
  },

  async "agent.setFeature"(req) {
    await raw().setAgentFeature(
      String(need(req.agentId, "agentId")),
      String(need(req.featureId, "featureId")),
      req.value,
    );
    return { featureId: req.featureId, value: req.value };
  },

  async "agent.setModel"(req) {
    await raw().setAgentModel(
      String(need(req.agentId, "agentId")),
      req.modelId === null ? null : String(req.modelId),
    );
    return { modelId: req.modelId ?? null };
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
