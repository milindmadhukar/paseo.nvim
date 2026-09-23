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
  private cleanups = new Set<() => void | Promise<void>>();
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

  addCleanup(cleanup: () => void | Promise<void>): () => void {
    this.cleanups.add(cleanup);
    return () => this.cleanups.delete(cleanup);
  }

  async connect(
    url: string,
    password?: string,
    e2ee?: { enabled: true; daemonPublicKeyB64: string },
  ): Promise<Record<string, unknown>> {
    if (this.daemon) await this.close();
    this.daemon = new DaemonClient({
      url,
      clientId: `paseo.nvim-${process.pid}`,
      clientType: "cli",
      ...(password ? { password } : {}),
      ...(e2ee ? { e2ee } : {}),
    });
    await this.daemon.connect();
    this.client = createPaseoApi(this.daemon);
    const info = this.daemon.getLastServerInfoMessage();
    return {
      connected: true,
      serverId: info?.serverId,
      hostname: info?.hostname,
      version: info?.version,
    };
  }

  async close(): Promise<void> {
    const cleanups = [...this.cleanups];
    this.cleanups.clear();
    for (const cleanup of cleanups) {
      try {
        await cleanup();
      } catch {
        /* teardown is best-effort */
      }
    }
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
      return await ctx.connect(
        String(need(req.url, "url")),
        req.password ? String(req.password) : undefined,
        req.e2ee && typeof req.e2ee === "object"
          ? {
              enabled: true,
              daemonPublicKeyB64: String(
                need(
                  (req.e2ee as Record<string, unknown>).daemonPublicKeyB64,
                  "e2ee.daemonPublicKeyB64",
                ),
              ),
            }
          : undefined,
      );
    },
    async close() {
      await ctx.close();
      return { closed: true };
    },
  };
}
