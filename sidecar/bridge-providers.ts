import { need, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { withFallbackActions } from "./bridge-normalize.ts";

/**
 * Everything adjustable about a session, read out of ONE agent snapshot.
 *
 * Shared by `agent.config` (a pull) and the state subscription in
 * `timeline.subscribe` (a push), because the Lua reads both into the same
 * fields -- a pushed update that spelled `modeId` differently from the pulled
 * one would show up as a header that changes shape depending on who last
 * touched it.
 *
 * `currentModeId` is the snapshot's own field; `runtimeInfo.modeId` is the
 * daemon's mirror of it and the fallback.
 */
export function describeSettings(snap: any): Record<string, unknown> {
  const runtime = snap?.runtimeInfo ?? {};
  return {
    provider: runtime.provider ?? null,
    model: runtime.model ?? null,
    modeId: snap?.currentModeId ?? runtime.modeId ?? runtime.mode ?? null,
    thinkingOptionId: runtime.thinkingOptionId ?? null,
    availableModes: (snap?.availableModes ?? []).map((m: any) => ({
      id: m.id,
      label: m.label,
      description: m.description ?? null,
    })),
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
          contextWindowUsedTokens:
            snap.lastUsage.contextWindowUsedTokens ?? null,
        }
      : null,

    // THE AUTHORITATIVE PENDING LIST, and the reason cross-client answering
    // used to desync.
    //
    // `permission_resolved` is a real event and it does fire -- but it is not
    // the only way a request stops being pending. The daemon's
    // `refreshSessionState` replaces this whole map wholesale and emits only
    // the snapshot, with no `permission_resolved` for anything that vanished.
    // A resolution that lands while the socket is down is never replayed
    // either. In both cases the truth rides HERE, on a snapshot this sidecar
    // was already subscribed to and was throwing away one line before it
    // became useful, leaving Neovim holding a prompt the daemon would refuse.
    pendingPermissions: (snap?.pendingPermissions ?? []).map(
      withFallbackActions,
    ),
  };
}

export function providerOps(ctx: BridgeConnection): Ops {
  const connected = () => ctx.connected();
  const raw = () => ctx.raw();
  return {
    async providers(req) {
      const where = req.cwd ? { cwd: String(req.cwd) } : {};
      // WAIT, do not snapshot. Provider discovery is lazy and PER DIRECTORY, so
      // the first call in a directory the daemon has not seen -- which is every
      // call in a workspace you just made -- comes back with every provider at
      // `status: "loading"` and no models. Everything downstream treats that as
      // "nothing is ready": the new-session screen refuses to open with "no
      // provider on this daemon has a model ready", and retrying a second later
      // works, which is the shape of a bug rather than of a daemon that is
      // genuinely unconfigured. `agent.create` already waits; this did not, so
      // the two disagreed about the same daemon.
      let snapshot: any;
      try {
        snapshot = await connected().providers.waitForReady({
          ...where,
          timeoutMs: 15_000,
        });
      } catch {
        // Discovery that never settles must not cost you the list. Whatever is
        // known now is still better than an error.
        snapshot = await connected().providers.snapshot(where);
      }
      return {
        entries: (snapshot.entries ?? []).map((entry: any) => ({
          provider: entry.provider,
          status: entry.status,
          // Separate from `status`, and both are needed. `status` is whether a
          // model is ready to start an AGENT; `enabled` is whether the
          // provider is configured at all -- which is the honest question for
          // "should a terminal offer to run its CLI".
          enabled: entry.enabled ?? null,
          label: entry.label ?? entry.provider,
          description: entry.description ?? null,
          defaultModeId: entry.defaultModeId ?? null,
          modes: (entry.modes ?? []).map((mode: any) => ({
            id: mode.id,
            label: mode.label,
            description: mode.description ?? null,
            icon: mode.icon ?? null,
            colorTier: mode.colorTier ?? null,
          })),
          models: (entry.models ?? []).map((model: any) => ({
            id: model.id,
            label: model.label ?? model.id,
            description: model.description ?? null,
            isDefault: model.isDefault ?? false,
            defaultThinkingOptionId: model.defaultThinkingOptionId ?? null,
            thinkingOptions: (model.thinkingOptions ?? []).map(
              (option: any) => ({
                id: option.id,
                label: option.label,
                description: option.description ?? null,
                isDefault: !!option.isDefault,
              }),
            ),
          })),
        })),
      };
    },

    async "providers.features"(req) {
      const provider = String(need(req.provider, "provider"));
      const result = await connected().providers.listFeatures({
        provider,
        cwd: String(need(req.cwd, "cwd")),
        ...(req.modeId ? { modeId: String(req.modeId) } : {}),
      });
      if (result.error) throw new Error(result.error);
      return { features: result.features ?? [] };
    },

    /**
     * Plan limits: the 5-hour and weekly windows, and what plan they belong to.
     *
     * NOT the same thing as the `usage` field above, which is per AGENT --
     * context window fill, tokens and cost for one session. This is per
     * PROVIDER and account-wide, and it is the one that answers "can I keep
     * going today".
     *
     * `listProviderUsage` lives on the raw DaemonClient rather than the typed
     * API, the same way `setAgentMode` does. The daemon fetches it per
     * provider from that provider's own account endpoint, so a provider with
     * no fetcher -- fable and gemini have none -- simply does not appear, and
     * one that is unauthenticated appears with `status: "unavailable"` and an
     * `error` to show. Both are the panel's problem, not ours: pass it
     * through whole.
     */
    async "providers.usage"() {
      const payload: any = await raw().listProviderUsage();
      return {
        fetchedAt: payload?.fetchedAt ?? null,
        providers: payload?.providers ?? [],
      };
    },

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
        const entry = (catalogue.entries ?? []).find(
          (e: any) => e.provider === runtime.provider,
        );
        models = (entry?.models ?? []).map((m: any) => ({
          id: m.id,
          label: m.label,
          isDefault: !!m.isDefault,
        }));
        const model = (entry?.models ?? []).find(
          (m: any) => m.id === runtime.model,
        );
        thinkingOptions = (model?.thinkingOptions ?? []).map((t: any) => ({
          id: t.id,
          label: t.label,
          isDefault: !!t.isDefault,
        }));
      } catch {
        /* the catalogue is a nicety; the modes and features below are not */
      }

      return {
        // The same reader the state subscription pushes through, so a pulled
        // config and a pushed one cannot disagree about a field name.
        // `pendingPermissions` used to be spelled out again here, because the
        // shared reader dropped it. It does not any more -- the pull and the
        // push now genuinely carry the same fields, which is the whole point
        // of the sentence above.
        ...describeSettings(snap),
        workspaceId: snap?.workspaceId ?? null,
        cwd: snap?.cwd ?? null,
        title: snap?.title ?? null,
        thinkingOptions,
        models,
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
      return {
        thinkingOptionId: req.thinkingOptionId ?? null,
        notice: notice ?? null,
      };
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
  };
}
