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

---Every workspace, Paseo's merged with ours.
---@param callback fun(list: paseo.PaseoWorkspace[]|nil, err: string|nil)
function M.list(callback)
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
      for _, ws in ipairs(registry.list()) do
        assembled[normalise(ws.root)] = ws
      end

      local out = {}
      for _, ws in ipairs(result.entries or {}) do
        if not ws.archivingAt then
          local ours = assembled[normalise(ws.directory)]
          out[#out + 1] = vim.tbl_extend("force", ws, {
            members = ours and registry.active(ours) or {},
            assembled = ours ~= nil,
          })
        end
      end

      table.sort(out, function(a, b)
        if (a.project or "") ~= (b.project or "") then
          return (a.project or "") < (b.project or "")
        end
        return (a.name or "") < (b.name or "")
      end)
      callback(out, nil)
    end)
  end)
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

---What discovery guessed, said out loud.
---
---`ws init` put these in a buffer and made you read them before anything
---happened. Nothing reads the file now, so they have to arrive as a message:
---the guessed base branch and the `shared` list are the two things discovery
---genuinely cannot decide, and both are wrong often enough to matter.
---@param plan paseo.Strategy
local function report(plan)
  local manifest = require "paseo.workspace.manifest"
  local lines = {
    ("wrote %s — %d repo(s)"):format(
      vim.fn.fnamemodify(manifest.path(plan.project), ":~"),
      vim.tbl_count(plan.manifest.repos)
    ),
  }
  if #(plan.manifest.shared or {}) > 0 then
    lines[#lines + 1] = ("shared = %s — prune what does not belong"):format(
      table.concat(plan.manifest.shared, ", ")
    )
  end
  for _, note in ipairs(plan.notes or {}) do
    lines[#lines + 1] = ("%s: %s"):format(note.repo, note.text)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN, { title = "paseo: manifest" })
end

---Create a workspace, whatever kind of project this is.
---
---ONE ENTRY POINT. `strategy` decides the shape, not the caller, and all three
---paths converge on the same thing: an ordinary Paseo workspace with a
---directory. That is the seam -- Paseo never learns whether it is looking at
---six assembled worktrees, one it cut itself, or a plain checkout.
---@param opts { name: string, root?: string }
---@param callback fun(id: string|nil, err: string|nil, plan: paseo.Strategy|nil)
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

  local plan = M.strategy(opts.root or assert(vim.uv.cwd()))

  -- A discovered manifest is WRITTEN rather than offered for review: being sent
  -- to read a TOML file is exactly the "which kind of project is this?" detour
  -- this entry point exists to remove. Its notes are not swallowed, though --
  -- they are what `ws init` would have shown, and `report` says them.
  if plan.kind == "discover" then
    local manifest = require "paseo.workspace.manifest"
    local ok, err = manifest.save(plan.project, plan.manifest, plan.notes)
    if not ok then
      return callback(
        nil,
        ("could not write %s: %s"):format(manifest.path(plan.project), tostring(err))
      )
    end
    report(plan)
    -- From here it is an ordinary manifested project, including on every later
    -- run: the file is now on disk, so `strategy` answers `assemble` next time.
    plan.kind = "assemble"
  end

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
        callback(result and result.id, create_err, plan)
      end)
    end

    -- `open` rather than `create`: it reuses the active workspace for that
    -- exact directory, so assembling twice does not litter the app with
    -- duplicates pointing at the same place.
    bridge.request("workspace.open", { cwd = directory }, function(open_err, result)
      callback(result and result.id, open_err, plan)
    end)
  end)
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
  vim.cmd[how == "cd" and "cd" or "tcd"](vim.fn.fnameescape(root))
  require("paseo.repos").invalidate()

  vim.api.nvim_exec_autocmds("User", { pattern = "PaseoWorkspaceOpen", data = { root = root } })
  vim.notify("paseo: " .. vim.fn.fnamemodify(root, ":~"), vim.log.levels.INFO)
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
  end)
end

---Sessions -- the agents -- in a workspace.
---@param ws paseo.PaseoWorkspace
---@param callback fun(sessions: table[]|nil, err: string|nil)
function M.sessions(ws, callback)
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
    end)
  end)
end

---Start a new session in a workspace.
---@param ws paseo.PaseoWorkspace
---@param opts? { title?: string }
---@param callback fun(id: string|nil, err: string|nil)
function M.new_session(ws, opts, callback)
  opts = opts or {}
  require("paseo.ui.create").review({
    cwd = ws.directory,
    preferred = require("paseo.config").get().paseo.provider,
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
    end)
  end)
end

return M
