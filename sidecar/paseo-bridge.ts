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

import { resolve } from "node:path";

import { createPaseoApi } from "@getpaseo/client";
// DaemonClient is not on the package root -- only the typed API is. It lives on
// the `internal/` subpath, which is where the setters this needs live too.
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
// The daemon's OWN formatter for a tool call. Every provider names its tools
// differently -- Bash/shell/run_command, Read/read_file/view -- and the rules
// for turning one into "Bash · rg foo src/" already exist here. Reimplementing
// them in Lua would be wrong on the next provider, which is the same reason
// modes and thinking levels are discovered rather than hardcoded.
import { buildToolCallDisplayModel } from "@getpaseo/protocol/tool-call-display";

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

// THE PIPE OUTLIVES NOTHING. When Neovim goes, so does this.
//
// A write to a dead pipe does not throw: it returns false and comes back later
// as an uncaughtException with code EPIPE -- in bun AND in node. The handler at
// the bottom of this file answered that by writing again, which failed the same
// way, which called the handler again. Sixteen orphaned sidecars sat at 90% of
// a core for a day each on that loop: 202 MILLION write(2) calls that moved
// 1153 bytes between them.
//
// `broken` is what breaks the cycle, and the 'error' listeners below are what
// set it -- the try/catch in write() only ever catches ERR_STREAM_DESTROYED,
// which is the one that throws synchronously.
let broken = false;
// Stderr is diagnostics, and it can fail on its own without the protocol being
// affected. Tracked separately so a closed fd 2 costs the logs and not the
// session.
let quiet = false;

/** The stream is gone, as opposed to merely unhappy. */
function isGone(error: any): boolean {
  const code = error?.code;
  return code === "EPIPE" || code === "ERR_STREAM_DESTROYED" || code === "EBADF";
}

/** Nothing can be said any more. Say nothing, and leave. */
function severed(): void {
  broken = true;
  bail(0);
}

// Registered before the first write, because an 'error' event with no listener
// is itself rethrown as an uncaughtException -- which is the loop again.
process.stdout.on("error", (error) => (isGone(error) ? severed() : void (broken = true)));
// Never log() from here: the log goes to the stream that just failed.
process.stderr.on("error", () => void (quiet = true));

function write(payload: unknown): void {
  if (broken) return;
  let line: string;
  try {
    line = JSON.stringify(payload) + "\n";
  } catch {
    // A payload that will not serialise is a DROPPED MESSAGE, never a crash:
    // this runs inside SDK subscription callbacks, where a throw escapes into
    // the daemon client's dispatcher rather than into any of our own handlers.
    return;
  }
  try {
    process.stdout.write(line);
  } catch (error) {
    if (isGone(error)) return severed();
    broken = true;
  }
}

function emit(event: string, extra: Record<string, unknown> = {}): void {
  write({ event, ...extra });
}

function log(...parts: unknown[]): void {
  if (quiet) return;
  try {
    process.stderr.write(parts.map(String).join(" ") + "\n");
  } catch {
    quiet = true;
  }
}

/**
 * THE ONLY WAY OUT, and it is not optional.
 *
 * Two things have to be true at once. Teardown must be ATTEMPTED, because a
 * timeline subscription left dangling is a leak on the daemon's side of the
 * socket. And teardown must not be ABLE to keep this process alive, because it
 * demonstrably can: `ops.close` awaits subscription releases and
 * `daemon.close()`, none of which is bounded, and a sidecar parked in one of
 * those is a sidecar that never exits.
 *
 * So the watchdog is armed first and never disarmed, and teardown is RACED
 * against it rather than awaited. On bun the watchdog is the thing that
 * actually fires -- bun delivers stdin EOF before the stdout error, so the
 * write that would have reached severed() never happens. Do not delete it
 * because node happens to exit in 17ms without it.
 *
 * ops.close is called DIRECTLY rather than queued. The queue is precisely what
 * can be head-of-line blocked -- `providers.waitForReady` sits on it for up to
 * 30 seconds -- and routing shutdown through it is why these processes lived
 * long enough to matter.
 */
