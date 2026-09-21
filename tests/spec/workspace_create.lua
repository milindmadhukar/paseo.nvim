--- Workspaces: creating and opening one.
---
--- Which shape `wcreate` picks from the directory it is standing in, the
--- manifest dialog that configures it, and what `<CR>` does with the result.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local go_home = t.go_home

---A plain directory holding `names` as repos, each on its own branch.
---@param names table<string, string>  repo name -> branch
---@return string project
local function multi_repo(names)
  local project = vim.fn.tempname()
  for name, branch in pairs(names) do
    local repo = vim.fs.joinpath(project, name)
    vim.fn.mkdir(repo, "p")
    for _, args in ipairs {
      { "init", "-q", "-b", branch, "." },
      { "config", "user.email", "t@example.com" },
      { "config", "user.name", "t" },
    } do
      vim.system(vim.list_extend({ "git", "-C", repo }, args)):wait()
    end
    local fd = assert(io.open(vim.fs.joinpath(repo, "f.txt"), "w"))
    fd:write "x\n"
    fd:close()
    vim.system({ "git", "-C", repo, "add", "-A" }):wait()
    vim.system({ "git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-qm", "i" }):wait()
  end
  return project
end

---@param group table
---@param id string
---@return table|nil
local function entry_of(group, id)
  for _, entry in ipairs(group.entries) do
    if entry.id == id then
      return entry
    end
  end
end

--- Opening a workspace happens IN THIS NEOVIM.
---
--- It used to spawn a Neovide window whenever one could be spawned, which is
--- one person's setup: a terminal Neovim has no GUI to spawn and `<CR>` looked
--- like it did nothing. The spawn is still available -- as a function you
--- write -- and everything here is about that seam holding.
---A plain directory holding `names` as repos, each on its own branch.
---@param names table<string, string>  repo name -> branch
---@return string project
local function multi_repo(names)
  local project = vim.fn.tempname()
  for name, branch in pairs(names) do
    local repo = vim.fs.joinpath(project, name)
    vim.fn.mkdir(repo, "p")
    for _, args in ipairs {
      { "init", "-q", "-b", branch, "." },
      { "config", "user.email", "t@example.com" },
      { "config", "user.name", "t" },
    } do
      vim.system(vim.list_extend({ "git", "-C", repo }, args)):wait()
    end
    local fd = assert(io.open(vim.fs.joinpath(repo, "f.txt"), "w"))
    fd:write "x\n"
    fd:close()
    vim.system({ "git", "-C", repo, "add", "-A" }):wait()
    vim.system({ "git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-qm", "i" }):wait()
  end
  return project
end

---@param group table
---@param id string
---@return table|nil

--- One entry point, three shapes, decided from the directory.
---
--- The regression this exists to prevent: `wcreate` in a plain git repo used to
--- fall through to `workspace.open` on the PRIMARY checkout, so two
--- "workspaces" were two names for the same files -- no isolation at all, and
--- nothing said so. The other half is ordering: an explicit manifest has to win
--- over "this is a git repo", or a member repo of a multi-repo project gets
--- isolated on its own and the siblings are left behind.
local function test_strategy()
  local workspaces = require "paseo.workspaces"
  local manifest = require "paseo.workspace.manifest"

  local solo = workspaces.strategy(root .. "/solo")
  eq("strategy: a git repo gets a worktree Paseo cuts itself", solo.kind, "worktree")
  eq("strategy: cut from what is CHECKED OUT, not origin/HEAD", solo.base, "main")
  truthy("strategy: cut from the repo toplevel", (solo.repo or ""):find "/solo$" ~= nil, solo.repo)

  eq(
    "strategy: a member repo with no manifest above it is just a repo",
    workspaces.strategy(root .. "/multi/clm").kind,
    "worktree"
  )

  local multi = workspaces.strategy(root .. "/multi")
  eq("strategy: a non-git parent holding repos discovers a manifest", multi.kind, "discover")
  eq(
    "strategy: and carries what it discovered, so create need not walk twice",
    multi.manifest and manifest.names(multi.manifest),
    { "clm", "clm_api" }
  )

  eq(
    "strategy: a directory that is neither gets a workspace on itself",
    workspaces.strategy(root .. "/plain").kind,
    "local"
  )

  eq("describe: a worktree names its base", workspaces.describe(solo), "isolated worktree off main")
  eq(
    "describe: an assembly counts its members",
    workspaces.describe { kind = "assemble", root = "", members = 5 },
    "5 worktree(s)"
  )

  -- Writing the manifest is a ONE-TIME event: the same directory answers
  -- `assemble` afterwards, rather than being rediscovered on every create.
  local project = vim.fn.tempname()
  local repo = vim.fs.joinpath(project, "repo")
  vim.fn.mkdir(repo, "p")
  for _, args in ipairs {
    { "init", "-q", "-b", "main", "." },
    { "config", "user.email", "t@example.com" },
    { "config", "user.name", "t" },
  } do
    vim.system(vim.list_extend({ "git", "-C", repo }, args)):wait()
  end
  local fd = assert(io.open(vim.fs.joinpath(repo, "f.txt"), "w"))
  fd:write "x\n"
  fd:close()
  vim.system({ "git", "-C", repo, "add", "-A" }):wait()
  vim.system({ "git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-qm", "init" }):wait()

  local fresh = workspaces.strategy(project)
  eq("strategy: a fresh multi-repo project discovers", fresh.kind, "discover")
  truthy("strategy: the discovered manifest saves", manifest.save(project, fresh.manifest, {}))
  eq("strategy: and is `assemble` from then on", workspaces.strategy(project).kind, "assemble")

  -- The ordering that matters: an explicit manifest beats "this is a repo".
  eq(
    "strategy: a manifest wins from inside a member repo",
    workspaces.strategy(repo).kind,
    "assemble"
  )
  eq(
    "strategy: and points at the project, not the member",
    workspaces.strategy(repo).project,
    project
  )

  vim.fn.delete(project, "rf")
