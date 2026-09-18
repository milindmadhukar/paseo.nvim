# Workspaces with the SDK

Use a workspace when an integration needs a durable place in the Paseo app for
agents, terminals, browsers and files related to one task.

A workspace has a working directory and can contain many sessions at once — in
the app each session is a tab. Projects contain workspaces; workspaces contain
sessions. The workspace is the stable container.

Every workspace has an isolation mode:

- **local** — an existing directory, such as your main checkout. Sessions share
  the files already on disk.
- **worktree** — a managed git worktree. Use it when a task needs its own
  directory and branch. More than one workspace may refer to the same managed
  worktree; Paseo removes it after its last workspace is archived.

`isolation: "worktree"` requires a git repository. A project registered as
`non_git` (a parent directory holding several repos) can only use `local`.

## Open a directory

```ts
const workspace = await client.workspaces.open("/Users/me/dev/storefront");
console.log(workspace.id, workspace.directory);
```

`open()` creates the project when needed and **reuses the active workspace for
that exact directory**. Use it when the directory is the identity you care
about.

## Create a fresh workspace

`create()` always creates a new workspace, even when another already uses the
directory:

```ts
const workspace = await client.workspaces.create({
  source: { kind: "directory", path: "/Users/me/dev/storefront" },
  title: "Checkout issue 42",
});
```

A Paseo-owned worktree, for concurrent work needing an isolated checkout:

```ts
const workspace = await client.workspaces.create({
  source: {
    kind: "worktree",
    cwd: "/Users/me/dev/storefront",
    action: "branch-off",
    refName: "main",
    branchName: "fix/checkout-42",
  },
  title: "Checkout issue 42",
});
```

You can pass `projectId` in either source when you already have one. Most
integrations should omit it; the daemon finds or creates the project from the
directory.

## Start an agent in a workspace

```ts
const agent = await workspace.agents.create({
  config: { provider: "claude/claude-sonnet-5" },
  prompt: "Map the checkout flow before changing anything.",
});
```

The handle supplies both the workspace identity and its actual directory, which
avoids mismatched placement arguments. For a one-off agent, `client.agents
.create({ cwd })` still works — the daemon creates a project and a fresh
workspace, and `agent.workspaceId` holds the generated ID.

## Terminals

```ts
const terminal = await workspace.terminals.create({ name: "Development" });
terminal.write("echo ready");
terminal.sendKeys(["Enter"]);

const { lines } = await terminal.capture();
const { entries } = await workspace.terminals.list();
await terminal.kill();
```

Two workspaces may share a directory; the workspace handle supplies the ID that
keeps their terminals separate. With an ID you already have, use
`client.workspaces.ref(workspaceId).terminals.create()`.

`sendKeys()` recognises `Enter`, `Tab`, `Escape`, `Space`, `BSpace`, `C-c`,
`C-d`, `C-z`, `C-l`, `C-a`, `C-e`; other strings pass through literally. Input
methods send without waiting for execution or acknowledgement.

## List workspaces

```ts
let cursor;
do {
  const page = await client.workspaces.list({
    filter: { query: "storefront" },
    page: { limit: 50, cursor },
  });
  for (const workspace of page.entries) {
    console.log(workspace.id, workspace.name, workspace.status);
  }
  cursor = page.pageInfo.nextCursor ?? undefined;
} while (cursor);
```

## Refresh and archive

```ts
const workspace = client.workspaces.ref(savedWorkspaceId);
const snapshot = await workspace.refresh();
if (snapshot) await workspace.archive();
```

Workspace archive is separate from agent archive. Archive each resource
according to the lifecycle your integration owns.
