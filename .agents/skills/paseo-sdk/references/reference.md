# SDK API reference

Import every supported runtime value and TypeScript type from
`@getpaseo/client`.

## `createPaseoClient(config)`

Creates a client **without** opening the connection.

| Required | Type | Meaning |
|---|---|---|
| `url` | `string` | Daemon WebSocket endpoint, including `/ws`. |

| Optional | Type | Default | Meaning |
|---|---|---|---|
| `clientId` | `string` | generated | Stable identifier for logs and subscriptions. |
| `password` | `string` | unset | Daemon password. |
| `authHeader` | `string` | unset | Complete authorization-header value for a proxy. |
| `connectTimeoutMs` | `number` | client default | Connection deadline. |
| `reconnect.enabled` | `boolean` | client default | Reconnect after an unexpected disconnect. |
| `reconnect.baseDelayMs` | `number` | client default | Initial reconnect delay. |
| `reconnect.maxDelayMs` | `number` | client default | Maximum reconnect delay. |
| `logger` | `PaseoLogger` | unset | Debug/info/warn/error sink. |

Relay E2EE clients may also pass `e2ee.enabled` and `e2ee.daemonPublicKeyB64`.

## Client lifecycle

| Method | Result | Behaviour |
|---|---|---|
| `connect()` | `Promise<void>` | Resolves after the daemon sends its server information. |
| `close()` | `Promise<void>` | Closes the connection and disposes this client. |
| `ensureConnected()` | `void` | Throws unless connected. |
| `getConnectionState()` | `ConnectionState` | `idle`, `connecting`, `connected`, `disconnected`, `disposed`. |

Create a new client after `close()`.

## `client.agents`

| Method | Result | Behaviour |
|---|---|---|
| `list(options?)` | `PaseoAgentListResult` | A page of agents. `scope`, `filter`, `sort`, `page`, `subscribe`. |
| `create(options)` | `PaseoAgentHandle` | Creates an agent and a fresh workspace for `cwd`. Requires `config`. |
| `ref(agentOrId)` | `PaseoAgentHandle` | Local handle, no fetch. |
| `subscribe(handler)` | unsubscribe fn | Local listener. Requires an owned `list({ subscribe: {} })`. |

Creation options: `config`, `cwd`, `parent`, `title`, `prompt`, `env`,
`outputSchema`, `images`, `attachments`, `git`, `worktree`, `autoArchive`,
`labels`.

`config` accepts:

| Field | Type | Meaning |
|---|---|---|
| `provider` | `string` | **Required** `provider/model`. |
| `modeId` | `string` | Provider operating or permission mode. |
| `thinkingOptionId` | `string` | Provider reasoning level. |
| `featureValues` | `Record<string, unknown>` | Values for features from `providers.listFeatures`. |
| `options` | JSON object | Provider-native settings, strictly validated. |
| `systemPrompt` | `string` | Additional system/developer instructions. |
| `mcpServers` | MCP server map | Session-scoped MCP servers. |
| `toolPolicy` | MCP tool policy | Exact preapproval rules for MCP tools. |

### Agent handle

| Member | Result | Behaviour |
|---|---|---|
| `id` | `string` | Stable daemon agent ID. |
| `workspaceId` | `string \| null` | Current workspace placement. |
| `cwd` | `string \| null` | Current working directory. |
| `status` | status or `null` | Current lifecycle status. |
| `capabilities` | flags or `null` | What the provider session supports. |
| `availableModes` | modes or `null` | Modes the session can switch to. |
| `pendingPermissions` | requests or `null` | Requests waiting on an answer. |
| `activeTurn` | turn or `null` | The turn in flight (`turnId`, `startedAt`). |
| `lastUsage` | usage or `null` | Tokens, cost, context-window use from the last turn. |
| `lastError` | `string \| null` | Last error recorded for the agent. |
| `features` | features or `null` | Provider feature toggles and their values. |
| `runtimeInfo` | info or `null` | Live provider, session ID, model, thinking option, mode. |
| `archivedAt` | `string \| null` | Archive timestamp; `null` while active. |
| `current()` | `PaseoAgent \| null` | The whole observed snapshot; never fetches. |
| `refresh(requestId?)` | refetch result or `null` | Fetches agent and project placement. |
| `send(text, options?)` | `Promise<void>` | Resolves when the daemon accepts the prompt. |
| `respondToPermission(options)` | `Promise<void>` | Answers a pending permission by `requestId`. |
| `run(text, options?)` | `PaseoAgentRunResult` | Sends and waits for that turn. `timeoutMs` default 10 min. |
| `waitForFinish(timeoutMs?)` | `PaseoAgentRunResult` | Waits for the active turn, including an initial prompt. |
| `commands(options?)` | `PaseoAgentCommandsResult` | The live session's slash commands and skills. |
| `subscribe(handler)` | unsubscribe fn | Filters directory updates to this ID; refreshes handle properties. |
| `archive()` | `{ archivedAt }` | Soft-deletes the agent, closes its runtime. |
| `detach()` | `Promise<void>` | Removes the parent relationship without stopping the agent. |

