import { createPaseoApi } from "@getpaseo/client";
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import { need, type Ops } from "./bridge-io.ts";

export type Unsubscribe = { release?: () => Promise<void> } & (() => void);
export type TimelineEntry = {
  timeline: Unsubscribe;
  state?: (() => void) | null;
};

// The typed SDK and raw setters share one socket. Subscriptions belong here so
// a stopped sidecar releases everything before the bounded process exit.
export class BridgeConnection {
  daemon: DaemonClient | null = null;
  client: ReturnType<typeof createPaseoApi> | null = null;
  // Two subscriptions per agent, not one. The timeline carries what the agent
  // SAYS; the state subscription carries what it IS -- mode, model, thinking
  // level, usage -- and those are not on the timeline at all. See
  // `timeline.subscribe` in bridge-timeline.ts.
  timelines = new Map<string, TimelineEntry>();
  directory: {
    subscription?: { release: () => Promise<void> };
    localUnsubscribe?: (() => void) | null;
  } | null = null;

  connected() {
    if (!this.client)
      throw new Error("not connected; send {op:'connect'} first");
    return this.client;
  }

  raw() {
    if (!this.daemon)
      throw new Error("not connected; send {op:'connect'} first");
    return this.daemon;
  }

  async connect(url: string, password?: string): Promise<void> {
    if (this.daemon) await this.close();
    this.daemon = new DaemonClient({
      url,
      clientId: `paseo.nvim-${process.pid}`,
      clientType: "cli",
      ...(password ? { password } : {}),
    });
    await this.daemon.connect();
    this.client = createPaseoApi(this.daemon);
  }

  async close(): Promise<void> {
    if (this.directory) {
      const held = this.directory;
      this.directory = null;
      held.localUnsubscribe?.();
      await held.subscription?.release().catch(() => {});
    }
    for (const entry of this.timelines.values()) {
      try {
        entry.state?.();
        await (entry.timeline.release?.() ?? entry.timeline());
      } catch {
        /* teardown is best-effort */
      }
    }
    this.timelines.clear();
    if (this.daemon) await this.daemon.close();
    this.daemon = null;
    this.client = null;
  }
}

export function connectionOps(ctx: BridgeConnection): Ops {
  return {
    async connect(req) {
      await ctx.connect(
        String(need(req.url, "url")),
        req.password ? String(req.password) : undefined,
      );
      return { connected: true };
    },
    async close() {
      await ctx.close();
      return { closed: true };
    },
  };
}
