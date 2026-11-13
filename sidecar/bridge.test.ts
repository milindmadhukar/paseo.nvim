import { test } from "node:test";
import assert from "node:assert/strict";
import { BridgeConnection } from "./bridge-connection.ts";
import {
  agentOps,
  describeAgent,
  matchesReviewAgent,
  preferredAgent,
  creationConfig,
  describeHistory,
} from "./bridge-agents.ts";
import { providerOps, describeSettings } from "./bridge-providers.ts";
import { describeItem, timelineOps } from "./bridge-timeline.ts";
import { terminalOps } from "./bridge-terminals.ts";
import {
  describePullRequest,
  describeWorkspace,
  workspaceOps,
} from "./bridge-workspaces.ts";
import { voiceOps } from "./bridge-voice.ts";
import { emit } from "./bridge-io.ts";
import { subagentOps } from "./bridge-subagents.ts";

/** stdout IS the protocol, so asserting on it is asserting on the wire. */
function captureStdout(run: () => void): string[] {
  const lines: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  (process.stdout as any).write = (chunk: any, ...args: any[]) => {
    if (typeof chunk === "string" && chunk.startsWith("{")) {
      lines.push(...chunk.split("\n").filter(Boolean));
      return true;
    }
    return (original as any)(chunk, ...args);
  };
  try {
    run();
  } finally {
    (process.stdout as any).write = original;
  }
  return lines;
}

async function captureStdoutAsync(run: () => Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  (process.stdout as any).write = (chunk: any, ...args: any[]) => {
    // Node's test reporter also writes through stdout while an async capture is
    // open. Only bridge protocol messages are JSON objects; forwarding every
    // other chunk keeps reporter traffic out of the assertions.
    if (typeof chunk === "string" && chunk.startsWith("{")) {
      lines.push(...chunk.split("\n").filter(Boolean));
      return true;
    }
    return (original as any)(chunk, ...args);
  };
  try {
    await run();
  } finally {
    (process.stdout as any).write = original;
  }
  return lines;
}

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
  // `find` asks the OTHER question -- "is there a session here at all" -- so
  // the provider is a preference for it and not a filter: this one is on the
  // wrong provider and is still the session you are looking at.
  assert.deepEqual(await ops["agent.find"](requested), {
    id: "claude-agent",
    provider: "claude/opus",
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

test("the chat opens a session that is already there, label or no label", () => {
  // A tab opened in the Paseo app. No `paseo.nvim` label, because the app has
  // never heard of us -- and the reason `:Paseo chat` used to offer to create
  // a second agent in a workspace that visibly had one open.
  const app = {
    id: "app",
    cwd: "/work",
    labels: {},
    updatedAt: "2026-01-02T00:00:00Z",
    runtimeInfo: { provider: "claude", model: "opus" },
  };
  const older = {
    id: "older-app",
    cwd: "/work",
    labels: {},
    updatedAt: "2026-01-01T00:00:00Z",
    runtimeInfo: { provider: "claude", model: "opus" },
  };
  const ours = {
    id: "ours",
    cwd: "/work",
    labels: { "paseo.nvim": "review" },
    updatedAt: "2025-12-01T00:00:00Z",
    runtimeInfo: { provider: "codex", model: "gpt-5.6-sol" },
  };
  const elsewhere = { id: "elsewhere", cwd: "/other", labels: {} };

  // Nothing of ours: the app's, most recently touched first.
  assert.equal(preferredAgent([elsewhere, older, app], "/work")?.id, "app");
  // Ours outranks the app's even on a different provider -- it is the session
  // this editor has been talking to.
  assert.equal(preferredAgent([app, ours, older], "/work")?.id, "ours");
  // Among the app's, the requested provider wins over recency.
  assert.equal(
    preferredAgent([app, older], "/work", "claude/opus")?.id,
    "app",
  );
  // A directory with nothing in it is still the create screen's job.
  assert.equal(preferredAgent([elsewhere], "/work"), undefined);
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
  let createdOptions: any;
  const api = {
    workspaces: {
      ref() {
        return {
          agents: {
            async create(options: any) {
              createdOptions = options;
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
    prompt: "continue from here",
    attachments: [
      {
        type: "text",
        mimeType: "text/plain",
        contextKind: "chat_history",
        text: "history",
      },
    ],
  };
  await agentOps(ctx)["agent.create"](request);
  assert.deepEqual(createdOptions.config, creationConfig(request, request.provider));
  assert.equal(createdOptions.prompt, request.prompt);
  assert.deepEqual(createdOptions.attachments, request.attachments);
});

function agentSendHarness(
  snapshot: Record<string, unknown>,
  options: { updateError?: Error } = {},
) {
  const calls: Array<{ kind: string; [key: string]: unknown }> = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    agents: {
      ref(agentId: string) {
        return {
          async refresh() {
            calls.push({ kind: "refresh", agentId });
          },
          current() {
            return snapshot;
          },
          async send(prompt: string) {
            calls.push({ kind: "send", prompt });
          },
        };
      },
    },
  })) as any;
  ctx.raw = (() => ({
    async updateAgent(agentId: string, updates: Record<string, unknown>) {
      calls.push({ kind: "update", agentId, updates });
      if (options.updateError) throw options.updateError;
    },
  })) as any;
  return { calls, send: agentOps(ctx)["agent.send"] };
}

test("a mid-turn send says how it meets the running turn, and an idle one says nothing", async () => {
  const seen: any[] = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    agents: {
      ref: () => ({
        async send(_prompt: string, options: any) {
          seen.push(options);
        },
      }),
    },
  })) as any;
  const send = agentOps(ctx)["agent.send"];
  await send({ op: "agent.send", agentId: "a", prompt: "x", activeTurnBehavior: "steer" });
  await send({ op: "agent.send", agentId: "a", prompt: "x", activeTurnBehavior: "interrupt" });
  // `queue` is the editor's own -- held until the turn ends -- and never a
  // wire value; nor is anything else.
  await send({ op: "agent.send", agentId: "a", prompt: "x", activeTurnBehavior: "queue" });
  await send({ op: "agent.send", agentId: "a", prompt: "x" });
  assert.deepEqual(seen, [
    { activeTurnBehavior: "steer" },
    { activeTurnBehavior: "interrupt" },
    {},
    {},
  ]);
});

test("a send is only a send: naming an agent is the daemon's job", async () => {
  // The sidecar used to fetch the agent and rename it from the first prompt
  // before every send -- a 0.8 workaround. The daemon does it now, so a send
  // must not touch the title, whatever the snapshot says.
  const { calls, send } = agentSendHarness({ title: null, lastUserMessageAt: null });
  assert.deepEqual(
    await send({ op: "agent.send", agentId: "a1", prompt: "Name this session" }),
    { sent: true, images: 0 },
  );
  assert.deepEqual(calls, [{ kind: "send", prompt: "Name this session" }]);
});

test("fork context is capability-gated and snapshots the complete conversation", async () => {
  const snapshot = {
    workspaceId: "ws-source",
    cwd: "/work/source",
    title: "Source",
    currentModeId: "full-access",
    runtimeInfo: {
      provider: "codex",
      model: "gpt-5.6-sol",
      thinkingOptionId: "high",
    },
    features: [{ id: "fast_mode", type: "toggle", value: true }],
  };
  let buildArgs: any[] = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    agents: {
      ref() {
        return {
          async refresh() {},
          current() {
            return snapshot;
          },
        };
      },
    },
  })) as any;
  (ctx as any).daemon = {
    getLastServerInfoMessage: () => ({ features: { agentForkContext: true } }),
    async buildAgentForkContext(...args: any[]) {
      buildArgs = args;
      return {
        attachment: {
          type: "text",
          mimeType: "text/plain",
          contextKind: "chat_history",
          text: "complete",
        },
        itemCount: 17,
      };
    },
  };
  const result: any = await agentOps(ctx)["agent.forkContext"]({
    op: "agent.forkContext",
    agentId: "agent-source",
  });
  assert.deepEqual(buildArgs, ["agent-source"]);
  assert.deepEqual(result.attachment, {
    type: "text",
    mimeType: "text/plain",
    contextKind: "chat_history",
    text: "complete",
  });
  assert.equal(result.itemCount, 17);
  assert.equal(result.workspaceId, "ws-source");
  assert.equal(result.cwd, "/work/source");
  assert.deepEqual(result.config, {
    provider: "codex/gpt-5.6-sol",
    modeId: "full-access",
    thinkingOptionId: "high",
    featureValues: { fast_mode: true },
  });

  (ctx as any).daemon.getLastServerInfoMessage = () => ({ features: {} });
  await assert.rejects(
    () =>
      agentOps(ctx)["agent.forkContext"]({
        op: "agent.forkContext",
        agentId: "agent-source",
      }),
    /does not support agent forking/,
  );
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

