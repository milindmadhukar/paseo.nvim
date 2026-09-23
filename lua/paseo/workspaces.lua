--- Workspaces, as Paseo sees them.
---
--- PASEO IS THE SOURCE OF TRUTH. A workspace created in the app, or by
--- `paseo workspace create`, is exactly as real as one this plugin assembled --
--- listing only our own registry made half of them invisible.
---
--- Our registry adds one thing Paseo cannot know: that a given directory is
--- several worktrees rather than one checkout. So the two are merged, keyed on
--- the directory.

local bridge = require "paseo.bridge"
local hosts = require "paseo.hosts"
local registry = require "paseo.registry"

local M = {}

---@class paseo.PaseoWorkspace
---@field id string
---@field name string
---@field directory string
---@field project string
---@field kind string          "directory" | "worktree"
---@field status string
---@field branch string|nil
---@field ownedWorktree boolean  Paseo cut this worktree itself.
---@field members { name: string, path: string }[]  From our registry; may be empty.
---@field assembled boolean    We assembled it out of N worktrees.
---@field group string         The project it is nested under HERE. See `M.group`.
---@field projectId string|nil Paseo's own project record.

---@param path string|nil
---@return string
local function normalise(path)
  if not path or path == "" then
    return ""
  end
  return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

---@param dir string
---@param args string[]
---@return string|nil
local function git(dir, args)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  local out = (res.stdout or ""):gsub("%s+$", "")
  return out ~= "" and out or nil
end

---Which project a workspace belongs to, as far as the EDITOR is concerned.
---
---PASEO GETS THIS WRONG FOR A `ws` WORKSPACE, and not by accident -- it cannot
---know. `<project>/.workspaces/<name>` is a plain directory holding several
---worktrees, because a git worktree is per repo and a unit of work spanning
---four repos has nowhere else to live. So it is not a git repo, and when the
---daemon is asked to open it, it registers that directory as a top-level
---project named after the WORKSPACE. `~/Code/openfin/.workspaces/billing`
---comes back as a project called `billing`, sitting as a sibling of `openfin`
---rather than inside it -- which is exactly how the sidebar drew it.
---
---The shape is recognisable from the path alone, which `repos.workspace_root`
---already does for the repo list. So the editor groups on that and leaves the
---daemon's own record alone: nothing is renamed, nothing is migrated, and a
---workspace made in the app lands in the same group as one made here.
---@param ws paseo.PaseoWorkspace
---@return string
function M.group(ws)
  if ws.hostId and not (hosts.get(ws.hostId) or {}).local_host then
    return ws.project or ws.name or ""
  end
  local root = require("paseo.repos").workspace_root(ws.directory)
  if root then
    -- `root` is `<project>/<workspaces_dir>/<name>`, so the project is two up.
    local project = vim.fs.dirname(vim.fs.dirname(root))
    local name = vim.fs.basename(project)
    if name and name ~= "" and name ~= "/" then
      return name
    end
  end
  return ws.project or ws.name or ""
end

---Every workspace, Paseo's merged with ours.
---@param callback fun(list: paseo.PaseoWorkspace[]|nil, err: string|nil)
function M.list(callback, host_id)
  local host = hosts.get(host_id)
  if not host then
    return callback(nil, "unknown Paseo host " .. tostring(host_id))
  end
  host_id = host.id
  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end

    bridge.request("workspaces.list", { limit = 200 }, function(list_err, result)
      if list_err then
        return callback(nil, list_err)
      end

      -- Our registry, indexed by directory, so a Paseo workspace pointed at an
      -- assembled directory picks up its members.
      local assembled = {}
      if host.local_host then
        for _, ws in ipairs(registry.list()) do
          assembled[normalise(ws.root)] = ws
        end
      end

      local out = {}
      for _, ws in ipairs(result.entries or {}) do
        if not ws.archivingAt then
          local ours = assembled[normalise(ws.directory)]
          local merged = vim.tbl_extend("force", ws, {
            members = ours and registry.active(ours) or {},
            assembled = ours ~= nil,
            hostId = host_id,
            local_directory = hosts.to_local(host_id, ws.directory),
          })
          merged.group = M.group(merged)
          out[#out + 1] = merged
        end
      end

      -- By GROUP, not by the daemon's project: see `M.group`. Sorting on the
      -- project is what put `billing` between `bar` and `openfin` instead of
      -- under the `openfin` it lives inside.
      table.sort(out, function(a, b)
        if (a.group or "") ~= (b.group or "") then
          return (a.group or "") < (b.group or "")
        end
        return (a.name or "") < (b.name or "")
      end)
      callback(out, nil)
    end, host_id)
  end, host_id)