let bailing = false;

function bail(code: number): void {
  if (bailing) return;
  bailing = true;

  setTimeout(() => process.exit(code), 2_000).unref();

  void Promise.resolve()
    .then(() => ops.close({ op: "close" }))
    .catch(() => {})
    .finally(() => {
      if (broken) return process.exit(code);
      // process.exit() TRUNCATES buffered stdout at the pipe buffer -- 65536 of
      // 200001 bytes, in both runtimes -- and a timeline.history reply is
      // routinely larger than that. On the graceful path let the loop drain and
      // exit on its own; the watchdog above is still armed if it will not.
      process.exitCode = code;
      try {
        process.stdin.pause();
      } catch {
        /* already gone */
      }
    });
}

function need<T>(value: T | null | undefined, what: string): T {
  if (value === null || value === undefined) throw new Error(`${what} is required`);
  return value;
}

/**
 * A daemon-driven callback that cannot take the process with it.
 *
 * Everything inside `dispatch` gets its throw turned into an error reply. These
 * do not: they run inside the SDK's own event dispatcher, so a throw is an
 * uncaughtException instead -- and the shape of a daemon event is whatever the
 * daemon's version says it is, not what this file assumes. A single `upsert`
 * that arrives without an `agent` should cost one dropped update, not the
 * session.
 */