**`workspaceId` through `archivedAt` mirror the last observed snapshot.** A
`ref()` handle reads `null` for all of them until something delivers one.

`PaseoAgentRunResult` = `{ status, final, error, lastMessage }`. `final`
refreshes the handle when present.

`PaseoAgentCommandsResult` = `{ agentId, commands, error }`. Each command has
`name`, `description`, `argumentHint` and an optional `kind` of `"command"` or
`"skill"`.

### Timeline handle

`agent.timeline.refetch(options?)` — options `direction`, `cursor`, `limit`,
`projection`, `requestId`.

`agent.timeline.subscribe(handler)` establishes network demand and restores it
after reconnect. Delivery is **live-only**; request missed history explicitly
with `refetch()`. See `events.md`.

## `client.projects`

| Method | Result | Behaviour |
|---|---|---|
| `list(options?)` | `PaseoProjectListResult` | Every registered project, including ones with no active workspaces. |
| `subscribe(handler)` | unsubscribe fn | Requests future project updates. `list()` supplies initial state. |

## `client.workspaces`

| Method | Result | Behaviour |
|---|---|---|
| `list(options?)` | `PaseoWorkspaceListResult` | List, filter, page or subscribe. |
| `open(cwd)` | `PaseoWorkspaceHandle` | Reuses the active workspace for a directory, or creates one. |
| `create(options)` | `PaseoWorkspaceHandle` | Always creates a fresh directory- or worktree-backed workspace. |
| `ref(workspaceOrId)` | `PaseoWorkspaceHandle` | Local handle. |
| `archive(workspaceOrId)` | archive result | Archives without first creating a handle. |
| `subscribe(handler)` | unsubscribe fn | Local listener; requires an owned observation. |

A workspace handle exposes `id`, `projectId`, `directory`, `name`, `status`,
`current()`, `refresh()`, `setTitle(title)`, `archive()`, `subscribe()`. Pass
`null` to `setTitle` to restore the derived name. Use
`workspace.agents.create(options)` to avoid repeating the workspace ID or
directory.

## `client.terminals`

Requires a host that supports workspace terminals; an older host makes the SDK
throw an update-host error.

| Method | Result | Behaviour |
|---|---|---|
| `create(options)` | `PaseoTerminalHandle` | Terminal owned by the required `workspaceId`. |
| `list(options?)` | `PaseoTerminalListResult` | `{ entries, requestId }`. |
| `ref(terminalOrId)` | `PaseoTerminalHandle` | Local handle; no fetch, no stream attach. |

Creation options: `workspaceId` (required, active), `cwd` (optional absolute;
defaults to the workspace directory and does not change ownership), `name`,
`command`/`args` (omit for the default shell), `size` `{ rows, cols }`,
`requestId`.

Handle: `current()`, `refresh(options?)`, `write(data)`, `sendKeys(keys)`,
`capture(options?)` → `{ terminalId, lines, totalLines, requestId }`,
`kill(requestId?)`.

Capture accepts `start`, `end`, `stripAnsi` (default `true`), `requestId`.
Bounds are zero-based and inclusive across scrollback and viewport; negative
bounds count from the end; omitted bounds capture everything.

## `client.providers`

| Method | Result | Behaviour |
|---|---|---|
| `waitForReady(options?)` | snapshot result | Waits until no provider is loading. Default timeout 60 s. |
| `snapshot(options?)` | snapshot result | The current catalog, immediately. |
| `refresh(options?)` | acknowledgement | Forces a catalog refresh. |
| `listAvailable()` | availability result | Installed provider availability. |
| `listModels(provider, options?)` | models result | Models for one provider and directory. |
| `listModes(provider, options?)` | modes result | Permission or operating modes. |
| `listFeatures(draftConfig)` | features result | Features for a draft provider configuration. |
| `diagnostic(provider)` | diagnostic result | Human-readable setup diagnostics. |
| `listUsage(options?)` | usage result | Subscription windows, balances, provider details. |
| `subscribe(handler)` | unsubscribe fn | Requests future catalog updates. |

## `client.config`

`config.get(requestId?)` returns the daemon's mutable configuration.
`config.patch(patch, requestId?)` validates, persists and returns it. This is
an **administrative** surface — a patch affects every client and every future
agent on that daemon. Per-agent choices belong in `config` on `agents.create`.

## Errors and cleanup

Connection, validation, rejection and timeout failures reject their promise.
Turn outcomes come back through `PaseoAgentRunResult.status` instead, because
permission and provider errors are expected agent states.

Always close the client in `finally`. Closing removes local listeners and the
network connection; it does **not** stop agents or archive workspaces.
