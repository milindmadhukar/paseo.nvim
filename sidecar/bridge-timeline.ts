import { buildToolCallDisplayModel } from "@getpaseo/protocol/tool-call-display";
import { need, guarded, emit, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { withFallbackActions } from "./bridge-normalize.ts";

/**
 * ONE timeline item, flattened for Lua. Used by BOTH the live subscription and
 * the history fetch, so a reply looks the same whether it just arrived or was
 * loaded from the daemon on open.
 *
 * This used to forward only assistant_message and user_message, and the comment
 * here said tool calls "belong in the Paseo app, not here". That was the whole
 * bug: the agent reading a file, running a command or thinking never reached
 * Neovim, so the window showed a long silence and then an answer.
 *
 * `kind` is the event name the Lua listens on. Returning null means the item is
 * bookkeeping with nothing to render -- plugin items, for now.
 */
export function describeItem(
  item: any,
  cwd?: string,
): { kind: string; [key: string]: unknown } | null {
  switch (item?.type) {
    case "assistant_message":
      return { kind: "text", text: item.text ?? "" };

    case "user_message":
      // TWO-WAY SYNC. The timeline carries user messages too, whoever typed
      // them -- the Paseo app, another client, or us.
      return { kind: "user", text: item.text ?? "" };

    case "reasoning":
      return { kind: "thinking", text: item.text ?? "" };

    case "tool_call": {
      // `display` is precomputed here so the Lua never has to know that a
      // "shell" detail keys its command as `command` and a "read" keys its path
      // as `filePath`. The renderer still gets the raw `detail` for the
      // expanded body.
      let display: unknown = null;
      try {
        display = buildToolCallDisplayModel({
          name: item.name,
          status: item.status,
          error: item.error,
          metadata: item.metadata,
          detail: item.detail,
          ...(cwd ? { cwd } : {}),
        });
      } catch {
        // A provider shape the installed SDK does not know is not a reason to
        // drop the card -- the Lua falls back to the bare tool name.
      }
      return {
        kind: "tool",
        callId: item.callId,
        name: item.name,
        status: item.status ?? "running",
        error: item.error == null ? null : String(item.error),
        display,
        detail: item.detail ?? null,
      };
    }

    case "todo":
      return {
        kind: "todo",
        items: (item.items ?? []).map((task: any) => ({
          text: task.text ?? "",
          status: task.status ?? (task.completed ? "completed" : "pending"),
        })),
      };

    case "error":
      return { kind: "notice", level: "error", message: item.message ?? "" };

    case "notification":
      return {
        kind: "notice",
        level: item.level ?? "info",
        message: item.message ?? "",
      };

    case "compaction":
      return {
        kind: "compaction",
        status: item.status ?? "loading",
        trigger: item.trigger ?? null,
        preTokens: item.preTokens ?? null,
      };

    default:
      return null;
  }
}

export function timelineOps(ctx: BridgeConnection): Ops {
  const connected = () => ctx.connected();
  return {
    async "timeline.subscribe"(req) {
      const id = String(need(req.agentId, "agentId"));
      if (ctx.timelines.has(id)) return { subscribed: true, already: true };

      const agent = connected().agents.ref(id);
      const unsubscribe = agent.timeline.subscribe(
        guarded("timeline", (update: any) => {
          const event = update?.event;
          if (!event) return;

          // seq and epoch live on the UPDATE, not the event. They are what lets a
          // consumer tell a live message apart from the same message arriving in a
          // history fetch -- without them the two race and the message renders
          // twice.
          const at = { seq: update.seq ?? null, epoch: update.epoch ?? null };

          switch (event.type) {
            case "timeline": {
              const described = describeItem(event.item);
              if (described) {
                const { kind, ...rest } = described;
                emit(kind, { agentId: id, ...rest, ...at });
              }
              break;
            }
            case "permission_requested":
              // The agent is BLOCKED until this is answered. It already rode the
              // same subscription; there was simply no case for it here, which is
              // why the permission dialog had nothing to show.
              emit("permission", {
                agentId: id,
                request: withFallbackActions(event.request),
              });
              break;
            case "permission_resolved":
              // Fires whoever answered -- including the Paseo app. That is what
              // lets a dialog open in Neovim close itself when you approve on the
              // desktop instead.
              emit("permission_resolved", {
                agentId: id,
                requestId: event.requestId,
                resolution: event.resolution ?? null,
              });
              break;
            case "turn_completed":
            case "turn_failed":
            case "turn_canceled":
              // The usage on turn_completed is the final word for the turn; the
              // panel wants it even though the turn event itself carries no lines.
              if (event.usage)
                emit("usage", { agentId: id, usage: event.usage });
              emit("turn", {
                agentId: id,
                outcome: event.type,
                error: event.error ?? null,
                reason: event.reason ?? null,
              });
              break;

            case "usage_updated":
              // Context-window fill and cost, pushed. The usage panel would
              // otherwise have to poll agent.config, which is a round trip per
              // refresh for a number that arrives here for free.
              emit("usage", { agentId: id, usage: event.usage });
              break;

            // Mode, model and thinking level can all be changed from the Paseo app
            // or another client. Without these the header shows whatever we last
            // set ourselves and quietly lies -- the same divergence that dropping
            // user_message used to cause.
            case "mode_changed":
              emit("settings", {
                agentId: id,
                modeId: event.currentModeId ?? null,
                availableModes: event.availableModes ?? [],
              });
              break;
            case "model_changed":
              emit("settings", {
                agentId: id,
                model: event.runtimeInfo?.model ?? null,
                provider: event.runtimeInfo?.provider ?? null,
              });
              break;
            case "thinking_option_changed":
              emit("settings", {
                agentId: id,
                thinkingOptionId: event.thinkingOptionId ?? null,
              });
              break;

            case "attention_required":
              emit("attention", { agentId: id, reason: event.reason });
              break;
            case "subscription_restored":
              // Reconnected. Nothing is replayed; the consumer decides whether to
              // ask for history.
              emit("restored", { agentId: id });
              break;
            case "replacement":
              // The previous epoch is invalid; anything already rendered is stale.
              emit("replaced", { agentId: id });
              break;
            case "error":
              emit("stream_error", {
                agentId: id,
                error: String(event.error ?? ""),
              });
              break;
          }
        }),
      );

      ctx.timelines.set(id, unsubscribe as any);
      await (unsubscribe as any).ready;
      return { subscribed: true };
    },

    async "timeline.history"(req) {
      const agent = connected().agents.ref(
        String(need(req.agentId, "agentId")),
      );
      const page: any = await agent.timeline.refetch({
        direction: (req.direction as any) ?? "before",
        limit: Number(req.limit ?? 100),
        // "projected" asks the DAEMON to collapse the timeline the way the app
        // sees it: assistant chunks merged, reasoning merged, and a tool call
        // already folded into its terminal status rather than arriving as a
        // running item followed by a completed one. Doing it here instead meant
        // reimplementing three merge rules that can drift from the daemon's.
        projection: "projected",
        ...(req.cursor ? { cursor: req.cursor as any } : {}),
      });

      // History renders through the SAME describeItem as the live subscription,
      // so reopening a chat shows the tool calls and thinking that were there the
      // first time rather than a conversation with all the work cut out of it.
      //
      // The projection above already merges, so the merge below is DEFENSIVE
      // only -- and it merges strictly adjacent text, never across a tool call.
      // The old code merged every assistant item in the page regardless of what
      // sat between them, which would now splice the sentence before "read a
      // file" onto the sentence after it and lose where the work happened.
      const items: { kind: string; [key: string]: unknown }[] = [];
      for (const entry of page.entries ?? []) {
        const described = describeItem(entry.item ?? {});
        if (!described) continue;
        // `seqEnd` rather than a running counter: it is what the live
        // subscription compares against to decide an event is a duplicate.
        described.seq = entry.seqEnd ?? entry.seqStart ?? null;
        const last = items[items.length - 1];
        if (last && last.kind === "text" && described.kind === "text") {
          last.text = String(last.text ?? "") + String(described.text ?? "");
          last.seq = described.seq;
        } else {
          items.push(described);
        }
      }

      return {
        items,
        // Free, from a call already being made: a chat opening onto an agent that
        // is ALREADY blocked can show the dialog rather than looking idle.
        pendingPermissions: (page.agent?.pendingPermissions ?? []).map(
          withFallbackActions,
        ),
        hasOlder: page.hasOlder ?? false,
        hasNewer: page.hasNewer ?? false,
        startCursor: page.startCursor ?? null,
        endCursor: page.endCursor ?? null,
        epoch: page.epoch ?? null,
      };
    },

    async "timeline.unsubscribe"(req) {
      const id = String(need(req.agentId, "agentId"));
      const unsubscribe = ctx.timelines.get(id);
      if (!unsubscribe) return { unsubscribed: false };
      ctx.timelines.delete(id);
      await ((unsubscribe as any).release?.() ?? unsubscribe());
      return { unsubscribed: true };
    },
  };
}
