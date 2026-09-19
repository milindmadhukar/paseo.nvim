import { resolve } from "node:path";
import { need, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";

/** Trailing slashes and `..` segments, so two spellings of one path compare equal. */
export function canonical(path: string): string {
  return resolve(path).replace(/\/+$/, "") || "/";
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
 * `workspaces.open()` is the fallback and not the first move: it is only
 * reached when nothing covers the directory, which is the case where
 * registering something new is what was actually wanted.
 */
export async function workspaceFor(
  ctx: BridgeConnection,
  cwd: string,
): Promise<any> {
  const api = ctx.connected();
  const want = canonical(cwd);

  const page: any = await api.workspaces.list({ page: { limit: 200 } });
  const owner = (page.entries ?? []).find((ws: any) => {
    if (ws.archivingAt) return false;
    const dir = ws.workspaceDirectory ?? ws.project?.checkout?.cwd ?? null;
    return dir ? canonical(String(dir)) === want : false;
  });

  return owner ? api.workspaces.ref(owner.id) : await api.workspaces.open(cwd);
}

export function workspaceOps(ctx: BridgeConnection): Ops {
  const connected = () => ctx.connected();
  return {
    async "workspace.open"(req) {
      const workspace = await connected().workspaces.open(
        String(need(req.cwd, "cwd")),
      );
      return {
        id: workspace.id,
        directory: (workspace as any).directory ?? null,
        projectId: (workspace as any).projectId ?? null,
      };
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
      return {
        id: workspace.id,
        directory: workspace.directory ?? null,
        projectId: workspace.projectId ?? null,
      };
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
