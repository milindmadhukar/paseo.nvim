import { need, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { withFallbackActions } from "./bridge-normalize.ts";

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
              contextWindowMaxTokens:
                snap.lastUsage.contextWindowMaxTokens ?? null,
              contextWindowUsedTokens:
                snap.lastUsage.contextWindowUsedTokens ?? null,
            }
          : null,
        pendingPermissions: (snap?.pendingPermissions ?? []).map(
          withFallbackActions,
        ),
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
