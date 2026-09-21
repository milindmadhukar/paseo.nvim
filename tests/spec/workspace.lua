--- Workspaces: the model.
---
--- What a workspace is made of, and what `:Paseo ws init` writes down.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local in_dir = t.in_dir

local function test_workspace()
  local workspace = require "paseo.workspace"
  local manifest = workspace.manifest

  -- The TOML subset, including the shapes init emits.
  local parsed = manifest.parse [[
shared = ["Docs"]
[repos.clm_api]
base = "dev"
copy = [".env", ".env.prod"]
submodules = true
[repos.hipa-v2]
base = "dev"
default = false
]]
  eq("manifest: parses repos", manifest.names(parsed), { "clm_api", "hipa-v2" })
  eq("manifest: parses arrays", parsed.repos.clm_api.copy, { ".env", ".env.prod" })
  eq("manifest: parses bools", parsed.repos.clm_api.submodules, true)
  -- Absent means included; only an explicit false opts out.
  eq("manifest: default set excludes `default = false`", manifest.select(parsed), { "clm_api" })
  eq(
    "manifest: --with opts one back in",
    manifest.select(parsed, nil, { "hipa-v2" }),
    { "clm_api", "hipa-v2" }
  )
  eq(
    "manifest: --repos wins over --with",
    manifest.select(parsed, { "clm_api" }, { "hipa-v2" }),
    { "clm_api" }
  )
  truthy(
    "manifest: an unknown repo is an error",
    select(2, manifest.select(parsed, { "nope" })) ~= nil
  )
  eq("manifest: render round-trips", manifest.parse(manifest.render(parsed, {})), parsed)

  -- Assembly, against the multi-repo fixture.
  local project = root .. "/multi"
  local m, notes = workspace.discover(project)
  truthy(
    "workspace: discovers the members",
    m and #manifest.names(m) == 2,
    m and vim.inspect(manifest.names(m))
  )
  truthy("workspace: Docs is shared", m and vim.tbl_contains(m.shared, "Docs"))
  -- `Docs` is a plain directory; `.workspaces` holds the worktrees and must
  -- never be offered as a shared sibling.
  truthy(
    "workspace: .workspaces is not shared",
    m and not vim.tbl_contains(m.shared, ".workspaces")
  )

  -- The fixture's node_modules is too small to be classified heavy, so declare
  -- the link explicitly -- link handling is what is under test.
  for _, name in ipairs(manifest.names(m)) do
    m.repos[name].link = { "node_modules" }
    m.repos[name].copy = { ".env" }
  end
  for _, name in ipairs(manifest.names(m)) do
    local fd = io.open(vim.fs.joinpath(project, name, ".env"), "w")
    if fd then
      fd:write "PORT=3000\n"
      fd:close()
    end
    vim.fn.mkdir(vim.fs.joinpath(project, name, "node_modules"), "p")
  end

  -- The fixture already holds an `otp` workspace, so worktree counts are
  -- compared BEFORE and AFTER rather than against an assumed 1.
  local function worktrees(name)
    local out = vim
      .system({ "git", "-C", vim.fs.joinpath(project, name), "worktree", "list" }, { text = true })
      :wait()
    return #vim.split(vim.trim(out.stdout or ""), "\n")
  end
  local before = { clm = worktrees "clm", clm_api = worktrees "clm_api" }

  local ws, err = workspace.create(m, { name = "spec", root = project })
  truthy("workspace: create succeeds", ws ~= nil, err)
  if not ws then
    return
  end

  for _, name in ipairs { "clm", "clm_api" } do
    local dir = vim.fs.joinpath(ws.root, name)
    local env = vim.uv.fs_lstat(vim.fs.joinpath(dir, ".env"))
    eq("workspace: " .. name .. "/.env is a copy, not a link", env and env.type, "file")
    local link = vim.uv.fs_lstat(vim.fs.joinpath(dir, "node_modules"))
    eq("workspace: " .. name .. "/node_modules is a link", link and link.type, "link")
  end

  local docs = vim.uv.fs_lstat(vim.fs.joinpath(ws.root, "Docs"))
  eq("workspace: Docs is symlinked into the workspace root", docs and docs.type, "link")

  -- A repo that ignores `node_modules/` does NOT ignore a SYMLINK of that name,
  -- so without the exclude block every linked dir shows as untracked forever --
  -- and removal then refuses over files we created ourselves.
  for _, name in ipairs { "clm", "clm_api" } do
    local dirty = vim
      .system({ "git", "-C", vim.fs.joinpath(ws.root, name), "status", "--porcelain" }, { text = true })
      :wait()
    eq("workspace: " .. name .. " worktree is clean", vim.trim(dirty.stdout or ""), "")
  end

  -- The primary checkouts are untouched: the whole point of isolation.
  for _, name in ipairs { "clm", "clm_api" } do
    local branch = vim
      .system({ "git", "-C", vim.fs.joinpath(project, name), "branch", "--show-current" }, { text = true })
      :wait()
    eq(
      "workspace: primary " .. name .. " is still on its own branch",
      vim.trim(branch.stdout or ""),
      "main"
    )
  end

  -- An untouched workspace removes cleanly. The regression: `HEAD --not
  -- --remotes` in a repo with NO remote lists the entire history, so every
  -- workspace in such a repo was unremovable.
  eq("workspace: nothing unsaved in a fresh workspace", workspace.unsaved(ws), {})
  local removed, rm_err = workspace.remove(ws)
  truthy("workspace: remove succeeds", removed, rm_err)

  for _, name in ipairs { "clm", "clm_api" } do
    -- `git worktree remove`, never rm -rf: deleting the directory is how stale
    -- .git/worktrees entries get left behind, and they only surface later as
    -- unrelated-looking failures. Compared against the count from BEFORE
    -- create: the fixture already holds a workspace of its own.
    eq(
      "workspace: " .. name .. " is back to its pre-create worktree count",
      worktrees(name),
      before[name]
    )

    -- And the branch with it. `git worktree remove` leaves it standing, so a
    -- project collected one dead `ws/<name>` per member per workspace anyone
    -- ever made -- kora still had a full set three days after the workspace
    -- that made them was gone.
    local left = vim
      .system(
        { "git", "-C", vim.fs.joinpath(project, name), "branch", "--list", "ws/spec" },
        { text = true }
      )
      :wait()
    eq(
      "workspace: and " .. name .. " has no ws/spec branch left behind",
      vim.trim(left.stdout or ""),
      ""
    )
  end

  -- And it refuses when there IS work.
  local ws2 = workspace.create(m, { name = "spec2", root = project })
  if ws2 then
    local dir = vim.fs.joinpath(ws2.root, "clm")
    local fd = assert(io.open(vim.fs.joinpath(dir, "f.txt"), "w"))
    fd:write "real work\n"
    fd:close()
    vim.system({ "git", "-C", dir, "add", "f.txt" }, { text = true }):wait()
    vim
      .system({ "git", "-C", dir, "-c", "commit.gpgsign=false", "commit", "-qm", "work" }, { text = true })
      :wait()

    local blockers = workspace.unsaved(ws2)
    truthy("workspace: an unpushed commit blocks removal", #blockers > 0, vim.inspect(blockers))
    truthy("workspace: and says why", (blockers[1] or ""):find "unpushed" ~= nil, blockers[1])

    -- A repository holding a DIRECTORY named after its base branch. kora-backend
    -- is one: `main/` sits next to `main`, git calls `HEAD --not --remotes main`
    -- ambiguous and fails, `git()` returns nil, and a nil answer to "is there
    -- unpushed work?" read as NO -- so the one repo where the check could not
    -- run was the one where removal went ahead and took the commits with it.
    vim.fn.mkdir(vim.fs.joinpath(dir, "main"), "p")
    local collide = assert(io.open(vim.fs.joinpath(dir, "main", "x.txt"), "w"))
    collide:write "x\n"
    collide:close()
    vim.system({ "git", "-C", dir, "add", "-A" }, { text = true }):wait()
    vim
      .system(
        { "git", "-C", dir, "-c", "commit.gpgsign=false", "commit", "-qm", "path named main" },
        { text = true }
      )
      :wait()
    local ambiguous = workspace.unsaved(ws2)
    truthy(
      "workspace: a base branch that is also a path still blocks removal",
      #ambiguous > 0 and (ambiguous[#ambiguous]):find "unpushed" ~= nil,
      vim.inspect(ambiguous)
    )

    truthy("workspace: force removes anyway", workspace.remove(ws2, { force = true }))
  end
end

local function test_ws_init()
  -- `raw`, because plain `ws init` now opens the configuration dialog. The
  -- buffer is the escape hatch behind it, and it is the half that carries the
  -- regression: `:Paseo ws init` named the buffer <root>/.ws/workspace.toml
  -- without creating .ws/, so `:w` failed with E212 "Can't open file for
  -- writing: no such file or directory" -- which reads like a permissions
  -- problem rather than a missing parent directory.
  local project = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(project, "repo"), "p")
  local repo = vim.fs.joinpath(project, "repo")
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

  in_dir(project, function()
    vim.cmd "Paseo ws init raw"
    vim.wait(2000, function()
      return vim.api.nvim_buf_get_name(0):find "workspace%.toml" ~= nil
    end, 50)

    local named = vim.api.nvim_buf_get_name(0)
    truthy(
      "ws init raw: the buffer is named after the manifest",
      named:find "%.ws/workspace%.toml" ~= nil,
      named
    )
    truthy(
      "ws init raw: .ws/ exists BEFORE you write",
      vim.uv.fs_stat(vim.fs.dirname(named)) ~= nil
    )

    local ok = pcall(vim.cmd, "silent write")
    truthy("ws init raw: :w succeeds", ok)
    truthy("ws init raw: the manifest is on disk", vim.uv.fs_stat(named) ~= nil)

    -- A second init must reuse the buffer already sitting on that path rather
    -- than failing on a duplicate name.
    truthy("ws init raw: running it twice does not error", pcall(vim.cmd, "Paseo ws init raw"))

    local loaded = require("paseo.workspace.manifest").load(project)
    truthy("ws init raw: what it wrote parses back", loaded ~= nil and loaded.repos.repo ~= nil)
    vim.cmd "silent tabonly"
  end)

  -- The manifest buffer outlives the suite otherwise, and the next time
  -- anything checks timestamps Neovim reports `E211: File ... no longer
  -- available` for a fixture we deleted on purpose.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):find(project, 1, true) == 1 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(project, "rf")