function guarded<T>(what: string, handler: (value: T) => void): (value: T) => void {
  return (value: T) => {
    try {
      handler(value);
    } catch (error) {
      log(`${what} handler:`, error);
    }
  };
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

/**
 * A permission request with buttons GUARANTEED to exist.
 *
 * `actions` is optional in the protocol, and a provider that omits it means
 * plain allow/deny. Synthesising them here rather than in Lua keeps the dialog
 * to one code path -- it renders `request.actions` and never asks whether they
 * are real.
 *
 * The synthetic ones are MARKED, because their ids are ours, not the
 * provider's. Sending an invented `selectedActionId` back is rejected, so
 * `agent.respondToPermission` strips it when the flag is set.
 */
function withFallbackActions(request: any): any {
  if (Array.isArray(request?.actions) && request.actions.length > 0) return request;
  return {
    ...request,
    actions: [
      { id: "__allow", label: "Allow", behavior: "allow", variant: "primary", synthetic: true },
      { id: "__deny", label: "Deny", behavior: "deny", variant: "secondary", synthetic: true },
    ],
  };
}

/**
 * ONE timeline item, flattened for Lua. Used by BOTH the live subscription and
 * the history fetch, so a reply looks the same whether it just arrived or was
 * loaded from the daemon on open.
 *
 * This used to forward only assistant_message and user_message, and the comment
 * here said tool calls "belong in the Paseo app, not here". That was the whole
 * bug: the agent reading a file, running a command or thinking never reached
 * Neovim, so the window showed a long silence and then an answer.
 *
 * `kind` is the event name the Lua listens on. Returning null means the item is
 * bookkeeping with nothing to render -- plugin items, for now.
 */
function describeItem(item: any, cwd?: string): { kind: string; [key: string]: unknown } | null {
  switch (item?.type) {
    case "assistant_message":
      return { kind: "text", text: item.text ?? "" };

    case "user_message":
      // TWO-WAY SYNC. The timeline carries user messages too, whoever typed
      // them -- the Paseo app, another client, or us.
      return { kind: "user", text: item.text ?? "" };

    case "reasoning":
      return { kind: "thinking", text: item.text ?? "" };

    case "tool_call": {
      // `display` is precomputed here so the Lua never has to know that a
      // "shell" detail keys its command as `command` and a "read" keys its path
      // as `filePath`. The renderer still gets the raw `detail` for the
      // expanded body.
      let display: unknown = null;
      try {
        display = buildToolCallDisplayModel({
          name: item.name,
          status: item.status,
          error: item.error,
          metadata: item.metadata,
          detail: item.detail,
          ...(cwd ? { cwd } : {}),
        });
      } catch {
        // A provider shape the installed SDK does not know is not a reason to
        // drop the card -- the Lua falls back to the bare tool name.
      }
      return {
        kind: "tool",
        callId: item.callId,
        name: item.name,
        status: item.status ?? "running",
        error: item.error == null ? null : String(item.error),
        display,
        detail: item.detail ?? null,
      };
    }

    case "todo":
      return {
        kind: "todo",
        items: (item.items ?? []).map((task: any) => ({
          text: task.text ?? "",
          status: task.status ?? (task.completed ? "completed" : "pending"),
        })),
      };

    case "error":
      return { kind: "notice", level: "error", message: item.message ?? "" };

    case "notification":
      return { kind: "notice", level: item.level ?? "info", message: item.message ?? "" };

    case "compaction":
      return {
        kind: "compaction",
        status: item.status ?? "loading",
        trigger: item.trigger ?? null,
        preTokens: item.preTokens ?? null,
      };

    default:
      return null;
  }
}

/** Trailing slashes and `..` segments, so two spellings of one path compare equal. */
function canonical(path: string): string {
  return resolve(path).replace(/\/+$/, "") || "/";
}

/**
 * The workspace handle covering `cwd` -- the EXISTING one wherever there is
 * one.
 *
 * Agents must be created through a workspace handle rather than by cwd, or the
 * daemon provisions a workspace for the directory it was handed. That is right
 * for a directory Paseo has never seen and badly wrong for one it already
 * owns: a Paseo-cut worktree gets registered a second time, as its own project,
 * because the worktree directory is itself a git repository.
 *
 * `workspaces.open()` is the fallback and not the first move: it is only
 * reached when nothing covers the directory, which is the case where
 * registering something new is what was actually wanted.
 */
async function workspaceFor(cwd: string): Promise<any> {
  const api = connected();
  const want = canonical(cwd);

  const page: any = await api.workspaces.list({ page: { limit: 200 } });
  const owner = (page.entries ?? []).find((ws: any) => {
    if (ws.archivingAt) return false;
    const dir = ws.workspaceDirectory ?? ws.project?.checkout?.cwd ?? null;
    return dir ? canonical(String(dir)) === want : false;
  });

  return owner ? api.workspaces.ref(owner.id) : await api.workspaces.open(cwd);
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
   *
   * PLACED IN THE WORKSPACE THAT ALREADY OWNS THE DIRECTORY, never by bare cwd.
   * `agents.create({ cwd })` on a directory the daemon has no workspace for
   * provisions one -- and for a Paseo-owned WORKTREE that means a whole second
   * PROJECT, named after the worktree directory, holding a duplicate workspace
   * pointed at the same files as the real one. Opening a chat inside a
   * worktree workspace this plugin had just created was enough to do it, and
   * the app then showed the same work twice under two different projects.
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

    const workspace = await workspaceFor(cwd);
    const agent = await workspace.agents.create({
      config: { provider },
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
    const unsubscribe = agent.timeline.subscribe(guarded("timeline", (update: any) => {
      const event = update?.event;
      if (!event) return;

      // seq and epoch live on the UPDATE, not the event. They are what lets a
      // consumer tell a live message apart from the same message arriving in a
      // history fetch -- without them the two race and the message renders
      // twice.
      const at = { seq: update.seq ?? null, epoch: update.epoch ?? null };

      switch (event.type) {
        case "timeline": {
          const described = describeItem(event.item);
          if (described) {
            const { kind, ...rest } = described;
            emit(kind, { agentId: id, ...rest, ...at });
          }
          break;
        }
        case "permission_requested":
          // The agent is BLOCKED until this is answered. It already rode the
          // same subscription; there was simply no case for it here, which is
          // why the permission dialog had nothing to show.
          emit("permission", { agentId: id, request: withFallbackActions(event.request) });
          break;
        case "permission_resolved":
          // Fires whoever answered -- including the Paseo app. That is what
          // lets a dialog open in Neovim close itself when you approve on the
          // desktop instead.
          emit("permission_resolved", {
            agentId: id,
            requestId: event.requestId,
            resolution: event.resolution ?? null,
          });
          break;
        case "turn_completed":
        case "turn_failed":
        case "turn_canceled":
          // The usage on turn_completed is the final word for the turn; the
          // panel wants it even though the turn event itself carries no lines.
          if (event.usage) emit("usage", { agentId: id, usage: event.usage });
          emit("turn", {
            agentId: id,
            outcome: event.type,
            error: event.error ?? null,
            reason: event.reason ?? null,
          });
          break;

        case "usage_updated":
          // Context-window fill and cost, pushed. The usage panel would
          // otherwise have to poll agent.config, which is a round trip per
          // refresh for a number that arrives here for free.
          emit("usage", { agentId: id, usage: event.usage });
          break;

        // Mode, model and thinking level can all be changed from the Paseo app
        // or another client. Without these the header shows whatever we last
        // set ourselves and quietly lies -- the same divergence that dropping
        // user_message used to cause.
        case "mode_changed":
          emit("settings", {
            agentId: id,
            modeId: event.currentModeId ?? null,
            availableModes: event.availableModes ?? [],
          });
          break;
        case "model_changed":
          emit("settings", {
            agentId: id,
            model: event.runtimeInfo?.model ?? null,
            provider: event.runtimeInfo?.provider ?? null,
          });
          break;
        case "thinking_option_changed":
          emit("settings", { agentId: id, thinkingOptionId: event.thinkingOptionId ?? null });
          break;

        case "attention_required":
          emit("attention", { agentId: id, reason: event.reason });
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
    }));

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

    const applyUpdate = guarded("agents", (message: any) => {
      // Both shapes reach here: the wire message, and the bare update the
      // local listener is handed.
      const payload = message?.type === "agent_update" ? message.payload : message;
      if (!payload?.kind) return;
      if (payload.kind === "upsert") {
        emit("agents", { kind: "upsert", agent: describe(payload.agent) });
      } else if (payload.kind === "remove") {
        emit("agents", { kind: "remove", id: payload.agentId });
      }
    });

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
        snapshot: guarded("agents snapshot", ({ entries }: any) =>
          emit("agents", { kind: "snapshot", entries: entries.map((e: any) => describe(e.agent)) }),
        ),
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
      // "projected" asks the DAEMON to collapse the timeline the way the app
      // sees it: assistant chunks merged, reasoning merged, and a tool call
      // already folded into its terminal status rather than arriving as a
      // running item followed by a completed one. Doing it here instead meant
      // reimplementing three merge rules that can drift from the daemon's.
      projection: "projected",
      ...(req.cursor ? { cursor: req.cursor as any } : {}),
    });

    // History renders through the SAME describeItem as the live subscription,
    // so reopening a chat shows the tool calls and thinking that were there the
    // first time rather than a conversation with all the work cut out of it.
    //
    // The projection above already merges, so the merge below is DEFENSIVE
    // only -- and it merges strictly adjacent text, never across a tool call.
    // The old code merged every assistant item in the page regardless of what
    // sat between them, which would now splice the sentence before "read a
    // file" onto the sentence after it and lose where the work happened.
    const items: { kind: string; [key: string]: unknown }[] = [];
    for (const entry of page.entries ?? []) {
      const described = describeItem(entry.item ?? {});
      if (!described) continue;
      // `seqEnd` rather than a running counter: it is what the live
      // subscription compares against to decide an event is a duplicate.
      described.seq = entry.seqEnd ?? entry.seqStart ?? null;
      const last = items[items.length - 1];
      if (last && last.kind === "text" && described.kind === "text") {
        last.text = String(last.text ?? "") + String(described.text ?? "");
        last.seq = described.seq;
      } else {
        items.push(described);
      }
    }

    return {
      items,
      // Free, from a call already being made: a chat opening onto an agent that
      // is ALREADY blocked can show the dialog rather than looking idle.
      pendingPermissions: (page.agent?.pendingPermissions ?? []).map(withFallbackActions),
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
      // What the usage panel draws. `contextWindowUsedTokens` over
      // `contextWindowMaxTokens` is the fill bar; the rest is the table.
      usage: snap?.lastUsage
        ? {
            inputTokens: snap.lastUsage.inputTokens ?? null,
            cachedInputTokens: snap.lastUsage.cachedInputTokens ?? null,
            outputTokens: snap.lastUsage.outputTokens ?? null,
            totalCostUsd: snap.lastUsage.totalCostUsd ?? null,
            contextWindowMaxTokens: snap.lastUsage.contextWindowMaxTokens ?? null,
            contextWindowUsedTokens: snap.lastUsage.contextWindowUsedTokens ?? null,
          }
        : null,
      pendingPermissions: (snap?.pendingPermissions ?? []).map(withFallbackActions),
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

  /**
   * Answer a permission request -- the thing that previously required the
   * desktop app.
   *
   * `behavior` is the union discriminant, and the two arms carry different
   * fields: allow takes updatedInput/updatedPermissions, deny takes a message
   * and `interrupt`. Building it here rather than passing a blob through means
   * a malformed response is a TypeScript error instead of a daemon rejection.
   *
   * `selectedActionId` is the provider's OWN action id, from request.actions --
   * "allow once" and "allow for this session" are both behavior:"allow" and
   * differ only by that id, so dropping it silently downgrades the answer.
   */
  async "agent.respondToPermission"(req) {
    const agent = connected().agents.ref(String(need(req.agentId, "agentId")));
    const requestId = String(need(req.requestId, "requestId"));
    const behavior = String(need(req.behavior, "behavior"));
    // A synthetic id is ours, not the provider's, and sending it back is
    // rejected. See withFallbackActions.
    const actionId =
      req.selectedActionId && !String(req.selectedActionId).startsWith("__")
        ? String(req.selectedActionId)
        : null;

    const response: any =
      behavior === "allow"
        ? {
            behavior: "allow",
            ...(actionId ? { selectedActionId: actionId } : {}),
            ...(req.updatedInput ? { updatedInput: req.updatedInput } : {}),
          }
        : {
            behavior: "deny",
            ...(actionId ? { selectedActionId: actionId } : {}),
            ...(req.message ? { message: String(req.message) } : {}),
            ...(req.interrupt === undefined ? {} : { interrupt: Boolean(req.interrupt) }),
          };

    await agent.respondToPermission({ requestId, response });
    return { requestId, behavior };
  },

  /**
   * Permissions already waiting on an agent.
   *
   * Needed because `permission_requested` fires ONCE, when the agent blocks. A
   * chat opened onto an agent that blocked five minutes ago never sees that
   * event, and without this it looks idle while the daemon waits for an answer.
   */
  async "agent.pendingPermissions"(req) {
    const agent: any = connected().agents.ref(String(need(req.agentId, "agentId")));
    await agent.refresh();
    const snap: any = agent.current();
    return { requests: (snap?.pendingPermissions ?? []).map(withFallbackActions) };
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
process.stdin.on("end", () => bail(0));
process.stdin.on("close", () => bail(0));
process.stdin.on("error", () => bail(0));
process.on("SIGHUP", () => bail(0));
process.on("SIGTERM", () => bail(0));
process.on("SIGINT", () => bail(0));

/**
 * Re-entrancy safe, and SILENT once the pipe is gone.
 *
 * The old body wrote to stderr and then to stdout. After Neovim exits both of
 * those fail with EPIPE, and an EPIPE with no 'error' listener arrives HERE --
 * so the handler for the failure was also the cause of the next one.
 */
process.on("uncaughtException", (error) => {
  if (isGone(error)) return severed();
  if (broken || bailing) return;
  log("uncaught:", error);
  emit("protocol_error", { error: String(error) });
});

// Previously unhandled entirely, and the default action for one is to kill the
// process -- an ops chain that rejects off the end of dispatch would have taken
// the sidecar down mid-session.
process.on("unhandledRejection", (reason) => {
  if (isGone(reason)) return severed();
  if (broken || bailing) return;
  log("unhandled rejection:", reason);
  emit("protocol_error", { error: String(reason) });
});

emit("ready", { pid: process.pid });