test("plan limits come through whole, including a provider that failed", async () => {
  // `listProviderUsage` lives on the raw DaemonClient rather than the typed
  // API, so this also pins that the op reaches for `ctx.raw()` -- a typed-API
  // lookup would be undefined and throw.
  const ctx = new BridgeConnection();
  ctx.raw = (() => ({
    async listProviderUsage() {
      return {
        fetchedAt: "2026-09-21T10:00:00Z",
        providers: [
          {
            providerId: "claude",
            displayName: "Claude",
            status: "available",
            planLabel: "Max 20x",
            windows: [
              { id: "five_hour", label: "Session", usedPct: 23 },
              { id: "weekly", label: "Weekly", usedPct: 91 },
            ],
          },
          {
            providerId: "codex",
            displayName: "Codex",
            status: "unavailable",
            planLabel: null,
            windows: [],
            error: "not signed in",
          },
        ],
      };
    },
  })) as any;
  const usage: any = await providerOps(ctx)["providers.usage"]({
    op: "providers.usage",
  });
  assert.equal(usage.providers[0].planLabel, "Max 20x");
  assert.deepEqual(
    usage.providers[0].windows.map((w: any) => w.id),
    ["five_hour", "weekly"],
  );
  // An unavailable provider is passed through rather than filtered out: the
  // panel draws "not signed in", which is the answer to a question the user
  // asked, unlike a card that is silently missing.
  assert.equal(usage.providers[1].error, "not signed in");

  // A daemon too old for the request must not take the panel down with it.
  const empty = new BridgeConnection();
  empty.raw = (() => ({
    async listProviderUsage() {
      return undefined;
    },
  })) as any;
  assert.deepEqual(
    await providerOps(empty)["providers.usage"]({ op: "providers.usage" }),
    { fetchedAt: null, providers: [] },
  );
});