end

local function test_manifest()
  local ui = require "paseo.ui.manifest"
  local manifest = require "paseo.workspace.manifest"

  local project = multi_repo { alpha = "main", beta = "dev" }
  vim.fn.mkdir(vim.fs.joinpath(project, "Docs"), "p")
  vim.fn.mkdir(vim.fs.joinpath(project, "junk"), "p")

  local draft = assert(ui.draft(project))
  local groups = ui.groups(draft)
  eq("manifest: two cards -- repos and shared", #groups, 2)
  eq("manifest: both repos are offered", #groups[1].entries, 2)

  -- The base on the right of the row is the whole reason toggles grew a note:
  -- it is what discovery most often gets wrong.
  eq("manifest: each repo carries its base as a note", entry_of(groups[1], "beta").note, "dev")

  -- Everything is in by default on a first run, siblings included.
  eq("manifest: a fresh repo starts included", entry_of(groups[1], "beta").value, true)
  eq("manifest: a fresh sibling starts kept", entry_of(groups[2], "junk").value, true)

  -- Unchecking a repo writes `default = false`, which is the ONLY thing
  -- `manifest.select` reads. A checked repo must carry no key at all --
  -- `default = true` is not a thing the renderer emits.
  ui.apply(draft, groups[1], entry_of(groups[1], "beta"))
  ui.apply(draft, groups[2], entry_of(groups[2], "junk"))
  local result = ui.result(draft)
  eq("manifest: an unchecked repo is opted out", result.repos.beta.default, false)
  eq("manifest: a checked repo carries no default key", result.repos.alpha.default, nil)
  eq("manifest: a pruned sibling is gone from shared", result.shared, { "Docs" })

  -- What the screen shows is what the file says.
  local parsed = manifest.parse(manifest.render(result, ui.notes(draft)))
  eq("manifest: the opt-out survives a round trip", parsed.repos.beta.default, false)
  eq("manifest: and so does the pruning", parsed.shared, { "Docs" })

  -- THE REGRESSION THIS SCREEN EXISTS FOR. The generated file says "PRUNE
  -- THIS" in a comment and openfin's `shared` still lists `test quotes`,
  -- because nothing that re-read the project ever honoured the pruning. A
  -- second open must not re-add a sibling that is still sitting on disk.
  truthy("manifest: it saves", manifest.save(project, result, ui.notes(draft)))
  local reopened = assert(ui.draft(project))
  local regroups = ui.groups(reopened)
  eq("manifest: a pruned sibling is still offered", entry_of(regroups[2], "junk") ~= nil, true)
  eq("manifest: but stays pruned", entry_of(regroups[2], "junk").value, false)
  eq("manifest: and the opted-out repo stays out", entry_of(regroups[1], "beta").value, false)

  -- Reloading re-walks the project. It must not undo either decision.
  ui.reload(reopened)
  local after = ui.groups(reopened)
  eq("manifest: a reload keeps the pruning", entry_of(after[2], "junk").value, false)
  eq("manifest: and keeps the opt-out", entry_of(after[1], "beta").value, false)

  -- Cancelling writes NOTHING. A half-decided manifest is worse than none:
  -- `strategy` would answer `assemble` from then on and never ask again.
  local fresh = multi_repo { solo = "main" }
  local created, err, plan = "unset", "unset", "unset"
  require("paseo.workspaces").create({
    name = "x",
    root = fresh,
    configure = function(_, done)
      done(nil)
    end,
  }, function(id, e, p)
    created, err, plan = id, e, p
  end)
  eq("manifest: cancelling creates nothing", created, nil)
  eq("manifest: and is not an error", err, nil)
  eq("manifest: and reports no plan, so the caller stays quiet", plan, nil)
  eq(
    "manifest: cancelling leaves no manifest on disk",
    vim.uv.fs_stat(manifest.path(fresh)),
    nil
  )

  -- Confirming writes what the hook handed back, not what discovery guessed.
  local edited = { workspaces_dir = ".workspaces", branch_prefix = "ws/", shared = {}, repos = {
    solo = { base = "main", default = false },
  } }
  require("paseo.workspaces").create({
    name = "y",
    root = fresh,
    configure = function(_, done)
      done(edited, {})
    end,
  }, function() end)
  local written = manifest.load(fresh)
  truthy("manifest: confirming writes the file", written ~= nil)
  eq("manifest: and writes the EDITED manifest, not the discovered one",
    written and written.repos.solo.default, false)
end

local function test_workspace_open()
  local config = require "paseo.config"
  local workspaces = require "paseo.workspaces"

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local resolved = vim.fn.resolve(dir)
  local ws = { directory = dir, name = "t" }

  local start_tabs = #vim.api.nvim_list_tabpages()

  -- The default. A tab of its own, tcd'd in: the objection that produced the
  -- GUI spawn -- that chdir leaves the old workspace's buffers behind -- is
  -- answered by the tab, not by a second process.
  config.setup {}
  eq("open: the default switches in this Neovim", config.defaults().workspaces.open, "tab")

  local seen
  local au = vim.api.nvim_create_autocmd("User", {
    pattern = "PaseoWorkspaceOpen",
    callback = function(ev)
      seen = ev.data.root
    end,
  })

  truthy("open: it opens", workspaces.open(ws))
  eq("open: in a new tab page", #vim.api.nvim_list_tabpages(), start_tabs + 1)
  eq("open: whose cwd is the workspace", vim.fn.resolve(vim.fn.getcwd()), resolved)
  eq("open: and it announces the root, so a config can fill the tab", seen, dir)
  -- `tcd`, not `cd`: the tab we came from must not have moved with it.
  vim.cmd.tabclose()
  truthy(
    "open: the tab it came from kept its cwd",
    vim.fn.resolve(vim.fn.getcwd()) ~= resolved,
    vim.fn.getcwd()
  )

  -- "tcd" is the same switch without the tab, for people who keep one.
  local tabs = #vim.api.nvim_list_tabpages()
  config.setup { workspaces = { open = "tcd" } }
  workspaces.open(ws)
  eq("open: `tcd` reuses this tab", #vim.api.nvim_list_tabpages(), tabs)
  eq("open: and still lands in the workspace", vim.fn.resolve(vim.fn.getcwd()), resolved)

  -- The escape hatch, which is how the Neovide spawn comes back.
  local spawned
  config.setup {
    workspaces = {
      open = function(got)
        spawned = got.directory
      end,
    },
  }
  tabs = #vim.api.nvim_list_tabpages()
  truthy("open: a function handles it", workspaces.open(ws))
  eq("open: and is handed the workspace", spawned, dir)
  eq("open: with no tab opened behind its back", #vim.api.nvim_list_tabpages(), tabs)

  -- Returning `false` DECLINES -- which is what lets one config spawn a window
  -- under a GUI and switch in place in a terminal, rather than being two
  -- configs.
  config.setup {
    workspaces = {
      open = function()
        return false
      end,
    },
  }
  workspaces.open(ws)
  eq("open: declining falls back to the built-in switch", #vim.api.nvim_list_tabpages(), tabs + 1)
  vim.cmd.tabclose()

  -- A function that throws must not strand you on the picker with nothing
  -- open. The error is reported; the workspace still opens.
  config.setup {
    workspaces = {
      open = function()
        error "nope"
      end,
    },
  }
  truthy("open: a broken handler still opens the workspace", workspaces.open(ws))
  vim.cmd.tabclose()

  -- A workspace with no directory is the one case that cannot open.
  eq("open: nothing to open without a directory", workspaces.open { name = "x" }, false)

  local bad = pcall(config.setup, { workspaces = { open = "neovide" } })
  eq("open: and an unknown mode is rejected at setup, not at <CR>", bad, false)

  vim.api.nvim_del_autocmd(au)
  config.setup {}
  go_home()
  vim.fn.delete(dir, "rf")
end

return {
  { "strategy", test_strategy },
  { "manifest", test_manifest },
  { "workspace open", test_workspace_open },
}
