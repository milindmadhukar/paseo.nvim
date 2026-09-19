import { createPaseoApi } from "@getpaseo/client";
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import { need, type Ops } from "./bridge-io.ts";

// The typed SDK and raw setters share one socket. Subscriptions belong here so
// a stopped sidecar releases everything before the bounded process exit.
export class BridgeConnection {
  daemon: DaemonClient | null = null;
  client: ReturnType<typeof createPaseoApi> | null = null;
  timelines = new Map<string, any>();
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
    for (const unsubscribe of this.timelines.values()) {
      try {
        await (unsubscribe.release?.() ?? unsubscribe());
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