end

--- Which project a workspace is nested under, in the editor's view of it.
---
--- The daemon cannot get this right and it is not its fault. A `ws` workspace
--- at `<project>/.workspaces/<name>` is a plain directory holding several
--- worktrees -- it has to be, because a git worktree is per repo -- so asking
--- the daemon to open it registers that directory as its own TOP-LEVEL project
--- named after the workspace. `~/Code/openfin/.workspaces/billing` came back as
--- a project called `billing`, drawn as a sibling of `openfin` rather than as
--- something inside it, which is exactly how the sidebar rendered it.
local function test_workspace_group()
  local workspaces = require "paseo.workspaces"

  eq(
    "ws group: a .workspaces child is grouped under its project",
    workspaces.group { directory = "/home/x/Code/openfin/.workspaces/billing" },
    "openfin"
  )
  eq(
    "ws group: however deep the path goes",
    workspaces.group { directory = "/home/x/Code/grasslabs/kora/.workspaces/nvim-e2e" },
    "kora"
  )
  eq(
    "ws group: an ordinary checkout keeps the daemon's project",
    workspaces.group { directory = "/home/x/Code/paseo.nvim", project = "paseo.nvim" },
    "paseo.nvim"
  )
  eq(
    "ws group: and a worktree under one does too",
    workspaces.group {
      directory = "/home/x/.paseo/worktrees/abc/ui-fixes",
      project = "paseo.nvim",
    },
    "paseo.nvim"
  )
  -- Nothing to go on is an empty string, never nil: it is a sort key and a
  -- table index in the panel.
  eq("ws group: nothing known is empty, not nil", workspaces.group {}, "")

  -- The directory name is configurable, and the shape test has to follow it.
  require("paseo.config").setup { workspaces = { dir = ".units" } }
  eq(
    "ws group: the marker directory follows the config",
    workspaces.group { directory = "/home/x/Code/openfin/.units/billing" },
    "openfin"
  )
  eq(
    "ws group: and `.workspaces` stops being one",
    workspaces.group { directory = "/home/x/Code/openfin/.workspaces/billing", project = "billing" },
    "billing"
  )
  require("paseo.config").setup {}
end

return {
  { "workspace", test_workspace },
  { "workspace group", test_workspace_group },
  { "ws init", test_ws_init },
}
