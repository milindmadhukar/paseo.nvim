import {
  need,
  guarded,
  emit,
  type Ops,
  type Request,
} from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { pictures, withFallbackActions } from "./bridge-normalize.ts";
import { describeWorkspace, workspaceFor } from "./bridge-workspaces.ts";
import { describeSettings } from "./bridge-providers.ts";

export function matchesReviewAgent(
  agent: any,
  cwd: string,
  provider?: string | null,
): boolean {
  if (agent.cwd !== cwd || agent.labels?.["paseo.nvim"] !== "review")
    return false;
  if (!provider) return true;
  const runtime = agent.runtimeInfo;
  return !!runtime && `${runtime.provider}/${runtime.model}` === provider;
}

function agentProvider(agent: any): string | null {
  const runtime = agent.runtimeInfo;
  return runtime?.provider && runtime?.model
    ? `${runtime.provider}/${runtime.model}`
    : null;
}

/**
 * The agent `:Paseo chat` should open in a directory, out of everything the
 * daemon has there.
 *
 * NOT the same question as `matchesReviewAgent`, which is "is this one OURS"
 * and is what `agent.ensure` has to keep asking -- creating what the new-agent
 * screen was just filled in for must not hand back somebody else's session.
 * This one is "is there anything here at all", and it is the whole difference
 * between a plugin that joins the session you are already running and one that
 * offers to start a second: a tab opened in the Paseo app carries no
 * `paseo.nvim` label, so the strict test said "no agent in this workspace" in
 * a workspace with two of them on screen.
 *
 * Preference order, most wanted first:
 *   1. ours, on the provider this editor is set to
 *   2. ours, on any provider
 *   3. anyone's, on the provider this editor is set to
 *   4. anyone's
 * and within each, whichever was touched most recently -- which is the one you
 * were just looking at.
 */
export function preferredAgent(
  agents: any[],
  cwd: string,
  provider?: string | null,
): any | undefined {
  const touched = (agent: any) =>
    Date.parse(agent.updatedAt ?? agent.createdAt ?? "") || 0;
  const rank = (agent: any) =>
    (agent.labels?.["paseo.nvim"] === "review" ? 2 : 0) +
    (provider && agentProvider(agent) === provider ? 1 : 0);

  return agents
    .filter((agent) => agent.cwd === cwd)
    .sort((a, b) => rank(b) - rank(a) || touched(b) - touched(a))[0];
}

export function creationConfig(req: Request, provider: string) {
  return {
    provider,
    ...(req.modeId ? { modeId: String(req.modeId) } : {}),
    ...(req.thinkingOptionId
      ? { thinkingOptionId: String(req.thinkingOptionId) }
      : {}),
    ...(req.featureValues &&
    typeof req.featureValues === "object" &&
    !Array.isArray(req.featureValues)
      ? { featureValues: req.featureValues as Record<string, unknown> }
      : {}),
  };
}

/** One agent, as the directory column draws it. */
export function describeAgent(agent: any): Record<string, unknown> {
  return {
    id: agent.id,
    title: agent.title ?? null,
    status: agent.status ?? null,
    createdAt: agent.createdAt ?? null,
    cwd: agent.cwd ?? null,
    workspaceId: agent.workspaceId ?? null,
    provider: agent.runtimeInfo?.provider ?? null,
    requiresAttention: (agent.pendingPermissions?.length ?? 0) > 0,
    // What the desktop app sorts its workspace sidebar by, carried whole so
    // the Lua side can draw the same four states. `requiresAttention` above is
    // OURS -- "a permission is pending" -- and every caller already reads it
    // that way; the daemon's own flag means something wider (a turn finished,
    // or failed, while nobody was looking), so it travels under its own name
    // rather than replacing ours under the same one.
    pendingPermissionCount: agent.pendingPermissions?.length ?? 0,
    attentionReason: agent.attentionReason ?? null,
    daemonAttention: agent.requiresAttention === true,
    // Carried through so the Lua side can tell OUR agents apart from the ones
    // that did the work. `explain` lists the latter for the review agent to
    // interrogate, and listing itself would be a loop.
    labels: agent.labels ?? null,
  };
}

/**
 * Follow the agent directory, once.
 *
 * THIS IS ALSO THE DEMAND CHANNEL, which is not obvious and cost an afternoon.
 * `agents.subscribe(handler)` and `agentHandle.subscribe(handler)` register
 * LOCAL listeners over a stream the daemon is not sending yet; it is the
 * `list({ subscribe: {} })` below that asks for it. A handle listener with no
 * directory subscription behind it is silent -- measured, not assumed: a mode
 * change produced nothing until this call had been made, and both listeners
 * fired on the very next one.
 *
 * So `timeline.subscribe` calls this too, for the settings it could not
 * otherwise see. It lives here because this module owns `ctx.directory`.
 */
