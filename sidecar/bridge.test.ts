import { test } from "node:test";
import assert from "node:assert/strict";
import { BridgeConnection } from "./bridge-connection.ts";
import {
  agentOps,
  matchesReviewAgent,
  creationConfig,
} from "./bridge-agents.ts";
import { providerOps } from "./bridge-providers.ts";

test("review reuse requires the requested provider and model", async () => {
  const claude = {
    id: "claude-agent",
    cwd: "/work",
    labels: { "paseo.nvim": "review" },
    runtimeInfo: { provider: "claude", model: "opus" },
  };
  assert.equal(matchesReviewAgent(claude, "/work", "claude/opus"), true);
  assert.equal(matchesReviewAgent(claude, "/work", "codex/gpt-5.6-sol"), false);
  assert.equal(matchesReviewAgent(claude, "/work"), true);
  let creations = 0;
  let createdConfig: any;
  const workspace = {
    agents: {
      async create(options: any) {
        creations++;
        createdConfig = options.config;
        return { id: "codex-agent" };
      },
    },
  };
  const api = {
    agents: {
      async list() {
        return { entries: [{ agent: claude }] };
      },
    },
    workspaces: {
      async list() {
        return { entries: [] };
      },
      async open() {
        return workspace;
      },
    },
  };
  const ctx = new BridgeConnection();
  ctx.connected = (() => api) as any;
  const ops = agentOps(ctx);
  const requested = {
    op: "agent.ensure",
    cwd: "/work",
    provider: "codex/gpt-5.6-sol",
    modeId: "auto-review",
    thinkingOptionId: "high",
    featureValues: { plan_mode: true, fast_mode: false },
  };
  assert.deepEqual(await ops["agent.find"](requested), {
    id: null,
    provider: null,
  });
  assert.deepEqual(await ops["agent.ensure"](requested), {
    id: "codex-agent",
    created: true,
    provider: requested.provider,
  });
  assert.equal(creations, 1);
  assert.deepEqual(createdConfig, {
    provider: requested.provider,
    modeId: "auto-review",
    thinkingOptionId: "high",
    featureValues: { plan_mode: true, fast_mode: false },
  });
  assert.deepEqual(
    await ops["agent.ensure"]({
      op: "agent.ensure",
      cwd: "/work",
      provider: "claude/opus",
    }),
    {
      id: "claude-agent",
      created: false,
      provider: "claude/opus",
    },
  );
  assert.equal(creations, 1);
  assert.deepEqual(
    await ops["agent.find"]({ op: "agent.find", cwd: "/work" }),
    {
      id: "claude-agent",
      provider: "claude/opus",
    },
  );
});

test("ensure rechecks after workspace lookup before creating", async () => {
  let lookups = 0;
  let creations = 0;
  const matching = {
    id: "another-client-agent",
    cwd: "/work",
    labels: { "paseo.nvim": "review" },
    runtimeInfo: { provider: "codex", model: "gpt-5.6-sol" },
  };
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    agents: {
      async list() {
        lookups++;
        return { entries: lookups === 1 ? [] : [{ agent: matching }] };
      },
    },
    workspaces: {
      async list() {
        return { entries: [] };
      },
      async open() {
        return {
          agents: {
            async create() {
              creations++;
              return { id: "duplicate" };
            },
          },
        };
      },
    },
  })) as any;
  assert.deepEqual(
    await agentOps(ctx)["agent.ensure"]({
      op: "agent.ensure",
      cwd: "/work",
      provider: "codex/gpt-5.6-sol",
    }),
    { id: matching.id, created: false, provider: "codex/gpt-5.6-sol" },
  );
  assert.equal(lookups, 2);
  assert.equal(creations, 0);
});

test("fresh workspace sessions receive initial settings", async () => {
  let createdConfig: any;
  const api = {
    workspaces: {
      ref() {
        return {
          agents: {
            async create(options: any) {
              createdConfig = options.config;
              return { id: "new" };
            },
          },
        };
      },
    },
  };
  const ctx = new BridgeConnection();
  ctx.connected = (() => api) as any;
  const request = {
    op: "agent.create",
    workspaceId: "ws",
    provider: "codex/gpt-5.6-sol",
    modeId: "full-access",
    thinkingOptionId: "medium",
    featureValues: { plan_mode: false, fast_mode: true },
  };
  await agentOps(ctx)["agent.create"](request);
  assert.deepEqual(createdConfig, creationConfig(request, request.provider));
});

test("catalog retains choices and feature lookup follows the model", async () => {
  const model = {
    id: "gpt-5.6-sol",
    label: "GPT-5.6-Sol",
    description: "Coding",
    isDefault: true,
    defaultThinkingOptionId: "high",
    thinkingOptions: [{ id: "high", label: "High", isDefault: true }],
  };
  const entry = {
    provider: "codex",
    status: "ready",
    label: "Codex",
    description: "Coding agent",
    defaultModeId: "auto-review",
    modes: [
      {
        id: "auto-review",
        label: "Auto-review",
        icon: "shield",
        colorTier: "moderate",
      },
    ],
    models: [model],
  };
  const featureRequests: any[] = [];
  const api = {
    providers: {
      async snapshot() {
        return { entries: [entry] };
      },
      async listFeatures(draft: any) {
        featureRequests.push(draft);
        return {
          features: [
            { id: "plan_mode", type: "toggle", label: "Plan", value: false },
          ],
        };
      },
    },
  };
  const ctx = new BridgeConnection();
  ctx.connected = (() => api) as any;
  const ops = providerOps(ctx);
  const catalog: any = await ops.providers({ op: "providers", cwd: "/work" });
  assert.equal(catalog.entries[0].defaultModeId, "auto-review");
  assert.equal(catalog.entries[0].modes[0].label, "Auto-review");
  assert.equal(catalog.entries[0].models[0].label, "GPT-5.6-Sol");
  assert.equal(catalog.entries[0].models[0].defaultThinkingOptionId, "high");
  const features: any = await ops["providers.features"]({
    op: "providers.features",
    provider: "codex/gpt-5.6-sol",
    cwd: "/work",
  });
  assert.equal(features.features[0].id, "plan_mode");
  assert.equal(featureRequests[0].provider, "codex/gpt-5.6-sol");
  await ops["providers.features"]({
    op: "providers.features",
    provider: "codex/gpt-5.5",
    cwd: "/work",
  });
  assert.equal(featureRequests[1].provider, "codex/gpt-5.5");
});