test("a workspace carries its project id, and a project can be forgotten", async () => {
  // `projectId` was read off the wire and dropped one field before it was
  // useful. Removing a project -- which the app offers beside archiving -- is
  // keyed on it and on nothing else, and for a `ws` workspace it is how you
  // get rid of the top-level project the daemon invented for
  // `<project>/.workspaces/<name>`.
  const removed: string[] = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    workspaces: {
      async list() {
        return {
          entries: [
            {
              id: "w1",
              name: "billing",
              workspaceDirectory: "/x/Code/openfin/.workspaces/billing",
              projectId: "prj_billing",
              projectDisplayName: "billing",
              projectRootPath: "/x/Code/openfin/.workspaces/billing",
              projectKind: "non_git",
              workspaceKind: "directory",
              status: "done",
            },
          ],
        };
      },
    },
  })) as any;
  ctx.raw = (() => ({
    async removeProject(id: string) {
      removed.push(id);
      // The daemon's real answer. This mock used to return `{ removed: true }`
      // -- the shape the op wrongly expected, so the test agreed with the bug.
      return { removedWorkspaceIds: ["wks_billing"] };
    },
  })) as any;

  const ops = workspaceOps(ctx);
  const page: any = await ops["workspaces.list"]({ op: "workspaces.list" });
  assert.equal(page.entries[0].projectId, "prj_billing");
  assert.deepEqual(
    await ops["project.remove"]({
      op: "project.remove",
      projectId: "prj_billing",
    }),
    { removed: true, removedWorkspaceIds: ["wks_billing"] },
  );
  assert.deepEqual(removed, ["prj_billing"]);

  // A missing id is an error, not a request that removes something else.
  await assert.rejects(() => ops["project.remove"]({ op: "project.remove" }));
});

test("an assembled workspace is created inside its project, not as one of its own", async () => {
  const created: any[] = [];
  const added: string[] = [];
  const opened: string[] = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    workspaces: {
      async list() {
        return {
          entries: [{ id: "wks_old", workspaceDirectory: "/code/kora/.workspaces/old/" }],
        };
      },
      ref: (id: string) =>
        id === "wks_old"
          ? { id, directory: "/code/kora/.workspaces/old" }
          : {
              id,
              directory: created.at(-1)?.source.path,
              projectId: created.at(-1)?.source.projectId,
            },
      async open(cwd: string) {
        opened.push(cwd);
        return { id: "wks_open", directory: cwd, projectId: "prj_invented" };
      },
    },
  })) as any;
  ctx.raw = (() => ({
    async addProject(cwd: string) {
      added.push(cwd);
      return { project: { projectId: "prj_kora" }, error: null };
    },
    // Through the RAW client: the typed `workspaces.create` drops the agent a
    // create-with-first-prompt makes.
    async createWorkspace(input: any) {
      created.push(input);
      return {
        workspace: { id: `wks_new${created.length}` },
        agent: input.agent ? { id: "agent_first" } : undefined,
        error: null,
      };
    },
  })) as any;
  const ops = workspaceOps(ctx);

  const fresh: any = await ops["workspace.open"]({
    op: "workspace.open",
    cwd: "/code/kora/.workspaces/billing",
    project: "/code/kora/",
  });
  assert.equal(fresh.projectId, "prj_kora");
  assert.deepEqual(added, ["/code/kora"]);
  assert.deepEqual(created[0].source, {
    kind: "directory",
    path: "/code/kora/.workspaces/billing",
    projectId: "prj_kora",
  });
  assert.deepEqual(opened, [], "never the find-or-create-by-directory path");

  // One that already exists is reused, whatever project it is under.
  const again: any = await ops["workspace.open"]({
    op: "workspace.open",
    cwd: "/code/kora/.workspaces/old",
    project: "/code/kora",
  });
  assert.equal(again.id, "wks_old");
  assert.equal(created.length, 1);

  // `create` names the project too, and keeps the title.
  await ops["workspace.create"]({
    op: "workspace.create",
    cwd: "/code/kora/.workspaces/billing",
    project: "/code/kora",
    title: "billing",
  });
  assert.equal(created[1].source.projectId, "prj_kora");
  assert.equal(created[1].title, "billing");

  // WITH a first prompt: the agent and the naming context ride the same
  // request, and the title is left off -- an explicit title is permanent and
  // would stop the daemon naming the workspace from the prompt.
  const withPrompt: any = await ops["workspace.create"]({
    op: "workspace.create",
    cwd: "/code/kora/.workspaces/billing",
    project: "/code/kora",
    title: "billing",
    prompt: "  Fix the invoice rounding  ",
    provider: "claude/opus",
    modeId: "plan",
  });
  const sent = created[2];
  assert.equal(sent.title, undefined, "no title beside a prompt");
  assert.deepEqual(sent.firstAgentContext, { prompt: "Fix the invoice rounding" });
  assert.equal(sent.agent.initialPrompt, "Fix the invoice rounding");
  assert.deepEqual(sent.agent.config, {
    provider: "claude",
    model: "opus",
    cwd: "/code/kora/.workspaces/billing",
    modeId: "plan",
  });
  assert.equal(withPrompt.agentId, "agent_first");

  // No project: an ordinary directory, which the daemon places itself.
  await ops["workspace.open"]({ op: "workspace.open", cwd: "/code/tracker" });
  assert.deepEqual(opened, ["/code/tracker"]);
});