end

---Every connected host's workspaces. One offline host does not blank the rest.
function M.list_all(callback)
  local left = hosts.count()
  local out, errors = {}, {}
  if left == 0 then
    return callback(out, nil, errors)
  end
  for _, host in ipairs(hosts.all()) do
    M.list(function(list, err)
      if err then
        errors[host.id] = err
      else
        vim.list_extend(out, list or {})
      end
      left = left - 1
      if left == 0 then
        table.sort(out, function(a, b)
          if a.hostId ~= b.hostId then
            return a.hostId < b.hostId
          end
          return (a.name or "") < (b.name or "")
        end)
        callback(out, nil, errors)
      end
    end, host.id)
  end
end

-- ----------------------------------------------------------------- creating

---@class paseo.Strategy
---@field kind "assemble"|"discover"|"worktree"|"local"
---@field root string      Directory a workspace was asked for.
---@field project string?  Project root holding the manifest.  assemble, discover
---@field manifest table?  Discovered, not yet on disk.        discover
---@field notes table[]?   What discovery could not decide.    discover
---@field repo string?     Git toplevel the worktree is cut from.  worktree
---@field base string?     Ref the worktree branches off.          worktree
---@field members integer? Worktrees assembled. Filled in after.   assemble

---The ref new work is cut from: what is CHECKED OUT, never origin/HEAD.
---
---Assembly learned this the hard way -- every openfin repo sits on `dev` while
---origin/HEAD reports `main`, so origin/HEAD would silently base the work on
---the wrong history. A second entry point getting it wrong is the same bug
---twice.
---@param repo string
---@return string
local function base_of(repo)
  local branch = git(repo, { "branch", "--show-current" })
  if branch then
    return branch
  end
  local head = git(repo, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  return head and (head:gsub("^origin/", "")) or "main"
end

---What creating a workspace in `root` would actually do.
---
---THE POINT IS THAT YOU SHOULD NOT HAVE TO KNOW. A multi-repo project needs its
---worktrees assembled, because Paseo's own isolation requires a git repository
---and a directory holding six of them is not one. A plain git repo needs no
---assembly at all -- Paseo cuts and owns the worktree itself. A directory that
---is neither gets a workspace on itself.
---
---That is three different mechanisms for one intention, and which one applies
---is a property of the DIRECTORY, not a question for the person typing. So it
---is answered here, once, instead of by remembering whether this project was
---the `ws init` kind.
---@param root string
---@return paseo.Strategy
function M.strategy(root)
  root = (vim.fn.fnamemodify(vim.fn.expand(root), ":p"):gsub("/+$", ""))

  -- An explicit manifest wins outright, and wins from INSIDE a member repo:
  -- ~/Code/kora/kora-app belongs to kora's manifest, not to kora-app alone.
  local project = registry.project_root(root)
  if project then
    return { kind = "assemble", root = root, project = project }
  end

  -- A git repository needs nothing assembled. This is the case the plugin used
  -- to have no answer for: it fell through to a plain workspace on the primary
  -- checkout, so two "workspaces" were two names for the same files.
  local top = git(root, { "rev-parse", "--show-toplevel" })
  if top then
    return { kind = "worktree", root = root, repo = top, base = base_of(top) }
  end

  -- Not a repo, but repos live below: the manifest is MISSING rather than
  -- deliberately absent, so it gets written on the way past.
  local m, notes = require("paseo.workspace").discover(root)
  if m then
    return { kind = "discover", root = root, project = root, manifest = m, notes = notes }
  end

  return { kind = "local", root = root }
end

---One phrase for the shape a plan turned out to be, for the message after it.
---@param plan paseo.Strategy|nil
---@return string
function M.describe(plan)
  if not plan then
    return "workspace"
  end
  if plan.kind == "worktree" then
    return "isolated worktree off " .. (plan.base or "?")
  end
  if plan.kind == "local" then
    return "shared checkout"
  end
  return ("%d worktree(s)"):format(plan.members or 0)
end

---Create a workspace, whatever kind of project this is.
---
---ONE ENTRY POINT. `strategy` decides the shape, not the caller, and all three
---paths converge on the same thing: an ordinary Paseo workspace with a
---directory. That is the seam -- Paseo never learns whether it is looking at
---six assembled worktrees, one it cut itself, or a plain checkout.
---@param opts { name: string, root?: string, new?: boolean, configure?: fun(ctx: table, done: fun(m: table|nil, notes: table[]|nil)) }
---@param callback fun(id: string|nil, err: string|nil, plan: paseo.Strategy|nil, workspace: paseo.PaseoWorkspace|nil)
function M.create(opts, callback)
  if not opts.name or opts.name == "" then
    return callback(nil, "a workspace needs a name")
  end
  if opts.name:find "[/\\ ]" then
    return callback(
      nil,
      ("workspace names may not contain slashes or spaces: %q"):format(opts.name)
    )
  end

  local host = hosts.get(opts.host_id)
  if not host then
    return callback(nil, "unknown Paseo host " .. tostring(opts.host_id))
  end
  opts.host_id = host.id
  local local_root = opts.local_root or (opts.remote and hosts.to_local(host.id, opts.root))
  local source_root = local_root or opts.root or assert(vim.uv.cwd())
  local plan = M.strategy(source_root)
  if not host.local_host then
    if plan.kind == "assemble" or plan.kind == "discover" then
      return callback(
        nil,
        "multi-repo assembled workspaces are local-only; create this workspace on the local host"
      )
    end
    local remote_root = opts.remote and opts.root or hosts.to_remote(host.id, source_root)
    if not remote_root then
      return callback(nil, source_root .. " is not mapped on Paseo host " .. host.label)
    end
    plan.root = remote_root
    if plan.kind == "worktree" then
      plan.repo = remote_root
    end
  end

  -- A discovered manifest is OFFERED before it is written. It used to be
  -- written outright, on the grounds that being sent to read a TOML file is
  -- the "which kind of project is this?" detour this entry point exists to
  -- remove -- but that traded one detour for a worse one, because the two
  -- things discovery cannot decide (each repo's base branch, and which
  -- siblings are shared context rather than junk) were then asked in comments
  -- inside a file nobody opens. The dialog asks them where you already are.
  --
  -- HANDED IN rather than reached for, so the whole path is drivable in a test
  -- with no window. The default is the dialog.
  if plan.kind == "discover" then
    local configure = opts.configure
      or function(ctx, done)
        require("paseo.ui.manifest").review(ctx, done)
      end
    return configure({
      root = plan.project,
      manifest = plan.manifest,
      notes = plan.notes,
    }, function(edited, notes)
      -- Nothing confirmed, nothing written. A half-decided manifest is worse
      -- than none: `strategy` would answer `assemble` from then on and never
      -- ask again.
      if not edited then
        return callback(nil, nil, nil)
      end
      local manifest = require "paseo.workspace.manifest"
      local ok, err = manifest.save(plan.project, edited, notes or plan.notes)
      if not ok then
        return callback(
          nil,
          ("could not write %s: %s"):format(manifest.path(plan.project), tostring(err))
        )
      end
      -- From here it is an ordinary manifested project, including on every
      -- later run: the file is now on disk, so `strategy` answers `assemble`.
      plan.manifest = edited
      plan.kind = "assemble"
      M.assemble(plan, opts, callback)
    end)
  end

  M.assemble(plan, opts, callback)
end

---Everything after the manifest question is settled.
---
---Split out of `create` only because the dialog made that question
---asynchronous; the three shapes still converge here exactly as before.
---@param plan paseo.Strategy
---@param opts { name: string, root?: string, new?: boolean }
---@param callback fun(id: string|nil, err: string|nil, plan: paseo.Strategy|nil, workspace: paseo.PaseoWorkspace|nil)
function M.assemble(plan, opts, callback)
  local directory = plan.root
  if plan.kind == "assemble" then
    local m, load_err = require("paseo.workspace.manifest").load(plan.project)
    if not m then
      return callback(nil, load_err)
    end
    if registry.find(opts.name, plan.project) then
      return callback(nil, ("a workspace called %q already exists here"):format(opts.name))
    end

    local ws, create_err =
      require("paseo.workspace").create(m, { name = opts.name, root = plan.project })
    if not ws then
      return callback(nil, create_err)
    end
    registry.add(ws)
    directory = ws.root
    plan.members = #registry.active(ws)
  end

  local host_id = opts.host_id
  bridge.ensure(function(err)
    if err then
      return callback(nil, err, plan)
    end

    if plan.kind == "worktree" then
      -- `workspace.open` here would hand back a workspace on the PRIMARY
      -- checkout -- not isolation at all, just a second name for the same
      -- files, which is the trap this branch exists to avoid.
      local prefix = require("paseo.config").get().workspaces.branch_prefix or "ws/"
      return bridge.request("workspace.create", {
        cwd = plan.repo,
        worktree = true,
        branch = prefix .. opts.name,
        base = plan.base,
        title = opts.name,
      }, function(create_err, result)
        callback(result and result.id, create_err, plan, result and {
          id = result.id,
          name = opts.name,
          directory = result.directory,
          project = plan.repo,
          kind = "worktree",
          ownedWorktree = true,
          assembled = false,
          members = {},
        } or nil)
      end, host_id)
    end

    -- `open` rather than `create`: it reuses the active workspace for that
    -- exact directory, so assembling twice does not litter the app with
    -- duplicates pointing at the same place.
    local op = opts.new and "workspace.create" or "workspace.open"
    local args = opts.new and { cwd = directory, title = opts.name } or { cwd = directory }
    bridge.request(op, args, function(open_err, result)
      callback(result and result.id, open_err, plan, result and {
        id = result.id,
        name = opts.name,
        directory = result.directory or directory,
        project = plan.project or plan.root,
        kind = plan.kind == "local" and "directory" or plan.kind,
        ownedWorktree = false,
        assembled = plan.kind == "assemble",
        members = {},
      } or nil)
    end, host_id)
  end, host_id)
end

---One workspace by daemon id.
---@param id string
---@param callback fun(workspace: paseo.PaseoWorkspace|nil, err: string|nil)
function M.get(id, callback, host_id)
  M.list(function(list, err)
    if err then
      return callback(nil, err)
    end
    for _, ws in ipairs(list or {}) do
      if ws.id == id then
        return callback(ws, nil)
      end
    end
    callback(nil, "the created workspace is not in Paseo's workspace list")
  end, host_id)
end

---Switch to a workspace.
---
---IN THIS NEOVIM by default, because that is what a Neovim plugin should do.
---This used to spawn a Neovide window unconditionally, which is one person's
---setup dressed up as a rule: over ssh, or in any terminal Neovim, there is no
---GUI to spawn and `<CR>` appeared to do nothing at all.
---
---The switch is a new tab page with its own `tcd`, not a bare `cd`, because the
---objection that produced the spawn is real -- chdir'ing in place leaves the
---buffers, LSP clients and jumplist of the workspace you just left pointing
---into it. A tab keeps them apart at the cost of one tab. `workspaces.open`
---picks something else, up to and including spawning that GUI window.
---
---An open chat comes WITH you (`paseo.ui.chat.follow`). It used to stay on the
---agent in the workspace you just left, which on the full-screen surface meant
---the one window on screen was describing somewhere else entirely.
---
---Fires `User PaseoWorkspaceOpen` with `data.root` afterwards, so a config can
---decide what the new tab should SHOW -- a file picker, oil, a dashboard --
---without having to replace the switch itself.
---@param ws paseo.PaseoWorkspace
---@return boolean opened
function M.open(ws)
  local root = ws and ws.directory
  if not root or root == "" then
    vim.notify("paseo: that workspace has no directory", vim.log.levels.WARN)
    return false
  end

  local host = hosts.get(ws.hostId)
  if host then
    hosts.select(host.id)
  end
  local local_root = ws.local_directory or (host and hosts.to_local(host.id, root))
  if host and not host.local_host and not local_root then
    require("paseo.ui.chat").open {
      root = root,
      host_id = host.id,
      remote = true,
      title = ws.name,
    }
    return true
  end
  local switch_root = local_root or root
  local how = require("paseo.config").get().workspaces.open

  if type(how) == "function" then
    local ok, declined = pcall(how, ws)
    if not ok then
      vim.notify("paseo: workspaces.open: " .. tostring(declined), vim.log.levels.ERROR)
    elseif declined ~= false then
      return true
    end
    -- Errored, or declined on purpose. Either way the workspace still has to
    -- open, and the built-in switch is the thing that always works.
    how = "tab"
  end

  if how == "tab" then
    vim.cmd.tabnew()
  end
  vim.cmd[how == "cd" and "cd" or "tcd"](vim.fn.fnameescape(switch_root))
  require("paseo.repos").invalidate()

  -- After the `tcd`, so the chat that lands is looking at the directory this
  -- Neovim is now in, and before the autocmd, so a config that opens something
  -- in the new tab gets the last word on where the cursor ends up.
  if host and not host.local_host then
    require("paseo.ui.chat").open {
      root = root,
      local_root = switch_root,
      host_id = host.id,
      remote = true,
      create = false,
    }
  else
    require("paseo.ui.chat").follow(switch_root)
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = "PaseoWorkspaceOpen",
    data = { root = switch_root, remote_root = root, host = host and host.id },
  })
  vim.notify("paseo: " .. vim.fn.fnamemodify(switch_root, ":~"), vim.log.levels.INFO)
  return true
