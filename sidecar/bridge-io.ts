export type Request = { id?: number; op: string; [key: string]: unknown };
export type Op = (req: Request) => Promise<unknown>;
export type Ops = Record<string, Op>;

let shutdown: (() => Promise<unknown>) | null = null;
export function setShutdown(fn: () => Promise<unknown>): void {
  shutdown = fn;
}

// THE PIPE OUTLIVES NOTHING. When Neovim goes, so does this.
//
// A write to a dead pipe does not throw: it returns false and comes back later
// as an uncaughtException with code EPIPE -- in bun AND in node. The handler at
// the bottom of this file answered that by writing again, which failed the same
// way, which called the handler again. Sixteen orphaned sidecars sat at 90% of
// a core for a day each on that loop: 202 MILLION write(2) calls that moved
// 1153 bytes between them.
//
// `broken` is what breaks the cycle, and the 'error' listeners below are what
// set it -- the try/catch in write() only ever catches ERR_STREAM_DESTROYED,
// which is the one that throws synchronously.
let broken = false;
// Stderr is diagnostics, and it can fail on its own without the protocol being
// affected. Tracked separately so a closed fd 2 costs the logs and not the
// session.
let quiet = false;

/** The stream is gone, as opposed to merely unhappy. */
export function isGone(error: any): boolean {
  const code = error?.code;
  return (
    code === "EPIPE" || code === "ERR_STREAM_DESTROYED" || code === "EBADF"
  );
}

/** Nothing can be said any more. Say nothing, and leave. */
export function severed(): void {
  broken = true;
  bail(0);
}

// Registered before the first write, because an 'error' event with no listener
// is itself rethrown as an uncaughtException -- which is the loop again.
process.stdout.on("error", (error) =>
  isGone(error) ? severed() : void (broken = true),
);
// Never log() from here: the log goes to the stream that just failed.
process.stderr.on("error", () => void (quiet = true));

export function write(payload: unknown): void {
  if (broken) return;
  let line: string;
  try {
    line = JSON.stringify(payload) + "\n";
  } catch {
    // A payload that will not serialise is a DROPPED MESSAGE, never a crash:
    // this runs inside SDK subscription callbacks, where a throw escapes into
    // the daemon client's dispatcher rather than into any of our own handlers.
    return;
  }
  try {
    process.stdout.write(line);
  } catch (error) {
    if (isGone(error)) return severed();
    broken = true;
  }
}

export function emit(event: string, extra: Record<string, unknown> = {}): void {
  write({ event, ...extra });
}

export function log(...parts: unknown[]): void {
  if (quiet) return;
  try {
    process.stderr.write(parts.map(String).join(" ") + "\n");
  } catch {
    quiet = true;
  }
}

/**
 * THE ONLY WAY OUT, and it is not optional.
 *
 * Two things have to be true at once. Teardown must be ATTEMPTED, because a
 * timeline subscription left dangling is a leak on the daemon's side of the
 * socket. And teardown must not be ABLE to keep this process alive, because it
 * demonstrably can: `ops.close` awaits subscription releases and
 * `daemon.close()`, none of which is bounded, and a sidecar parked in one of
 * those is a sidecar that never exits.
 *
 * So the watchdog is armed first and never disarmed, and teardown is RACED
 * against it rather than awaited. On bun the watchdog is the thing that
 * actually fires -- bun delivers stdin EOF before the stdout error, so the
 * write that would have reached severed() never happens. Do not delete it
 * because node happens to exit in 17ms without it.
 *
 * ops.close is called DIRECTLY rather than queued. The queue is precisely what
 * can be head-of-line blocked -- `providers.waitForReady` sits on it for up to
 * 30 seconds -- and routing shutdown through it is why these processes lived
 * long enough to matter.
 */
let bailing = false;

export function bail(code: number): void {
  if (bailing) return;
  bailing = true;

  setTimeout(() => process.exit(code), 2_000).unref();

  void Promise.resolve()
    .then(() => shutdown?.())
    .catch(() => {})
    .finally(() => {
      if (broken) return process.exit(code);
      // process.exit() TRUNCATES buffered stdout at the pipe buffer -- 65536 of
      // 200001 bytes, in both runtimes -- and a timeline.history reply is
      // routinely larger than that. On the graceful path let the loop drain and
      // exit on its own; the watchdog above is still armed if it will not.
      process.exitCode = code;
      try {
        process.stdin.pause();
      } catch {
        /* already gone */
      }
    });
}

export function need<T>(value: T | null | undefined, what: string): T {
  if (value === null || value === undefined)
    throw new Error(`${what} is required`);
  return value;
}

/**
 * A daemon-driven callback that cannot take the process with it.
 *
 * Everything inside `dispatch` gets its throw turned into an error reply. These
 * do not: they run inside the SDK's own event dispatcher, so a throw is an
 * uncaughtException instead -- and the shape of a daemon event is whatever the
 * daemon's version says it is, not what this file assumes. A single `upsert`
 * that arrives without an `agent` should cost one dropped update, not the
 * session.
 */
export function guarded<T>(
  what: string,
  handler: (value: T) => void,
): (value: T) => void {
  return (value: T) => {
    try {
      handler(value);
    } catch (error) {
      log(`${what} handler:`, error);
    }
  };
}

export function installExitHandlers(): void {
  process.stdin.on("end", () => bail(0));
  process.stdin.on("close", () => bail(0));
  process.stdin.on("error", () => bail(0));
  process.on("SIGHUP", () => bail(0));
  process.on("SIGTERM", () => bail(0));
  process.on("SIGINT", () => bail(0));

  /**
   * Re-entrancy safe, and SILENT once the pipe is gone.
   *
   * The old body wrote to stderr and then to stdout. After Neovim exits both of
   * those fail with EPIPE, and an EPIPE with no 'error' listener arrives HERE --
   * so the handler for the failure was also the cause of the next one.
   */
  process.on("uncaughtException", (error) => {
    if (isGone(error)) return severed();
    if (broken || bailing) return;
    log("uncaught:", error);
    emit("protocol_error", { error: String(error) });
  });

  // Previously unhandled entirely, and the default action for one is to kill the
  // process -- an ops chain that rejects off the end of dispatch would have taken
  // the sidecar down mid-session.
  process.on("unhandledRejection", (reason) => {
    if (isGone(reason)) return severed();
    if (broken || bailing) return;
    log("unhandled rejection:", reason);
    emit("protocol_error", { error: String(reason) });
  });
}
