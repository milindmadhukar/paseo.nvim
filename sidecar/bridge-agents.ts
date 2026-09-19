import { need, guarded, emit, type Ops, type Request } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { pictures, withFallbackActions } from "./bridge-normalize.ts";
import { workspaceFor } from "./bridge-workspaces.ts";

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
    cwd: agent.cwd ?? null,
    workspaceId: agent.workspaceId ?? null,
    provider: agent.runtimeInfo?.provider ?? null,
    requiresAttention: (agent.pendingPermissions?.length ?? 0) > 0,
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
export async function followDirectory(ctx: BridgeConnection): Promise<void> {
  if (ctx.directory) return;

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

  // TWO SDK GENERATIONS, and the installed one is the older.
  //
  // 0.9+ returns an owned `subscription` from list({ subscribe: {} }) whose
  // snapshot callback fires before updates. 0.8 has no such object:
  // `agents.subscribe(handler)` registers a LOCAL listener and the list call
  // is what asks the daemon to start streaming. Writing only the documented
  // 0.9 form failed at runtime with "undefined is not an object (evaluating
  // 'result.subscription.subscribe')", so both are handled and the difference
  // is confined here.
  let localUnsubscribe: (() => void) | null = null;
  if (typeof (api.agents as any).subscribe === "function") {
    localUnsubscribe = (api.agents as any).subscribe(applyUpdate);
  }

  const result: any = await api.agents.list({
    filter: { includeArchived: false },
    subscribe: {},
  });

  if (result?.subscription?.subscribe) {
    // 0.9+: the owned subscription supersedes the local listener, and delivers
    // its own snapshot first.
    localUnsubscribe?.();
    localUnsubscribe = null;
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
  } else {
    // 0.8: the list result IS the snapshot.
    emit("agents", {
      kind: "snapshot",
      entries: (result.entries ?? []).map((e: any) => describeAgent(e.agent)),
    });
  }

  ctx.directory = { subscription: result?.subscription, localUnsubscribe };
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
      }));
      return {
        entries: req.cwd ? entries.filter((e) => e.cwd === req.cwd) : entries,
      };
    },

    async "agent.find"(req) {
      const agent = await reviewAgent(
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

      const workspace = await workspaceFor(ctx, cwd);
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
      const agent = connected().agents.ref(
        String(need(req.agentId, "agentId")),
      );
      const images = pictures(req);
      await agent.send(
        String(need(req.prompt, "prompt")),
        images ? { images } : undefined,
      );
      return { sent: true, images: images?.length ?? 0 };
    },

    async "agent.run"(req) {
      const agent = connected().agents.ref(
        String(need(req.agentId, "agentId")),
      );
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
      held.localUnsubscribe?.();
      await held.subscription?.release();
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

      const agent = await workspace.agents.create({
        config: creationConfig(req, provider),
        ...(req.title ? { title: String(req.title) } : {}),
        ...(req.prompt ? { prompt: String(req.prompt) } : {}),
        labels: { "paseo.nvim": "session" },
      });
      return { id: agent.id, provider };
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

      if (behavior === "allow" && req.thenModeId) {
        const notice = await ctx
          .raw()
          .setAgentMode(agentId, String(req.thenModeId));
        return {
          requestId,
          behavior,
          modeId: req.thenModeId,
          notice: notice ?? null,
        };
      }
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