test("a worktree with no branch is the daemon's to name", async () => {
  const created: any[] = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    workspaces: {
      ref: (id: string) => ({
        id,
        async fetch() {
          return { id, directory: "/code/kora-wt", projectId: "prj" };
        },
      }),
    },
  })) as any;
  ctx.raw = (() => ({
    async createWorkspace(input: any) {
      created.push(input);
      return { workspace: { id: "wks_auto" }, agent: { id: "a1" }, error: null };
    },
    async getBranchSuggestions(opts: any) {
      return {
        branches: ["main", "dev"],
        branchDetails: [{ name: "main", committerDate: 2 }],
        error: null,
        echoed: opts,
      };
    },
  })) as any;
  const ops = workspaceOps(ctx);

  await ops["workspace.create"]({
    op: "workspace.create",
    cwd: "/code/kora",
    worktree: true,
    base: "dev",
    prompt: "Fix the invoice rounding",
    provider: "claude/opus",
  });
  const source = created[0].source;
  assert.equal(source.kind, "worktree");
  assert.equal(source.refName, "dev");
  assert.equal("branchName" in source, false, "no branch: the daemon names it");
  assert.deepEqual(created[0].firstAgentContext, { prompt: "Fix the invoice rounding" });

  // A branch somebody chose is still sent.
  await ops["workspace.create"]({
    op: "workspace.create",
    cwd: "/code/kora",
    worktree: true,
    branch: "ws/mine",
    prompt: "x",
    provider: "claude/opus",
  });
  assert.equal(created[1].source.branchName, "ws/mine");

  const branches: any = await ops["branches"]({ op: "branches", cwd: "/code/kora" });
  assert.deepEqual(branches.branches, ["main", "dev"]);
  assert.equal(branches.details[0].name, "main");
});

test("stopping a turn goes through the raw client, which is the only one that has it", async () => {
  // `PaseoAgentHandle` has no cancel in 0.8.0 -- the typed API cannot express
  // this at all -- so the op reaches for `ctx.raw()`. That is not a
  // workaround: `paseo agent stop` calls exactly this method.
  const canceled: string[] = [];
  const ctx = new BridgeConnection();
  ctx.raw = (() => ({
    async cancelAgent(id: string) {
      canceled.push(id);
    },
  })) as any;
  const ops = agentOps(ctx);
  assert.deepEqual(
    await ops["agent.cancel"]({ op: "agent.cancel", agentId: "a1" }),
    { canceled: true },
  );
  assert.deepEqual(canceled, ["a1"]);
  await assert.rejects(() => ops["agent.cancel"]({ op: "agent.cancel" }));
});

test("dictation is raw PCM16 with the rate in the format string", async () => {
  // The format string is not decoration: the daemon parses the sample rate out
  // of it with /rate\s*=\s*(\d+)/ and resamples from there, and what rides
  // in `audio` is headerless little-endian PCM16 -- no wav, no webm, no opus.
  // Getting either wrong transcribes at the wrong speed rather than failing.
  const calls: any[] = [];
  const ctx = new BridgeConnection();
  ctx.raw = (() => ({
    async startDictationStream(id: string, format: string) {
      calls.push(["start", id, format]);
    },
    sendDictationStreamChunk(
      id: string,
      seq: number,
      audio: string,
      format: string,
    ) {
      calls.push(["chunk", id, seq, audio, format]);
    },
    async finishDictationStream(id: string, finalSeq: number) {
      calls.push(["finish", id, finalSeq]);
      return { dictationId: id, text: "hello there" };
    },
    cancelDictationStream(id: string) {
      calls.push(["cancel", id]);
    },
  })) as any;

  const ops = voiceOps(ctx);
  const format = "pcm16;rate=16000";
  await ops["dictation.start"]({ op: "dictation.start", dictationId: "d1", format });
  await ops["dictation.chunk"]({
    op: "dictation.chunk",
    dictationId: "d1",
    seq: 1,
    audio: "AAEC",
    format,
  });
  const done: any = await ops["dictation.finish"]({
    op: "dictation.finish",
    dictationId: "d1",
    finalSeq: 1,
  });
  assert.equal(done.text, "hello there");
  assert.deepEqual(calls, [
    ["start", "d1", format],
    ["chunk", "d1", 1, "AAEC", format],
    ["finish", "d1", 1],
  ]);

  await ops["dictation.cancel"]({ op: "dictation.cancel", dictationId: "d1" });
  assert.deepEqual(calls.at(-1), ["cancel", "d1"]);

  // A daemon with no speech model rejects the START, and that rejection is the
  // message worth showing -- `dispatch` turns it into {ok:false,error}, so the
  // op must not swallow it.
  const broken = new BridgeConnection();
  broken.raw = (() => ({
    async startDictationStream() {
      throw new Error("speech models are not downloaded");
    },
  })) as any;
  await assert.rejects(
    () =>
      voiceOps(broken)["dictation.start"]({
        op: "dictation.start",
        dictationId: "d2",
        format,
      }),
    /speech models are not downloaded/,
  );
});

