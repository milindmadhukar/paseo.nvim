import { resolve } from "node:path";
import { need, type Ops, type Request } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";
import { pictures } from "./bridge-normalize.ts";

/** Trailing slashes and `..` segments, so two spellings of one path compare equal. */
export function canonical(path: string): string {
  return resolve(path).replace(/\/+$/, "") || "/";
}

/**
 * The id of the project rooted at `root`, registering it if Paseo has not seen
 * it. `addProject` is find-or-create by root path, so this is idempotent.
 */
export async function projectIdFor(
  ctx: BridgeConnection,
  root: string,
): Promise<string> {
  const result: any = await ctx.raw().addProject(canonical(root));
  if (result?.error || !result?.project?.projectId) {
    throw new Error(result?.error ?? `Paseo did not register ${root} as a project`);
  }
  return String(result.project.projectId);
}

/**
 * A new directory workspace at `cwd`, inside the project rooted at `project`.
 *
 * The project is the point. An assembled workspace --
 * `<project>/.workspaces/<name>`, N worktrees side by side -- is not a git
 * repository, and a directory source WITHOUT a `projectId` makes the daemon
 * find-or-create a project rooted at that exact directory: every workspace
 * became a top-level project named after itself, beside the one it belongs
 * to. That path is a server compat shim
 * (`COMPAT(workspaceCreateMissingProjectId)`, due for removal after
 * 2027-01-15); naming the project is the supported request.
 */
async function createInProject(
  ctx: BridgeConnection,
  req: Request,
  cwd: string,
  project: string,
): Promise<{ workspace: any; agentId: string | null }> {
  const projectId = await projectIdFor(ctx, project);
  return await createWithFirstAgent(ctx, req, {
    kind: "directory",
    path: canonical(cwd),
    projectId,
  });
}

/**
 * `provider/model` into the daemon's two fields. The model may itself contain
 * a slash (`openrouter/anthropic/claude-…`), so only the FIRST one splits.
 */
function splitProvider(value: string): { provider: string; model?: string } {
  const at = value.indexOf("/");
  return at < 0
    ? { provider: value }
    : { provider: value.slice(0, at), model: value.slice(at + 1) };
}

/**
 * Create a workspace -- and, when the request carries a first prompt, its
 * first agent with it, in the same request.
 *
 * THE SAME REQUEST IS THE POINT. The daemon generates a workspace's title (and
 * a worktree's branch name) from the first prompt, and only inside
 * `workspace.create`, and only when that request carries `firstAgentContext`.
 * A later `agent.create` with a `workspaceId` never names anything, and no
 * send ever does. This used to create the workspace bare and the agent after
 * it, so every workspace started from the editor sat in the sidebar as `main`
 * or as the slug typed for its directory.
 *
 * And no `title` when there is a prompt: an explicit title is permanent -- the
 * generated one is only written over the provisional first line, never over a
 * name somebody chose.
 *
 * Both `agent` and `firstAgentContext`, as the app sends them: a daemon without
 * the creation lifecycle strips `agent` and still names from the context.
 * Through the RAW client because the typed `workspaces.create` returns only the
 * workspace handle and drops the agent it just created.
 */
async function createWithFirstAgent(
  ctx: BridgeConnection,
  req: Request,
  source: any,
): Promise<{ workspace: any; agentId: string | null }> {
  const prompt = typeof req.prompt === "string" ? req.prompt.trim() : "";
  const sourceCwd = String(source.path ?? source.cwd);
  const images = pictures(req);
  const attachments = Array.isArray(req.attachments) ? req.attachments : null;

  let agent: Record<string, unknown> | undefined;
  if (prompt && req.provider) {
    agent = {
      config: {
        ...splitProvider(String(req.provider)),
        cwd: sourceCwd,
        ...(req.agentTitle ? { title: String(req.agentTitle) } : {}),
        ...(req.modeId ? { modeId: String(req.modeId) } : {}),
        ...(req.thinkingOptionId
          ? { thinkingOptionId: String(req.thinkingOptionId) }
          : {}),
        ...(req.featureValues &&
        typeof req.featureValues === "object" &&
        !Array.isArray(req.featureValues)
          ? { featureValues: req.featureValues }
          : {}),
      },
      initialPrompt: prompt,
      ...(images ? { images } : {}),
      ...(attachments ? { attachments } : {}),
      labels: { "paseo.nvim": "review" },
    };
  }

  const result: any = await ctx.raw().createWorkspace({
    source,
    ...(prompt
      ? { firstAgentContext: { prompt } }
      : req.title
        ? { title: String(req.title) }
        : {}),
    ...(agent ? { agent } : {}),
  });
  if (result?.error || !result?.workspace) {
    throw new Error(
      String(result?.error ?? "the daemon did not create the workspace"),
    );
  }
  return {
    workspace: ctx.connected().workspaces.ref(result.workspace.id),
    agentId: result.agent?.id ?? null,
  };
}

