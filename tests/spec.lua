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
local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

---Scan every owned TypeScript file, including new modules. A negative check
---against only the executable entry point becomes vacuous after a refactor.
local function sidecar_source()
  local parts = {}
  local function scan(dir)
    for name, kind in vim.fs.dir(dir) do
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" and name ~= "node_modules" then
        scan(path)
      elseif kind == "file" and name:match "%.ts$" then
        local fd = assert(io.open(path, "r"))
        parts[#parts + 1] = fd:read "*a"
        fd:close()
      end
    end
  end
  scan(vim.fs.joinpath(repo_root, "sidecar"))
  return table.concat(parts, "\n")
end

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
  -- NOT "the default is always last": it is only there when nothing else
  -- named a port. Asserting otherwise was asserting the bug.
  eq("daemon: a named port is the last word", sources[#sources], "daemon.listen")

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

  -- The hardcoded default is a LAST RESORT. Falling through to 6767 when the
  -- daemon's own config named a different port meant silently connecting to a
  -- DIFFERENT daemon -- and it made autostart unreachable, because there was
  -- always something answering.
  write_config "127.0.0.1:6799"
  config.setup { paseo = { home = tmp } }
  local sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  truthy(
    "daemon: a configured port suppresses the 6767 fallback",
    not vim.tbl_contains(sources, "default"),
    vim.inspect(sources)
  )

  -- ...but with no config.json at all, the default is the only thing there is.
  os.remove(tmp .. "/config.json")
  config.setup { paseo = { home = tmp } }
  sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  eq("daemon: with no config.json the default is used", sources, { "default" })

  -- `paseo` must be resolved, not trusted: the desktop binary opens a window.
  local cli = daemon.cli()
  if cli then
    truthy(
      "daemon: cli() only accepts the headless wrapper",
      vim.fn.resolve(cli):match "resources/bin/paseo$" ~= nil,
      vim.fn.resolve(cli)
    )
  end

  config.setup {}
end

-- ---------------------------------------------------------------- bridge

local function test_bridge()
  local bridge = require "paseo.bridge"

  -- The regression: this resolved through the runtimepath, and lazy.nvim
  -- resolves Lua modules through its own loader -- so `require` worked while
  -- the plugin directory was not yet on `rtp`, and the sidecar "could not
  -- start" on a plugin that was installed and working.
  local found = vim.api.nvim_get_runtime_file("sidecar/paseo-bridge.ts", false)[1]
  truthy(
    "bridge: the sidecar script is on disk",
    found ~= nil or vim.uv.fs_stat(vim.fn.getcwd() .. "/sidecar/paseo-bridge.ts") ~= nil
  )
  truthy("bridge: not running before it is started", not bridge.running())

  -- Every module has to at least load: a syntax error in one of these only
  -- shows up when you press the key, which is the worst time to find it.
  for _, name in ipairs {
    "paseo.ui.chat",
    "paseo.ui.session",
    "paseo.workspaces",
    "paseo.pickers.sessions",
    "paseo.pickers.workspaces",
  } do
    truthy("bridge: " .. name .. " loads", (pcall(require, name)))
  end

  -- The regression: `id` is the request-correlation field and bridge.request
  -- sets it LAST, so anything in args called `id` is silently replaced by the
  -- request number. An agent passed that way reached the daemon as "4" and was
  -- rejected as an ambiguous prefix across three agents.
  local source = sidecar_source()
  if source ~= "" then
    truthy(
      "bridge: no op takes its agent under the reserved key `id`",
      source:find 'need%(req%.id, "id"%)' == nil
    )

    -- The regression: `agent.ensure` created agents with a bare `cwd`, so the
    -- daemon provisioned a workspace for the directory it was handed. Inside a
    -- Paseo-cut WORKTREE -- itself a git repository -- that meant a second
    -- PROJECT named after the worktree directory, holding a duplicate
    -- workspace over the same files. Opening a chat in a workspace this plugin
    -- had just made was enough, and the app showed the work twice.
    --
    -- Agents go through a workspace handle. Both of them, forever.
    truthy(
      "bridge: no agent is created off the bare api, only through a workspace",
      source:find("api.agents.create", 1, true) == nil
    )
    truthy(
      "bridge: and the owning workspace is looked up before one is opened",
      source:find("function workspaceFor", 1, true) ~= nil
    )

    -- THE REGRESSION THAT COST SIXTEEN CORES. When Neovim died the sidecar's
    -- stdout became a pipe with no reader, every write failed with EPIPE, and
    -- the uncaughtException handler reported that by writing to stdout -- so
    -- the handler for the failure was the cause of the next one. 202 million
    -- write(2) calls that moved 1153 bytes between them, at 90% of a core,
    -- for as long as the machine was up.
    --
    -- Both halves are load-bearing and neither is obviously necessary on its
    -- own, which is why they are asserted rather than trusted: a guarded write
    -- that still reports failures by writing is the same bug.
    truthy("bridge: the write path gives up once the pipe is broken", source:find("if (broken) return", 1, true) ~= nil)
    truthy(
      "bridge: and the error handler does not write into a broken pipe",
      source:find("if (broken || bailing) return", 1, true) ~= nil
    )
    -- On bun -- which is the runtime `runtime()` picks -- the watchdog is the
    -- ONLY thing that exits: bun delivers stdin EOF before the stdout error,
    -- so the write that would trip the broken flag never happens. Deleting
    -- this because node exits without it regresses every bun user to a
    -- permanently hung orphan.
    truthy("bridge: and shutdown has a deadline", source:find("setTimeout(() => process.exit(code)", 1, true) ~= nil)
  end

  -- The same regression, executed rather than read: orphan.sh severs the read
  -- ends of a live sidecar and gives it five seconds to notice. Against the
  -- code that shipped this fails, having burnt a full core-second per second.
  local orphan = vim.fs.joinpath(vim.fn.getcwd(), "tests", "orphan.sh")
  if vim.uv.fs_stat(orphan) and vim.fn.executable "node" == 1 then
    local run = vim.system({ orphan }, { text = true }):wait(90000)
    truthy(
      "bridge: the sidecar dies when its stdout does",
      run.code == 0,
      (run.stdout or "") .. (run.stderr or "")
    )
  end

  -- VimLeavePre does not come back, so a teardown that waits for a round trip
  -- is a teardown that never happens -- which is how the orphans were made.
  -- Closing stdin is the part that has to be unconditional.
  local lua_bridge = io.open(vim.fn.getcwd() .. "/lua/paseo/bridge.lua", "r")
  if lua_bridge then
    local source = lua_bridge:read "*a"
    lua_bridge:close()
    truthy("bridge: stop() closes stdin whatever the sidecar says", source:find("handle:write(nil)", 1, true) ~= nil)
    truthy("bridge: stop() does not wait for a reply to kill", source:find("handle:kill(15)", 1, true) ~= nil)
    -- Two ensure() calls during an autostart used to spawn two sidecars and
    -- orphan the first.
    truthy("bridge: a boot in flight is not started twice", source:find("if state.starting then", 1, true) ~= nil)
  end

  -- The sending code moved from explain.lua into the chat window when the
  -- chat became the primary surface; the rule did not move with it by itself.
  local chat = io.open(vim.fn.getcwd() .. "/lua/paseo/ui/chat.lua", "r")
  if chat then
    local source = chat:read "*a"
    chat:close()
    truthy(
      "bridge: the chat sends `agentId`, not `id`",
      source:find("agentId = chat.agent_id", 1, true) ~= nil
    )
  end
end

-- ---------------------------------------------------------------- image

local function test_image()
  local image = require "paseo.image"

  -- Binary, with the NUL bytes and the 0x0a that make readfile() the wrong
  -- tool: a PNG signature is exactly that shape.
  local bytes = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0"
  local path = vim.fn.tempname() .. ".png"
  local fd = assert(io.open(path, "wb"))
  fd:write(bytes)
  fd:close()

  local png, err = image.from_file(path)
  eq("image: a .png is read as image/png", png and png.mime, "image/png")
  eq("image: no error with it", err, nil)
  -- The regression this guards: reading through readfile() split the file on
  -- newlines and dropped the NULs, so the bytes that arrived were not the
  -- bytes on disk -- and a provider rejected the result as a corrupt image.
  eq("image: the bytes survive the round trip", png and vim.base64.decode(png.data), bytes)
  eq("image: and the size is the size before encoding", png and png.bytes, #bytes)

  local text = vim.fn.tempname() .. ".txt"
  local handle = assert(io.open(text, "w"))
  handle:write "not a picture"
  handle:close()
  local none, why = image.from_file(text)
  truthy("image: a .txt is refused", none == nil and why ~= nil)

  local absent, missing = image.from_file(vim.fn.tempname() .. ".png")
  truthy("image: a file that is not there is refused", absent == nil and missing ~= nil)

  -- Refused HERE rather than after a round trip to the daemon: no provider
  -- takes a 40 MB screenshot, and base64 makes it a third larger again.
  local limit = image.max_bytes
  image.max_bytes = 4
  local big, too_big = image.from_file(path)
  image.max_bytes = limit
  truthy("image: an oversized file is refused before sending", big == nil and too_big ~= nil)

  local names = {}
  for _, reader in ipairs(image.readers()) do
    names[#names + 1] = reader.name
  end
  eq("image: the clipboard readers are reported for checkhealth", names, {
    "wl-paste",
    "xclip",
    "pngpaste",
  })

  -- Placeholders are TEXT in the prompt; the bytes are a field of the request.
  -- Inlining base64 into the prompt is the obvious wrong turn here -- it works
  -- once, against one provider, and reads as a wall of noise on the timeline.
  local chat = io.open(vim.fn.getcwd() .. "/lua/paseo/ui/chat.lua", "r")
  if chat then
    local source = chat:read "*a"
    chat:close()
    truthy(
      "image: the chat sends images beside the prompt, not inside it",
      source:find("images = #images > 0 and images or nil", 1, true) ~= nil
    )
  end

  vim.fn.delete(path)
  vim.fn.delete(text)
end

-- ------------------------------------------------------------------ ref

local function test_ref()
  local ref = require "paseo.ref"

  -- A file with no repository at all. This was impossible: build() required
  -- repos.resolve() to succeed, so "ask about this file" silently did nothing
  -- for a scratch file, a note, or anything under ~/.config.
  local loose = vim.fn.tempname() .. ".txt"
  local fd = assert(io.open(loose, "w"))
  fd:write "alpha\nbeta\ngamma\ndelta\n"
  fd:close()

  -- A fresh tab: the review suite leaves a gitsigns diff panel current, and
  -- those windows set 'winfixbuf', which makes :edit fail with E1513.
  vim.cmd "tabnew"
  vim.cmd.edit(vim.fn.fnameescape(loose))
  local file = ref.file()
  truthy("ref: a file outside any git repo still yields a reference", file ~= nil)
  eq("ref: and it has no repo", file and file.repo, nil)
  eq("ref: its root is the file's directory", file and file.root, vim.fs.dirname(loose))
  truthy(
    "ref: render() does not require a repo",
    file and ref.render(file):find("alpha", 1, true) ~= nil
  )

  -- A <cmd> mapping fires while visual mode is STILL ACTIVE, so '< and '> hold
  -- the PREVIOUS selection. Reading them sent the agent the wrong lines with no
  -- error at all.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd "normal! Vj"
  vim.cmd [[execute "normal! \<Esc>"]]
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd "normal! V"

  local marks = vim.api.nvim_buf_get_mark(0, "<")[1]
  local visual = ref.visual()
  eq("ref: the marks are indeed stale mid-selection", marks, 1)
  eq("ref: visual() reads the LIVE selection, not the marks", visual and visual.lnum, 4)
  eq("ref: and its text is the selected line", visual and visual.lines[1], "delta")

  vim.cmd [[execute "normal! \<Esc>"]]
  vim.cmd "tabclose"
  os.remove(loose)
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

-- ----------------------------------------------------------- workspace

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
    truthy("workspace: force removes anyway", workspace.remove(ws2, { force = true }))
  end
end

-- ------------------------------------------------------------ ws init

local function test_ws_init()
  -- The regression: `:Paseo ws init` named the buffer <root>/.ws/workspace.toml
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
    vim.cmd "Paseo ws init"
    vim.wait(2000, function()
      return vim.api.nvim_buf_get_name(0):find "workspace%.toml" ~= nil
    end, 50)

    local named = vim.api.nvim_buf_get_name(0)
    truthy(
      "ws init: the buffer is named after the manifest",
      named:find "%.ws/workspace%.toml" ~= nil,
      named
    )
    truthy("ws init: .ws/ exists BEFORE you write", vim.uv.fs_stat(vim.fs.dirname(named)) ~= nil)

    local ok = pcall(vim.cmd, "write")
    truthy("ws init: :w succeeds", ok)
    truthy("ws init: the manifest is on disk", vim.uv.fs_stat(named) ~= nil)

    -- A second init must reuse the buffer already sitting on that path rather
    -- than failing on a duplicate name.
    truthy("ws init: running it twice does not error", pcall(vim.cmd, "Paseo ws init"))

    local loaded = require("paseo.workspace.manifest").load(project)
    truthy("ws init: what it wrote parses back", loaded ~= nil and loaded.repos.repo ~= nil)
    vim.cmd "tabonly"
  end)

  vim.fn.delete(project, "rf")
end

-- ------------------------------------------------------------------ ui

--- The rendering layer. All pure, so all of it runs headlessly.
local function test_ui()
  local render = require "paseo.ui.render"
  local timeline = require "paseo.ui.timeline"
  local transcript = require "paseo.ui.transcript"
  require("paseo.ui.hl").setup()

  -- Every module has to at least load, same reason as the bridge suite.
  for _, name in ipairs {
    "paseo.ui.hl",
    "paseo.ui.render",
    "paseo.ui.timeline",
    "paseo.ui.transcript",
    "paseo.ui.permission",
  } do
    truthy("ui: " .. name .. " loads", (pcall(require, name)))
  end

  -- ---------------------------------------------------------------- render

  -- A card whose lines are not all exactly the requested width draws a ragged
  -- right edge, which is what every box-drawing bug looks like.
  local card = render.card(
    { { "✓ Shell", "PaseoToolOk" } },
    { { { "ls -la" } }, { { "a.txt" } } },
    { width = 40 }
  )
  local ragged
  for _, line in ipairs(card) do
    if render.width(line) ~= 40 then
      ragged = render.concat(line)
    end
  end
  eq("ui: every card line is exactly the requested width", ragged, nil)

  -- Found by real agent history, not by a fixture: a multi-line shell command
  -- comes back with newlines in `display.summary`, and nvim_buf_set_lines
  -- rejects a line containing one ("'replacement string' item contains
  -- newlines"). A single heredoc in a transcript was enough to hit it.
  local newline_card = render.card(
    { { "Shell", "PaseoToolName" }, { "cat <<EOF\nhello\nEOF", "PaseoToolArg" } },
    {},
    { width = 50 }
  )
  eq(
    "ui: a cell containing a newline is flattened, not passed through",
    render.concat(newline_card[1]):find("\n", 1, true),
    nil
  )
  eq("ui: and the card is still exactly its width", render.width(newline_card[1]), 50)

  -- Also from real data: a header long enough to be truncated used the body's
  -- width budget, which does not account for the opening "╭─ " and the closing
  -- corner, so every truncated card came out one column too wide.
  local long = render.card(
    { { string.rep("x", 400), "PaseoToolArg" } },
    { { { string.rep("y", 400) } } },
    { width = 60 }
  )
  local widths = {}
  for _, line in ipairs(long) do
    widths[#widths + 1] = render.width(line)
  end
  eq("ui: a truncated header does not overflow the card", widths, { 60, 60, 60 })

  -- A collapsed card is ONE line. A transcript of three-line boxes around
  -- "read a file" is unreadable.
  eq("ui: a card with no body is a single line", #render.card({ { "x" } }, {}, { width = 40 }), 1)

  -- Extmark columns are BYTES; widths are display columns. Box-drawing and the
  -- status glyphs make the two differ on literally every card line.
  local buf = vim.api.nvim_create_buf(false, true)
  render.to_buffer(buf, require("paseo.ui.hl").ns, 0, -1, {
    { { "│ ", "PaseoBorder" }, { "ok", "PaseoToolOk" } },
  })
  local marks =
    vim.api.nvim_buf_get_extmarks(buf, require("paseo.ui.hl").ns, 0, -1, { details = true })
  local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  local second = marks[2]
  eq(
    "ui: extmark columns are byte offsets, not display columns",
    second and text:sub(second[3] + 1, second[4].end_col),
    "ok"
  )

  -- Highlights must outrank treesitter: the transcript is a markdown buffer and
  -- markdown's captures sit at the default priority of 100.
  truthy("ui: transcript highlights outrank treesitter", marks[1] and marks[1][4].priority == 200)

  -- ------------------------------------------------------------- timeline

  -- The whole complaint: the agent reading a file and running commands was
  -- invisible. Each of these must produce something.
  for _, case in ipairs {
    { "shell", { type = "shell", command = "ls -la", output = "a\nb", exitCode = 0 } },
    { "read", { type = "read", filePath = "/tmp/a.lua", offset = 1, limit = 20 } },
    { "edit", { type = "edit", filePath = "/tmp/a.lua", unifiedDiff = "@@ -1 +1 @@\n-a\n+b" } },
    { "write", { type = "write", filePath = "/tmp/a.lua", content = "x\ny" } },
    { "search", { type = "search", query = "foo", numFiles = 2, numMatches = 7 } },
    { "fetch", { type = "fetch", url = "https://example.com", code = 200 } },
    { "sub_agent", { type = "sub_agent", description = "explore", log = "", actions = {} } },
    { "plan", { type = "plan", text = "do the thing" } },
    { "plain_text", { type = "plain_text", text = "note" } },
    { "unknown", { type = "unknown", input = { a = 1 }, output = nil } },
  } do
    local built = timeline.card({
      kind = "tool",
      callId = "c",
      name = "T",
      status = "completed",
      display = { displayName = "T", summary = "s" },
      detail = case[2],
    }, { width = 60, expanded = true })
    truthy("ui: a " .. case[1] .. " tool call renders", #built.lines > 0)
  end

  -- Reasoning is the "thinking steps" half of the complaint.
  local thought = timeline.card({ kind = "thinking", text = "line one\nline two" }, { width = 60 })
  truthy("ui: reasoning renders", #thought.lines > 0)
  truthy("ui: reasoning is collapsible", thought.collapsible)
  eq("ui: reasoning collapses to one line", #thought.lines, 1)

  -- A failure you have to expand to notice is a failure you will not notice.
  local failed = timeline.card({
    kind = "tool",
    callId = "c",
    name = "T",
    status = "failed",
    error = "boom",
    display = { displayName = "T", errorText = "exit 1" },
    detail = { type = "shell", command = "false" },
  }, { width = 60 })
  truthy(
    "ui: a failed tool call shows its error while collapsed",
    render.concat(failed.lines[1]):find("exit 1", 1, true) ~= nil
  )

  -- ----------------------------------------------------------- transcript

  local chat = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(chat)

  transcript.upsert(chat, { kind = "user", text = "run ls" })
  transcript.upsert(chat, {
    kind = "tool",
    callId = "call-1",
    name = "Bash",
    status = "running",
    display = { displayName = "Shell", summary = "ls -la" },
    detail = { type = "shell", command = "ls -la" },
  })
  -- Content arriving BELOW the running card is what makes its line number go
  -- stale, which is why blocks are anchored by extmark rather than by row.
  transcript.upsert(chat, { kind = "thinking", text = "waiting" })
  transcript.stream(chat, "Run")
  transcript.stream(chat, "ning.")

  local before = vim.api.nvim_buf_line_count(chat.conversation)
  transcript.upsert(chat, {
    kind = "tool",
    callId = "call-1",
    name = "Bash",
    status = "completed",
    display = { displayName = "Shell", summary = "ls -la" },
    detail = { type = "shell", command = "ls -la", output = "a.txt", exitCode = 0 },
  })

  -- The regression this guards: a tool call arrives TWICE, running then
  -- completed. Appending the second one prints every command in the
  -- transcript twice.
  eq("ui: a completing tool call replaces its card rather than appending", before,
    vim.api.nvim_buf_line_count(chat.conversation))
  local blocks = 0
  for _ in pairs(chat.blocks) do
    blocks = blocks + 1
  end
  eq("ui: and does not create a second block", blocks, 4)

  local joined = table.concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
  truthy("ui: the completed card shows its terminal status", joined:find("✓", 1, true) ~= nil)
  truthy("ui: and no longer shows the running one", joined:find("◐", 1, true) == nil)

  -- Streamed chunks must join: a reply delivered as "Run" + "ning." renders
  -- "Running.", not two lines.
  truthy("ui: streamed chunks join into one block", joined:find("Running.", 1, true) ~= nil)

  -- Expanding grows the card and pushes everything below it down; the anchors
  -- must survive that, or the next replace lands in the wrong place.
  local tool = chat.blocks[chat.by_call["call-1"]]
  tool.expanded = true
  transcript.rerender(chat, tool)
  truthy(
    "ui: expanding a card reveals its output",
    table.concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("a.txt", 1, true) ~= nil
  )
  eq("ui: anchors survive a block changing height", #vim.api.nvim_buf_get_extmarks(
    chat.conversation, require("paseo.ui.hl").ns_anchor, 0, -1, {}), 4)

  -- `replaced` invalidates the epoch. It was emitted by the sidecar and
  -- listened to by nobody, so a replacement left stale messages on screen.
  transcript.reset(chat)
  eq("ui: reset empties the transcript", vim.api.nvim_buf_line_count(chat.conversation), 1)
  eq("ui: and drops the callId map", next(chat.by_call), nil)

  -- --------------------------------------------------------------- surfaces

  -- Opening and closing the float must leave nothing behind. The regression:
  -- `close()` set its state to nil before the helper that closes the
  -- conversation and composer floats read it, so two windows survived every
  -- close and stacked up across the session.
  local float = require "paseo.ui.float"
  local surface_chat = {
    root = vim.uv.cwd(),
    agent_id = "test-agent",
    provider = "test",
    streaming = false,
    pending = {},
    conversation = vim.api.nvim_create_buf(false, true),
    composer = vim.api.nvim_create_buf(false, true),
  }
  transcript.reset(surface_chat)
  transcript.upsert(surface_chat, { kind = "user", text = "hello" })

  local wins_before = #vim.api.nvim_list_wins()
  local bufs_before = #vim.api.nvim_list_bufs()
  for _ = 1, 3 do
    float.open(surface_chat)
    float.select "Usage"
    float.select "Chat"
    float.close()
  end
  eq("ui: the float leaves no windows behind", #vim.api.nvim_list_wins(), wins_before)
  eq("ui: the float leaves no buffers behind", #vim.api.nvim_list_bufs(), bufs_before)

  -- THE "1-5 JUMP DOES NOT WORK" BUG. The tab keys were mapped on the chrome
  -- buffer alone, and on the Chat tab -- the tab it opens on -- the chrome
  -- never holds the cursor, because `show_chat_panes` enters the composer. So
  -- every one of those keystrokes went to a buffer with no such mapping, while
  -- the footer advertised them.
  ---@param buf integer
  ---@param key string
  local function mapping(buf, key)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == key then
        return m.desc or "(no desc)"
      end
    end
    return nil
  end

  float.open(surface_chat)
  eq(
    "ui: the cursor lands in the composer",
    vim.api.nvim_get_current_buf(),
    surface_chat.composer
  )
  truthy(
    "ui: so the tab keys are bound THERE, not only on the chrome",
    mapping(surface_chat.composer, "1") ~= nil and mapping(surface_chat.composer, "5") ~= nil
  )
  truthy(
    "ui: and on the conversation, which is the other pane you read from",
    mapping(surface_chat.conversation, "5") ~= nil
  )
  -- Pressed where the cursor actually is.
  vim.api.nvim_feedkeys("5", "x", false)
  eq("ui: pressing 5 in the composer jumps to the fifth tab", float.tab(), float.TABS[5])
  vim.api.nvim_feedkeys("1", "x", false)
  eq("ui: and 1 comes back to the conversation", float.tab(), "Chat")

  -- The conversation keeps its own `<Tab>`, which expands a tool card to show
  -- what the command printed. That is worth more there than a second way to
  -- cycle tabs, and `1`-`6` reach every tab from the conversation anyway.
  truthy(
    "ui: the float does not take <Tab> from the conversation",
    mapping(surface_chat.conversation, "<Tab>") ~= "paseo: next tab",
    mapping(surface_chat.conversation, "<Tab>")
  )
  eq(
    "ui: but the composer, which had no <Tab>, cycles with it",
    mapping(surface_chat.composer, "<Tab>"),
    "paseo: next tab"
  )

  -- These are buffers you KEEP -- the sidebar shows the same two -- so a
  -- mapping left behind would go on swallowing digits with no dashboard open.
  float.close()
  truthy(
    "ui: closing the float gives the composer its digits back",
    mapping(surface_chat.composer, "1") == nil and mapping(surface_chat.composer, "<Tab>") == nil
  )
  truthy(
    "ui: and the conversation's",
    mapping(surface_chat.conversation, "1") == nil
  )

  -- Z-INDEX. The surface used to sit at 100, above the 50 that `nvim_open_win`
  -- and plenary's popup hand out by default -- so every telescope picker and
  -- `vim.ui.select` opened FROM the dashboard rendered underneath it, and
  -- looked like nothing had happened.
  float.open(surface_chat)
  local highest = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local win_config = vim.api.nvim_win_get_config(win)
    if win_config.relative ~= "" then
      highest = math.max(highest, win_config.zindex or 0)
    end
  end
  truthy(
    "ui: the dashboard stacks below a default float, so pickers open on top",
    highest < 50,
    highest
  )
  float.close()

  -- GEOMETRY IS CONFIGURABLE, and the box is the whole reason: a margin in
  -- cells that looks right on a 200-column monitor is most of a laptop screen,
  -- and someone whose terminal float is already a known size wants this one to
  -- match it rather than to be near it.
  local config = require "paseo.config"
  ---@return table
  local function box()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local win_config = vim.api.nvim_win_get_config(win)
      if win_config.relative ~= "" and win_config.zindex == config.get().ui.float.zindex then
        return win_config
      end
    end
    return {}
  end

  -- THE UNIT IS A PERCENTAGE, 1-100. Fractions were the first attempt: `0.92`
  -- and `92` are each obvious once you know which convention you are in, and
  -- nothing on the page tells you which. floaterm's `size` is percentages, so
  -- percentages are what a number copied between the two configs means.
  config.setup { ui = { float = { width = 50, height = 50 } } }
  float.open(surface_chat)
  local half = box()
  eq("ui: a number is a percentage of the editor", {
    half.width,
    half.height,
  }, {
    math.max(60, math.floor(vim.o.columns * 50 / 100)),
    math.max(20, math.floor(vim.o.lines * 50 / 100)),
  })
  eq("ui: and with no row/col it centres", {
    half.row,
    half.col,
  }, {
    math.floor((vim.o.lines - half.height) / 2),
    math.floor((vim.o.columns - half.width) / 2),
  })
  float.close()

  -- The same arithmetic, in the same order, as floaterm's -- so the two agree
  -- to the cell rather than to within a rounding error, and a config that
  -- gives them one size gets them one place.
  local floaterm_h = math.floor(vim.o.lines * (90 / 100))
  local floaterm_w = math.floor(vim.o.columns * (92 / 100))
  config.setup { ui = { float = { width = 92, height = 90 } } }
  float.open(surface_chat)
  local matched = box()
  eq("ui: a percentage matches floaterm's, box and position", {
    matched.width,
    matched.height,
    matched.row,
    matched.col,
  }, {
    floaterm_w,
    floaterm_h,
    math.floor(vim.o.lines / 2 - floaterm_h / 2),
    math.floor(vim.o.columns / 2 - floaterm_w / 2),
  })
  float.close()

  -- `row`/`col` are CELLS: they are window coordinates, not sizes. A function
  -- is the escape hatch for a size no percentage can express, and returns
  -- cells too. Neither may put the border off screen.
  config.setup {
    ui = {
      float = {
        width = function(columns)
          return columns
        end,
        height = 100,
        row = -5,
        col = 9999,
      },
    },
  }
  float.open(surface_chat)
  local pinned = box()
  eq("ui: a function returns cells, row/col are cells, and both are clamped", {
    pinned.width,
    pinned.height,
    pinned.row,
    pinned.col,
  }, { vim.o.columns, vim.o.lines, 0, 0 })
  float.close()

  -- The composer is measured from the bottom, and the conversation gets what
  -- is left -- so a composer taller than the box would hand the conversation a
  -- negative height rather than merely looking wrong.
  config.setup { ui = { float = { composer = 999 } } }
  float.open(surface_chat)
  local squeezed = vim.api.nvim_win_get_config(surface_chat.win_conversation)
  truthy(
    "ui: an absurd composer height still leaves the conversation a window",
    squeezed.height >= 5,
    squeezed.height
  )
  float.close()
  config.setup {}

  float.open(surface_chat)

  -- FEATURE PARITY. The header used to be the conversation window's winbar,
  -- and the conversation window only exists on the Chat tab -- so every other
  -- tab had no header at all and the dashboard could not tell you which model
  -- it was on. It is a volt section in the chrome now.
  float.select "Usage"
  eq("ui: the panels do not keep a conversation window", surface_chat.win_conversation, nil)
  local chrome_buf
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    -- volt is a HARD dependency now -- there is no plain-text fallback behind
    -- the chrome any more -- so this is a lookup, not a probe.
    if require("volt.state")[buf] then
      chrome_buf = buf
    end
  end
  truthy("ui: the dashboard chrome is a volt buffer", chrome_buf ~= nil)
  if chrome_buf then
    local marks =
      vim.api.nvim_buf_get_extmarks(chrome_buf, -1, { 0, 0 }, { 1, -1 }, { details = true })
    local drawn = {}
    for _, mark in ipairs(marks) do
      for _, cell in ipairs(mark[4].virt_text or {}) do
        drawn[#drawn + 1] = cell[1]
      end
    end
    drawn = table.concat(drawn)
    truthy(
      "ui: the header is drawn in the chrome, so it survives leaving the Chat tab",
      drawn:find("test", 1, true) ~= nil,
      drawn
    )
    truthy(
      "ui: and the tab bar is numbered, so 1-6 is a hint you can read",
      drawn:find("5 Usage", 1, true) ~= nil,
      drawn
    )

    -- Clicking a tab is the other half of "1-5 jump": volt dispatches a click
    -- through the cell's third element, and `volt.events.enable` -- which this
    -- surface never called, because it drives gen_data/redraw itself rather
    -- than going through `volt.run` -- is what routes LeftMouse to it.
    local targets = 0
    for _, row in pairs(require("volt.state")[chrome_buf].clickables) do
      targets = targets + #row
    end
    truthy("ui: the tab bar and header carry click targets", targets >= #float.TABS, targets)
    truthy("ui: and volt's mouse dispatch is switched on", vim.g.extmarks_events == true)

    -- The six panels SHARE the chrome buffer, so a panel that binds keys has
    -- to give them back. `<CR>` is the one that matters: volt binds it at open
    -- and that is how every other panel's rows are reached from the keyboard,
    -- so a Session panel that simply DELETED its own `<CR>` on the way out
    -- would leave the key dead on all five of the others.
    local function buf_map(lhs)
      local found = vim.fn.maparg(lhs, "n", false, true)
      return type(found) == "table" and found.buffer == 1 and found or nil
    end
    vim.api.nvim_set_current_buf(chrome_buf)

    local volt_cr = buf_map "<CR>"
    truthy("ui: volt binds <CR> on the chrome buffer", volt_cr ~= nil)
    eq("ui: and the Session keys are not bound on another tab", buf_map "h", nil)

    float.select "Session"
    truthy("ui: the Session panel takes the movement keys", buf_map "h" ~= nil)
    truthy("ui: and its group mnemonics", buf_map "s" ~= nil)
    truthy("ui: and displaces volt's <CR>", buf_map("<CR>").callback ~= volt_cr.callback)

    float.select "Usage"
    eq("ui: leaving gives the movement keys back", buf_map "h", nil)
    eq("ui: and the mnemonics", buf_map "s", nil)
    eq(
      "ui: and RESTORES volt's <CR> rather than deleting it",
      buf_map("<CR>").callback,
      volt_cr.callback
    )
  end
  float.close()

  -- Volt keys its state by buffer and never clears it; ours must.
  local entries = 0
  for _ in pairs(require "volt.state") do
    entries = entries + 1
  end
  eq("ui: the float clears its volt state", entries, 0)
  eq("ui: and takes its buffer off volt's key handler", #require("volt.events").bufs, 0)

  -- The session panel replaces four separate `vim.ui.select` prompts, so its
  -- rows have to be actionable -- a read-only list of settings you still have
  -- to leave the panel to change would be worse than the prompts.
  local session = require "paseo.ui.session"
  local session_panel = require "paseo.ui.panels.session"
  local widgets = require "paseo.ui.widgets"

  surface_chat.config_snapshot = {
    model = "opus",
    modeId = "default",
    thinkingOptionId = "low",
    availableModes = {
      { id = "plan", label = "Plan" },
      { id = "default", label = "Always ask" },
      { id = "bypassPermissions", label = "Bypass" },
    },
    thinkingOptions = { { id = "low", label = "Think", isDefault = true } },
    models = { { id = "opus", label = "Opus 5" }, { id = "sonnet", label = "Sonnet 5" } },
    features = { { id = "fast_mode", label = "Fast mode", type = "toggle", value = true } },
  }

  -- The daemon reports four lists that agree about nothing. One shape out, or
  -- the renderer has to know which group it is drawing.
  local groups = session.groups(surface_chat)
  eq("session: four groups come back", #groups, 4)
  local by_id = {}
  for _, group in ipairs(groups) do
    by_id[group.id] = group
  end
  eq("session: the mode group knows what is set", by_id.mode.current, "default")
  eq("session: the model group does too", by_id.model.current, "opus")
  eq("session: a toggle keeps its value", by_id.features.entries[1].value, true)
  eq("session: a default is noted", by_id.thinking.entries[1].note, "default")
  -- The one that matters: `bypassPermissions` cannot look like `plan`.
  eq("session: bypassing permissions is drawn as danger", by_id.mode.entries[3].tone, "danger")
  eq("session: and planning is not", by_id.mode.entries[1].tone, nil)

  local clickable = 0
  for _, line in ipairs(session_panel.lines(surface_chat, 80)) do
    for _, cell in ipairs(line) do
      -- A table, not a function: the cells carry `{ click = …, hover = … }`
      -- now, because hover has to paint a chip the same way focus does.
      if type(cell[3]) == "table" and type(cell[3].click) == "function" then
        clickable = clickable + 1
      end
    end
  end
  truthy("ui: the session panel's rows carry click actions", clickable >= 6)

  -- A card one cell narrower than its neighbour is instantly visible in a
  -- two-column layout, and `render.card` -- the older one -- had exactly that
  -- class of off-by-one in its header budget.
  local card = widgets.card {
    title = "Permission mode",
    icon = "",
    w = 40,
    lines = { { { "short" } }, { { string.rep("x", 90) } } },
  }
  local ragged = nil
  for i, line in ipairs(card) do
    if render.width(line) ~= 40 then
      ragged = ("row %d is %d wide"):format(i, render.width(line))
    end
  end
  eq("ui: every row of a card is exactly its width", ragged, nil)

  -- volt's `hpad` expands a cell whose text is the literal `_pad_`, and
  -- `line_w` skips it when measuring -- but `render.width` counts it as five
  -- columns of text. So the order is hpad THEN truncate, never the reverse,
  -- and `widgets.row` resolves the sentinel before returning.
  local justified = widgets.row({ { "left" } }, { { "right" } }, 30)
  eq("ui: a justified row lands on its width", render.width(justified), 30)
  for _, cell in ipairs(justified) do
    truthy("ui: and leaves no _pad_ sentinel behind", cell[1] ~= "_pad_")
  end

  -- Keyboard, not just mouse: the panel used to have no mappings at all, so
  -- the only way to change a setting was to aim at it.
  local view = session_panel.new(surface_chat)
  local _, focused = view:resolve()
  eq("session: focus starts on what is set", focused.id, "default")
  view:move(1)
  local _, after = view:resolve()
  eq("session: and moves on to the next entry", after.id, "bypassPermissions")
  view:jump "s"
  local jumped_group, jumped = view:resolve()
  eq("session: a mnemonic jumps to its group", jumped_group.id, "model")
  eq("session: landing on what that group has set", jumped.id, "opus")
  -- Running off the end of a group lands on the NEXT GROUP rather than
  -- wrapping inside itself, so `j` means "the next thing" everywhere and
  -- there is one traversal rather than one per card. `m` lands on the
  -- selected mode, which is the second of three; two steps back is one step
  -- past the top.
  view:jump "m"
  view:move(-1)
  view:move(-1)
  local wrapped_group, wrapped = view:resolve()
  eq("session: stepping off the top lands in the last group", wrapped_group.id, "model")
  eq("session: on its last entry", wrapped.id, "sonnet")

  -- `maparg` reads the CURRENT buffer, not the one being bound -- and at the
  -- moment the Session panel attaches, the current buffer is usually the
  -- COMPOSER, whose `<CR>` sends the prompt. Saving the displaced mapping from
  -- the wrong buffer restored "send the prompt" onto the chrome buffer.
  local host = vim.api.nvim_create_buf(false, true)
  local elsewhere = vim.api.nvim_create_buf(false, true)
  local host_cr = function() end
  local elsewhere_cr = function() end
  vim.keymap.set("n", "<CR>", host_cr, { buffer = host })
  vim.keymap.set("n", "<CR>", elsewhere_cr, { buffer = elsewhere })

  local was = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(elsewhere)
  session_panel.attach(surface_chat, host)
  session_panel.detach(surface_chat, host)

  vim.api.nvim_buf_call(host, function()
    eq(
      "session: detaching restores the mapping THAT BUFFER had",
      vim.fn.maparg("<CR>", "n", false, true).callback,
      host_cr
    )
  end)
  vim.api.nvim_buf_call(elsewhere, function()
    eq(
      "session: and leaves the buffer that happened to be current alone",
      vim.fn.maparg("<CR>", "n", false, true).callback,
      elsewhere_cr
    )
  end)
  vim.api.nvim_set_current_buf(was)
  vim.api.nvim_buf_delete(host, { force = true })
  vim.api.nvim_buf_delete(elsewhere, { force = true })

  -- `:Paseo mode` used to be a `vim.ui.select`. It is the same view object the
  -- dashboard draws, in a window of its own, which is why there is no second
  -- renderer to keep in step.
  local settings = require "paseo.ui.settings"
  local wins_before, bufs_before = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
  settings.open(surface_chat, "mode")
  truthy("settings: the popup opens", settings.is_open())

  local popup_buf = vim.api.nvim_get_current_buf()
  eq("settings: with a filetype of its own", vim.bo[popup_buf].ft, "paseo-settings")
  -- The height is VOLT'S, read back out of its state after `gen_data`. A
  -- window sized before the layout is built is sized against a guess, and this
  -- layout's size depends on how many models the provider has.
  eq(
    "settings: sized to the layout volt measured",
    vim.api.nvim_win_get_height(0),
    require("volt.state")[popup_buf].h
  )
  eq(
    "settings: and the buffer has exactly that many lines to anchor extmarks to",
    #vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false),
    require("volt.state")[popup_buf].h
  )
  -- `only` means one group, not a highlighted group in a list of four.
  local drawn_groups = 0
  for _, name in ipairs { "Permission mode", "Thinking", "Model", "Features" } do
    for _, line in ipairs(vim.api.nvim_buf_get_extmarks(popup_buf, -1, 0, -1, { details = true })) do
      for _, cell in ipairs(line[4].virt_text or {}) do
        if cell[1] == name then
          drawn_groups = drawn_groups + 1
        end
      end
    end
  end
  eq("settings: opened on one group, it draws one group", drawn_groups, 1)

  -- A section that changes height when you MOVE THE MOUSE is a crash. Volt
  -- records each section's starting row once, in `gen_data`, then draws at
  -- those offsets without clearing or re-padding -- so a description that
  -- appeared on hover wrote extmarks past the end of the buffer and raised
  -- "Invalid 'line': out of range" from inside `vim.on_key`.
  local tall = {
    agent_id = "x",
    config_snapshot = {
      modeId = "short",
      availableModes = {
        { id = "short", label = "Short", description = "One line." },
        {
          id = "long",
          label = "Long",
          description = ("wordy "):rep(60),
        },
      },
      thinkingOptions = {},
      models = {},
      features = {},
    },
  }
  local stable = session_panel.new(tall)
  local on_short = #stable:lines(60)
  stable:move(1)
  local on_long = #stable:lines(60)
  eq("session: a card's height does not depend on which entry is focused", on_long, on_short)

  settings.close()
  truthy("settings: and closes", not settings.is_open())
  eq("settings: leaving no windows behind", #vim.api.nvim_list_wins(), wins_before)
  eq("settings: nor buffers", #vim.api.nvim_list_bufs(), bufs_before)
  eq("settings: nor an entry in volt's state", require("volt.state")[popup_buf], nil)

  -- Clamping the WINDOW without clamping the LAYOUT is worse than not
  -- clamping at all: `nvim_open_win` shrinks quietly, volt goes on drawing at
  -- the rows it recorded, and the throw lands between opening the window and
  -- binding `q` -- an empty popup over a full-screen backdrop with no key
  -- that dismisses either.
  local real_lines = vim.o.lines
  vim.o.lines = 20
  surface_chat.config_snapshot.models = {}
  for i = 1, 12 do
    surface_chat.config_snapshot.models[i] = { id = "m" .. i, label = "Model " .. i }
  end
  local opened = pcall(settings.open, surface_chat)
  truthy("settings: twelve models on a twenty-row editor still opens", opened)
  if opened then
    local squeezed = vim.api.nvim_get_current_buf()
    local drawn = #vim.api.nvim_buf_get_lines(squeezed, 0, -1, false)
    eq("settings: the buffer is as long as the layout volt measured", drawn, require("volt.state")[squeezed].h)
    truthy("settings: and fits the editor", vim.api.nvim_win_get_height(0) <= vim.o.lines - 4)
    settings.close()
  end

  -- `nvim_buf_set_lines` collapses extmarks onto the last line rather than
  -- deleting them, so a redraw of a SHORTER layout stacked every row it no
  -- longer had on the popup's bottom row, overprinting there forever. Needs
  -- room to shrink into, so it is checked on a tall editor rather than the
  -- clamped one above.
  vim.o.lines = 40
  settings.open(surface_chat, "model")
  local shrinking = vim.api.nvim_get_current_buf()
  local before = #vim.api.nvim_buf_get_lines(shrinking, 0, -1, false)
  surface_chat.config_snapshot.models = {
    { id = "m1", label = "Model 1" },
    { id = "m2", label = "Model 2" },
  }
  vim.api.nvim_feedkeys(vim.keycode "l", "x", false)
  local after = #vim.api.nvim_buf_get_lines(shrinking, 0, -1, false)
  truthy("settings: dropping ten models shrinks the buffer", after < before, before .. " -> " .. after)

  local per_row = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(shrinking, require("volt.state")[shrinking].ns, 0, -1, {}))
  do
    per_row[mark[2]] = (per_row[mark[2]] or 0) + 1
  end
  local stacked = nil
  for row, n in pairs(per_row) do
    if n > 1 then
      stacked = ("row %d carries %d"):format(row, n)
    end
  end
  eq("settings: and leaves no extmarks stacked on a row", stacked, nil)
  settings.close()

  vim.o.lines = real_lines

  -- Volt's convention is the cell's THIRD element, and everything between the
  -- panel and volt must preserve it -- truncate, flatten and to_volt all
  -- rebuild cell tables.
  local action = function() end
  local through = render.to_volt { render.truncate({ { "x", "PaseoDim", action } }, 40) }
  eq("ui: click actions survive truncate and to_volt", through[1][1][3], action)

  -- The dashboard is the DEFAULT surface: it is the one with everything on it,
  -- and the sidebar is what `<C-f>` switches to.
  local defaults = config.defaults()
  eq("ui: the configured default surface is the dashboard", defaults.ui.surface, "float")
  truthy(
    "ui: whose z-index is below the 50 a float gets by default",
    defaults.ui.float.zindex < 50
  )

  -- Pasting an image is what `p` does now -- read the clipboard, fall through
  -- to an ordinary paste when it holds no picture -- so the composer no longer
  -- spends four columns of a narrow pane teaching you `^V`.
  local sidebar = require "paseo.ui.sidebar"
  local wins_at_hint = #vim.api.nvim_list_wins()
  sidebar.open(surface_chat)
  local hint = vim.wo[surface_chat.win_composer].winbar
  truthy("ui: the composer's hint does not advertise ^V", hint:find("^V", 1, true) == nil, hint)
  truthy("ui: it still says how to send", hint:find("send", 1, true) ~= nil, hint)
  sidebar.close(surface_chat)
  eq("ui: and the sidebar closes both its windows", #vim.api.nvim_list_wins(), wins_at_hint)

  -- The sidebar is configurable in the same units as the float, which is the
  -- point of the units: one number means one thing everywhere.
  config.setup {
    ui = { sidebar = { width = 30, min_width = 20, composer = 4, position = "left" } },
  }
  sidebar.open(surface_chat)
  eq(
    "ui: the sidebar takes a percentage too",
    vim.api.nvim_win_get_width(surface_chat.win_conversation),
    math.max(20, math.floor(vim.o.columns * 30 / 100))
  )
  eq(
    "ui: and an explicit composer height",
    vim.api.nvim_win_get_height(surface_chat.win_composer),
    4
  )
  truthy(
    "ui: `position = left` puts it on the left",
    vim.api.nvim_win_get_position(surface_chat.win_conversation)[2] == 0,
    vim.inspect(vim.api.nvim_win_get_position(surface_chat.win_conversation))
  )
  sidebar.close(surface_chat)

  -- min_width is in CELLS and wins over the percentage: 40% of a small
  -- terminal is a pane too narrow to read a tool card in, and the percentage
  -- has no way to know that.
  config.setup { ui = { sidebar = { width = 1, min_width = 30 } } }
  sidebar.open(surface_chat)
  eq(
    "ui: min_width floors the percentage, in cells",
    vim.api.nvim_win_get_width(surface_chat.win_conversation),
    30
  )
  sidebar.close(surface_chat)

  -- And the cap is `winwidth`, not the editor: Neovim gives the window you
  -- came back to its minimum width and takes the difference out of ours, so
  -- asking for more than that is a number that quietly does not happen. Asking
  -- for the whole editor should land on the widest pane that actually holds.
  config.setup { ui = { sidebar = { width = 100, min_width = 1 } } }
  sidebar.open(surface_chat)
  eq(
    "ui: and the cap is what 'winwidth' leaves, so the number asked for holds",
    vim.api.nvim_win_get_width(surface_chat.win_conversation),
    math.max(20, vim.o.columns - math.max(vim.o.winwidth, 10) - 1)
  )
  sidebar.close(surface_chat)
  config.setup {}

  -- Both surfaces draw the header from ONE builder, so they cannot drift into
  -- disagreeing about which mode the session is in.
  surface_chat.mode = "acceptEdits"
  surface_chat.permissions = { { id = "x" } }
  local header = render.concat(sidebar.header(surface_chat))
  truthy("ui: the header shows the mode", header:find("acceptEdits", 1, true) ~= nil)
  truthy("ui: and shouts when something is waiting on you", header:find("needs you", 1, true) ~= nil)

  -- The spinner. A static `●` looked identical at two seconds and at two
  -- minutes, so a wedged turn and a working one were the same picture; the
  -- elapsed count is the half that tells them apart.
  local chat = require "paseo.ui.chat"
  surface_chat.permissions = {}
  chat.set_streaming(surface_chat, true)
  local frame, seconds = chat.progress(surface_chat)
  local busy = render.concat(sidebar.header(surface_chat))
  truthy("ui: a running turn reports a frame", frame ~= nil, frame)
  truthy("ui: which the header draws", frame and busy:find(frame, 1, true) ~= nil, busy)
  eq("ui: alongside the seconds it has been running", seconds, 0)

  -- The invariant that keeps the timer honest: `streaming` is only ever set
  -- through the setter, so a timer can never outlive the turn it belongs to
  -- and redraw a header forever on a chat nobody is looking at.
  chat.set_streaming(surface_chat, false)
  truthy("ui: and the timer is closed when the turn ends", surface_chat.spinner == nil)
  eq("ui: an idle turn reports no frame", (chat.progress(surface_chat)), nil)

  -- `%` is the statusline escape character: a path or command containing one
  -- would be read as a format item and eat the rest of the bar.
  local escaped = render.to_winbar { { "50% done", "PaseoDim" } }
  truthy("ui: winbar text escapes %", escaped:find("50%% done", 1, true) ~= nil)

  -- ---------------------------------------------------- source invariants

  -- NOT `vim.fn.getcwd()`: the review and ws-init suites `tcd` into fixture
  -- directories, so by the time this runs the cwd is wherever they left it and
  -- every one of these assertions silently skipped instead of failing.
  local root_dir = vim.fs.dirname(vim.api.nvim_get_runtime_file("lua/paseo/ui/render.lua", false)[1])
  root_dir = root_dir and vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(root_dir)))

  local function source_of(path)
    if not root_dir then
      return nil
    end
    local fd = io.open(root_dir .. "/" .. path, "r")
    if not fd then
      return nil
    end
    local text = fd:read "*a"
    fd:close()
    return text
  end

  truthy("ui: the source tree under test was located", root_dir ~= nil)

  local sidecar = sidecar_source()
  if sidecar then
    -- The root cause of "I can't see the thinking steps": the sidecar's switch
    -- forwarded only assistant_message and user_message and dropped the rest.
    truthy("ui: the sidecar forwards reasoning", sidecar:find('case "reasoning"', 1, true) ~= nil)
    truthy("ui: the sidecar forwards tool calls", sidecar:find('case "tool_call"', 1, true) ~= nil)
    truthy(
      "ui: the sidecar forwards permission requests",
      sidecar:find('case "permission_requested"', 1, true) ~= nil
    )
    truthy(
      "ui: history carries tool calls too, through the same describer",
      sidecar:find("describeItem(entry.item", 1, true) ~= nil
    )
    -- A synthesised action id is ours, not the provider's, and sending one back
    -- is rejected.
    truthy(
      "ui: synthetic action ids are stripped before answering",
      sidecar:find('startsWith("__")', 1, true) ~= nil
    )
  end

  local chat_source = source_of "lua/paseo/ui/chat.lua"
  if chat_source then
    truthy(
      "ui: the replaced event is handled",
      chat_source:find('bridge.on("replaced"', 1, true) ~= nil
    )
  end

  -- Volt sets `modifiable = false` and binds `q`/`<Esc>` to close. Handing it
  -- the composer would make the one buffer you type into untypeable.
  for _, path in ipairs { "lua/paseo/ui/chat.lua", "lua/paseo/ui/transcript.lua" } do
    local text = source_of(path)
    if text then
      truthy(
        "ui: " .. path .. " never hands a chat buffer to volt",
        text:find("volt.run", 1, true) == nil and text:find("volt.mappings", 1, true) == nil
      )
    end
  end

  -- volt.draw does `table.remove(marks, 3)` on whatever it is handed, stripping
  -- the actions permanently. So to_volt must hand over COPIES -- asserted by
  -- behaviour rather than by grepping for `vim.deepcopy`, which says nothing
  -- about whether the copy actually reaches volt.
  local source_line = { { "click me", "PaseoKey", { click = function() end } } }
  local handed = render.to_volt { source_line }
  truthy("ui: to_volt hands volt a different table", handed[1] ~= source_line)
  truthy("ui: and different cells within it", handed[1][1] ~= source_line[1])
  table.remove(handed[1][1], 3) -- what volt.draw does
  truthy(
    "ui: so volt stripping the actions cannot reach ours",
    source_line[1][3] ~= nil
  )
end

-- --------------------------------------------------------- create strategy

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
  truthy(
    "strategy: cut from the repo toplevel",
    (solo.repo or ""):find "/solo$" ~= nil,
    solo.repo
  )

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

-- --------------------------------------------------------------- questions

local function test_questions()
  local questions = require "paseo.ui.questions"
  local render = require "paseo.ui.render"
  local timeline = require "paseo.ui.timeline"

  truthy("questions: the module loads", (pcall(require, "paseo.ui.questions")))

  -- Claude's own AskUserQuestion, as the daemon forwards it.
  local claude = {
    id = "permission-1",
    kind = "question",
    name = "AskUserQuestion",
    title = "How should I reconcile your local work?",
    input = {
      questions = {
        {
          question = "How should I reconcile your local work?",
          header = "Reconcile",
          multiSelect = false,
          allowOther = true,
          options = {
            { label = "Rebase", description = "Replay my commits on top" },
            { label = "Merge" },
          },
        },
      },
    },
  }

  local one = questions.parse(claude)
  eq("questions: a question request parses", one and #one, 1)
  eq(
    "questions: options keep their descriptions",
    one[1].options[1].description,
    "Replay my commits on top"
  )
  truthy("questions: allowOther means free text is an answer", one[1].free)

  -- The whole bug: a request to ACT carries no questions and must stay on the
  -- allow/deny path rather than be answered as if it did.
  eq("questions: a tool permission is not a question", questions.parse {
    kind = "tool",
    name = "Write",
    input = { file_path = "/tmp/x", content = "y" },
  }, nil)

  -- Two questions in one request: the shape that rendered as one.
  local pair = {
    id = "permission-2",
    kind = "question",
    input = {
      questions = {
        {
          question = "Which ones apply?",
          header = "Applies",
          multiSelect = true,
          options = { { label = "A" }, { label = "B" } },
        },
        { question = "Optional comment", header = "Comment", options = {}, allowEmpty = true },
      },
    },
  }

  local both = questions.parse(pair)
  eq("questions: every question in the request is parsed", #both, 2)
  truthy("questions: no options at all is a free-text question", both[2].free)
  truthy("questions: allowEmpty may be skipped", both[2].optional)

  eq(
    "questions: a label containing the separator is quoted",
    questions.join { "Rebase, then push", "B" },
    '"Rebase, then push", B'
  )

  local input = questions.input(pair, both, { [1] = questions.join { "A", "B" }, [2] = "" })
  eq("questions: answers are keyed by the question text", input.answers["Which ones apply?"], "A, B")
  eq("questions: and by the header other providers read", input.answers["Applies"], "A, B")
  eq("questions: a skipped answer is sent as no answer", input.answers["Comment"], nil)
  eq("questions: the questions go back with them", #input.questions, 2)

  -- `answers = {}` encodes as `[]`, which is not an answers object: a set
  -- skipped whole still has to arrive as a dict.
  eq(
    "questions: answered nothing still sends an object",
    vim.json.encode(questions.input(pair, both, {}).answers),
    "{}"
  )

  -- ----------------------------------------------------------------- state

  local state = questions.state(both)
  eq("questions: the first question is the one the keys act on", state.current, 1)

  questions.choose(state, 1)
  questions.choose(state, 2)
  eq("questions: multi-select accumulates", questions.answers(state)[1], "A, B")
  questions.choose(state, 1)
  eq("questions: and a second press takes it back off", questions.answers(state)[1], "B")
  eq("questions: multi-select does not move on by itself", state.current, 1)

  -- Unanswered means UNSENDABLE while the question is not optional.
  local blocked = questions.state(both)
  eq("questions: an unanswered question blocks the send", questions.missing(blocked), 1)
  questions.choose(blocked, 1)
  eq("questions: and stops blocking once answered", questions.missing(blocked), nil)

  -- The optional second question is free text, and typing moves nothing on
  -- because there is nothing after it.
  questions.move(state, 1)
  eq("questions: <Tab> moves to the next question", state.current, 2)
  questions.write(state, "  looks right  ")
  eq("questions: a typed answer is trimmed", questions.answers(state)[2], "looks right")

  -- Single-select replaces and moves on: there is nothing else to say.
  local single = questions.state(one)
  questions.choose(single, 2)
  questions.choose(single, 1)
  eq("questions: single-select replaces rather than accumulating", questions.answers(single)[1], "Rebase")

  eq(
    "questions: the badge says what was answered, not just `allowed`",
    questions.label(both, questions.answers(state)),
    "Applies: B · Comment: looks right"
  )

  -- The transcript card showed `title`, which is the FIRST question and its
  -- labels, so a request carrying two was recorded as one.
  local card = timeline.card({ kind = "permission", request = pair }, { width = 60 })
  local text = {}
  for _, line in ipairs(card.lines) do
    text[#text + 1] = render.concat(line)
  end
  text = table.concat(text, "\n")
  truthy("questions: the inline card shows the second question too", text:find("Optional comment", 1, true) ~= nil, text)
  truthy("questions: and the options under it", text:find("A", 1, true) ~= nil, text)
end

local function test_provider_setup()
  local bridge = require "paseo.bridge"
  local create = require "paseo.ui.create"
  local session = require "paseo.ui.session"
  local chat = require "paseo.ui.chat"
  local config = require "paseo.config"
  local sidebar = require "paseo.ui.sidebar"
  local old_ensure, old_request = bridge.ensure, bridge.request
  local old_select, old_current = vim.ui.select, chat.current
  local old_toggle, old_load = session.toggle, chat.load_settings
  local old_preference = config.get().paseo.provider
  local requests = {}
  local hold_features, held_feature_callback = false, nil
  local catalogue = { entries = {
    {
      provider = "claude", status = "ready", label = "Claude", defaultModeId = "default",
      modes = { { id = "plan", label = "Plan" }, { id = "default", label = "Ask" } },
      models = { { id = "opus", label = "Opus", isDefault = true } },
    },
    {
      provider = "codex", status = "ready", label = "Codex", defaultModeId = "auto-review",
      modes = { { id = "auto-review", label = "Auto-review" } },
      models = {
        {
          id = "gpt-5.6-sol", label = "GPT-5.6-Sol", isDefault = true,
          thinkingOptions = { { id = "high", label = "High", isDefault = true } },
        },
        {
          id = "gpt-5.6-luna", label = "GPT-5.6-Luna",
          thinkingOptions = { { id = "medium", label = "Medium", isDefault = true } },
        },
      },
    },
  } }
  local ok, err = pcall(function()
    bridge.ensure = function(callback)
      callback(nil)
    end
    bridge.request = function(op, args, callback)
      requests[#requests + 1] = { op = op, args = args }
      if op == "providers" then
        callback(nil, catalogue)
      elseif op == "providers.features" then
        if hold_features then
          held_feature_callback = callback
          return
        end
        callback(nil, { features = args.provider:find("luna", 1, true)
          and { { id = "plan_mode", type = "toggle", label = "Plan", value = false } }
          or {
            { id = "fast_mode", type = "toggle", label = "Fast", value = false },
            { id = "plan_mode", type = "toggle", label = "Plan", value = false },
          } })
      elseif op == "agent.config" then
        callback(nil, chat.test_config)
      elseif op == "agent.setMode" then
        callback(nil, {})
      else
        error("unexpected bridge op: " .. op)
      end
    end

    local chosen, select_count
    local chosen_model = "gpt-5.6-sol"
    select_count = 0
    vim.ui.select = function(items, _, callback)
      select_count = select_count + 1
      if items[1] and items[1].provider then
        return callback(items[#items])
      end
      for _, item in ipairs(items) do
        if item.id == chosen_model then
          return callback(item)
        end
      end
      callback(items[1])
    end
    create.select_model({ cwd = "/work" }, function(selection)
      chosen = selection
    end)
    truthy("provider: picker completes", vim.wait(1000, function()
      return chosen ~= nil
    end))
    eq("provider: separate provider and model selections", select_count, 2)
    eq("provider: labeled Codex model is selected", chosen and chosen.provider, "codex/gpt-5.6-sol")
    eq("provider: direct model ids are validated", create.find(catalogue.entries, "codex/nope"), nil)
    local draft = create.draft(chosen)
    eq("provider: default permissions come from daemon", draft.modeId, "auto-review")
    eq("provider: default reasoning comes from model", draft.thinkingOptionId, "high")

    create.preference("codex/gpt-5.6-sol", function() end)
    eq("provider: preference changes without creating an agent", config.get().paseo.provider, "codex/gpt-5.6-sol")
    truthy("provider: no creation op was sent", vim.iter(requests):all(function(request)
      return request.op ~= "agent.ensure" and request.op ~= "agent.create"
    end))

    local reviewed
    create.review({ cwd = "/work", preferred = "codex/gpt-5.6-sol" }, function(value)
      reviewed = value
    end)
    truthy("provider: review screen opens", vim.wait(1000, function()
      local buf = vim.api.nvim_get_current_buf()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        :find("New Paseo session", 1, true) ~= nil
    end))
    chosen_model = "gpt-5.6-luna"
    hold_features = true
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_feedkeys(vim.keycode "<CR>", "x", false)
    truthy("provider: changing model re-fetches its features", vim.wait(1000, function()
      local found = 0
      for _, request in ipairs(requests) do
        if request.op == "providers.features" then
          found = found + 1
        end
      end
      return found >= 2
    end))
    vim.api.nvim_feedkeys("c", "x", false)
    eq("provider: cannot create before the model features arrive", reviewed, nil)
    hold_features = false
    held_feature_callback(nil, { features = {
      { id = "plan_mode", type = "toggle", label = "Plan", value = false },
    } })
    truthy("provider: model features finish loading", vim.wait(1000, function()
      local buf = vim.api.nvim_get_current_buf()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        :find("Loading model features", 1, true) == nil
    end))
    vim.api.nvim_feedkeys("c", "x", false)
    truthy("provider: review creates a draft", vim.wait(1000, function()
      return reviewed ~= nil
    end))
    eq("provider: reviewed model is the changed model", reviewed and reviewed.provider, "codex/gpt-5.6-luna")
    eq("provider: changed model drops absent features", reviewed and reviewed.featureValues.fast_mode, nil)

    vim.ui.select = function(_, _, callback)
      callback(nil)
    end
    local cancelled = false
    create.review({ cwd = "/work" }, function(selection, review_err)
      cancelled = selection == nil and review_err == nil
    end)
    truthy("provider: cancel creates nothing", vim.wait(1000, function()
      return cancelled
    end))

    local fake_chat = { agent_id = "agent", root = "/work" }
    chat.current = function()
      return fake_chat
    end
    local toggled
    session.toggle = function(id)
      toggled = id
    end
    chat.test_config = {
      provider = "codex", modeId = "auto-review",
      features = { { id = "plan_mode", type = "toggle", label = "Plan", value = false } },
      availableModes = { { id = "auto-review" } },
    }
    session.plan()
    vim.wait(1000, function()
      return toggled ~= nil
    end)
    eq("provider: Codex Plan uses feature toggle", toggled, "plan_mode")

    chat.test_config = {
      provider = "claude", modeId = "default", features = {},
      availableModes = { { id = "plan" }, { id = "default" } },
    }
    chat.load_settings = function() end
    session.plan()
    vim.wait(1000, function()
      return requests[#requests].op == "agent.setMode"
    end)
    eq("provider: Claude Plan uses its mode", requests[#requests].args.modeId, "plan")

    local header = sidebar.header {
      provider = "codex/gpt-5.6-sol", root = "/work", features = { plan_mode = true, fast_mode = true },
      feature_list = {
        { id = "fast_mode", label = "Fast", type = "toggle" },
        { id = "plan_mode", label = "Plan", type = "toggle" },
      },
    }
    local text = {}
    for _, cell in ipairs(header) do
      text[#text + 1] = cell[1]
    end
    text = table.concat(text)
    truthy("provider: header shows all enabled feature labels", text:find("Fast", 1, true) and text:find("Plan", 1, true))
  end)
  bridge.ensure, bridge.request = old_ensure, old_request
  vim.ui.select, chat.current = old_select, old_current
  session.toggle, chat.load_settings = old_toggle, old_load
  config.get().paseo.provider = old_preference
  if not ok then
    error(err)
  end
end

-- --------------------------------------------------------------------- plan
--
-- Approving a plan is TWO decisions -- build it, and with how much rope -- and
-- the dialog only ever asked the first. The daemon answered the second itself,
-- always `acceptEdits`, and there was no way to say otherwise from here.
--
-- The response cannot carry a mode (`AgentPermissionResponse` has no field for
-- one), so every Implement button carries the daemon's OWN action id and
-- differs only in the `mode` the sidecar sets afterwards. That is what these
-- assert: one approval, several answers to "and then what".

local function test_plan()
  local plan = require "paseo.ui.plan"
  local render = require "paseo.ui.render"
  local timeline = require "paseo.ui.timeline"

  -- What the daemon actually sends: kind "plan", NO detail, and the markdown
  -- in `input.plan`.
  local request = {
    id = "req-1",
    kind = "plan",
    name = "ExitPlanMode",
    title = "Ready to code?",
    description = "Rip out the old permission dialog",
    input = { plan = "## Step one\n\nRip out the old thing.\n\n## Step two\n\nPut a new one in." },
    actions = {
      { id = "reject", label = "Reject", behavior = "deny", variant = "danger", intent = "dismiss" },
      { id = "implement", label = "Implement", behavior = "allow", variant = "primary", intent = "implement" },
    },
  }

  local claude = {
    { id = "plan", label = "Plan Mode" },
    { id = "default", label = "Always Ask" },
    { id = "acceptEdits", label = "Accept File Edits" },
    { id = "auto", label = "Auto mode" },
    { id = "bypassPermissions", label = "Bypass" },
  }

  truthy("plan: a plan request is recognised by kind", plan.parse(request))
  -- By `kind`, not by `name`: mapping ExitPlanMode onto it is the daemon's
  -- job, already done, for every provider rather than just for Claude.
  truthy(
    "plan: an ordinary tool permission is not one",
    not plan.parse { kind = "tool", name = "Write", input = {} }
  )
  truthy("plan: and neither is a question", not plan.parse { kind = "question" })

  -- The plan text. `detail` is nil for these, so a dialog rendering `detail`
  -- showed an empty box and asked you to approve it.
  truthy("plan: the text comes from input.plan", plan.text(request):find("Step one", 1, true) ~= nil)
  eq(
    "plan: metadata.planText is the fallback",
    plan.text { kind = "plan", metadata = { planText = "from metadata" } },
    "from metadata"
  )
  eq(
    "plan: then description",
    plan.text { kind = "plan", description = "from description" },
    "from description"
  )
  eq("plan: and nothing at all is an empty string, not nil", plan.text { kind = "plan" }, "")

  local actions = plan.actions(request, claude)
  eq("plan: claude gets three Implement buttons and a Reject", #actions, 4)
  eq("plan: least rope first, so `y` is the cautious key", {
    actions[1].mode,
    actions[2].mode,
    actions[3].mode,
  }, { "acceptEdits", "auto", "default" })
  eq("plan: and the last one denies", actions[4].behavior, "deny")

  -- THE POINT. The daemon keys its own behaviour off `selectedActionId` and
  -- rejects an id it does not know, so all three Implements send its id and
  -- differ only by the mode applied afterwards.
  eq("plan: every Implement carries the daemon's own action id", {
    actions[1].id,
    actions[2].id,
    actions[3].id,
  }, { "implement", "implement", "implement" })

  -- Modes are per PROVIDER. codex has auto/auto-review/full-access and no
  -- `acceptEdits`, and offering it a button that cannot work would be worse
  -- than offering nothing.
  local codex = plan.actions(request, { { id = "auto", label = "Auto" }, { id = "full-access" } })
  eq("plan: a mode the provider does not have is dropped", #codex, 2)
  eq("plan: leaving the one that does exist", codex[1].mode, "auto")

  -- No modes reported means nothing honest to offer: the request's own
  -- Implement/Reject stands rather than a guess.
  truthy("plan: no reported modes falls back to the request's buttons", plan.actions(request, {}) == nil)
  truthy(
    "plan: and so does a request with no allow action to build on",
    plan.actions({ kind = "plan", actions = { { id = "reject", behavior = "deny" } } }, claude) == nil
  )

  -- The daemon offers this one only when the session was in bypassPermissions
  -- before it entered plan mode, and restores that mode SERVER-side -- so it
  -- must come through untouched, with no mode of ours attached.
  local resumable = vim.deepcopy(request)
  resumable.actions[#resumable.actions + 1] = {
    id = "implement_resume",
    label = "Implement with Bypass",
    behavior = "allow",
    intent = "implement_resume",
  }
  local resumed = plan.actions(resumable, claude)
  eq("plan: the daemon's resume button survives", #resumed, 5)
  eq("plan: with its own id", resumed[4].id, "implement_resume")
  truthy("plan: and no mode of ours attached to it", resumed[4].mode == nil)

  -- The badge otherwise reads "allowed", which for a plan is true and useless:
  -- the whole point of the four buttons is that they differ.
  eq("plan: the badge says which mode you landed in", plan.label(actions[2]), "implemented, auto")
  eq("plan: and a reject says you are still planning", plan.label(actions[4]), "rejected, still planning")

  -- Long plans are capped, and say so rather than just stopping.
  local long = { kind = "plan", input = { plan = string.rep("a line\n", 40) } }
  local capped = plan.render(long, 5)
  eq("plan: a long plan is capped", #capped, 6)
  truthy("plan: and admits what it cut", capped[6]:find("35 more lines", 1, true) ~= nil, capped[6])

  -- The inline card showed `description` -- a summary line at best -- so the
  -- record of what was approved did not contain the plan.
  local card = timeline.card({ kind = "permission", request = request }, { width = 60 })
  local text = {}
  for _, line in ipairs(card.lines) do
    text[#text + 1] = render.concat(line)
  end
  text = table.concat(text, "\n")
  truthy("plan: the inline card shows the plan itself", text:find("Step two", 1, true) ~= nil, text)
end

-- ----------------------------------------------------------------- settings
--
-- Mode, model, thinking level and usage are NOT on the timeline: the daemon
-- folds each into the agent snapshot and suppresses dispatch, so the sidecar's
-- `mode_changed` case had never once fired and a mode set in the Paseo app
-- never reached the header. These cover the Lua half -- what the plugin does
-- with a settings payload once one finally arrives.

local function test_settings()
  local chat_mod = require "paseo.ui.chat"
  local float = require "paseo.ui.float"
  local render = require "paseo.ui.render"
  local sidebar = require "paseo.ui.sidebar"

  local modes = {
    { id = "plan", label = "Plan Mode" },
    { id = "default", label = "Always Ask" },
    { id = "acceptEdits", label = "Accept File Edits" },
    { id = "auto", label = "Auto mode" },
  }
  local chat = {
    root = assert(vim.uv.cwd()),
    agent_id = "spec-settings",
    mode = "Always Ask",
    config_snapshot = {
      modeId = "default",
      availableModes = modes,
      thinkingOptions = {},
      models = {},
      features = {},
    },
  }

  -- Rebuilding the dashboard is a full volt regeneration, so count the calls.
  local rebuilds = 0
  local real_rebuild = float.rebuild
  float.rebuild = function()
    rebuilds = rebuilds + 1
  end

  chat_mod.apply_settings(chat, { agentId = "spec-settings", modeId = "auto", availableModes = modes })

  -- THE BUG: this stored the raw id, while `agent.config` stored the label, so
  -- one session read "Plan Mode" or "plan" in the header depending on which
  -- had spoken last.
  eq("settings: a pushed mode is stored as its label", chat.mode, "Auto mode")
  truthy(
    "settings: and the header says so",
    render.concat(sidebar.header(chat)):find("Auto mode", 1, true) ~= nil,
    render.concat(sidebar.header(chat))
  )
  -- The Session panel draws its `●` from the snapshot, which nothing patched:
  -- the header could report a mode the panel below it still marked elsewhere.
  eq("settings: the panel's snapshot is patched too", chat.config_snapshot.modeId, "auto")
  eq("settings: a real change redraws the panel", rebuilds, 1)

  -- This payload arrives on every usage tick -- seven times in one short turn,
  -- measured against a live daemon -- and the mode is in all of them. A panel
  -- rebuild behind each would be a regeneration per token count.
  for used = 1000, 2000, 1000 do
    chat_mod.apply_settings(chat, {
      agentId = "spec-settings",
      modeId = "auto",
      availableModes = modes,
      usage = { contextWindowUsedTokens = used, contextWindowMaxTokens = 200000 },
    })
  end
  eq("settings: an unchanged mode does not redraw it again", rebuilds, 1)
  eq("settings: but the usage still lands", chat.usage.contextWindowUsedTokens, 2000)

  -- Features are compared by VALUE, not by the table they arrived in.
  chat_mod.apply_settings(chat, {
    agentId = "spec-settings",
    features = { { id = "fast_mode", value = true } },
  })
  eq("settings: a changed feature redraws the panel", rebuilds, 2)
  chat_mod.apply_settings(chat, {
    agentId = "spec-settings",
    features = { { id = "fast_mode", value = true } },
  })
  eq("settings: the same feature again does not", rebuilds, 2)

  -- A mode the provider did not report is still better shown than dropped.
  chat_mod.apply_settings(chat, { agentId = "spec-settings", modeId = "invented", availableModes = modes })
  eq("settings: an unknown id falls back to itself", chat.mode, "invented")

  float.rebuild = real_rebuild
end

-- ------------------------------------------------------------------- follow
--
-- Auto-scroll existed and stopped working on the first block taller than three
-- lines, which is every tool card. The old test was `cursor >= line_count - 3`
-- on a window that is never focused, so the cursor was only ever where the
-- previous scroll left it: once a block outgrew the gap, it could not catch up
-- and the lock was gone for the rest of the session.

local function test_follow()
  local transcript = require "paseo.ui.transcript"

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 60,
    height = 10,
    style = "minimal",
  })
  vim.wo[win].scrolloff = 0

  local chat = { conversation = buf, win_conversation = win }
  transcript.reset(chat)

  -- Twelve lines, which is both realistic for a tool card and comfortably more
  -- than the three the old heuristic allowed.
  local lines = {}
  for i = 1, 12 do
    lines[i] = "line " .. i
  end
  local block = table.concat(lines, "\n")

  local function showing_last()
    return vim.fn.line("w$", win) >= vim.api.nvim_buf_line_count(buf)
  end

  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: the first block scrolls into view", showing_last())
  -- The old code failed HERE and never recovered.
  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: and so does a second taller than three lines", showing_last())
  for _ = 1, 3 do
    transcript.upsert(chat, { kind = "text", text = block })
  end
  truthy("follow: still following five blocks later", showing_last())

  -- Streaming is the case that matters most: `stream` re-renders the open text
  -- block on every chunk rather than appending, so following has to survive a
  -- block that grows under it.
  for i = 1, 10 do
    transcript.stream(chat, ("chunk %d\n"):format(i))
  end
  truthy("follow: a streaming reply keeps the tail in view", showing_last())

  -- Scrolling back to reread something must not be yanked away.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: scrolled up, it stays where you put it", not showing_last())

  -- And returning to the bottom resumes it, with no flag to reset.
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: and back at the bottom it picks up again", showing_last())

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
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
    { "image", test_image },
    { "registry", test_registry },
    { "ref", test_ref },
    { "workspace", test_workspace },
    { "ws init", test_ws_init },
    { "ui", test_ui },
    { "provider", test_provider_setup },
    { "questions", test_questions },
    { "plan", test_plan },
    { "follow", test_follow },
    { "settings", test_settings },
    { "strategy", test_strategy },
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