export function followDirectory(ctx: BridgeConnection): Promise<void> {
  if (ctx.directory) return Promise.resolve();
  // ONE FOLLOW AT A TIME. Requests run concurrently now (bridge-dispatch.ts),
  // and `agents.subscribe` and `timeline.subscribe` both arrive here on a
  // chat's first open: two that both saw no directory would subscribe twice
  // and leak the first. The second waits on the first instead.
  if (!ctx.following) {
    ctx.following = startFollowing(ctx).finally(() => {
      ctx.following = null;
    });
  }
  return ctx.following;
}

async function startFollowing(ctx: BridgeConnection): Promise<void> {
  const api = ctx.connected();

  const applyUpdate = guarded("agents", (message: any) => {
    // Both shapes reach here: the wire message, and the bare update the local
    // listener is handed.
    const payload = message?.type === "agent_update" ? message.payload : message;
    if (!payload?.kind) return;
    if (payload.kind === "upsert") {
      emit("agents", { kind: "upsert", agent: describeAgent(payload.agent) });
    } else if (payload.kind === "remove") {
      emit("agents", { kind: "remove", id: payload.agentId });
    }
  });

  // The owned subscription delivers its snapshot first and every update
  // after it, and releasing it is what tells the daemon to stop. (There was a
  // second path here for SDK 0.8, whose list result had no subscription; the
  // pinned SDK has had one since 0.9.)
  const result: any = await api.agents.list({
    filter: { includeArchived: false },
    subscribe: {},
  });
  result.subscription.subscribe({
    snapshot: guarded("agents snapshot", ({ entries }: any) =>
      emit("agents", {
        kind: "snapshot",
        entries: entries.map((e: any) => describeAgent(e.agent)),
      }),
    ),
    update: applyUpdate,
    error: (error: unknown) =>
      emit("agents", { kind: "error", error: String(error) }),
  });

  // WORKSPACES TOO. A workspace's title is written AFTER it is created -- the
  // daemon names it from the first prompt in the background -- and its diff
  // stat, branch, pull request and CI change under it for as long as it lives.
  // An upsert carries the workspace whole, described as the list describes it,
  // so the rail patches the one row in place; a removal is only the fact, and
  // the Lua side refetches, since it owns what a list means.
  let workspaces: any = null;
  try {
    // THE SAME PAGE THE APP ASKS FOR, not one row. The daemon watches a
    // workspace's checkout -- and so computes its diff stat, dirty flag and
    // pull request at all -- only for workspaces a subscription has been sent
    // (session.ts `reconcileWorkspaceGitObservers`). A page of one meant one
    // workspace in the whole daemon ever had a live stat.
    workspaces = await api.workspaces.list({
      subscribe: {},
      sort: [{ key: "activity_at", direction: "desc" }],
      page: { limit: 200 },
    });
    workspaces?.subscription?.subscribe({
      snapshot: () => {},
      // The subscription hands over the MESSAGE, `{ type, payload }`; the
      // update is its payload. (This read `update.workspace` off the message
      // for as long as only the fact was forwarded, which hid it.)
      update: guarded("workspaces", (message: any) => {
        const update = message?.payload ?? message;
        emit("workspaces_changed", {
          kind: update?.kind ?? null,
          workspaceId:
            update?.workspace?.id ?? update?.workspaceId ?? update?.id ?? null,
          workspace:
            update?.kind === "upsert" && update?.workspace
              ? describeWorkspace(update.workspace)
              : null,
        });
      }),
      error: () => {},
    });
  } catch {
    // A daemon that will not stream workspaces still polls fine.
    workspaces = null;
  }

  ctx.directory = {
    subscription: result.subscription,
    workspaces: workspaces?.subscription,
  };
}