end

---Archive a workspace, and dismantle its worktrees if we assembled them.
---@param ws paseo.PaseoWorkspace
---@param opts? { force: boolean }
---@param callback fun(err: string|nil)
function M.archive(ws, opts, callback)
  opts = opts or {}

  -- Ours first: `workspace.remove` refuses when a member holds work that
  -- exists nowhere else, and that refusal must not be lost behind an archive
  -- that already happened.
  if ws.assembled then
    local ours
    for _, entry in ipairs(registry.list()) do
      if normalise(entry.root) == normalise(ws.directory) then
        ours = entry
      end
    end
    if ours then
      local ok, err = require("paseo.workspace").remove(ours, { force = opts.force })
      if not ok then
        return callback(err)
      end
      registry.remove(ours.name, ours.project)
    end
  end

  bridge.request("workspace.archive", { workspaceId = ws.id }, function(err)
    callback(err)
  end, ws.hostId)
end

---Archive a workspace, asking the one question worth asking.
---
---Lifted out of the telescope picker, where it was a local, so the Workspaces
---panel offers the same act rather than a second implementation of it that
---forgets the refusal path.
---
---The refusal is the point. `workspace.remove` declines when a member worktree
---holds work that exists nowhere else, and it names exactly what would be lost
---- so that is a question, not an error to swallow and not something to force
---past on your behalf.
---@param ws paseo.PaseoWorkspace
---@param after? fun()
function M.confirm_archive(ws, after)
  local label = ws.name or ws.directory or ws.id

  local function go(force)
    M.archive(ws, { force = force }, function(err)
      if not err then
        vim.notify("paseo: archived " .. label, vim.log.levels.INFO)
        return after and vim.schedule(after)
      end

      if not force and err:find "refusing" then
        vim.schedule(function()
          vim.ui.select({ "No, keep it", "Yes, discard that work" }, {
            prompt = err:gsub("\n.*", "") .. " — discard?",
          }, function(choice)
            if choice and choice:find "Yes" then
              go(true)
            end
          end)
        end)
        return
      end
      vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end)
  end

  go(false)
