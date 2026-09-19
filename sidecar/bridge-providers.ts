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
      const snapshot = await connected().providers.snapshot(
        req.cwd ? { cwd: String(req.cwd) } : {},
      );
      return {
        entries: (snapshot.entries ?? []).map((entry: any) => ({
          provider: entry.provider,
          status: entry.status,
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