/**
 * The workspace handle covering `cwd` -- the EXISTING one wherever there is
 * one.
 *
 * Agents must be created through a workspace handle rather than by cwd, or the
 * daemon provisions a workspace for the directory it was handed. That is right
 * for a directory Paseo has never seen and badly wrong for one it already
 * owns: a Paseo-cut worktree gets registered a second time, as its own project,
 * because the worktree directory is itself a git repository.
 *
 * Registering something new is only reached when nothing covers the directory.
 * With `project` -- the root of the project an assembled workspace belongs to
 * -- it is registered inside that project; without, `workspaces.open()` lets
 * the daemon decide, which is right for an ordinary checkout.
 */
export async function workspaceFor(
  ctx: BridgeConnection,
  cwd: string,
  project?: string | null,
): Promise<any> {
  const api = ctx.connected();
  const want = canonical(cwd);

  const page: any = await api.workspaces.list({ page: { limit: 200 } });
  const owner = (page.entries ?? []).find((ws: any) => {
    if (ws.archivingAt) return false;
    const dir = ws.workspaceDirectory ?? ws.project?.checkout?.cwd ?? null;
    return dir ? canonical(String(dir)) === want : false;
  });

  if (owner) return api.workspaces.ref(owner.id);
  if (project)
    return (await createInProject(ctx, { op: "workspace.open" }, cwd, project))
      .workspace;
  return await api.workspaces.open(cwd);
}

