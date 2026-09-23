import { emit, need, type Ops } from "./bridge-io.ts";
import type { BridgeConnection } from "./bridge-connection.ts";

/**
 * Paseo's terminals, as PTYs rather than as text.
 *
 * A terminal is BYTES -- escape sequences, cursor moves, colour, a TUI
 * redrawing itself. The SDK's `client.terminals` namespace is the polled half
 * (list / capture / kill) and its capture returns ANSI-stripped strings, which
 * throws away everything that makes watching `claude` or `codex` run worth
 * doing. The live half is on the raw DaemonClient this bridge already holds:
 * `observeTerminal` delivers the PTY's own
 * output, and Neovim has libvterm built in, so those bytes go straight to
 * `nvim_open_term` and render themselves.
 *
 * Base64 in both directions, because this bridge is JSONL and PTY output is
 * not text -- it is frequently invalid UTF-8 mid-chunk.
 */

const FLUSH_MS = 16;

export function terminalOps(ctx: BridgeConnection): Ops {
  const raw = () => ctx.raw();

  const attached = new Set<string>();
  const terminalSubscriptions = new Map<
    string,
    { release: () => Promise<void>; unregister: () => void }
  >();
  const directorySubscriptions = new Map<
    string,
    { release: () => Promise<void>; unregister: () => void }
  >();
  let legacyStreamOff: (() => void) | null = null;
  // Output arrives in many small writes -- a build log is thousands of them.
  // Emitting a JSON line per write puts that whole flood through stdin parsing
  // and `vim.schedule` one chunk at a time, so it is coalesced per terminal
  // and flushed on a frame.
  const pending = new Map<string, Uint8Array[]>();
  let timer: ReturnType<typeof setTimeout> | null = null;

  function flush(): void {
    timer = null;
    for (const [terminalId, chunks] of pending) {
      pending.delete(terminalId);
      // Detached between the write and the flush: the buffer it would have
      // gone to is gone, and Neovim would have nowhere to put it.
      if (!attached.has(terminalId) || chunks.length === 0) continue;
      let total = 0;
      for (const chunk of chunks) total += chunk.length;
      const joined = new Uint8Array(total);
      let at = 0;
      for (const chunk of chunks) {
        joined.set(chunk, at);
        at += chunk.length;
      }
      emit("terminal_output", {
        id: terminalId,
        data: Buffer.from(joined).toString("base64"),
      });
    }
  }

  function queue(terminalId: string, data: Uint8Array): void {
    const held = pending.get(terminalId);
    if (held) held.push(data);
    else pending.set(terminalId, [data]);
    if (!timer) timer = setTimeout(flush, FLUSH_MS);
  }

  function followLegacyStream(): void {
    if (legacyStreamOff) return;
    legacyStreamOff = raw().onTerminalStreamEvent((event: any) => {
      if (!attached.has(event.terminalId)) return;
      if (event.type === "output" || event.type === "restore") {
        queue(event.terminalId, event.data);
      }
    });
    ctx.addCleanup(() => {
      legacyStreamOff?.();
      legacyStreamOff = null;
    });
  }

  /** What the daemon says it can do, so a missing feature degrades rather than throws. */
  function features(): Record<string, boolean> {
    return (raw().getLastServerInfoMessage()?.features ?? {}) as Record<
      string,
      boolean
    >;
  }

  return {
    /**
     * The terminals under a directory.
     *
     * Through the RAW client rather than `client.terminals.list()`, for two
     * reasons. The typed namespace runs every entry through a schema that
     * keeps only `{id, workspaceId, cwd, name}` -- dropping `title` and the
     * `activity` the list column draws its status glyph from -- and it throws
     * outright against a daemon that does not advertise `workspaceTerminals`,
     * which is a hard failure where an empty list is the honest answer.
     */
    async "terminals.list"(req) {
      const payload: any = await raw().listTerminals(
        req.cwd ? String(req.cwd) : undefined,
        undefined,
        req.workspaceId
          ? { workspaceId: String(req.workspaceId) }
          : undefined,
      );
      return { entries: payload?.terminals ?? [] };
    },

    /** Push for the list: a terminal opened, closed or changed activity anywhere. */
    async "terminals.watch"(req) {
      const cwd = String(need(req.cwd, "cwd"));
      if (!directorySubscriptions.has(cwd)) {
        const publish = (message: any) => {
          const payload = message?.payload ?? message;
          emit("terminals", {
            kind: "snapshot",
            cwd: payload?.cwd ?? cwd,
            entries: payload?.terminals ?? [],
          });
        };
        if (typeof (raw() as any).observeTerminals === "function") {
          const observation = raw().observeTerminals({ cwd });
          const unsubscribe = observation.subscribe({
            snapshot: publish,
            update: publish,
          });
          const release = async () => {
            unsubscribe();
            await observation.release();
          };
          const unregister = ctx.addCleanup(release);
          directorySubscriptions.set(cwd, { release, unregister });
          publish(await observation.ready);
        } else {
          const off = raw().on("terminals_changed", publish);
          await (raw() as any).subscribeTerminals({ cwd });
          const release = async () => off();
          const unregister = ctx.addCleanup(release);
          directorySubscriptions.set(cwd, { release, unregister });
          publish(await raw().listTerminals(cwd));
        }
      }
      return { watching: true };
    },

    async "terminals.create"(req) {
      const cwd = String(need(req.cwd, "cwd"));
      const payload: any = await raw().createTerminal(
        cwd,
        req.name ? String(req.name) : undefined,
        undefined,
        {
          ...(req.command ? { command: String(req.command) } : {}),
          ...(Array.isArray(req.args) ? { args: req.args.map(String) } : {}),
          ...(req.workspaceId
            ? { workspaceId: String(req.workspaceId) }
            : {}),
          ...(req.rows && req.cols
            ? { size: { rows: Number(req.rows), cols: Number(req.cols) } }
            : {}),
        },
      );
      return { terminal: payload?.terminal ?? payload ?? null };
    },

    async "terminals.rename"(req) {
      await raw().renameTerminal({
        terminalId: String(need(req.terminalId, "terminalId")),
        title: String(need(req.title, "title")),
      });
      return { renamed: true };
    },

    async "terminals.kill"(req) {
      const id = String(need(req.terminalId, "terminalId"));
      attached.delete(id);
      pending.delete(id);
      const held = terminalSubscriptions.get(id);
      if (held) {
        terminalSubscriptions.delete(id);
        held.unregister();
        await held.release().catch(() => {});
      }
      await raw().killTerminal(id);
      return { killed: true };
    },

    /**
     * Attach to a terminal's live output.
     *
     * `restore` is what makes an attach show the session you are joining
     * rather than a blank screen -- the daemon replays the scrollback as PTY
     * bytes. It is gated behind a server feature, so an older daemon gets a
     * plain live attach plus one capture, which is the same content without
     * the colour.
     */
    async "terminals.attach"(req) {
      const id = String(need(req.terminalId, "terminalId"));
      const rows = Number(req.rows ?? 24);
      const cols = Number(req.cols ?? 80);

      attached.add(id);

      const previous = terminalSubscriptions.get(id);
      if (previous) {
        terminalSubscriptions.delete(id);
        previous.unregister();
        await previous.release().catch(() => {});
      }

      const restores = features()["terminal-restore-modes"] === true;
      const receive = (event: any) => {
        if (!attached.has(event.terminalId)) return;
        // `output` is live; `restore` is the scrollback replay the daemon
        // sends on subscribe. `snapshot` is a cell grid for clients that
        // render terminals themselves, so Neovim's libvterm ignores it.
        if (event.type === "output" || event.type === "restore") {
          queue(event.terminalId, event.data);
        }
      };
      const restoreOptions = {
        ...(restores
          ? {
              restore: {
                mode: "full-snapshot" as const,
                scrollbackLines: Number(req.scrollback ?? 2000),
                size: { rows, cols },
              },
            }
          : {}),
      };

      const observation =
        typeof (raw() as any).observeTerminal === "function"
          ? raw().observeTerminal(
        id,
              receive,
              restoreOptions,
            )
          : null;
      let result: any;
      if (observation) {
        result = await observation.ready;
      } else {
        followLegacyStream();
        result = await raw().subscribeTerminal(id, restoreOptions);
      }
      if (result?.error) {
        attached.delete(id);
        await observation?.release().catch(() => {});
        throw new Error(String(result.error));
      }
      const release = async () => {
        attached.delete(id);
        pending.delete(id);
        if (observation) await observation.release();
        else if (typeof (raw() as any).unsubscribeTerminal === "function")
          await (raw() as any).unsubscribeTerminal(id);
      };
      const unregister = ctx.addCleanup(release);
      terminalSubscriptions.set(id, { release, unregister });

      // Claim the size we are actually rendering at. `update` rather than
      // `claim`: this terminal may well be open in the Paseo app at the same
      // time, and taking size ownership would reflow it under somebody else.
      raw().sendTerminalInput(id, {
        type: "resize",
        rows,
        cols,
        intent: "update",
      });

      if (!restores) {
        const captured: any = await raw().captureTerminal(id, {
          stripAnsi: false,
        });
        const lines: string[] = captured?.lines ?? [];
        if (lines.length > 0) {
          queue(id, new TextEncoder().encode(lines.join("\r\n") + "\r\n"));
        }
      }
      return { attached: true, restored: restores };
    },

    async "terminals.detach"(req) {
      const id = String(need(req.terminalId, "terminalId"));
      attached.delete(id);
      pending.delete(id);
      const held = terminalSubscriptions.get(id);
      if (held) {
        terminalSubscriptions.delete(id);
        held.unregister();
        await held.release();
      }
      return { detached: true };
    },

    /**
     * Keystrokes, base64'd, because a PTY takes bytes and this pipe takes JSON.
     *
     * Decoded as UTF-8 and not as latin1, which is the trap here: the frame
     * encoder runs a string payload through `TextEncoder`, so decoding these
     * bytes to a latin1 string would re-encode every byte above 0x7f as two
     * and turn one typed `é` into mojibake at the far end. UTF-8 in, UTF-8
     * out, and the bytes Neovim handed us are the bytes the PTY receives.
     */
    async "terminals.input"(req) {
      raw().sendTerminalInput(String(need(req.terminalId, "terminalId")), {
        type: "input",
        data: Buffer.from(String(need(req.data, "data")), "base64").toString(
          "utf8",
        ),
      });
      return { sent: true };
    },

    async "terminals.resize"(req) {
      raw().sendTerminalInput(String(need(req.terminalId, "terminalId")), {
        type: "resize",
        rows: Number(need(req.rows, "rows")),
        cols: Number(need(req.cols, "cols")),
        intent: "update",
      });
      return { resized: true };
    },
  };
}
