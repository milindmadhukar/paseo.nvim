import { resolve } from "node:path";
import { need, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";

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
  cwd: string,
  project: string,
  title?: string,
): Promise<any> {
  const projectId = await projectIdFor(ctx, project);
  return await ctx.connected().workspaces.create({
    source: { kind: "directory", path: canonical(cwd), projectId },
    ...(title ? { title } : {}),
  });
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
  if (project) return await createInProject(ctx, cwd, project);
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
      if (!req.worktree && req.project) {
        const workspace = await createInProject(
          ctx,
          String(need(req.cwd, "cwd")),
          String(req.project),
          req.title ? String(req.title) : undefined,
        );
        return await createdWorkspace(workspace);
      }

      const source: any = req.worktree
        ? {
            kind: "worktree",
            cwd: String(need(req.cwd, "cwd")),
            action: "branch-off",
            refName: String(req.base ?? "main"),
            branchName: String(need(req.branch, "branch")),
          }
        : { kind: "directory", path: String(need(req.cwd, "cwd")) };

      const workspace: any = await connected().workspaces.create({
        source,
        ...(req.title ? { title: String(req.title) } : {}),
      });
      return await createdWorkspace(workspace);
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