test("a timeline item keeps its kind on the payload, not just in the event name", async () => {
  // THE BUG THAT MADE EVERY TOOL CARD INVISIBLE. `kind` is the event name the
  // Lua listens on AND the field its renderer dispatches on; emitting it as
  // only the former left every tool call, reasoning block, todo and notice
  // drawing literally nothing, while `text` and `user` survived because those
  // two rebuild `kind` on the Lua side. Asserted against the wire, because a
  // fixture that sets `kind` by hand is exactly what let this through.
  const lines = captureStdout(() => {
    emit("tool", {
      agentId: "a",
      ...(describeItem({
        type: "tool_call",
        callId: "c1",
        name: "Bash",
        status: "completed",
        error: null,
        detail: { type: "shell", command: "ls" },
      }) as any),
    });
  });
  const payload = JSON.parse(lines[0]!);
  assert.equal(payload.event, "tool");
  assert.equal(payload.kind, "tool");
  assert.equal(payload.callId, "c1");
});

test("describeSettings carries the daemon's pending permissions", () => {
  // The reconciliation data the Lua needs to notice a request answered on the
  // desktop. It was reaching the sidecar on a snapshot we were already
  // subscribed to and being dropped one function call before it was useful.
  const settings: any = describeSettings({
    runtimeInfo: { provider: "claude", model: "opus" },
    pendingPermissions: [{ id: "req-1", name: "Bash" }],
  });
  assert.deepEqual(
    settings.pendingPermissions.map((r: any) => r.id),
    ["req-1"],
  );
  // No pendings is an EMPTY LIST, never absent: the Lua treats nil as "this
  // sidecar is too old to say" and would skip reconciling entirely.
  assert.deepEqual(describeSettings({}).pendingPermissions, []);
});

test("describeAgent carries what the workspace column sorts by", () => {
  // A turn that FAILED while nobody watched, with nothing pending: the daemon
  // wants attention, ours does not, and the reason is what tells red from a
  // plain unread finish.
  const failed: any = describeAgent({
    id: "a1",
    status: "idle",
    requiresAttention: true,
    attentionReason: "error",
    pendingPermissions: [],
  });
  assert.equal(failed.requiresAttention, false);
  assert.equal(failed.daemonAttention, true);
  assert.equal(failed.attentionReason, "error");
  assert.equal(failed.pendingPermissionCount, 0);

  const asking: any = describeAgent({ id: "a2", pendingPermissions: [{ id: "r" }] });
  assert.equal(asking.requiresAttention, true);
  assert.equal(asking.pendingPermissionCount, 1);
  // Absent on the wire is null and false, never undefined: a missing key is
  // dropped by JSON and the Lua cannot tell "no" from "too old to say".
  assert.equal(asking.attentionReason, null);
  assert.equal(asking.daemonAttention, false);
});

test("terminal input survives the trip as bytes, and output coalesces", async () => {
  const sent: any[] = [];
  let handler: ((event: any) => void) | null = null;
  const ctx = new BridgeConnection();
  (ctx as any).daemon = {
    // The 0.15 shape: an observation handed the receiver, released by handle.
    observeTerminal(_id: string, receive: (event: any) => void) {
      handler = receive;
      return { ready: Promise.resolve({ error: null, slot: 1 }), release: async () => {} };
    },
    getLastServerInfoMessage: () => ({ features: {} }),
    async captureTerminal() {
      return { lines: [] };
    },
    sendTerminalInput(id: string, message: any) {
      sent.push({ id, message });
    },
  };
  const ops = terminalOps(ctx);

  await ops["terminals.attach"]!({ op: "x", terminalId: "t", rows: 10, cols: 40 });

  // `é` is the whole point: the frame encoder runs a string payload through
  // TextEncoder, so decoding our base64 to latin1 would re-encode every byte
  // above 0x7f as two and deliver mojibake to the PTY.
  const typed = "echo é\r";
  await ops["terminals.input"]!({
    op: "x",
    terminalId: "t",
    data: Buffer.from(typed, "utf8").toString("base64"),
  });
  assert.equal(sent.at(-1)!.message.data, typed);

  // Many small PTY writes must reach Neovim as few lines, not thousands.
  const lines = await captureStdoutAsync(async () => {
    // The scrollback replay, as SDK 0.15 delivers it: begin, data, end. Only
    // the data is bytes for the screen. Reading only the pre-0.15 `restore`
    // drew a blank terminal until the next byte of live output.
    handler!({ terminalId: "t", type: "replay", replay: { type: "begin", rows: 10, cols: 40 } });
    handler!({ terminalId: "t", type: "replay", replay: { type: "data", data: new TextEncoder().encode("a") } });
    handler!({ terminalId: "t", type: "replay", replay: { type: "end" } });
    handler!({ terminalId: "t", type: "output", data: new TextEncoder().encode("b") });
    // A cell grid for clients that render their own terminal. We do not.
    handler!({ terminalId: "t", type: "snapshot", state: {} });
    await new Promise((done) => setTimeout(done, 40));
  });
  const outputs = lines.map((l) => JSON.parse(l)).filter((m) => m.event === "terminal_output");
  assert.equal(outputs.length, 1);
  assert.equal(Buffer.from(outputs[0].data, "base64").toString("utf8"), "ab");

  // Detached means detached: bytes still in flight have nowhere to land.
  await ops["terminals.detach"]!({ op: "x", terminalId: "t" });
  const after = await captureStdoutAsync(async () => {
    handler!({ terminalId: "t", type: "output", data: new TextEncoder().encode("c") });
    await new Promise((done) => setTimeout(done, 40));
  });
  assert.equal(after.filter((l) => l.includes("terminal_output")).length, 0);
});

