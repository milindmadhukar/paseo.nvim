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

-- ---------------------------------------------------------------- explain

--- `:Paseo qfask` reads the PLAIN quickfix list now -- the hunk list moved out
--- to the user's config -- so the only thing it may assume is what every
--- quickfix entry has: a buffer, a line and some text. The chat is stubbed
--- because this is about what gets rendered, not about opening a window.
local function test_explain_quickfix()
  in_dir(root .. "/multi/.workspaces/otp", function()
    local attached
    local real_chat = package.loaded["paseo.ui.chat"]
    package.loaded["paseo.ui.chat"] = {
      attach = function(text, opts)
        attached = { text = text, opts = opts, via = "attach" }
      end,
      -- What `qfask` uses now: the box takes the question, then this sends.
      ask = function(prompt, opts)
        attached = { text = opts and opts.context, opts = opts, prompt = prompt, via = "ask" }
      end,
      attach_events = function() end,
    }
    -- The directory too, and not only for isolation: `siblings()` calls
    -- `agents.watch()`, which would spawn the real sidecar here and break the
    -- bridge suite's "not running before it is started".
    local real_agents = package.loaded["paseo.agents"]
    package.loaded["paseo.agents"] = {
      watch = function() end,
      for_root = function()
        return {
          { id = "ag_theirs", title = "otp flow", provider = "p/m", status = "idle" },
          { id = "ag_ours", title = "paseo.nvim review", labels = { ["paseo.nvim"] = "review" } },
        }
      end,
    }
    package.loaded["paseo.explain"] = nil

    local ok, err = pcall(function()
      local repos = require "paseo.repos"
      local git = require "paseo.git"

      local items = {}
      for _, repo in ipairs(repos.list()) do
        for _, hunk in ipairs(git.hunks(repo)) do
          items[#items + 1] = {
            filename = vim.fs.joinpath(repo.worktree, hunk.path),
            lnum = hunk.lnum,
            text = ("+%d -%d"):format(hunk.added, hunk.removed),
          }
        end
      end
      truthy("explain: the fixture produced hunks to list", #items >= 2, "items: " .. #items)
      vim.fn.setqflist({}, " ", { title = "spec", items = items })

      require("paseo.explain").quickfix()

      -- The box, not the chat: `qfask` asks what you want to know before it
      -- opens anything. Nothing is sent until it is answered.
      truthy(
        "explain: the ask box opens rather than the chat",
        require("paseo.ui.prompt").is_open()
      )
      truthy("explain: and nothing is sent until it is answered", attached == nil)

      vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "what broke?" })
      vim.cmd "stopinsert"
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      vim.wait(300, function()
        return attached ~= nil
      end)

      truthy("explain: answering the box sends", attached ~= nil)
      eq("explain: the question is the prompt", attached and attached.prompt, "what broke?")
      eq("explain: and the list rides along as context", attached and attached.via, "ask")
      if attached then
        truthy(
          "explain: paths are ABSOLUTE, so entries from sibling worktrees resolve",
          attached.text:find "\n%- /.*f%.txt:%d+" ~= nil,
          attached.text
        )
        truthy(
          "explain: the root is a worktree the entries came from",
          attached.opts and attached.opts.root ~= nil and vim.startswith(attached.opts.root, root)
            or false,
          vim.inspect(attached.opts)
        )
        truthy(
          "explain: sibling agents are listed for the review agent to ask",
          attached.text:find "ag_theirs" ~= nil,
          attached.text
        )
        truthy(
          "explain: but not paseo.nvim's own agents -- that would be a loop",
          attached.text:find "ag_ours" == nil,
          attached.text
        )
      end

      -- An empty list must not even open the box.
      attached = nil
      vim.fn.setqflist({}, " ", { title = "spec", items = {} })
      require("paseo.explain").quickfix()
      truthy("explain: an empty quickfix list sends nothing", attached == nil)
      truthy("explain: and does not open the box either", not require("paseo.ui.prompt").is_open())
    end)

    package.loaded["paseo.agents"] = real_agents
    package.loaded["paseo.ui.chat"] = real_chat
    package.loaded["paseo.explain"] = nil
    vim.fn.setqflist({}, " ", { title = "spec", items = {} })
    if not ok then
      error(err, 0)
    end
  end)
end

-- ---------------------------------------------------------------- prompt

