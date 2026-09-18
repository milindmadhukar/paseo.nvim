--- The test suite. Run it with `tests/run.sh`.
---
--- No plenary, no busted: the interesting assertions are all about what real
--- git and real gitsigns do, so the suite needs a real Neovim and real
--- repositories far more than it needs a framework.
---
--- Every case here corresponds to something that was actually wrong at some
--- point, not to a line of code that wanted covering.

local root = assert(vim.env.PASEO_FIXTURES, "PASEO_FIXTURES is not set")

local M = {}
local results = { passed = 0, failed = 0, lines = {} }

---@param name string
---@param ok boolean
---@param detail? string
local function record(name, ok, detail)
  if ok then
    results.passed = results.passed + 1
    results.lines[#results.lines + 1] = ("  ok    %s"):format(name)
  else
    results.failed = results.failed + 1
    results.lines[#results.lines + 1] = ("  FAIL  %s%s"):format(
      name,
      detail and ("\n          " .. detail) or ""
    )
  end
end

local function eq(name, got, want)
  local same = vim.deep_equal(got, want)
  record(
    name,
    same,
    not same and ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)) or nil
  )
end

local function truthy(name, value, detail)
  record(name, value and true or false, detail)
end

---@param dir string
---@param fn fun()
local function in_dir(dir, fn)
  local prev = vim.uv.cwd()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  require("paseo.repos").invalidate()
  local ok, err = pcall(fn)
  vim.cmd.cd(vim.fn.fnameescape(prev))
  require("paseo.repos").invalidate()
  if not ok then
    error(err, 0)
  end
end

---Reset a fixture repo's index so staging tests start clean.
local function reset_index(worktree)
  vim.system({ "git", "-C", worktree, "reset", "-q", "HEAD", "--", "." }):wait()
end

---@param hunks paseo.Hunk[]
---@param path string
---@return paseo.Hunk[]
local function for_path(hunks, path)
  return vim.tbl_filter(function(h)
    return h.path == path
  end, hunks)
end

-- ---------------------------------------------------------------- repos.list