end

---Forget a project -- Paseo's record of it, never the files.
---
---The counterpart to archiving, and the app offers both. Archiving retires one
---unit of work; this drops the daemon's record of a whole directory tree, and
---for a `ws` workspace it is how you get rid of the top-level project the
---daemon invented for `<project>/.workspaces/<name>`.
---
---Takes a LIST of project ids, because a group in the sidebar is not one
---daemon project: grouping on the path puts `openfin` and the invented
---`billing` in the same group, and removing "the group" has to mean all of
---them or it leaves half behind.
---@param ids string[]
---@param label string  What to call it in the confirmation.
---@param after? fun()
function M.remove_project(ids, label, after)
  ids = ids or {}
  if #ids == 0 then
    return vim.notify("paseo: no project to remove", vim.log.levels.WARN)
  end

  local prompt = ("Remove %s from Paseo? (%d project%s; files are not touched)"):format(
    label,
    #ids,
    #ids == 1 and "" or "s"
  )
  vim.ui.select({ "No", "Yes, remove it" }, { prompt = prompt }, function(choice)
    if not (choice and choice:find "Yes") then
      return
    end
    local left, failed = #ids, nil
    for _, id in ipairs(ids) do
      bridge.request("project.remove", { projectId = id }, function(err)
        failed = failed or err
        left = left - 1
        if left > 0 then
          return
        end
        if failed then
          vim.notify("paseo: " .. failed, vim.log.levels.ERROR)
        else
          vim.notify("paseo: removed " .. label, vim.log.levels.INFO)
        end
        if after then
          vim.schedule(after)
        end
      end)
    end
  end)