test("subagent updates reach Lua as the events it listens for, in the chat's item shape", async () => {
  let deliver: ((message: any) => void) | null = null;
  const subscribed: string[][] = [];
  const ctx = new BridgeConnection();
  ctx.connected = (() => ({
    observeEvents(events: string[]) {
      subscribed.push(events);
      return {
        subscribe({ update }: any) {
          deliver = update;
        },
        ready: Promise.resolve(),
        async release() {},
      };
    },
  })) as any;
  ctx.raw = (() => ({
    async listProviderSubagents(parent: string) {
      return { subagents: [{ id: "t1", parentAgentId: parent, title: "Explore", status: "running", extra: "dropped" }] };
    },
    async fetchProviderSubagentTimeline(_parent: string, _id: string, options: any) {
      assert.equal(options.direction, "tail");
      return {
        epoch: "e1",
        window: { minSeq: 1, maxSeq: 2, nextSeq: 3 },
        rows: [
          { seq: 1, item: { type: "assistant_message", text: "looking" } },
          { seq: 2, item: { type: "plugin", id: "x" } },
        ],
      };
    },
  })) as any;
  const ops = subagentOps(ctx);

  await ops["subagents.follow"]({ op: "subagents.follow" });
  assert.deepEqual(subscribed, [["agent.provider_subagents.update"]]);
  assert.equal((await ops["subagents.follow"]({ op: "subagents.follow" }) as any).already, true);

  const lines = captureStdout(() => {
    deliver!({
      type: "agent.provider_subagents.update",
      payload: { kind: "upsert", subagent: { id: "t1", parentAgentId: "p", status: "completed" } },
    });
    deliver!({
      type: "agent.provider_subagents.update",
      payload: {
        kind: "timeline",
        parentAgentId: "p",
        subagentId: "t1",
        item: { type: "assistant_message", text: "done" },
        seq: 7,
        epoch: "e1",
      },
    });
    deliver!({
      type: "agent.provider_subagents.update",
      payload: { kind: "remove", parentAgentId: "p", subagentId: "t1" },
    });
  }).map((line) => JSON.parse(line));

  assert.equal(lines[0].event, "subagent");
  assert.equal(lines[0].subagent.status, "completed");
  assert.deepEqual(
    { event: lines[1].event, kind: lines[1].kind, text: lines[1].text, seq: lines[1].seq, subagentId: lines[1].subagentId },
    { event: "subagent_item", kind: "text", text: "done", seq: 7, subagentId: "t1" },
  );
  assert.deepEqual({ event: lines[2].event, kind: lines[2].kind }, { event: "subagent", kind: "remove" });

  const listed: any = await ops["subagents.list"]({ op: "subagents.list", agentId: "p" });
  assert.equal(listed.subagents[0].title, "Explore");
  assert.equal(listed.subagents[0].extra, undefined);

  // An item with nothing to render is skipped, not drawn as a blank card.
  const history: any = await ops["subagent.history"]({ op: "subagent.history", agentId: "p", subagentId: "t1" });
  assert.deepEqual(history.items, [{ kind: "text", text: "looking", seq: 1 }]);
  assert.equal(history.seq, 2);
  assert.equal(history.epoch, "e1");
});

test("a workspace carries what the app's sidebar row shows: lines changed, branch, PR and CI", () => {
  const ws = describeWorkspace({
    id: "w1",
    name: "rail-tree",
    workspaceDirectory: "/code/paseo.nvim",
    status: "running",
    statusEnteredAt: "2026-11-13T06:00:00Z",
    diffStat: { additions: 120, deletions: 7 },
    gitRuntime: { currentBranch: "feat/tree", isDirty: true, aheadOfOrigin: 2, behindOfOrigin: 0 },
    githubRuntime: {
      pullRequest: {
        url: "https://github.com/o/r/pull/42",
        title: "tree",
        state: "open",
        isMerged: false,
        isDraft: false,
        checks: [
          { name: "lint", status: "success" },
          { name: "test", status: "pending" },
          { name: "build", status: "weird-forge-string" },
        ],
        reviewDecision: "approved",
      },
    },
  });
  assert.deepEqual(ws.diffStat, { additions: 120, deletions: 7 });
  assert.equal(ws.branch, "feat/tree");
  assert.equal(ws.dirty, true);
  assert.equal(ws.ahead, 2);
  assert.equal(ws.statusEnteredAt, "2026-11-13T06:00:00Z");
  // The number comes off the URL when the forge did not send one; a check in
  // a vocabulary nobody knows is still running, as the app reads it.
  assert.deepEqual(
    { n: ws.pr.number, s: ws.pr.state, c: ws.pr.checks, d: ws.pr.checksDone, t: ws.pr.checksTotal, r: ws.pr.review },
    { n: 42, s: "open", c: "running", d: 1, t: 3, r: "approved" },
  );

  // A detached HEAD is no branch, and no PR and no stat are null, not zero.
  const bare = describeWorkspace({ id: "w2", gitRuntime: { currentBranch: "HEAD" } });
  assert.equal(bare.branch, null);
  assert.equal(bare.pr, null);
  assert.equal(bare.diffStat, null);

  // One failure fails the lot, however many are still going.
  const failed = describePullRequest({
    url: "https://github.com/o/r/pull/7",
    state: "OPEN",
    checks: [{ status: "failure" }, { status: "pending" }],
  });
  assert.equal(failed.checks, "failed");
  assert.equal(failed.state, "open");
  // A summary without the checks themselves still says something.
  assert.equal(describePullRequest({ url: "https://x/pull/1", state: "open", checksStatus: "success" }).checks, "passed");
  assert.equal(describePullRequest({ url: "https://x/pull/1", state: "open", checksStatus: "none" }).checks, null);
  assert.equal(describePullRequest({ url: "https://x/pull/1", state: "closed", isMerged: true }).state, "merged");
  assert.equal(describePullRequest({ url: "https://gitlab.com/o/r/-/merge_requests/9", state: "closed" }).number, 9);
  assert.equal(describePullRequest(null), null);
});

