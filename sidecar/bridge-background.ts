import { need, guarded, emit, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";

/**
 * BACKGROUND WORK: what an agent left running after its turn. A Claude
 * `run_in_background` shell, a Codex or OpenCode monitor, and (0.17) the
 * daemon's own: a heartbeat schedule aimed at the agent, a PR/MR watch.
 *
 * The daemon keeps one live list per agent and pushes the WHOLE list as
 * `agent.background_work.update` whenever it changes; there is no delta. An
 * item that can be stopped carries `canStop` and a `stopToken`, which the stop
 * request must echo -- a token from before the item was replaced is refused
 * ("no longer available to stop"), so a stop never lands on the wrong thing.
 *
 * Two capabilities, as the app gates them (`background-work/host.ts`):
 * `agentBackgroundWork` for the list and the stream, `agentBackgroundWorkStop`
 * for stopping. Without the second, `canStop`/`stopToken` are stripped, so no
 * Stop is offered that the host would refuse.
 */

/** One item, with only the fields the Lua draws. */
export function describeBackgroundItem(item: any, canStop: boolean) {
  const stoppable = canStop && item?.canStop === true && !!item?.stopToken;
  return {
    id: String(item?.id ?? ""),
    kind: String(item?.kind ?? "other"),
    description: item?.description ?? null,
    command: item?.command ?? null,
    startedAt: item?.startedAt ?? null,
    canStop: stoppable,
    stopToken: stoppable ? String(item.stopToken) : null,
  };
}

function features(ctx: BridgeConnection): Record<string, unknown> {
  return (ctx.raw().getLastServerInfoMessage()?.features ?? {}) as Record<
    string,
    unknown
  >;
}

export function backgroundOps(ctx: BridgeConnection): Ops {
  // One stream for every agent, held for the life of the connection, like the
  // subagent one: the daemon only sends these to a client that asked for the
  // event by name.
  let following: { release: () => Promise<void> } | null = null;

  const canStop = () => features(ctx).agentBackgroundWorkStop === true;

  return {
    async "background.follow"() {
      if (features(ctx).agentBackgroundWork !== true) {
        return { following: false, supported: false };
      }
      if (following) return { following: true, already: true, supported: true };
      const observation: any = ctx.raw().observeAgentBackgroundWork();
      let first = true;
      observation.subscribe({
        // A snapshot after the first is the stream coming back after a
        // reconnect: whatever changed meanwhile was never pushed, so the Lua
        // lists again.
        snapshot: guarded("background", () => {
          if (first) {
            first = false;
            return;
          }
          emit("background_resync", {});
        }),
        update: guarded("background", (message: any) => {
          if (message?.type !== "agent.background_work.update") return;
          const payload = message.payload ?? {};
          const stop = canStop();
          emit("background", {
            agentId: payload.agentId,
            items: (payload.items ?? []).map((item: any) =>
              describeBackgroundItem(item, stop),
            ),
          });
        }),
      });
      following = observation;
      ctx.addCleanup(async () => {
        const held = following;
        following = null;
        await held?.release().catch(() => {});
      });
      await observation.ready;
      return { following: true, supported: true };
    },

    async "background.list"(req) {
      const agentId = String(need(req.agentId, "agentId"));
      if (features(ctx).agentBackgroundWork !== true) {
        return { agentId, items: [], supported: false };
      }
      const items: any[] = await ctx.raw().listAgentBackgroundWork(agentId);
      const stop = canStop();
      return {
        agentId,
        items: (items ?? []).map((item) => describeBackgroundItem(item, stop)),
        supported: true,
      };
    },

    async "background.stop"(req) {
      const agentId = String(need(req.agentId, "agentId"));
      const itemId = String(need(req.itemId, "itemId"));
      const stopToken = String(need(req.stopToken, "stopToken"));
      // The client checks the capability and the token itself and throws a
      // sentence the Lua can show as it is.
      await ctx.raw().stopAgentBackgroundWork(agentId, {
        id: itemId,
        stopToken,
        canStop: true,
      } as any);
      return { agentId, itemId, stopped: true };
    },
  };
}