export function workspaceOps(ctx: BridgeConnection): Ops {
  const connected = () => ctx.connected();

  async function createdWorkspace(workspace: any) {
    let snapshot = workspace.current?.() ?? null;
    if (!workspace.directory && !snapshot?.workspaceDirectory) {
      snapshot = await workspace.refresh?.();
    }
    return {
      id: workspace.id,
      directory:
        workspace.directory ??
        snapshot?.workspaceDirectory ??
        snapshot?.project?.checkout?.cwd ??
        null,
      projectId: workspace.projectId ?? snapshot?.projectId ?? null,
      name: workspace.name ?? snapshot?.name ?? snapshot?.title ?? null,
    };
  }

  return {
    async "workspace.open"(req) {
      const workspace = await workspaceFor(
        ctx,
        String(need(req.cwd, "cwd")),
        req.project ? String(req.project) : null,
      );
      return await createdWorkspace(workspace);
    },

    async "workspaces.list"(req) {
      const page: any = await connected().workspaces.list({
        ...(req.query ? { filter: { query: String(req.query) } } : {}),
        page: { limit: Number(req.limit ?? 200) },
      });
      // Field names taken from the wire, not guessed: the directory is
      // `workspaceDirectory`, and `directory` does not exist.
      return {
        entries: (page.entries ?? []).map((ws: any) => ({
          id: ws.id,
          name: ws.name ?? ws.title ?? null,
          directory: ws.workspaceDirectory ?? ws.project?.checkout?.cwd ?? null,
          project: ws.projectDisplayName ?? ws.projectId ?? null,
          // The project RECORD, not its display name. Removing a project --
          // which the app offers and this dropped one line before it was
          // useful -- is keyed on this and on nothing else.
          projectId: ws.projectId ?? null,
          projectRoot: ws.projectRootPath ?? null,
          projectKind: ws.projectKind ?? null,
          kind: ws.workspaceKind ?? null,
          status: ws.status ?? null,
          branch: ws.project?.checkout?.currentBranch ?? null,
          // Whether PASEO owns the worktree, as opposed to it pointing at a
          // primary checkout -- the difference between isolated and not.
          ownedWorktree: ws.project?.checkout?.isPaseoOwnedWorktree ?? false,
          archivingAt: ws.archivingAt ?? null,
        })),
      };
    },

    async "workspace.create"(req) {
      const cwd = String(need(req.cwd, "cwd"));
      const created =
        !req.worktree && req.project
          ? await createInProject(ctx, req, cwd, String(req.project))
          : await createWithFirstAgent(
              ctx,
              req,
              req.worktree
                ? {
                    kind: "worktree",
                    cwd,
                    action: "branch-off",
                    refName: String(req.base ?? "main"),
                    branchName: String(need(req.branch, "branch")),
                  }
                : { kind: "directory", path: cwd },
            );
      return {
        ...(await createdWorkspace(created.workspace)),
        agentId: created.agentId,
      };
    },

    /**
     * Start the first agent in a directory, with its first prompt -- the
     * moment a workspace can be NAMED.
     *
     * What "here" means depends on what is already here:
     *   - a Paseo worktree or checkout, or a workspace somebody titled: the
     *     agent joins it. It already has a name worth keeping, and a second
     *     workspace on a worktree's path would register the worktree as a
     *     project of its own (see `workspaceFor`).
     *   - nothing, or a plain checkout still called by its branch (`main`):
     *     a fresh directory workspace in the same project, created WITH the
     *     prompt, so the daemon titles it the way the app's New workspace
     *     does. The untitled one is left alone.
     */
    async "agent.start"(req) {
      const cwd = canonical(String(need(req.cwd, "cwd")));
      need(req.prompt, "prompt");
      need(req.provider, "provider");
      const api = connected();

      const page: any = await api.workspaces.list({ page: { limit: 200 } });
      const owner = (page.entries ?? []).find((ws: any) => {
        if (ws.archivingAt) return false;
        const dir = ws.workspaceDirectory ?? ws.project?.checkout?.cwd ?? null;
        return dir ? canonical(String(dir)) === cwd : false;
      });
      const keeps =
        owner &&
        (owner.workspaceKind === "worktree" ||
          owner.workspaceKind === "checkout" ||
          (typeof owner.title === "string" && owner.title.trim() !== ""));

      if (keeps) {
        const images = pictures(req);
        const agent = await api.workspaces.ref(owner.id).agents.create({
          config: {
            provider: String(req.provider),
            ...(req.modeId ? { modeId: String(req.modeId) } : {}),
            ...(req.thinkingOptionId
              ? { thinkingOptionId: String(req.thinkingOptionId) }
              : {}),
            ...(req.featureValues && typeof req.featureValues === "object"
              ? { featureValues: req.featureValues as Record<string, unknown> }
              : {}),
          },
          prompt: String(req.prompt),
          ...(images ? { images } : {}),
          labels: { "paseo.nvim": "review" },
        } as any);
        return { agentId: agent.id, workspaceId: owner.id, created: false };
      }

      const projectId = owner?.projectId
        ? String(owner.projectId)
        : await projectIdFor(ctx, String(req.project ?? cwd));
      const created = await createWithFirstAgent(ctx, req, {
        kind: "directory",
        path: cwd,
        projectId,
      });
      if (!created.agentId) {
        throw new Error("the daemon created the workspace but no agent in it");
      }
      return {
        agentId: created.agentId,
        workspaceId: created.workspace.id,
        created: true,
      };
    },

    /**
     * Forget a project. NOT its files, and not its workspaces' files.
     *
     * The app offers this beside archiving a workspace, and the two are
     * genuinely different acts: archiving retires one unit of work, removing a
     * project drops the daemon's whole record of a directory tree -- which for
     * a `ws` workspace is how you get rid of the top-level project the daemon
     * invented for `<project>/.workspaces/<name>` in the first place.
     *
     * `removeProject` is on the raw client, like `cancelAgent`.
     */
    async "project.remove"(req) {
      const result: any = await ctx
        .raw()
        .removeProject(String(need(req.projectId, "projectId")));
      return { removed: result?.removed ?? true };
    },

    async "workspace.archive"(req) {
      const workspace = connected().workspaces.ref(
        String(need(req.workspaceId, "workspaceId")),
      );
      const result = await workspace.archive();
      return { archivedAt: (result as any)?.archivedAt ?? null };
    },
  };
}