// ------------------------------------------------------------- scheduling

import { createScheduler, laneOf } from "./bridge-dispatch.ts";

/** A `run` whose ops take as long as `delays[op]` says, and a log of starts/ends. */
function recorder(delays: Record<string, number>) {
  const log: string[] = [];
  const run = async (req: any) => {
    const name = `${req.op}#${req.id}`;
    log.push(`start ${name}`);
    await new Promise((r) => setTimeout(r, delays[req.op] ?? 0));
    log.push(`end ${name}`);
  };
  return { log, run };
}

test("scheduler: nothing starts before an earlier connect has finished", async () => {
  const { log, run } = recorder({ connect: 30 });
  const schedule = createScheduler(run);
  const all = [
    schedule({ op: "connect", id: 1 }),
    schedule({ op: "providers", id: 2 }),
    schedule({ op: "workspaces.list", id: 3 }),
  ];
  await Promise.all(all);
  assert.equal(log[0], "start connect#1");
  assert.equal(log[1], "end connect#1");
});

test("scheduler: a slow read does not hold up an unrelated one", async () => {
  const { log, run } = recorder({ providers: 60, "timeline.history": 1 });
  const schedule = createScheduler(run);
  const slow = schedule({ op: "providers", id: 1 });
  const fast = schedule({ op: "timeline.history", id: 2, agentId: "a" });
  await fast;
  assert.ok(log.includes("end timeline.history#2"));
  assert.ok(!log.includes("end providers#1"), "history waited for providers");
  await slow;
});

test("scheduler: requests about the same thing keep their order", async () => {
  const { log, run } = recorder({ "terminals.input": 20, "timeline.subscribe": 30 });
  const schedule = createScheduler(run);
  await Promise.all([
    schedule({ op: "terminals.input", id: 1, terminalId: "t" }),
    schedule({ op: "terminals.input", id: 2, terminalId: "t" }),
    schedule({ op: "timeline.subscribe", id: 3, agentId: "a" }),
    schedule({ op: "timeline.history", id: 4, agentId: "a" }),
  ]);
  assert.ok(log.indexOf("end terminals.input#1") < log.indexOf("start terminals.input#2"));
  assert.ok(log.indexOf("end timeline.subscribe#3") < log.indexOf("start timeline.history#4"));
});

test("scheduler: close waits for what is running, and later requests wait for close", async () => {
  const { log, run } = recorder({ providers: 30, close: 10 });
  const schedule = createScheduler(run);
  await Promise.all([
    schedule({ op: "providers", id: 1 }),
    schedule({ op: "close", id: 2 }),
    schedule({ op: "connect", id: 3 }),
    schedule({ op: "agents.list", id: 4 }),
  ]);
  assert.ok(log.indexOf("end providers#1") < log.indexOf("start close#2"));
  assert.ok(log.indexOf("end close#2") < log.indexOf("start connect#3"));
  assert.ok(log.indexOf("end connect#3") < log.indexOf("start agents.list#4"));
});

test("scheduler: a turn neither blocks its agent's lane nor a close", async () => {
  const { log, run } = recorder({ "agent.run": 80 });
  const schedule = createScheduler(run);
  void schedule({ op: "agent.run", id: 1, agentId: "a" });
  await new Promise((r) => setTimeout(r, 5));
  await schedule({ op: "agent.send", id: 2, agentId: "a" });
  await schedule({ op: "close", id: 3 });
  assert.ok(!log.includes("end agent.run#1"), "waited for the turn");
});

test("scheduler: a failing op does not deafen the rest", async () => {
  const errors: unknown[] = [];
  const schedule = createScheduler(
    async (req: any) => {
      if (req.id === 1) throw new Error("boom");
    },
    (e) => errors.push(e),
  );
  await schedule({ op: "x", id: 1 });
  let ran = false;
  const after = createScheduler(async () => {
    ran = true;
  });
  await after({ op: "y", id: 2 });
  await schedule({ op: "y", id: 2 });
  assert.equal(errors.length, 1);
  assert.ok(ran);
});

test("scheduler: two workspace-makers on one directory go one at a time", () => {
  assert.equal(laneOf({ op: "workspace.open", cwd: "/x" }), "cwd:/x");
  assert.equal(laneOf({ op: "agent.start", cwd: "/x" }), "cwd:/x");
  assert.equal(laneOf({ op: "providers", cwd: "/x" }), null);
});

import { followDirectory } from "./bridge-agents.ts";