local function test_repos()
  local repos = require "paseo.repos"

  in_dir(root .. "/solo", function()
    local list = repos.list()
    eq("repos: plain repo yields exactly one", #list, 1)
    eq("repos: named after the repo", list[1] and list[1].name, "solo")
  end)

  in_dir(root .. "/multi/.workspaces/otp", function()
    local names = vim.tbl_map(function(r)
      return r.name
    end, repos.list())
    eq("repos: multi-repo workspace yields every member, sorted", names, { "clm", "clm_api" })
  end)

  in_dir(root .. "/multi/.workspaces/otp/Docs", function()
    local names = vim.tbl_map(function(r)
      return r.name
    end, repos.list())
    eq("repos: found from a non-repo sibling inside the workspace", names, { "clm", "clm_api" })
  end)

  in_dir(root .. "/solo/.workspaces/inner", function()
    local list = repos.list()
    eq("repos: single-repo workspace yields one", #list, 1)
    -- The regression: a linked worktree's basename is the WORKSPACE name, so
    -- naming by basename reported this as "inner" rather than "solo".
    eq(
      "repos: named from the common dir, not the worktree basename",
      list[1] and list[1].name,
      "solo"
    )
    truthy(
      "repos: gitdir is the per-worktree dir, not the common dir",
      list[1] and list[1].gitdir:find("worktrees/inner", 1, true) ~= nil,
      list[1] and list[1].gitdir
    )
  end)

  in_dir(root .. "/plain", function()
    eq("repos: outside any repo yields an empty list, not nil", repos.list(), {})
  end)
end

-- --------------------------------------------------------------- git.status

local function test_status()
  local git, repos = require "paseo.git", require "paseo.repos"

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    local changes = git.status(repo)
    local by_path = {}
    for _, c in ipairs(changes) do
      by_path[c.path] = c
    end

    -- The rename is the parsing trap: its record is followed by a SECOND
    -- NUL-terminated field. Split naively and every entry after it shifts.
    truthy("status: rename is parsed", by_path["new-name.txt"] ~= nil)
    eq(
      "status: rename carries its source",
      by_path["new-name.txt"] and by_path["new-name.txt"].orig_path,
      "old-name.txt"
    )
    -- The proof the stream did not desync: entries after the rename survive.
    truthy("status: entries after the rename survive", by_path["untracked.txt"] ~= nil)
    truthy(
      "status: untracked is flagged",
      by_path["untracked.txt"] and by_path["untracked.txt"].untracked
    )
    truthy("status: path with a space", by_path["dir with space/odd name.txt"] ~= nil)
    truthy("status: non-ASCII path arrives unquoted", by_path["ünïcode ✓.txt"] ~= nil)
    truthy("status: deleted file is listed", by_path["deleted-file.txt"] ~= nil)
    truthy(
      "status: .workspaces is excluded, so a worktree does not pollute the list",
      by_path[".workspaces/"] == nil
    )
  end)
end

-- ---------------------------------------------------------------- git.hunks

local function test_hunks()
  local git, repos = require "paseo.git", require "paseo.repos"

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    local hunks = git.hunks(repo, git.status(repo))

    local bof = for_path(hunks, "bof.txt")[1]
    eq("hunks: beginning-of-file delete is kind=delete", bof and bof.kind, "delete")
    -- `@@ -1 +0,0 @@` gives c = 0, which is not a valid quickfix line.
    eq("hunks: BOF delete clamps lnum to 1", bof and bof.lnum, 1)

    local eof = for_path(hunks, "eof.txt")[1]
    eq("hunks: end-of-file delete is kind=delete", eof and eof.kind, "delete")
    eq("hunks: EOF delete lands on the last remaining line", eof and eof.lnum, 1)

    local whole = for_path(hunks, "deleted-file.txt")[1]
    truthy("hunks: whole-file deletion is flagged", whole and whole.file_deleted)

    local untracked = for_path(hunks, "untracked.txt")[1]
    eq("hunks: untracked file is one synthetic entry", untracked and untracked.kind, "new")

    -- A pure rename has no content change, so rename detection must pair the
    -- two sides. Without the source in the pathspec it reports as a whole-file
    -- add instead.
    eq("hunks: a pure rename produces no hunks", #for_path(hunks, "new-name.txt"), 0)

    local many = for_path(hunks, "many-hunks.txt")
    eq("hunks: multi-hunk file splits into three", #many, 3)
    local kinds = vim.tbl_map(function(h)
      return h.kind
    end, many)
    eq("hunks: kinds are classified", kinds, { "change", "delete", "add" })
    -- The omitted-count trap: `@@ -2 +2 @@` means -2,1 +2,1. Read the missing
    -- count as 0 and this single-line change becomes a phantom deletion.
    eq("hunks: a single-line change is not read as a deletion", many[1] and many[1].added, 1)

    truthy("hunks: each carries its patch text", many[1] and #many[1].lines > 1)
  end)
end

-- ---------------------------------------------------------------- git.stage

local function test_stage()
  local git, repos = require "paseo.git", require "paseo.repos"

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    reset_index(repo.worktree)

    -- Partial staging: one hunk of three, the others untouched. This is the
    -- assertion that `--unidiff-zero` placement is right.
    local many = for_path(git.hunks(repo, git.status(repo)), "many-hunks.txt")
    local target
    for _, h in ipairs(many) do
      if h.kind == "delete" then
        target = h
      end
    end

    local err
    git.stage(target, function(e)
      err = e or false
    end)
    vim.wait(3000, function()
      return err ~= nil
    end)
    eq("stage: the delete hunk applies", err, false)

    local staged =
      vim.system({ "git", "-C", repo.worktree, "diff", "--cached" }, { text = true }):wait().stdout
    truthy("stage: the deletion is in the index", staged:find("-10", 1, true) ~= nil)
    truthy(
      "stage: the OTHER hunks are not",
      staged:find "TWO%-CHANGED" == nil and staged:find "APPENDED" == nil
    )

    local unstaged =
      vim.system({ "git", "-C", repo.worktree, "diff" }, { text = true }):wait().stdout
    truthy(
      "stage: the other two hunks remain unstaged",
      unstaged:find("TWO-CHANGED", 1, true) ~= nil
    )
  end)

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    reset_index(repo.worktree)

    -- Every hunk, including the two gitsigns structurally cannot do.
    local hunks = git.hunks(repo, git.status(repo))
    local remaining = #hunks
    for _, hunk in ipairs(hunks) do
      git.stage(hunk, function()
        remaining = remaining - 1
      end)
    end
    vim.wait(8000, function()
      return remaining == 0
    end)

    local left = vim
      .system({ "git", "-C", repo.worktree, "diff", "--name-only" }, { text = true })
      :wait().stdout
    eq("stage: staging every hunk leaves nothing unstaged", vim.trim(left), "")

    local cached = vim
      .system({ "git", "-C", repo.worktree, "diff", "--cached", "--name-only" }, { text = true })
      :wait().stdout
    truthy(
      "stage: the whole-file deletion reached the index (gitsigns cannot do this)",
      cached:find("deleted-file.txt", 1, true) ~= nil
    )
    truthy(
      "stage: the untracked file reached the index",
      cached:find("untracked.txt", 1, true) ~= nil
    )
    reset_index(repo.worktree)
  end)
end

-- --------------------------------------------------------------------- qf

local function test_qf()
  in_dir(root .. "/multi/.workspaces/otp", function()
    local qf = require "paseo.qf"
    local n = qf.all { open = false }
    truthy("qf: spans both repos of the workspace", n >= 3, "entries: " .. n)

    vim.cmd "copen"
    local buf = vim.fn.getqflist({ qfbufnr = 1 }).qfbufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    truthy(
      "qf: renders a repo column when there is more than one repo",
      (lines[1] or ""):find "^clm" ~= nil,
      lines[1]
    )
    truthy(
      "qf: renders path:lnum and counts",
      (lines[1] or ""):find "f%.txt:%d+%s+[+]%d+ %-%d+" ~= nil,
      lines[1]
    )
    vim.cmd "cclose"

    local items = vim.fn.getqflist()
    truthy(
      "qf: filenames are absolute, so entries from two worktrees both open",
      vim.api.nvim_buf_get_name(items[1].bufnr):sub(1, 1) == "/"
    )
    truthy("qf: the hunk behind an entry is retrievable", qf.hunk(1) ~= nil)
  end)

  in_dir(root .. "/solo", function()
    local qf = require "paseo.qf"
    qf.all { open = false }
    vim.cmd "copen"
    local buf = vim.fn.getqflist({ qfbufnr = 1 }).qfbufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    truthy("qf: no repo column for a single repo", (lines[1] or ""):find "^solo" == nil, lines[1])
    vim.cmd "cclose"
  end)
end

-- ----------------------------------------------------------------- review

local function test_review()
  in_dir(root .. "/multi/.workspaces/otp", function()
    local before = #vim.api.nvim_list_tabpages()
    local opened
    require("paseo.review").open({}, function(n)
      opened = n
    end)
    vim.wait(20000, function()
      return opened ~= nil
    end)

    eq("review: one panel per member repo", opened, 2)
    -- The bug this guards: the panels were launched in a loop, and because
    -- gitsigns resolves its repo from getcwd() INSIDE its async body, both
    -- raced on the last tab's cwd and neither opened.
    eq(
      "review: one tab per panel, staging tabs discarded",
      #vim.api.nvim_list_tabpages(),
      before + 2
    )

    local gitdirs = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        local member = name:match "gitsigns%-diff://.*/worktrees/([^/]+)"
        if member then
          gitdirs[#gitdirs + 1] = member
        end
      end
    end
    table.sort(gitdirs)
    eq("review: each panel is pinned to its own worktree gitdir", gitdirs, { "clm", "clm_api" })

    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd.tabclose()
    end
  end)
end

-- ---------------------------------------------------------------- daemon

local function test_daemon()
  local daemon = require "paseo.daemon"
  local config = require "paseo.config"

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")

  -- Closed, not just written: an unclosed handle leaves the JSON in Lua's
  -- buffer, the reader sees an empty file, and the test passes or fails for
  -- reasons that have nothing to do with the code.
  local function write_config(listen)
    local fd = assert(io.open(tmp .. "/config.json", "w"))
    fd:write(vim.json.encode { daemon = { listen = listen } })
    fd:close()
  end

  write_config "127.0.0.1:7777"
  config.setup { paseo = { home = tmp } }
  local sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  truthy("daemon: reads daemon.listen from config.json", vim.tbl_contains(sources, "daemon.listen"))
  local listened = daemon.candidates()[1]
  eq("daemon: uses the port config.json names, not 6767", listened and listened.port, 7777)
  eq("daemon: the default is always a fallback", sources[#sources], "default")

  write_config "unix:/run/paseo.sock"
  config.setup { paseo = { home = tmp } }
  sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  truthy(
    "daemon: a unix-socket listen is skipped, not turned into a bad URL",
    not vim.tbl_contains(sources, "daemon.listen")
  )

  config.setup { paseo = { url = "ws://127.0.0.1:1234/ws" } }
  local first = daemon.candidates()[1]
  eq("daemon: an explicit url wins outright", first and first.source, "config")

  config.setup {}
end

-- ---------------------------------------------------------------- bridge

local function test_bridge()
  local bridge = require "paseo.bridge"

  -- The regression: this resolved through the runtimepath, and lazy.nvim
  -- resolves Lua modules through its own loader -- so `require` worked while
  -- the plugin directory was not yet on `rtp`, and the sidecar "could not
  -- start" on a plugin that was installed and working.
  local found = vim.api.nvim_get_runtime_file("bin/paseo-bridge.ts", false)[1]
  truthy(
    "bridge: the sidecar script is on disk",
    found ~= nil or vim.uv.fs_stat(vim.fn.getcwd() .. "/bin/paseo-bridge.ts") ~= nil
  )
  truthy("bridge: not running before it is started", not bridge.running())

  -- The regression: `id` is the request-correlation field and bridge.request
  -- sets it LAST, so anything in args called `id` is silently replaced by the
  -- request number. An agent passed that way reached the daemon as "4" and was
  -- rejected as an ambiguous prefix across three agents.
  local sidecar = io.open(vim.fn.getcwd() .. "/bin/paseo-bridge.ts", "r")
  if sidecar then
    local source = sidecar:read "*a"
    sidecar:close()
    truthy(
      "bridge: no op takes its agent under the reserved key `id`",
      source:find 'need%(req%.id, "id"%)' == nil
    )
  end

  local explain = io.open(vim.fn.getcwd() .. "/lua/paseo/explain.lua", "r")
  if explain then
    local source = explain:read "*a"
    explain:close()
    truthy("bridge: explain sends `agentId`", source:find("agentId = agent_id", 1, true) ~= nil)
  end
end

-- ------------------------------------------------------------- registry

local function test_registry()
  local reg = require "paseo.registry"

  -- An absent registry is not an error: it means `ws` has never run, which is
  -- the normal state for anyone using only the review half of this plugin.
  local saved = vim.env.XDG_STATE_HOME
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  reg.invalidate()
  eq("registry: an absent file yields an empty list, not nil", reg.list(), {})

  local dir = vim.fs.joinpath(vim.env.XDG_STATE_HOME, "ws")
  vim.fn.mkdir(dir, "p")
  local fd = assert(io.open(vim.fs.joinpath(dir, "registry.json"), "w"))
  fd:write(vim.json.encode {
    version = 1,
    workspaces = {
      {
        name = "otp",
        project = "/tmp/proj",
        root = "/tmp/proj/.workspaces/otp",
        branch = "ws/otp",
        repos = {
          { name = "clm", path = "/tmp/proj/.workspaces/otp/clm", state = "active" },
          { name = "hipa", origin = "/tmp/proj/hipa", state = "declared" },
        },
      },
    },
  })
  fd:close()

  reg.invalidate()
  local list = reg.list()
  eq("registry: reads the file", #list, 1)
  -- A declared member has no worktree yet; it must not be offered as one.
  eq("registry: active() skips declared members", #reg.active(list[1]), 1)
  eq(
    "registry: containing() finds a workspace from inside it",
    (reg.containing "/tmp/proj/.workspaces/otp/clm/app.py" or {}).name,
    "otp"
  )
  eq("registry: containing() returns nil outside one", reg.containing "/tmp/elsewhere", nil)

  vim.env.XDG_STATE_HOME = saved
  reg.invalidate()
end

function M.run()
  local suites = {
    { "repos", test_repos },
    { "git.status", test_status },
    { "git.hunks", test_hunks },
    { "git.stage", test_stage },
    { "qf", test_qf },
    { "review", test_review },
    { "daemon", test_daemon },
    { "bridge", test_bridge },
    { "registry", test_registry },
  }

  for _, suite in ipairs(suites) do
    results.lines[#results.lines + 1] = suite[1]
    local ok, err = xpcall(suite[2], debug.traceback)
    if not ok then
      results.failed = results.failed + 1
      results.lines[#results.lines + 1] = ("  FAIL  %s threw\n          %s"):format(suite[1], err)
    end
  end

  local summary = ("\n%d passed, %d failed"):format(results.passed, results.failed)
  io.stdout:write(table.concat(results.lines, "\n") .. summary .. "\n")
  return results.failed
end

return M
