---
name: paseo-sdk
description: Build a program that drives a Paseo daemon through the `@getpaseo/client` TypeScript SDK over its WebSocket API — creating and resuming agents, streaming timeline events, managing workspaces and terminals, discovering providers and models. Use when writing or debugging code that talks to Paseo (a sidecar, bridge, editor integration, dashboard, webhook handler, or CI job), or when asked about `createPaseoClient`, `agents.create/run/ref`, `timeline.subscribe`, `workspaces.open/create`, `ws://…/ws`, or agent labels. For driving Paseo by hand use the `paseo` skill (CLI/MCP); for "how do I configure Paseo" use `paseo-help`.
---

# Paseo TypeScript SDK

`@getpaseo/client` drives a Paseo daemon from your own program. You pick a
provider and model, give an agent a prompt and a directory, and the daemon does
the work: it launches the provider CLI, keeps the session alive, and streams it
to the Paseo app. Agents you create appear next to hand-started ones and
**outlive your process**.

Requires Node.js 22+. Bun works too.

```bash
npm install @getpaseo/client
```

## The whole thing in one block

```ts
import { createPaseoClient } from "@getpaseo/client";

const client = createPaseoClient({ url: "ws://127.0.0.1:6767/ws" });
await client.connect();                       // resolves once the daemon identifies itself

const agent = await client.agents.create({
  config: { provider: "claude/claude-sonnet-5" },   // ALWAYS "provider/model"
  cwd: "/home/me/dev/storefront",
  prompt: "Review the current diff and name the riskiest change.",
});

const result = await agent.waitForFinish();   // 10 min default; pass ms to change
if (result.status === "idle") console.log(result.lastMessage);

await client.close();                          // does NOT stop the agent
```

## The seven things that bite

1. **`create()` resolves when the session exists, not when the prompt is done.**
   Await `waitForFinish()` or `run()` for the turn.
2. **`waitForFinish()` returns a status; it does not throw on a failed turn.**
   `idle` (done, ready for more) · `permission` (a human must answer in Paseo)
   · `error` (provider ended the turn badly) · `timeout` (deadline elapsed —
   **the agent is still running**; a timeout does not cancel it).
3. **Never infer turn completion from an `agent_update` transition to `idle`.**
   Use the `turn_completed` / `turn_failed` / `turn_canceled` timeline events.
4. **`ref(id)` does not contact the daemon.** Every property (`status`, `cwd`,
   `workspaceId`, …) reads `null` until `refresh()`, `run()`, `waitForFinish()`,
   a timeline refetch, or a `subscribe()` snapshot arrives. `current()` returns
   the whole snapshot, and distinguishes "not observed" from "observed as null".
5. **Closing the client does not archive anything.** Archive temporary agents
   yourself, in a `finally`. Never archive agents your integration did not
   create.
6. **Assistant messages arrive in pieces.** Concatenate the streamed text, or
   use `run()` and read `lastMessage` when you only want the final reply.
7. **`config.options` is strictly validated per provider.** A misspelled key
   fails agent creation rather than being ignored — which is a feature.

## Streaming instead of waiting

```ts
const unsubscribe = agent.timeline.subscribe((update) => {
  const { event } = update;
  if (event.type === "timeline" && event.item.type === "assistant_message") {
    process.stdout.write(event.item.text);
  }
  if (event.type === "turn_completed") console.log("\ndone");
  if (event.type === "subscription_restored") { /* reconnected; history NOT replayed */ }
  if (event.type === "replacement") { void agent.timeline.refetch(); }  // old epoch invalid
  if (event.type === "error") { /* observation stopped; establish a new one */ }
});
await unsubscribe.ready;     // initial subscription acknowledged
```

Render from the snapshot first, then apply updates. See
`references/events.md` — epochs, cursors, reconnect recovery and directory
subscriptions are the part that rots if you improvise it.

## Finding your way back

Persist IDs, do not recreate. `client.agents.ref(id)` and
`client.workspaces.ref(id)` rebuild handles. **Labels** are
application-owned metadata for exactly this — namespace the keys:

```ts
await client.agents.create({ /* … */ labels: { "my-app-role": "planner" } });
const page = await client.agents.list({ filter: { labels: { "my-app-role": "planner" } } });
```

## Where to read next

Load only what the task needs.

| File | When |
|---|---|
| `references/quickstart.md` | connecting, passwords, remote daemons |
| `references/agents.md` | follow-ups, subagents, structured output, `commands()`, archive/detach |
| `references/events.md` | **subscriptions, epochs, cursors, reconnect** — read before writing any live UI |
| `references/workspaces.md` | reusing a directory, creating a worktree, terminals |
| `references/providers.md` | discovering installed providers, models, modes, features |
| `references/provider-options.md` | sandboxing and provider-native settings (codex / claude / opencode) |
| `references/reference.md` | the full API surface: every method, option and handle property |
| `references/recipes.md` | issue → agent, parallel reviewers, resident roles, cleanup |
| `references/transport.md` | **endpoint discovery, measured latencies, why not the CLI** |

Upstream docs: <https://paseo.sh/docs/sdk.md>. The current index of every Paseo
doc page is <https://paseo.sh/llms.txt>; fetch it when a question falls outside
the SDK.