test("followDirectory: two at once subscribe once", async () => {
  const ctx = new BridgeConnection();
  let lists = 0;
  const subscription = { subscribe() {}, release: async () => {} };
  (ctx as any).connected = () => ({
    agents: {
      list: async () => {
        lists += 1;
        await new Promise((r) => setTimeout(r, 20));
        return { subscription };
      },
    },
    workspaces: { list: async () => ({ subscription }) },
  });
  await Promise.all([followDirectory(ctx), followDirectory(ctx)]);
  assert.equal(lists, 1);
  assert.ok(ctx.directory);
  await followDirectory(ctx);
  assert.equal(lists, 1);
});

test("history lists only archived agents, with the names a search matches", () => {
  const rows = describeHistory([
    { agent: { id: "live", title: "Live", archivedAt: null }, project: {} },
    {
      agent: { id: "internal", title: "x", archivedAt: "2026-01-01", internal: true },
      project: {},
    },
    {
      agent: {
        id: "old",
        title: "Old chat",
        status: "closed",
        cwd: "/w/old",
        archivedAt: "2026-01-02",
        updatedAt: "2026-01-03",
      },
      project: {
        projectName: "paseo.nvim",
        workspaceName: "search",
        checkout: { currentBranch: "feat/search" },
      },
    },
  ]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, "old");
  assert.equal(rows[0].branch, "feat/search");
  assert.equal(rows[0].workspaceName, "search");
  assert.equal(rows[0].projectName, "paseo.nvim");
  assert.equal(rows[0].archivedAt, "2026-01-02");
  assert.equal(rows[0].updatedAt, "2026-01-03");
});

test("history asks newest first and never fails the search", async () => {
  let asked: any = null;
  const ctx = new BridgeConnection();
  (ctx as any).daemon = {
    async fetchAgentHistory(options: any) {
      asked = options;
      return { entries: [] };
    },
  };
  assert.deepEqual(
    await agentOps(ctx)["agents.history"]({ op: "agents.history", limit: 500 }),
    { entries: [] },
  );
  assert.deepEqual(asked.sort, [{ key: "updated_at", direction: "desc" }]);
  assert.equal(asked.page.limit, 200);

  (ctx as any).daemon = {
    async fetchAgentHistory() {
      throw new Error("unknown message");
    },
  };
  assert.deepEqual(
    await agentOps(ctx)["agents.history"]({ op: "agents.history" }),
    { entries: [] },
  );
});

test("history scoped to a project is filtered by the daemon on its ids", async () => {
  let asked: any = null;
  const ctx = new BridgeConnection();
  (ctx as any).daemon = {
    async fetchWorkspaces() {
      return {
        entries: [
          { projectId: "p1", projectRootPath: "/x/app/" },
          { projectId: "p9", projectRootPath: "/x/other" },
        ],
        // A project whose workspaces are all archived is still this one.
        emptyProjects: [{ projectId: "p2", projectRootPath: "/x/app" }],
      };
    },
    async fetchAgentHistory(options: any) {
      asked = options;
      return {
        entries: [
          { agent: { id: "mine", archivedAt: "1" }, project: { projectKey: "p1" } },
          // A daemon too old for the filter sends everyone's; dropped here.
          { agent: { id: "theirs", archivedAt: "1" }, project: { projectKey: "p9" } },
        ],
      };
    },
  };
  const ops = agentOps(ctx);
  const result: any = await ops["agents.history"]({
    op: "agents.history",
    projectIds: ["p0"],
    projectRoots: ["/x/app"],
  });
  assert.deepEqual(asked.filter.projectKeys.sort(), ["p0", "p1", "p2"]);
  assert.deepEqual(result.projectIds.sort(), ["p0", "p1", "p2"]);
  assert.deepEqual(result.entries.map((e: any) => e.id), ["mine"]);
  assert.equal(result.entries[0].projectKey, "p1");

  // Not a project at all: no history asked for, and it says so.
  asked = null;
  (ctx as any).daemon.fetchWorkspaces = async () => ({ entries: [], emptyProjects: [] });
  assert.deepEqual(
    await ops["agents.history"]({ op: "agents.history", projectIds: [], projectRoots: ["/x/none"] }),
    { entries: [], projectIds: [] },
  );
  assert.equal(asked, null);

  // Unscoped: no filter, as before.
  await ops["agents.history"]({ op: "agents.history" });
  assert.equal((asked as any).filter, undefined);
});

test("prompt index is capability-gated without throwing", async () => {
  let asked: string | null = null;
  const ctx = new BridgeConnection();
  (ctx as any).daemon = {
    getLastServerInfoMessage: () => ({ features: {} }),
    async listAgentTimelinePrompts(id: string) {
      asked = id;
      return { prompts: [] };
    },
  };
  const ops = timelineOps(ctx);
  assert.deepEqual(await ops["timeline.prompts"]({ op: "timeline.prompts", agentId: "a1" }), {
    unsupported: true,
    prompts: [],
  });
  assert.equal(asked, null);

  (ctx as any).daemon = {
    getLastServerInfoMessage: () => ({
      features: { agentTimelinePromptIndex: true },
    }),
    async listAgentTimelinePrompts(id: string) {
      asked = id;
      return {
        epoch: "e1",
        error: null,
        prompts: [{ seq: 4, timestamp: "t", preview: "fix the rail" }],
      };
    },
  };
  assert.deepEqual(await ops["timeline.prompts"]({ op: "timeline.prompts", agentId: "a1" }), {
    epoch: "e1",
    prompts: [{ seq: 4, timestamp: "t", preview: "fix the rail" }],
  });
  assert.equal(asked, "a1");
});