export function agentOps(ctx: BridgeConnection): Ops {
  const connected = () => ctx.connected();
  async function reviewAgent(cwd: string, provider?: string | null) {
    const page = await connected().agents.list({
      filter: { includeArchived: false },
      page: { limit: 100 },
    });
    return page.entries.find(({ agent }: any) =>
      matchesReviewAgent(agent, cwd, provider),
    )?.agent;
  }
  return {
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
        labels: agent.labels ?? null,
      }));
      return {
        entries: req.cwd ? entries.filter((e) => e.cwd === req.cwd) : entries,
      };
    },

    async "agent.find"(req) {
      const page = await connected().agents.list({
        filter: { includeArchived: false },
        page: { limit: 100 },
      });
      const agent = preferredAgent(
        page.entries.map(({ agent }: any) => agent),
        String(need(req.cwd, "cwd")),
        req.provider ? String(req.provider) : null,
      );
      return agent
        ? {
            id: agent.id,
            provider: agentProvider(agent),
          }
        : { id: null, provider: null };
    },

    async "agent.ensure"(req) {
      const api = connected();
      const cwd = String(need(req.cwd, "cwd"));

      const requested = req.provider ? String(req.provider) : null;
      const existing = await reviewAgent(cwd, requested);
      if (existing)
        return {
          id: existing.id,
          created: false,
          provider: agentProvider(existing),
        };

      let provider = requested;
      if (!provider) {
        // Ask the daemon rather than guessing: installed providers and configured
        // models differ between hosts, and a hardcoded model id fails at create().
        const snapshot = await api.providers.waitForReady({
          cwd,
          timeoutMs: 30_000,
        });
        const entry = (snapshot.entries ?? []).find(
          (e: any) => e.status === "ready",
        );
        const model =
          entry?.models?.find((m: any) => m.isDefault) ??
          entry?.models?.[0] ??
          null;
        if (!entry || !model)
          throw new Error("no provider model is ready on this daemon");
        provider = `${entry.provider}/${model.id}`;
      }

      const workspace = await workspaceFor(
        ctx,
        cwd,
        req.project ? String(req.project) : null,
      );
      // `agent.find` is only a read-only preview. Another client may have
      // created the matching review agent while we resolved the workspace.
      const concurrent = await reviewAgent(cwd, requested);
      if (concurrent)
        return {
          id: concurrent.id,
          created: false,
          provider: agentProvider(concurrent),
        };
      const agent = await workspace.agents.create({
        config: creationConfig(req, provider),
        title: req.title ? String(req.title) : "paseo.nvim review",
        // Namespaced, per the SDK's own guidance: several tools may manage agents
        // on one daemon, and this is how we find ours again.
        labels: { "paseo.nvim": "review" },
      });
      return { id: agent.id, created: true, provider };
    },

    async "agent.send"(req) {
      const agentId = String(need(req.agentId, "agentId"));
      const prompt = String(need(req.prompt, "prompt"));
      const agent = connected().agents.ref(agentId);
      const images = pictures(req);
      // No naming here. The daemon titles an untitled, unused agent from its
      // first prompt itself (verified against 0.15.3), which this used to do
      // by hand -- a fetch and an update in front of every send, for a 0.8
      // daemon nobody runs any more.
      const behavior =
        req.activeTurnBehavior === "steer" ||
        req.activeTurnBehavior === "interrupt"
          ? req.activeTurnBehavior
          : undefined;
      await agent.send(prompt, {
        ...(images ? { images } : {}),
        ...(behavior ? { activeTurnBehavior: behavior } : {}),
      } as any);
      return { sent: true, images: images?.length ?? 0 };
    },

    async "agent.run"(req) {
      const agentId = String(need(req.agentId, "agentId"));
      const prompt = String(need(req.prompt, "prompt"));
      const agent = connected().agents.ref(agentId);
      const images = pictures(req);
      const result = await agent.run(prompt, {
        timeoutMs: Number(req.timeoutMs ?? 10 * 60_000),
        ...(images ? { images } : {}),
      });
      return {
        status: result.status,
        lastMessage: result.lastMessage ?? null,
        error: result.error ?? null,
      };
    },

    async "agents.subscribe"() {
      // The directory may already be followed -- `timeline.subscribe` needs the
      // same stream for its settings. A second subscriber still needs its
      // SNAPSHOT, though: `agents.lua` renders from one and applies updates on
      // top, so returning a bare `already` left the picker's table empty for
      // good.
      const already = ctx.directory !== null;
      await followDirectory(ctx);
      if (already) {
        const page: any = await connected().agents.list({
          filter: { includeArchived: false },
        });
        emit("agents", {
          kind: "snapshot",
          entries: (page.entries ?? []).map((e: any) => describeAgent(e.agent)),
        });
      }
      return { subscribed: true, already };
    },

    async "agents.unsubscribe"() {
      if (!ctx.directory) return { unsubscribed: false };
      // Not while a chat is open. This stream is also what carries mode, model
      // and thinking level to `timeline.subscribe`, so releasing it here would
      // silently freeze every open header at whatever it last said.
      if (ctx.timelines.size > 0)
        return { unsubscribed: false, heldBy: ctx.timelines.size };
      const held = ctx.directory;
      ctx.directory = null;
      await held.subscription?.release();
      await held.workspaces?.release().catch(() => {});
      return { unsubscribed: true };
    },

    async "agent.create"(req) {
      const api = connected();
      const workspace: any = api.workspaces.ref(
        String(need(req.workspaceId, "workspaceId")),
      );

      let provider = req.provider ? String(req.provider) : null;
      if (!provider) {
        const snapshot: any = await api.providers.waitForReady({
          timeoutMs: 30_000,
        });
        const entry = (snapshot.entries ?? []).find(
          (e: any) => e.status === "ready",
        );
        const model =
          entry?.models?.find((m: any) => m.isDefault) ??
          entry?.models?.[0] ??
          null;
        if (!entry || !model)
          throw new Error("no provider model is ready on this daemon");
        provider = `${entry.provider}/${model.id}`;
      }

      // Images ride with a first prompt, as they do on `agent.start`: a
      // draft's first message is whatever you sent, screenshots included.
      const images = req.prompt ? pictures(req) : null;
      const agent = await workspace.agents.create({
        config: creationConfig(req, provider),
        ...(req.title ? { title: String(req.title) } : {}),
        ...(req.prompt ? { prompt: String(req.prompt) } : {}),
        ...(images ? { images } : {}),
        ...(Array.isArray(req.attachments) && req.attachments.length > 0
          ? { attachments: req.attachments as any }
          : {}),
        labels: { "paseo.nvim": "session" },
      } as any);
      return { id: agent.id, provider };
    },

    async "agent.forkContext"(req) {
      const api = connected();
      const raw = ctx.raw();
      if (raw.getLastServerInfoMessage()?.features?.agentForkContext !== true) {
        throw new Error(
          "this Paseo host does not support agent forking; update Paseo and try again",
        );
      }

      const agentId = String(need(req.agentId, "agentId"));
      const agent: any = api.agents.ref(agentId);
      await agent.refresh();
      const snapshot: any = agent.current();
      const settings: any = describeSettings(snapshot);
      const context = await raw.buildAgentForkContext(agentId);

      if (!context.attachment) {
        throw new Error("Paseo could not build fork context for this agent");
      }

      return {
        attachment: context.attachment,
        itemCount: context.itemCount,
        workspaceId: snapshot?.workspaceId ?? null,
        cwd: snapshot?.cwd ?? null,
        title: snapshot?.title ?? null,
        config: {
          provider:
            settings.provider && settings.model
              ? `${settings.provider}/${settings.model}`
              : null,
          modeId: settings.modeId ?? null,
          thinkingOptionId: settings.thinkingOptionId ?? null,
          featureValues: Object.fromEntries(
            (settings.features ?? []).map((feature: any) => [
              feature.id,
              feature.value,
            ]),
          ),
        },
      };
    },

    /**
     * Interrupt a running turn. A no-op for an idle agent.
     *
     * `cancelAgent` is on the raw DaemonClient; `PaseoAgentHandle` has no
     * cancel in 0.8.0, so the typed API cannot express this at all. That is
     * not a workaround -- `paseo agent stop` calls exactly this method, and
     * so does the app's stop button.
     *
     * The result arrives as a `turn_canceled` on the timeline, which the Lua
     * already listens for, so there is nothing to report back beyond having
     * asked.
     */
    async "agent.cancel"(req) {
      await ctx.raw().cancelAgent(String(need(req.agentId, "agentId")));
      return { canceled: true };
    },

    async "agent.archive"(req) {
      const agent = connected().agents.ref(
        String(need(req.agentId, "agentId")),
      );
      const result = await agent.archive();
      return { archivedAt: result?.archivedAt ?? null };
    },

    async "agent.respondToPermission"(req) {
      const agentId = String(need(req.agentId, "agentId"));
      const agent = connected().agents.ref(agentId);
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
              ...(req.interrupt === undefined
                ? {}
                : { interrupt: Boolean(req.interrupt) }),
            };

      await agent.respondToPermission({ requestId, response });
      return { requestId, behavior };
    },

    async "agent.pendingPermissions"(req) {
      const agent: any = connected().agents.ref(
        String(need(req.agentId, "agentId")),
      );
      await agent.refresh();
      const snap: any = agent.current();
      return {
        requests: (snap?.pendingPermissions ?? []).map(withFallbackActions),
      };
    },
  };
}