end

---Agent sessions in a workspace.
---@param ws paseo.PaseoWorkspace
---@param callback fun(agent_sessions: table[]|nil, err: string|nil)
function M.agent_sessions(ws, callback)
  local host_id = ws.hostId
  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end
    bridge.request("agents.list", { limit = 200 }, function(list_err, result)
      if list_err then
        return callback(nil, list_err)
      end
      local dir = normalise(ws.directory)
      local out = {}
      for _, agent in ipairs(result.entries or {}) do
        -- Matched on workspaceId when the daemon reports one, and on directory
        -- otherwise: agents created before this plugin existed have a cwd but
        -- may predate the workspace they now sit in.
        if agent.workspaceId == ws.id or normalise(agent.cwd) == dir then
          out[#out + 1] = agent
        end
      end
      table.sort(out, function(a, b)
        return (a.title or a.id) < (b.title or b.id)
      end)
      callback(out, nil)
    end, host_id)
  end, host_id)
end

---Compatibility alias for the old ambiguous name.
M.sessions = M.agent_sessions

---Start a new agent session in a workspace.
---@param ws paseo.PaseoWorkspace
---@param opts? { title?: string }
---The Paseo workspace a directory belongs to.
---
---A workspace's `directory` is its working directory, and anything under it is
---in it -- which is how a member worktree resolves to the workspace that
---assembled it. One walk, in one place: the agent picker and the Sessions
---panel both need the answer and had no business each writing it.
---@param root string
---@param callback fun(ws: paseo.PaseoWorkspace|nil, err: string|nil)
function M.for_dir(root, callback)
  local host = hosts.get()
  local here = host.local_host and vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
    or hosts.to_remote(host.id, root)
  if not here then
    return callback(nil, root .. " is not mapped on Paseo host " .. host.label)
  end
  M.list(function(list, err)
    if err then
      return callback(nil, err)
    end
    for _, ws in ipairs(list) do
      local dir = host.local_host and vim.fn.resolve(ws.directory or ""):gsub("/+$", "")
        or (ws.directory or ""):gsub("/+$", "")
      if dir ~= "" and (here == dir or vim.startswith(here, dir .. "/")) then
        return callback(ws, nil)
      end
    end
    callback(nil, "this directory is not in a Paseo workspace yet")
  end, host.id)
end

---@param callback fun(id: string|nil, err: string|nil)
function M.new_agent_session(ws, opts, callback)
  opts = opts or {}
  require("paseo.ui.create").review({
    cwd = ws.directory,
    preferred = (hosts.get(ws.hostId) or {}).provider
      or require("paseo.config").get().paseo.provider,
    host_id = ws.hostId,
  }, function(draft, review_err)
    if review_err or not draft then
      return callback(nil, review_err or "cancelled")
    end
    bridge.request("agent.create", {
      workspaceId = ws.id,
      provider = draft.provider,
      modeId = draft.modeId,
      thinkingOptionId = draft.thinkingOptionId,
      featureValues = draft.featureValues,
      title = opts.title,
    }, function(err, result)
      if not err then
        require("paseo.config").get().paseo.provider = draft.provider
      end
      callback(result and result.id, err)
    end, ws.hostId)
  end)
end

---Compatibility alias for the former ambiguous name.
M.new_session = M.new_agent_session

return M