--- The ask box. It is a WINDOW, not a blocking prompt, so every exit has to
--- answer the caller exactly once -- including the ones nobody chose.
local function test_prompt()
  local prompt = require "paseo.ui.prompt"

  local function box(fn)
    local got, calls = "unset", 0
    prompt.open({ title = "app/main.py:42" }, function(q)
      calls = calls + 1
      got = q
    end)
    local buf = vim.api.nvim_get_current_buf()
    fn(buf)
    vim.wait(200, function()
      return calls > 0
    end)
    return got, calls
  end

  -- NOT `vim.ui.input`: a one-line field cannot hold a question with a blank
  -- line in it and throws away your insert-mode keymaps and undo.
  prompt.open({ title = "x" }, function() end)
  local buf = vim.api.nvim_get_current_buf()
  truthy("prompt: the box is a real, modifiable buffer", vim.bo[buf].modifiable)
  eq("prompt: with the composer's filetype, so your keymaps work", vim.bo[buf].filetype, "markdown")
  local cfg = vim.api.nvim_win_get_config(0)
  eq("prompt: floating over the editor", cfg.relative, "editor")
  -- Above the dashboard's 30, below the permission dialog's 200: a permission
  -- request must never come up behind a box you are typing in.
  truthy(
    "prompt: z-index sits above the dashboard, below the dialog",
    cfg.zindex > 30 and cfg.zindex < 200,
    tostring(cfg.zindex)
  )
  vim.api.nvim_win_close(0, true)
  vim.wait(100)

  local text, calls = box(function(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "why is this here?", "", "second paragraph" })
    vim.cmd "stopinsert"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end)
  eq(
    "prompt: <CR> sends the question, blank lines and all",
    text,
    "why is this here?\n\nsecond paragraph"
  )
  eq("prompt: and answers the caller exactly once", calls, 1)

  -- Grows with the question: "why?" and a paragraph are different shapes, and
  -- a fixed height makes one of them unreadable.
  prompt.open({ title = "x" }, function() end)
  local grow = vim.api.nvim_get_current_buf()
  local before = vim.api.nvim_win_get_config(0).height
  vim.api.nvim_buf_set_lines(grow, 0, -1, false, vim.split(("l\n"):rep(40), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = grow })
  local after = vim.api.nvim_win_get_config(0).height
  truthy(
    "prompt: the box grows with the question",
    after > before,
    ("%d -> %d"):format(before, after)
  )
  truthy("prompt: but is capped, not unbounded", after <= 14, tostring(after))
  vim.api.nvim_win_close(0, true)
  vim.wait(100)

  -- An empty box is a cancel. Sending one costs a turn and gets you "what
  -- would you like to know?".
  local empty, empty_calls = box(function(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "", "   " })
    vim.cmd "stopinsert"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end)
  eq("prompt: an empty box cancels rather than sending nothing", empty, nil)
  eq("prompt: and still answers the caller", empty_calls, 1)

  local escaped, esc_calls = box(function(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "never mind" })
    vim.cmd "stopinsert"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  end)
  eq("prompt: <Esc> cancels and throws the draft away", escaped, nil)
  eq("prompt: answering the caller, not leaving it hanging", esc_calls, 1)

  -- THE ONE THAT BITES: closed by `:q` or a window command rather than by a
  -- key we bound. Without the WinClosed guard the reference is queued and
  -- nothing ever sends it.
  local closed, closed_calls = box(function()
    vim.cmd "stopinsert"
    vim.api.nvim_win_close(0, true)
  end)
  eq("prompt: a window closed from outside still cancels", closed, nil)
  eq("prompt: exactly once", closed_calls, 1)

  truthy("prompt: nothing is left open", not prompt.is_open())
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
    truthy(
      "bridge: the write path gives up once the pipe is broken",
      source:find("if (broken) return", 1, true) ~= nil
    )
    truthy(
      "bridge: and the error handler does not write into a broken pipe",
      source:find("if (broken || bailing) return", 1, true) ~= nil
    )
    -- On bun -- which is the runtime `runtime()` picks -- the watchdog is the
    -- ONLY thing that exits: bun delivers stdin EOF before the stdout error,
    -- so the write that would trip the broken flag never happens. Deleting
    -- this because node exits without it regresses every bun user to a
    -- permanently hung orphan.
    truthy(
      "bridge: and shutdown has a deadline",
      source:find("setTimeout(() => process.exit(code)", 1, true) ~= nil
    )
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
    truthy(
      "bridge: stop() closes stdin whatever the sidecar says",
      source:find("handle:write(nil)", 1, true) ~= nil
    )
    truthy(
      "bridge: stop() does not wait for a reply to kill",
      source:find("handle:kill(15)", 1, true) ~= nil
    )
    -- Two ensure() calls during an autostart used to spawn two sidecars and
    -- orphan the first.
    truthy(
      "bridge: a boot in flight is not started twice",
      source:find("if state.starting then", 1, true) ~= nil
    )
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

  -- A fresh tab, so nothing another suite left current can set 'winfixbuf' on
  -- us -- that makes :edit fail with E1513.
  vim.cmd "tabnew"
  vim.cmd.edit(vim.fn.fnameescape(loose))
  local file = ref.file()
  truthy("ref: a file outside any git repo still yields a reference", file ~= nil)
  eq("ref: and it has no repo", file and file.repo, nil)
  eq("ref: its root is the file's directory", file and file.root, vim.fs.dirname(loose))
  truthy(
    "ref: render() does not require a repo",
    file and ref.render(file):find(loose, 1, true) ~= nil
  )
  -- The prompt names the file and stops. Inlining made it scale with whatever
  -- you asked about -- a long hunk, or a new file, which gitsigns reports as
  -- one all-added hunk and which therefore pasted the file in whole.
  truthy(
    "ref: render() points at the file rather than quoting it",
    file and ref.render(file):find("alpha", 1, true) == nil,
    file and ref.render(file)
  )
  truthy(
    "ref: and gives an ABSOLUTE path -- `path` is workspace-relative, `root` is not",
    file and ref.render(file):find(vim.fn.fnamemodify(loose, ":p"), 1, true) ~= nil
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

  -- THE ONE CARVE-OUT, tested on a hand-built ref because driving a real
  -- deletion needs gitsigns attached asynchronously to a fixture repo.
  --
  -- A pure deletion's lines are not in the file, so "go and read it" sends the
  -- agent to the code that SURVIVED -- `lnum` is the line ABOVE the removed
  -- block -- and it explains the wrong thing confidently. Those lines are the
  -- one thing that must still be quoted.
  local deleted = {
    repo = nil,
    root = "/tmp",
    path = "app/main.py",
    abs = "/tmp/app/main.py",
    lnum = 42,
    end_lnum = 42,
    lines = { "@@ -42,2 +42,0 @@", "-gone", "-also gone" },
    detached = true,
    modified = false,
    kind = "hunk",
  }
  local rendered = ref.render(deleted)
  truthy(
    "ref: a deleted hunk is still quoted -- it is not in the file to read",
    rendered:find("-also gone", 1, true) ~= nil,
    rendered
  )
  truthy(
    "ref: and is fenced as a diff, not as the file's language",
    rendered:find("```diff", 1, true) ~= nil,
    rendered
  )
  truthy(
    "ref: and says the line is ABOVE the removed block, not the removal",
    rendered:find("ABOVE", 1, true) ~= nil,
    rendered
  )

  deleted.detached = false
  deleted.modified = true
  local live = ref.render(deleted)
  truthy(
    "ref: an attached hunk is a location, not a quotation",
    live:find("gone", 1, true) == nil,
    live
  )
  truthy(
    "ref: an unsaved buffer is declared, since the agent reads disk",
    live:find("unsaved changes", 1, true) ~= nil,
    live
  )

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
  --
  -- Pinned to a FRAMED style. The width invariant is a property of having a
  -- right-hand border to line up: an unframed card has no right edge, and
  -- padding one to full width would put trailing whitespace on every line of a
  -- buffer the user yanks out of. That is asserted separately below.
  local card = render.card(
    { { "Shell", "PaseoToolOk" } },
    { { { "ls -la" } }, { { "a.txt" } } },
    { width = 40, kind = "rounded" }
  )
  local ragged
  for _, line in ipairs(card) do
    if render.width(line) ~= 40 then
      ragged = render.concat(line)
    end
  end
  eq("ui: every framed card line is exactly the requested width", ragged, nil)

  -- Found by real agent history, not by a fixture: a multi-line shell command
  -- comes back with newlines in `display.summary`, and nvim_buf_set_lines
  -- rejects a line containing one ("'replacement string' item contains
  -- newlines"). A single heredoc in a transcript was enough to hit it.
  local newline_card = render.card(
    { { "Shell", "PaseoToolName" }, { "cat <<EOF\nhello\nEOF", "PaseoToolArg" } },
    {},
    { width = 50, kind = "rounded" }
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
    { width = 60, kind = "rounded" }
  )
  local widths = {}
  for _, line in ipairs(long) do
    widths[#widths + 1] = render.width(line)
  end
  eq("ui: a truncated header does not overflow the card", widths, { 60, 60, 60 })

  -- Every style has to hold two invariants, whatever it does in between: a
  -- collapsed card is one line, and nothing overflows the width it was given.
  -- Those are the two that break the transcript rather than merely looking
  -- wrong -- an over-wide line soft-wraps and a multi-line "collapsed" card
  -- makes a fold of one fact.
  for _, kind in ipairs { "plate", "rule", "rounded", "square" } do
    eq(
      "ui: a card with no body is a single line -- " .. kind,
      #render.card({ { "x" } }, {}, { width = 40, kind = kind }),
      1
    )

    local over
    for _, line in
      ipairs(
        render.card(
          { { string.rep("x", 400) } },
          { { { string.rep("y", 400) } }, { { "short" } } },
          { width = 40, kind = kind }
        )
      )
    do
      if render.width(line) > 40 then
        over = render.width(line)
      end
    end
    eq("ui: no card line overflows its width -- " .. kind, over, nil)
  end

  -- An unframed card must NOT pad: these lines are real buffer text, and
  -- trailing whitespace on every row of a tool card is whitespace in whatever
  -- the reader yanks out of the transcript.
  local unpadded
  for _, line in
    ipairs(render.card({ { "Shell" } }, { { { "ls -la" } } }, { width = 40, kind = "plate" }))
  do
    if render.concat(line):match "%s$" then
      unpadded = render.concat(line)
    end
  end
  eq("ui: an unframed card does not pad to width", unpadded, nil)

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

  -- The one detail type with no arm, on exactly the operation you most want to
  -- watch: an expanded worktree-setup card used to be a header and nothing
  -- else, so a setup command that failed left a worktree you cannot build in
  -- and no way to see which command did it.
  local setup = table.concat(
    vim.tbl_map(
      render.concat,
      timeline.detail_body({
        type = "worktree_setup",
        worktreePath = "/tmp/wt",
        branchName = "ws/thing",
        commands = {
          { index = 1, command = "bun install", status = "completed", exitCode = 0 },
          { index = 2, command = "bun run build", status = "failed", exitCode = 2 },
        },
      }, 60)
    ),
    "\n"
  )
  truthy("ui: a worktree setup names its branch", setup:find("ws/thing", 1, true) ~= nil)
  truthy("ui: and each command it ran", setup:find("bun run build", 1, true) ~= nil)
  truthy("ui: and how the failing one failed", setup:find("exit 2", 1, true) ~= nil)

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

  -- A command is open WHILE it runs, under the default `ui.expand = "running"`.
  -- Watching the output arrive is the whole reason to have this window open;
  -- a card that hides it until you press <Tab> is a card that tells you the
  -- agent is busy and nothing else.
  truthy(
    "ui: a running command shows its output as it arrives",
    chat.blocks[chat.by_call["call-1"]].expanded
  )

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
  -- transcript twice. The transcript must therefore get SHORTER here -- the
  -- card folds on success -- and never longer.
  truthy(
    "ui: a completing tool call replaces its card rather than appending",
    vim.api.nvim_buf_line_count(chat.conversation) < before
  )
  truthy("ui: and folds once it has succeeded", not chat.blocks[chat.by_call["call-1"]].expanded)
  local blocks = 0
  for _ in pairs(chat.blocks) do
    blocks = blocks + 1
  end
  eq("ui: and does not create a second block", blocks, 4)

  local joined = table.concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
  -- Named through the registry, not pasted in. A literal glyph in a test is
  -- the same fragile thing as a literal glyph in the source -- and when the
  -- source one went missing, a test holding its own copy would have gone on
  -- passing while the card drew nothing.
  local glyphs = require "paseo.ui.icons"
  truthy(
    "ui: the completed card shows its terminal status",
    joined:find(glyphs.status.completed, 1, true) ~= nil
  )
  truthy(
    "ui: and no longer shows the running one",
    joined:find(glyphs.status.running, 1, true) == nil
  )

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
    table
      .concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("a.txt", 1, true) ~= nil
  )
  eq(
    "ui: anchors survive a block changing height",
    #vim.api.nvim_buf_get_extmarks(chat.conversation, require("paseo.ui.hl").ns_anchor, 0, -1, {}),
    4
  )

  -- THE BUG THAT MADE EVERY TOOL CARD INVISIBLE, at the only place it was
  -- observable: the shape of the line the sidecar actually writes.
  --
  -- Every other assertion in this file hand-builds an item with `kind` set,
  -- which is exactly why the suite stayed green while the live transcript
  -- rendered nothing at all -- the sidecar used `kind` as the event NAME and
  -- destructured it off the payload, and the renderer dispatches on
  -- `item.kind`. So this one asserts against the wire and not against a
  -- convenient fixture.
  local wire = vim.json.decode(
    '{"event":"tool","agentId":"a","kind":"tool","callId":"wire-1","name":"Bash",'
      .. '"status":"completed","display":{"displayName":"Shell","summary":"echo hi"},'
      .. '"detail":{"type":"shell","command":"echo hi","output":"hi","exitCode":0}}'
  )
  local wire_before = vim.api.nvim_buf_line_count(chat.conversation)
  transcript.upsert(chat, wire)
  truthy(
    "ui: an item in the sidecar's own wire shape renders",
    vim.api.nvim_buf_line_count(chat.conversation) > wire_before
  )

  -- A card you opened by hand is yours. It must not snap shut under you the
  -- moment the command finishes, which is precisely when you are reading it.
  local pinned = chat.blocks[chat.by_call["wire-1"]]
  pinned.expanded = true
  pinned.pinned = true
  transcript.rerender(chat, pinned, vim.tbl_extend("force", wire, { status = "completed" }))
  truthy("ui: a card you opened by hand stays open", pinned.expanded)

  -- `replaced` invalidates the epoch. It was emitted by the sidecar and
  -- listened to by nobody, so a replacement left stale messages on screen.
  chat.permissions = { { id = "req-1" } }
  chat.permission_blocks = { ["req-1"] = 99 }
  transcript.reset(chat)
  eq("ui: reset empties the transcript", vim.api.nvim_buf_line_count(chat.conversation), 1)
  eq("ui: and drops the callId map", next(chat.by_call), nil)
  -- The permission bookkeeping points at blocks that just went away. Left
  -- behind, it named block ids that no longer exist -- so the resolution badge
  -- could never be written -- and made the re-offer that follows a reset hit
  -- the de-duplicate and drop the inline card for good.
  eq("ui: reset drops the held permissions", next(chat.permissions), nil)
  eq("ui: and the blocks they pointed at", next(chat.permission_blocks), nil)

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
  eq("ui: the cursor lands in the composer", vim.api.nvim_get_current_buf(), surface_chat.composer)
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
  truthy("ui: and the conversation's", mapping(surface_chat.conversation, "1") == nil)

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
    local marks = vim.api.nvim_buf_get_extmarks(
      chrome_buf,
      -1,
      { 0, 0 },
      { 1, -1 },
      { details = true }
    )
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
    -- Every tab's NUMBER, at every width. The bar degrades from name+icon to
    -- name, to icon, to bare number as the terminal narrows, and the number is
    -- the one thing it must never drop -- it is the only place that says which
    -- key goes where, and the tab that would fall off the end is always the
    -- last one, which is the one you had not discovered yet.
    local unnumbered = {}
    for i = 1, #require("paseo.ui.float").TABS do
      if not drawn:find(" " .. i .. " ", 1, true) then
        unnumbered[#unnumbered + 1] = i
      end
    end
    eq("ui: every tab keeps its number however narrow the bar gets", unnumbered, {}, drawn)

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
  -- Every glyph in the registry has to BE something, and the check has to walk
  -- the WHOLE registry rather than the four markers it used to.
  --
  -- This has now happened twice. `check_on`/`check_off` were empty strings --
  -- the codepoints had been lost out of the file -- so the Session panel's
  -- feature toggles drew no marker at all and "off" was indistinguishable from
  -- "not drawn". That got fixed, and a test was added covering exactly those
  -- four names; meanwhile six slots in `render.icons`, the `permission` marker
  -- in the Sessions panel, two group icons and five inline glyphs elsewhere
  -- were empty the entire time, and the suite stayed green.
  --
  -- An empty icon is not a visible failure: the line still draws. So the check
  -- is width, over everything, with no list to keep in step.
  local registry = require "paseo.ui.icons"
  local blank = {}
  for name, glyph in pairs(registry.all()) do
    if vim.api.nvim_strwidth(glyph) < 1 then
      blank[#blank + 1] = name
    end
  end
  table.sort(blank)
  eq("ui: no glyph in the registry is empty", blank, {})

  -- The two selection markers additionally have to be exactly ONE cell. They
  -- are drawn in fixed-width rows, and a two-cell marker shifts everything to
  -- its right by a column on precisely the rows that are selected.
  for _, name in ipairs { "check_on", "check_off", "radio_on", "radio_off" } do
    eq(
      "ui: the " .. name .. " marker is exactly one cell",
      vim.api.nvim_strwidth(widgets.icons[name] or ""),
      1
    )
  end

  -- A key is spelled the way a keyboard spells it, and anything unrecognised
  -- comes back UNCHANGED rather than empty -- a hint bar that silently drops
  -- the key it is describing is worse than one that prints `<Plug>foo`.
  eq("ui: a chord is spelled out", registry.spell "<C-f>", "Ctrl + f")
  eq("ui: a bare key is left alone", registry.spell "q", "q")
  eq("ui: an unknown special key survives", registry.spell "<Plug>foo", "<Plug>foo")

  -- ----------------------------------------------------------------- style

  -- Every style has to produce the SAME number of rows for the same content.
  -- volt records a section's start row when the layout is measured and never
  -- recomputes it on redraw, so a card whose height depended on the frame
  -- would move every section below it the moment `ui.style` changed -- and
  -- two cards paired side by side would stop squaring up.
  local style = require "paseo.ui.style"
  local heights = {}
  for _, kind in ipairs(style.CARDS) do
    heights[#heights + 1] = #widgets.card {
      title = "Title",
      w = 40,
      kind = kind,
      lines = { { { "one" } }, { { "two" } }, { { "three" } } },
    }
  end
  eq("ui: every card style is the same height", heights, { 5, 5, 5, 5 })

  local widths = {}
  for _, kind in ipairs(style.CARDS) do
    for _, line in
      ipairs(widgets.card {
        title = "Title",
        w = 40,
        kind = kind,
        lines = { { { string.rep("z", 200) } } },
      })
    do
      if render.width(line) ~= 40 then
        widths[#widths + 1] = kind .. ":" .. render.width(line)
      end
    end
  end
  eq("ui: every panel card row is exactly its width", widths, {})

  -- A preset name and the table form have to mean the same thing, and a table
  -- only has to name what it changes.
  eq("ui: a preset resolves", style.resolve "rounded", { card = "rounded", border = "rounded" })
  eq(
    "ui: a table layers over its preset",
    style.resolve { preset = "rounded", border = "none" },
    { card = "rounded", border = "none" }
  )
  eq(
    "ui: nothing resolves to the default",
    style.resolve(nil),
    { card = "plate", border = "invisible" }
  )
  truthy("ui: a known preset validates", style.valid "square")
  truthy("ui: an unknown preset does not", not style.valid "hexagonal")
  truthy("ui: an unknown card does not", not style.valid { card = "hexagonal" })
  -- "invisible" keeps a real border and paints it fg == bg. Dropping the
  -- border instead would take its one cell of padding with it and put the
  -- content hard against the window edge.
  eq(
    "ui: an invisible border is still a border",
    (style.window_border { border = "invisible" }),
    "rounded"
  )

  -- ----------------------------------------------------------------- theme

  -- The elevation ladder has to actually STEP, in the right direction, or
  -- every "raised" surface washes into the one under it. Light themes step the
  -- other way; that sign is the whole reason this is derived rather than
  -- written down.
  local theme = require "paseo.ui.theme"
  local previous_bg = vim.o.background
  for _, background in ipairs { "dark", "light" } do
    vim.o.background = background
    local t = theme.derive()
    if t.opaque then
      local seen, duplicate = {}, nil
      for _, tier in ipairs { "bg0", "bg1", "bg2", "bg3", "bg4" } do
        if seen[t.bg[tier]] then
          duplicate = tier
        end
        seen[t.bg[tier]] = true
      end
      eq("ui: the " .. background .. " elevation ladder has five distinct tiers", duplicate, nil)
      eq("ui: and it steps " .. background, t.sign, background == "dark" and 1 or -1)
    end

    -- An accent used as text has to be legible on the plate it sits on. This
    -- is measured rather than assumed: `morning`'s "added" is #90ee90, which
    -- is unreadable on a plate tinted with that same green, while `default`'s
    -- is already dark enough that pushing it further lands on black.
    local groups = theme.groups()
    local illegible = {}
    for _, name in ipairs {
      "PaseoChipOn",
      "PaseoChipFocus",
      "PaseoChipWarn",
      "PaseoChipDanger",
      "PaseoKeycap",
      "PaseoGreenTile",
      "PaseoRedTile",
      "PaseoBlueTile",
      "PaseoYellowTile",
    } do
      local group = groups[name]
      if group.bg and theme.contrast(group.fg, group.bg) < theme.MIN_CONTRAST then
        illegible[#illegible + 1] = name
      end
    end
    eq("ui: every " .. background .. " plate is legible", illegible, {})
  end
  vim.o.background = previous_bg

  -- A colour already clear of the target is left exactly alone -- a theme that
  -- had its accents right keeps them.
  eq("ui: a legible colour is untouched", theme.readable("#ffffff", "#000000", 3.2), "#ffffff")

  -- Three rules that only a real colourscheme can break, so they are checked
  -- against several. All three were found by looking at `morning`.
  local scheme_before = vim.g.colors_name
  for _, scheme in ipairs { "habamax", "morning", "default", "desert" } do
    if pcall(vim.cmd.colorscheme, scheme) then
      local c = theme.palette()

      -- 1. Dim has to be DIMMER than body text. `morning` sets `Comment` to
      -- pure blue against a black `Normal`, so every quiet label came out
      -- louder than the words it was qualifying.
      truthy(
        "ui: dim text recedes behind body text on " .. scheme,
        theme.contrast(c.grey, c.bg) <= theme.contrast(c.text, c.bg),
        ("grey %s (%.1f) vs text %s (%.1f)"):format(
          c.grey,
          theme.contrast(c.grey, c.bg),
          c.text,
          theme.contrast(c.text, c.bg)
        )
      )

      -- 2. ...and it has to be chrome-coloured, not syntax-coloured. A
      -- saturated comment colour is quiet by luminance and loud by saturation,
      -- which is the half a contrast check does not catch.
      truthy(
        "ui: dim text is neutral on " .. scheme,
        theme.saturation(c.grey) <= theme.MAX_CHROME_SATURATION,
        ("%s at %.2f"):format(c.grey, theme.saturation(c.grey))
      )

      -- 3. "Green" has to be green. Sourcing it from `String` meant that on
      -- `morning` a tool that SUCCEEDED was drawn in magenta -- the colour of
      -- a string literal, which is not a shade of "it worked". `Added` means
      -- what we mean; `String` only happens to.
      local hue = select(1, require("volt.color").hex2hsl(c.green))
      truthy(
        "ui: the success accent is actually green on " .. scheme,
        hue >= 60 and hue <= 190,
        ("%s at hue %.0f"):format(c.green, hue)
      )
    end
  end
  if scheme_before then
    pcall(vim.cmd.colorscheme, scheme_before)
  end

  -- A bar's track is the ABSENCE of fill, so it is derived from the background
  -- rather than from the comment colour. On `morning` a comment-derived track
  -- came out pale blue and a 42% bar looked full.
  local track = vim.api.nvim_get_hl(0, { name = "PaseoTrack" })
  truthy("ui: the bar track is defined", track.fg ~= nil)

  -- ---------------------------------------------------------------- layout

  -- The chrome's row budget was three independent copies of the same
  -- arithmetic -- `g.height - 4` in one place, `g.row + 3` in another, and a
  -- bare `row - 5` in a third to turn a cursor line into a list index. The one
  -- that got missed would not error; it would put the click targets a row off.
  local layout = require "paseo.ui.layout"
  for _, height in ipairs { 24, 40, 60 } do
    local rows = layout.rows(height)
    eq("ui: the body gets height - 4 rows at " .. height, rows.body_height, height - 4)
    eq("ui: the footer owns the last row at " .. height, rows.footer, height)
    eq("ui: the body ends above it at " .. height, rows.body_last, height - 1)

    local g = { row = 2, col = 3, width = 100, height = height, composer = 7 }
    local panes = layout.panes(g)
    eq("ui: the panes start below the rule at " .. height, panes.top, g.row + 3)
    -- The composer's bottom border lands ON the last body row, never on the
    -- footer.
    eq(
      "ui: the composer's border lands on the last body row at " .. height,
      panes.composer_row + panes.composer,
      layout.screen_row(g, rows.body_last)
    )
  end

  -- Two rows of chrome plus the panel's own heading. `item_at` returns nil
  -- above the list rather than a zero or a negative, so a click on the heading
  -- is "nothing", not "the item before the first one".
  eq("ui: a cursor row maps to a list index", layout.item_at(8, 2), 3)
  eq("ui: the first item is index 1", layout.item_at(6, 2), 1)
  eq("ui: above the list is nothing", layout.item_at(4, 2), nil)

  -- --------------------------------------------------------------- animate

  local animate = require "paseo.ui.animate"
  local scratch = vim.api.nvim_create_buf(false, true)

  -- `animate = false` has to be INSTANT, not fast: a tween that still eases
  -- when motion is off is motion.
  require("paseo.config").setup { ui = { animate = false } }
  eq("ui: motion off reports disabled", animate.enabled "bars", false)
  eq(
    "ui: motion off returns the target immediately",
    animate.tween { key = "t.off", buf = scratch, section = "body", target = 73 },
    73
  )
  eq("ui: motion off never reveals partially", animate.revealed("t.off", 12), 12)

  require("paseo.config").setup {}

  -- The FIRST sight of a value is not a transition. Animating from zero on the
  -- first draw makes every panel open by sweeping its bars up, which is a lot
  -- of motion to say nothing.
  eq(
    "ui: a first value is not animated",
    animate.tween { key = "t.first", buf = scratch, section = "body", target = 61 },
    61
  )

  -- A reveal may only ever draw FEWER rows, never more. volt records a
  -- section's start row when the layout is measured and never recomputes it,
  -- so a reveal that grew past the block's final height would draw every
  -- section below it at the wrong row -- which surfaces as
  -- `Invalid 'line': out of range` thrown from inside `vim.on_key`.
  animate.reveal { key = "t.reveal", buf = scratch, section = "body" }
  local shown = animate.revealed("t.reveal", 20)
  truthy(
    "ui: a reveal never draws more rows than it was given",
    shown >= 1 and shown <= 20,
    tostring(shown)
  )

  -- The two effects are independent. `reveal` used to delegate to `flash` --
  -- same machine, a start time and a repaint clock -- and picked up its gate
  -- along with it, so turning flash off silently turned reveal off too.
  require("paseo.config").setup {
    ui = { animate = { flash = false, reveal = true, bars = true, fps = 30 } },
  }
  animate.reveal { key = "t.indep", buf = scratch, section = "body" }
  truthy("ui: reveal still runs with flash off", animate.revealed("t.indep", 20) < 20)
  animate.flash { key = "t.indep.flash", buf = scratch, section = "body" }
  eq("ui: and flash stays off", animate.flash_stop "t.indep.flash", nil)
  require("paseo.config").setup {}

  -- Tearing down must not throw. Every live effect holds a `uv` timer, which
  -- is userdata -- so the obvious `vim.deepcopy(live)` to iterate safely over
  -- a table being mutated raises "Cannot deepcopy object of type userdata",
  -- from inside the dashboard's close path.
  animate.flash { key = "t.flash", buf = scratch, section = "body" }
  local torn = pcall(animate.stop_all)
  truthy("ui: stopping every effect does not throw", torn)
  eq("ui: and a stopped flash reports no stop", animate.flash_stop "t.flash", nil)

  -- --------------------------------------------------------------- widgets

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
    eq(
      "settings: the buffer is as long as the layout volt measured",
      drawn,
      require("volt.state")[squeezed].h
    )
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
  truthy(
    "settings: dropping ten models shrinks the buffer",
    after < before,
    before .. " -> " .. after
  )

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
  truthy("ui: whose z-index is below the 50 a float gets by default", defaults.ui.float.zindex < 50)

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
  truthy(
    "ui: and shouts when something is waiting on you",
    header:find("needs you", 1, true) ~= nil
  )

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
  local root_dir =
    vim.fs.dirname(vim.api.nvim_get_runtime_file("lua/paseo/ui/render.lua", false)[1])
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

  -- The overlay's architecture, pinned so it cannot quietly re-couple. It draws
  -- its own card and OWNS its child windows, so `volt.mappings` -- which binds
  -- `q`/`<Esc>` to a teardown that knows nothing about them -- would leave the
  -- answer box behind. It takes callbacks rather than reaching for the daemon,
  -- which is what keeps `permission -> ask` one-way and lets the spec above drive
  -- it with stubs. And it types into a real buffer, which is the whole point of
  -- the inline box over the `vim.ui.input` it replaced.
  ---Source with the comments taken out. These modules EXPLAIN what they refuse to
  ---do -- `ask.lua` says in prose why `volt.mappings` and `vim.ui.input` are the
  ---wrong tools -- and a grep over the prose finds the words it is looking for in
  ---the sentence saying they are absent.
  ---@param path string
  ---@return string|nil
  local function code_of(path)
    local text = source_of(path)
    if not text then
      return nil
    end
    local kept = {}
    for line in (text .. "\n"):gmatch "(.-)\n" do
      if not line:match "^%s*%-%-" then
        kept[#kept + 1] = line
      end
    end
    return table.concat(kept, "\n")
  end

  local ask_source = code_of "lua/paseo/ui/answer.lua"
  if ask_source then
    truthy(
      "ui: the ask overlay never hands its teardown to volt",
      ask_source:find("volt.mappings", 1, true) == nil
    )
    truthy("ui: nor talks to the daemon itself", ask_source:find("paseo.bridge", 1, true) == nil)
    truthy(
      "ui: and answers in a buffer rather than a prompt",
      ask_source:find("vim.ui.input", 1, true) == nil
    )
  end
  local permission_source = code_of "lua/paseo/ui/permission.lua"
  if permission_source then
    truthy(
      "ui: and the dialog it was carved out of no longer prompts either",
      permission_source:find("vim.ui.input", 1, true) == nil
    )
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
  truthy("ui: so volt stripping the actions cannot reach ours", source_line[1][3] ~= nil)
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

-- ----------------------------------------------------------- opening a ws

--- Opening a workspace happens IN THIS NEOVIM.
---
--- It used to spawn a Neovide window whenever one could be spawned, which is
--- one person's setup: a terminal Neovim has no GUI to spawn and `<CR>` looked
--- like it did nothing. The spawn is still available -- as a function you
--- write -- and everything here is about that seam holding.
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
  vim.fn.delete(dir, "rf")
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
  eq(
    "questions: a tool permission is not a question",
    questions.parse {
      kind = "tool",
      name = "Write",
      input = { file_path = "/tmp/x", content = "y" },
    },
    nil
  )

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
  eq(
    "questions: answers are keyed by the question text",
    input.answers["Which ones apply?"],
    "A, B"
  )
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

  -- `typed` is what tells a picked LABEL apart from typed text, which the
  -- overlay needs to know to draw them in different places.
  eq("questions: a picked label is not a typed answer", #questions.typed(both[1], { "A" }), 0)
  eq(
    "questions: and anything that is not a label is",
    questions.typed(both[1], { "A", "something else" })[1],
    "something else"
  )

  -- Skipping. Only where the question says nothing is an acceptable answer, and
  -- it CLEARS rather than leaving a half-answer behind.
  local skipping = questions.state(both)
  questions.choose(skipping, 1)
  eq("questions: a required question cannot be skipped", questions.skip(skipping), false)
  eq("questions: and skipping it changes nothing", #skipping.picked[1], 1)
  questions.move(skipping, 1)
  questions.write(skipping, "never mind")
  eq("questions: an optional one can be", questions.skip(skipping), true)
  eq("questions: and the skip clears what was there", #skipping.picked[2], 0)

  -- Answering out of ORDER still reports the first gap, which is what the
  -- overlay's <CR> jumps to.
  local gapped = questions.state(both)
  questions.move(gapped, 1)
  questions.write(gapped, "later one")
  eq("questions: the first gap is what is missing, not the last", questions.missing(gapped), 1)

  -- Single-select replaces and moves on: there is nothing else to say.
  local single = questions.state(one)
  questions.choose(single, 2)
  questions.choose(single, 1)
  eq(
    "questions: single-select replaces rather than accumulating",
    questions.answers(single)[1],
    "Rebase"
  )

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
  truthy(
    "questions: the inline card shows the second question too",
    text:find("Optional comment", 1, true) ~= nil,
    text
  )
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
  local catalogue = {
    entries = {
      {
        provider = "claude",
        status = "ready",
        label = "Claude",
        defaultModeId = "default",
        modes = { { id = "plan", label = "Plan" }, { id = "default", label = "Ask" } },
        models = { { id = "opus", label = "Opus", isDefault = true } },
      },
      {
        provider = "codex",
        status = "ready",
        label = "Codex",
        defaultModeId = "auto-review",
        modes = { { id = "auto-review", label = "Auto-review" } },
        models = {
          {
            id = "gpt-5.6-sol",
            label = "GPT-5.6-Sol",
            isDefault = true,
            thinkingOptions = { { id = "high", label = "High", isDefault = true } },
          },
          {
            id = "gpt-5.6-luna",
            label = "GPT-5.6-Luna",
            thinkingOptions = { { id = "medium", label = "Medium", isDefault = true } },
          },
        },
      },
    },
  }
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
        callback(nil, {
          features = args.provider:find("luna", 1, true)
              and { { id = "plan_mode", type = "toggle", label = "Plan", value = false } }
            or {
              { id = "fast_mode", type = "toggle", label = "Fast", value = false },
              { id = "plan_mode", type = "toggle", label = "Plan", value = false },
            },
        })
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
    truthy(
      "provider: picker completes",
      vim.wait(1000, function()
        return chosen ~= nil
      end)
    )
    eq("provider: separate provider and model selections", select_count, 2)
    eq("provider: labeled Codex model is selected", chosen and chosen.provider, "codex/gpt-5.6-sol")
    eq(
      "provider: direct model ids are validated",
      create.find(catalogue.entries, "codex/nope"),
      nil
    )
    local draft = create.draft(chosen)
    eq("provider: default permissions come from daemon", draft.modeId, "auto-review")
    eq("provider: default reasoning comes from model", draft.thinkingOptionId, "high")

    create.preference("codex/gpt-5.6-sol", function() end)
    eq(
      "provider: preference changes without creating an agent",
      config.get().paseo.provider,
      "codex/gpt-5.6-sol"
    )
    truthy(
      "provider: no creation op was sent",
      vim.iter(requests):all(function(request)
        return request.op ~= "agent.ensure" and request.op ~= "agent.create"
      end)
    )

    local reviewed
    create.review({ cwd = "/work", preferred = "codex/gpt-5.6-sol" }, function(value)
      reviewed = value
    end)
    truthy(
      "provider: review screen opens",
      vim.wait(1000, function()
        local buf = vim.api.nvim_get_current_buf()
        return table
          .concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          :find("New Paseo session", 1, true) ~= nil
      end)
    )
    chosen_model = "gpt-5.6-luna"
    hold_features = true
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_feedkeys(vim.keycode "<CR>", "x", false)
    truthy(
      "provider: changing model re-fetches its features",
      vim.wait(1000, function()
        local found = 0
        for _, request in ipairs(requests) do
          if request.op == "providers.features" then
            found = found + 1
          end
        end
        return found >= 2
      end)
    )
    vim.api.nvim_feedkeys("c", "x", false)
    eq("provider: cannot create before the model features arrive", reviewed, nil)
    hold_features = false
    held_feature_callback(nil, {
      features = {
        { id = "plan_mode", type = "toggle", label = "Plan", value = false },
      },
    })
    truthy(
      "provider: model features finish loading",
      vim.wait(1000, function()
        local buf = vim.api.nvim_get_current_buf()
        return table
          .concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          :find("Loading model features", 1, true) == nil
      end)
    )
    vim.api.nvim_feedkeys("c", "x", false)
    truthy(
      "provider: review creates a draft",
      vim.wait(1000, function()
        return reviewed ~= nil
      end)
    )
    eq(
      "provider: reviewed model is the changed model",
      reviewed and reviewed.provider,
      "codex/gpt-5.6-luna"
    )
    eq(
      "provider: changed model drops absent features",
      reviewed and reviewed.featureValues.fast_mode,
      nil
    )

    vim.ui.select = function(_, _, callback)
      callback(nil)
    end
    local cancelled = false
    create.review({ cwd = "/work" }, function(selection, review_err)
      cancelled = selection == nil and review_err == nil
    end)
    truthy(
      "provider: cancel creates nothing",
      vim.wait(1000, function()
        return cancelled
      end)
    )

    local fake_chat = { agent_id = "agent", root = "/work" }
    chat.current = function()
      return fake_chat
    end
    local toggled
    session.toggle = function(id)
      toggled = id
    end
    chat.test_config = {
      provider = "codex",
      modeId = "auto-review",
      features = { { id = "plan_mode", type = "toggle", label = "Plan", value = false } },
      availableModes = { { id = "auto-review" } },
    }
    session.plan()
    vim.wait(1000, function()
      return toggled ~= nil
    end)
    eq("provider: Codex Plan uses feature toggle", toggled, "plan_mode")

    chat.test_config = {
      provider = "claude",
      modeId = "default",
      features = {},
      availableModes = { { id = "plan" }, { id = "default" } },
    }
    chat.load_settings = function() end
    session.plan()
    vim.wait(1000, function()
      return requests[#requests].op == "agent.setMode"
    end)
    eq("provider: Claude Plan uses its mode", requests[#requests].args.modeId, "plan")

    local header = sidebar.header {
      provider = "codex/gpt-5.6-sol",
      root = "/work",
      features = { plan_mode = true, fast_mode = true },
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
    truthy(
      "provider: header shows all enabled feature labels",
      text:find("Fast", 1, true) and text:find("Plan", 1, true)
    )
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
      {
        id = "reject",
        label = "Reject",
        behavior = "deny",
        variant = "danger",
        intent = "dismiss",
      },
      {
        id = "implement",
        label = "Implement",
        behavior = "allow",
        variant = "primary",
        intent = "implement",
      },
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
  truthy(
    "plan: the text comes from input.plan",
    plan.text(request):find("Step one", 1, true) ~= nil
  )
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
  truthy(
    "plan: no reported modes falls back to the request's buttons",
    plan.actions(request, {}) == nil
  )
  truthy(
    "plan: and so does a request with no allow action to build on",
    plan.actions({ kind = "plan", actions = { { id = "reject", behavior = "deny" } } }, claude)
      == nil
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
  eq(
    "plan: and a reject says you are still planning",
    plan.label(actions[4]),
    "rejected, still planning"
  )

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

--- Answering somewhere else must not desync this side.
---
--- `permission_resolved` is a real event and it does fire, but it is not the
--- only way a request stops being pending: the daemon replaces its pending map
--- wholesale on a session refresh with no resolution for what vanished, and a
--- resolution that lands while the socket is down is never replayed. The list
--- held here used to have exactly one add and one remove and no way to be told
--- it was wrong, so any of those left a prompt that `gp` would reopen and the
--- daemon would refuse.
--- The overlay that answers a question or decides a plan.
---
--- Driven with stub handlers rather than a daemon, which is the whole reason
--- |paseo.ui.answer| takes them as an argument: every assertion here is about what
--- is on screen and what comes back out, and none of it needs a socket.
local function test_answer()
  local ask = require "paseo.ui.answer"
  local plan = require "paseo.ui.plan"
  local questions = require "paseo.ui.questions"

  ---A chat with a REAL conversation window, because the overlay anchors to one.
  ---@param width integer
  local function chat_with_window(width)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    vim.cmd "only"
    local buf = vim.api.nvim_create_buf(false, true)
    vim.cmd "vsplit"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, width)
    return { root = root, agent_id = "a1", conversation = buf, win_conversation = win }
  end

  ---Everything volt actually drew, as one string.
  ---@param buf integer
  local function drawn(buf)
    local parts = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      for _, cell in ipairs(mark[4].virt_text or {}) do
        parts[#parts + 1] = cell[1]
      end
    end
    return table.concat(parts, " ")
  end

  local function press(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
  end

  local request = {
    id = "ask-1",
    kind = "question",
    name = "AskUserQuestion",
    actions = { { id = "deny", label = "Deny", behavior = "deny" } },
    input = {
      questions = {
        {
          question = "How should I reconcile your local work?",
          header = "Reconcile",
          options = {
            { label = "Rebase", description = "Replay mine on top" },
            { label = "Merge" },
          },
        },
        {
          question = "Which checks should run?",
          header = "Checks",
          multiSelect = true,
          options = { { label = "tests" }, { label = "lint" } },
        },
        { question = "Anything else?", header = "Note", options = {}, allowEmpty = true },
      },
    },
  }

  local asked = questions.parse(request)
  local sent, declined
  local function handlers()
    return {
      submit = function(state)
        sent = questions.answers(state)
      end,
      choose = function() end,
      reject = function(interrupt)
        declined = interrupt and "interrupt" or "deny"
      end,
    }
  end

  local chat = chat_with_window(90)
  ask.open(chat, request, { actions = request.actions, state = questions.state(asked) }, handlers())

  local card = vim.api.nvim_get_current_buf()
  local card_win = vim.api.nvim_get_current_win()

  -- The overlay is volt's, and it is over the CHAT window rather than centred on
  -- the editor. Anchoring is what makes "takes over the chat window" true on
  -- both surfaces without a branch per surface.
  truthy("ask: the card is a volt buffer", require("volt.state")[card] ~= nil)
  eq(
    "ask: and is anchored to the chat window",
    vim.api.nvim_win_get_config(card_win).relative,
    "win"
  )
  eq("ask: to THAT chat window", vim.api.nvim_win_get_config(card_win).win, chat.win_conversation)
  truthy(
    "ask: it fits inside it",
    vim.api.nvim_win_get_width(card_win) <= vim.api.nvim_win_get_width(chat.win_conversation)
      and vim.api.nvim_win_get_height(card_win)
        <= vim.api.nvim_win_get_height(chat.win_conversation)
  )

  -- Clickable, which is the half `volt.events.add` alone does not give you.
  local targets = 0
  for _, row in pairs(require("volt.state")[card].clickables) do
    targets = targets + #row
  end
  truthy("ask: the options carry click targets", targets > 0, targets)

  -- ONE question at a time, and the counter is what says so. Both halves matter:
  -- the second question being absent is the feature, and `2 of 3` is what stops
  -- that teaching you the first answer was the whole reply.
  local shown = drawn(card)
  truthy("ask: the first question is drawn", shown:find("reconcile", 1, true) ~= nil, shown)
  eq("ask: and the second is not", shown:find("Which checks", 1, true), nil)
  truthy("ask: the counter says how many there are", shown:find("1 of 3", 1, true) ~= nil, shown)
  truthy("ask: and the hint does not offer to send yet", shown:find "answer this one" ~= nil, shown)

  -- Volt lays a section out by row and never clears, so the window and the
  -- buffer have to agree after a step that changed the line count.
  local function consistent(label)
    local state = require("volt.state")[card]
    eq(
      "ask: " .. label .. " -- volt's height is the buffer's",
      state.h,
      vim.api.nvim_buf_line_count(card)
    )
    eq("ask: " .. label .. " -- and the window's", state.h, vim.api.nvim_win_get_height(card_win))
    local overflow = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card, -1, 0, -1, {})) do
      if mark[2] >= vim.api.nvim_buf_line_count(card) then
        overflow = overflow + 1
      end
    end
    eq("ask: " .. label .. " -- nothing is drawn past the end", overflow, 0)
  end
  consistent "on open"

  -- Nothing answered yet, so <CR> cannot send. It jumps to the gap instead --
  -- which on the first question means it stays, and says so.
  press "<CR>"
  eq("ask: an incomplete set is not sent", sent, nil)

  -- Single-select replaces and advances, so one keypress moves the stepper on.
  press "1"
  shown = drawn(card)
  truthy("ask: picking advances to the next question", shown:find("2 of 3", 1, true) ~= nil, shown)
  consistent "after stepping"

  -- Multi-select accumulates and stays put.
  press "1"
  press "2"
  truthy("ask: multi-select stays on its question", drawn(card):find("2 of 3", 1, true) ~= nil)

  -- The third question has no options at all, so the box is the only thing to
  -- do. A REAL buffer, and never volt's -- that is the difference between
  -- writing an answer and filling in a text field.
  press "<Tab>"
  press "i"
  local box = vim.api.nvim_get_current_buf()
  truthy("ask: the answer box is a real, typeable buffer", vim.bo[box].modifiable and box ~= card)
  eq("ask: and is never handed to volt", require("volt.state")[box], nil)

  vim.api.nvim_buf_set_lines(box, 0, -1, false, { "looks", "right" })
  press "<CR>"
  truthy(
    "ask: what was typed is shown back",
    drawn(card):find("looks right", 1, true) ~= nil,
    drawn(card)
  )

  -- Complete, so now it sends -- and the hint said so first.
  truthy(
    "ask: the hint offers to send once nothing is missing",
    drawn(card):find "send the answers" ~= nil
  )
  vim.api.nvim_set_current_win(card_win)
  press "<CR>"
  eq("ask: the whole set is sent at once", sent and #sent, 3)
  eq("ask: single-select, as its label", sent and sent[1], "Rebase")
  eq("ask: multi-select, joined", sent and sent[2], "tests, lint")
  eq("ask: and the typed answer, flattened onto one line", sent and sent[3], "looks right")

  ask.close()
  sent = nil

  -- Dismiss is not deny, and the picks survive it: that is the whole reason
  -- <Esc> does not answer.
  -- A REQUEST OF ITS OWN, because `request` has already been answered above and
  -- its picks are held on the chat -- reopening that one resumes onto its
  -- free-text question, where the box takes the focus and a keypress is text.
  local pair = {
    id = "ask-2",
    kind = "question",
    actions = { { id = "deny", label = "Deny", behavior = "deny" } },
    input = {
      questions = {
        { question = "First of two?", options = { { label = "A" }, { label = "B" } } },
        { question = "Second of two?", options = { { label = "C" }, { label = "D" } } },
      },
    },
  }
  local two = questions.parse(pair)

  ask.open(chat, pair, { actions = pair.actions, state = questions.state(two) }, handlers())
  -- `q`, not `<Esc>`: `nvim_feedkeys` eats a bare `<Esc>` in normal mode before
  -- any mapping sees it. They are bound to the same thing.
  press "2"
  press "q"
  eq("ask: dismissing closes the overlay", ask.showing(), nil)
  eq("ask: and does not answer it", sent, nil)

  ask.open(chat, pair, { actions = pair.actions, state = questions.state(two) }, handlers())
  -- Resumed, not restarted: a fresh `questions.state` went in and the held one
  -- came back out, so the stepper is still on the question you had reached.
  truthy(
    "ask: and reopening resumes rather than starting again",
    drawn(vim.api.nvim_get_current_buf()):find("2 of 2", 1, true) ~= nil,
    drawn(vim.api.nvim_get_current_buf())
  )
  press "n"
  eq("ask: `n` declines rather than allowing", declined, "deny")
  ask.close()

  -- More options than rows. The list is windowed around the focus rather than
  -- cut off, because a fifteenth option you cannot scroll to is unreachable
  -- however the keys are bound -- and the card must still fit the chat window.
  local many = {}
  for i = 1, 15 do
    many[i] = { label = "option " .. i }
  end
  local long_list = {
    id = "ask-many",
    kind = "question",
    actions = { { id = "deny", label = "Deny", behavior = "deny" } },
    input = { questions = { { question = "Pick one of many", options = many } } },
  }
  chat = chat_with_window(80)
  vim.api.nvim_win_set_height(chat.win_conversation, 14)
  ask.open(chat, long_list, {
    actions = long_list.actions,
    state = questions.parse(long_list) and questions.state(questions.parse(long_list)),
  }, handlers())
  for _ = 1, 9 do
    press "j"
  end
  card = vim.api.nvim_get_current_buf()
  shown = drawn(card)
  truthy(
    "ask: a long list keeps the focused option in view",
    shown:find("option 10", 1, true) ~= nil,
    shown
  )
  truthy("ask: and says how many are above it", shown:find("↑", 1, true) ~= nil, shown)
  truthy("ask: and below", shown:find("↓", 1, true) ~= nil, shown)
  truthy(
    "ask: while still fitting the chat window",
    vim.api.nvim_win_get_height(vim.fn.bufwinid(card))
      <= vim.api.nvim_win_get_height(chat.win_conversation),
    vim.api.nvim_win_get_height(vim.fn.bufwinid(card))
  )
  ask.close()

  -- A chat window too narrow to read an option in gets the SAME overlay,
  -- centred on the editor. Not a second, drifting one.
  chat = chat_with_window(30)
  ask.open(chat, request, { actions = request.actions, state = questions.state(asked) }, handlers())
  eq(
    "ask: a chat window too narrow falls back to the editor",
    vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative,
    "editor"
  )
  truthy(
    "ask: and it is the same card, not a lesser one",
    drawn(vim.api.nvim_get_current_buf()):find("reconcile", 1, true) ~= nil
  )
  ask.close()

  -- A win-relative float does NOT die with its parent. Without the WinClosed
  -- guard this is an orphan hanging over whatever replaces the chat window.
  chat = chat_with_window(90)
  ask.open(chat, request, { actions = request.actions, state = questions.state(asked) }, handlers())
  vim.api.nvim_win_close(chat.win_conversation, true)
  vim.wait(200, function()
    return ask.showing() == nil
  end)
  eq("ask: the overlay goes with the chat window it was anchored to", ask.showing(), nil)

  -- ------------------------------------------------------------------- plans
  local long = {}
  for i = 1, 120 do
    long[i] = "plan line " .. i
  end
  local plan_request = {
    id = "ask-plan",
    kind = "plan",
    actions = {
      { id = "impl", label = "Implement", behavior = "allow" },
      { id = "rej", label = "Reject", behavior = "deny" },
    },
    input = { plan = table.concat(long, "\n") },
  }
  chat = chat_with_window(90)
  local modes = { { id = "acceptEdits" }, { id = "auto" }, { id = "default" } }
  local picked
  ask.open(chat, plan_request, {
    actions = plan.actions(plan_request, modes),
    plan = true,
  }, {
    submit = function() end,
    choose = function(action)
      picked = action
    end,
    reject = function() end,
  })

  card = vim.api.nvim_get_current_buf()
  local body
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "markdown" and buf ~= chat.conversation then
      body = buf
    end
  end

  -- The whole point: a plan is READ, so it is real text in a window you scroll,
  -- and it is not budgeted against the screen and truncated the way the dialog
  -- it replaces did. You cannot approve what you were not shown.
  truthy("ask: a plan gets a real-text body", body ~= nil)
  eq("ask: carrying the plan in full", body and vim.api.nvim_buf_line_count(body), 120)
  eq("ask: which is not volt's either", body and require("volt.state")[body], nil)
  eq("ask: and nothing is elided", drawn(card):find "more lines", nil)
  truthy(
    "ask: one Implement per mode it could land in",
    drawn(card):find("accept edits", 1, true) ~= nil,
    drawn(card)
  )

  press "1"
  eq("ask: a button sends the daemon's own action id", picked and picked.id, "impl")
  eq("ask: with the mode that button means", picked and picked.mode, "acceptEdits")

  ask.close()

  -- Volt keys its state by buffer and keeps the buffer on its key handler; both
  -- halves are ours to undo, for every window the overlay opened.
  eq("ask: closing clears the card's volt state", require("volt.state")[card], nil)
  local listed = false
  for _, buf in ipairs(require("volt.events").bufs) do
    listed = listed or buf == card
  end
  eq("ask: and takes it off volt's key handler", listed, false)
  -- The augroup is deleted outright, and `nvim_get_autocmds` raises on a group
  -- that does not exist -- so "it threw" IS the pass here.
  local kept = pcall(vim.api.nvim_get_autocmds, { group = "paseo.answer" })
  eq("ask: no autocmds are left behind", kept, false)
  vim.cmd "only"
  eq("ask: and no windows", #vim.api.nvim_list_wins(), 1)
end

local function test_permission_sync()
  local permission = require "paseo.ui.permission"
  local transcript = require "paseo.ui.transcript"

  local chat = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(chat)

  local function request(id)
    return { id = id, kind = "tool", name = "Bash", title = "Run " .. id, actions = {} }
  end

  permission.reconcile(chat, { request "a", request "b" })
  eq("sync: a pending list we did not have is offered", #chat.permissions, 2)
  truthy("sync: and each one is in the conversation", chat.permission_blocks["a"] ~= nil)

  -- The case the event stream never reports: answered on the desktop while we
  -- were not listening, so it is simply absent from the next snapshot.
  permission.reconcile(chat, { request "b" })
  eq("sync: one answered elsewhere is dropped", #chat.permissions, 1)
  eq("sync: and the one still pending is kept", chat.permissions[1].id, "b")

  local badge = chat.blocks[chat.permission_blocks["a"]]
  eq(
    "sync: the inline card says so rather than going quiet",
    badge.item.resolution,
    "answered elsewhere"
  )

  -- Agreement must cost nothing -- this runs on every snapshot tick.
  permission.reconcile(chat, { request "b" })
  eq("sync: a list that agrees changes nothing", #chat.permissions, 1)

  permission.reconcile(chat, {})
  eq("sync: an empty list clears the queue", #chat.permissions, 0)

  -- A `replaced` epoch empties the block table. The re-offer that follows used
  -- to hit the de-duplicate and return early, so the request stayed held with
  -- no card anywhere -- the winbar said `needs you` and the conversation had
  -- no record of why.
  permission.reconcile(chat, { request "c" })
  local before = chat.permission_blocks["c"]
  chat.blocks = {}
  permission.offer(chat, request "c")
  truthy(
    "sync: a held request whose card was thrown away is redrawn",
    chat.permission_blocks["c"] ~= before and chat.blocks[chat.permission_blocks["c"]] ~= nil
  )
  eq("sync: and is not held twice", #chat.permissions, 1)
end

--- The terminal directory: the list half of Paseo terminals.
---
--- The subtlety worth a test is that `terminals_changed` is a full list FOR
--- ONE CWD and never a delta, so the naive "replace everything" that the agent
--- directory can get away with would drop every terminal under every other
--- root the moment one workspace reported in.
local function test_terminals()
  local terminals = require "paseo.terminals"
  local apply = terminals._apply

  local root = "/tmp/paseo-spec-a"
  local other = "/tmp/paseo-spec-b"

  apply {
    kind = "snapshot",
    cwd = root,
    entries = {
      { id = "t1", name = "zsh" },
      {
        id = "t2",
        name = "claude",
        activity = { state = "attention", attentionReason = "needs_input" },
      },
    },
  }
  apply { kind = "snapshot", cwd = other, entries = { { id = "t3", name = "codex" } } }

  eq("terminals: a root lists its own", #terminals.for_root(root), 2)
  eq("terminals: and not another's", #terminals.for_root(other), 1)
  eq("terminals: sorted by name", terminals.for_root(root)[1].name, "claude")

  -- THE BUG A FULL-LIST-PER-CWD PAYLOAD INVITES: one root reporting must not
  -- empty the others.
  apply { kind = "snapshot", cwd = root, entries = { { id = "t1", name = "zsh" } } }
  eq("terminals: a changed root drops what it no longer lists", #terminals.for_root(root), 1)
  eq("terminals: and leaves other roots alone", #terminals.for_root(other), 1)

  eq(
    "terminals: one waiting on you is marked",
    terminals.glyph({
      activity = { state = "attention" },
    })[2],
    "PaseoDanger"
  )
  eq(
    "terminals: a working one is not",
    terminals.glyph({ activity = { state = "working" } })[2],
    "PaseoAgent"
  )
  eq("terminals: nor an idle one", terminals.glyph({})[2], "PaseoDim")

  apply { kind = "snapshot", cwd = root, entries = {} }
  eq("terminals: an empty list empties the root", #terminals.for_root(root), 0)

  -- The panel is a tab like any other, so the surface must actually offer it.
  truthy(
    "terminals: the dashboard has a tab for them",
    vim.tbl_contains(require("paseo.ui.float").TABS, "Terminals")
  )
end

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

  chat_mod.apply_settings(
    chat,
    { agentId = "spec-settings", modeId = "auto", availableModes = modes }
  )

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
  chat_mod.apply_settings(
    chat,
    { agentId = "spec-settings", modeId = "invented", availableModes = modes }
  )
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
    { "explain", test_explain_quickfix },
    { "prompt", test_prompt },
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
    { "ask", test_answer },
    { "sync", test_permission_sync },
    { "terminals", test_terminals },
    { "follow", test_follow },
    { "settings", test_settings },
    { "strategy", test_strategy },
    { "workspace open", test_workspace_open },
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
