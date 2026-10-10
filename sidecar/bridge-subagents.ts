import { need, guarded, emit, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { describeItem } from "./bridge-timeline.ts";

/**
 * Subagents, of the PROVIDER's kind: Claude's Task tool, Codex's spawned
 * agents. The daemon tracks them per parent agent -- a descriptor each, and a
 * timeline of their own -- and pushes both as `agent.provider_subagents.update`.
 *
 * Read-only by construction. The protocol has a list, a timeline fetch and the
 * update stream for these, and no message that sends one anything: a provider
 * subagent is driven by its parent, not by the person watching it. The other
 * kind -- an agent started THROUGH Paseo, labelled `paseo.parent-agent-id` -- is
 * an ordinary agent, needs nothing here, and takes messages like any other.
 */

/** One descriptor, with only the fields the Lua draws. */
export function describeSubagent(subagent: any) {
  return {
    id: String(subagent?.id ?? ""),
    parentAgentId: String(subagent?.parentAgentId ?? ""),
    parentSubagentId: subagent?.parentSubagentId ?? null,
    provider: subagent?.provider ?? null,
    title: subagent?.title ?? null,
    description: subagent?.description ?? null,
    subtitle: subagent?.subtitle ?? null,
    status: subagent?.status ?? "running",
    createdAt: subagent?.createdAt ?? null,
    updatedAt: subagent?.updatedAt ?? null,
    cwd: subagent?.cwd ?? null,
  };
}

/** One `agent.provider_subagents.update` payload, as the event(s) Lua gets. */
export function forwardSubagentUpdate(payload: any): void {
  if (payload?.kind === "upsert" && payload.subagent) {
    emit("subagent", { kind: "upsert", subagent: describeSubagent(payload.subagent) });
  } else if (payload?.kind === "remove") {
    emit("subagent", {
      kind: "remove",
      parentAgentId: payload.parentAgentId,
      subagentId: payload.subagentId,
    });
  } else if (payload?.kind === "timeline") {
    // The SAME item shape as a parent's timeline, so the Lua draws a
    // subagent's work with the cards it already has.
    const described = describeItem(payload.item);
    if (described) {
      emit("subagent_item", {
        parentAgentId: payload.parentAgentId,
        subagentId: payload.subagentId,
        ...described,
        seq: payload.seq ?? null,
        epoch: payload.epoch ?? null,
      });
    }
  }
}

export function subagentOps(ctx: BridgeConnection): Ops {
  // One stream for every parent, held for the life of the connection. The
  // daemon only sends these updates to a client that asked for the event by
  // name -- explicit event subscriptions -- so without this a chat never hears
  // that a subagent started.
  let following: { release: () => Promise<void> } | null = null;

  return {
    async "subagents.follow"() {
      if (following) return { following: true, already: true };
      const observation: any = ctx
        .connected()
        .observeEvents(["agent.provider_subagents.update"]);
      observation.subscribe({
        snapshot: () => {},
        update: guarded("subagents", (message: any) => {
          if (message?.type === "agent.provider_subagents.update") {
            forwardSubagentUpdate(message.payload);
          }
        }),
      });
      following = observation;
      // A reconnect builds a new client; the next follow has to subscribe on
      // that one rather than answer `already` about a socket that is gone.
      ctx.addCleanup(async () => {
        const held = following;
        following = null;
        await held?.release().catch(() => {});
      });
      await observation.ready;
      return { following: true };
    },

    async "subagents.list"(req) {
      const parent = String(need(req.agentId, "agentId"));
      const result: any = await ctx.raw().listProviderSubagents(parent);
      return { subagents: (result?.subagents ?? []).map(describeSubagent) };
    },

    async "subagent.history"(req) {
      const parent = String(need(req.agentId, "agentId"));
      const subagent = String(need(req.subagentId, "subagentId"));
      const result: any = await ctx.raw().fetchProviderSubagentTimeline(parent, subagent, {
        direction: "tail",
        limit: Number(req.limit ?? 200),
      });
      const items = [];
      for (const row of result?.rows ?? []) {
        const described = describeItem(row.item);
        if (described) items.push({ ...described, seq: row.seq ?? null });
      }
      return {
        items,
        epoch: result?.epoch ?? null,
        seq: result?.window?.maxSeq ?? null,
      };
    },
  };
}
