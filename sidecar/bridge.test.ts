import { test } from "node:test";
import assert from "node:assert/strict";
import { BridgeConnection } from "./bridge-connection.ts";
import {
  agentOps,
  matchesReviewAgent,
  creationConfig,
} from "./bridge-agents.ts";
import { providerOps, describeSettings } from "./bridge-providers.ts";
import { describeItem } from "./bridge-timeline.ts";
import { terminalOps } from "./bridge-terminals.ts";
import { workspaceOps } from "./bridge-workspaces.ts";
import { voiceOps } from "./bridge-voice.ts";
import { emit } from "./bridge-io.ts";

/** stdout IS the protocol, so asserting on it is asserting on the wire. */
function captureStdout(run: () => void): string[] {
  const lines: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  (process.stdout as any).write = (chunk: any) => {
    lines.push(...String(chunk).split("\n").filter(Boolean));
    return true;
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
  (process.stdout as any).write = (chunk: any) => {
    lines.push(...String(chunk).split("\n").filter(Boolean));
    return true;
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
      return { removed: true };
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
    { removed: true },
  );
  assert.deepEqual(removed, ["prj_billing"]);

  // A missing id is an error, not a request that removes something else.
  await assert.rejects(() => ops["project.remove"]({ op: "project.remove" }));
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

test("terminal input survives the trip as bytes, and output coalesces", async () => {
  const sent: any[] = [];
  let handler: ((event: any) => void) | null = null;
  const ctx = new BridgeConnection();
  (ctx as any).daemon = {
    onTerminalStreamEvent(fn: (event: any) => void) {
      handler = fn;
      return () => {};
    },
    getLastServerInfoMessage: () => ({ features: {} }),
    async subscribeTerminal() {
      return { error: null, slot: 1 };
    },
    async captureTerminal() {
      return { lines: [] };
    },
    sendTerminalInput(id: string, message: any) {
      sent.push({ id, message });
    },
    unsubscribeTerminal() {},
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
    handler!({ terminalId: "t", type: "restore", data: new TextEncoder().encode("a") });
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
