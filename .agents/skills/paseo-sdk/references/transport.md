# Transport: reaching the daemon

Measured on a live daemon (Paseo 0.7.2, 2026-09-18). These numbers decide the
architecture, so they are recorded rather than re-guessed.

| Channel | Latency | Verdict |
|---|---|---|
| `paseo … --json` CLI | **2380–2460 ms** | Boots Electron per invocation. Unusable for anything interactive. |
| `GET /api/status` | ~8 ms | Liveness + identity probe. |
| `GET /api/health` | ~8 ms | Liveness only. |
| `ws://127.0.0.1:6767/ws` | ~1–10 ms | **The real API.** Everything the SDK does. |

There is no REST API for agents or workspaces — those paths 404. Anything
beyond liveness goes over the WebSocket.

**Use the CLI only for one-shot writes** where 2.4 s does not matter and a
stable documented surface does (`paseo agent send --prompt-file`,
`paseo workspace create`), and as a degraded fallback. Never on an interactive
path.

## Endpoint discovery

Do not hardcode the port. Resolve in this order (the order Paseo's own VS Code
extension uses), taking the first that answers:

1. an explicit setting your integration exposes;
2. an environment variable your integration defines;
3. `daemon.listen` in `$PASEO_HOME/config.json` (`PASEO_HOME` defaults to
   `~/.paseo`);
4. `127.0.0.1:6767`.

Probe each candidate with `GET /api/status`:

```console
$ curl -s http://127.0.0.1:6767/api/status
{"status":"server_info","serverId":"srv_XnUI5hLnillF","hostname":"spaceship",
 "version":"0.7.2","listen":"127.0.0.1:6767"}
```

**A `401` still means "found it"** — the daemon is there and wants a password.
Treat it as reachable and prompt, rather than moving to the next candidate.

Only TCP listens can be reached this way. Unix sockets and Windows pipes
(`unix:`, `pipe:`, `ws+unix:`) are a different transport; reject them rather
than pretending.

## Remote daemons

The same client reaches one unchanged — pass `wss://…/ws` plus `password`, or
an `authHeader` for a proxy. `paseo --host ssh://…` exists for the CLI. Nothing
about the SDK code changes.

## Secrets

Keep the plaintext password in the host process. Do not write it into rendered
HTML, runtime config blobs, or message payloads crossing a trust boundary. Use
it to open the WebSocket and nowhere else.
