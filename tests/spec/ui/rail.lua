--- The workspace rail: what each workspace's state is, where the column goes,
--- and the toggle.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

local function test_buckets()
  local agents = require "paseo.agents"

  -- The desktop app's rule, case by case. Each of these is a different glyph
  -- on the rail, so each one answered wrongly is a workspace drawn as doing
  -- something it is not.
  eq(
    "rail: a pending permission is waiting on you",
    agents.bucket { status = "running", pendingPermissionCount = 1 },
    "needs_input"
  )
  eq(
    "rail: so is our own permission flag, from an older sidecar",
    agents.bucket { status = "idle", requiresAttention = true },
    "needs_input"
  )
  eq("rail: a failed agent is failed", agents.bucket { status = "error" }, "failed")
  eq(
    "rail: and so is one the daemon flagged for an error",
    agents.bucket { status = "idle", attentionReason = "error", daemonAttention = true },
    "failed"
  )
  eq("rail: running is running", agents.bucket { status = "running" }, "running")
  eq("rail: and booting spins too", agents.bucket { status = "initializing" }, "running")
  eq(
    "rail: finished unseen is news",
    agents.bucket { status = "idle", attentionReason = "finished", daemonAttention = true },
    "attention"
  )
  eq("rail: and otherwise it is done", agents.bucket { status = "idle" }, "done")

  -- One answer for a workspace: its most urgent agent.
  local root = vim.fn.tempname()
  local host = require("paseo.hosts").selected()
  agents._apply {
    kind = "snapshot",
    hostId = host,
    entries = {
      { id = "r1", status = "running", cwd = root },
      { id = "r2", status = "idle", cwd = root .. "/sub" },
      { id = "r3", status = "idle", requiresAttention = true, cwd = root },
      { id = "elsewhere", status = "error", cwd = root .. "-other" },
    },
  }
  eq(
    "rail: a workspace answers with its most urgent agent",
    agents.workspace_bucket(root, host),
    "needs_input"
  )
  eq(
    "rail: and a sibling directory is not inside it",
    agents.workspace_bucket(root .. "-other", host),
    "failed"
  )
  eq("rail: no agents is none", agents.workspace_bucket(root .. "-nobody", host), "none")

  -- MANY WORKSPACES, ONE DIRECTORY. Every agent the app starts in a checkout
  -- gets a workspace of its own on the same path; matched by directory, the
  -- one running agent set every row in the project spinning.
  agents._apply {
    kind = "snapshot",
    hostId = host,
    entries = {
      { id = "busy", status = "running", cwd = root, workspaceId = "wks_busy" },
      { id = "quiet", status = "idle", cwd = root, workspaceId = "wks_quiet" },
      { id = "legacy", status = "idle", cwd = root },
    },
  }
  local busy = { id = "wks_busy", directory = root, hostId = host }
  local quiet = { id = "wks_quiet", directory = root, hostId = host }
  local empty = { id = "wks_empty", directory = root, hostId = host }
  eq(
    "rail: the running agent's own workspace spins",
    agents.workspace_bucket(busy, host),
    "running"
  )
  eq("rail: a sibling on the same directory does not", agents.workspace_bucket(quiet, host), "done")
  eq(
    "rail: one whose agents are elsewhere answers for the id-less one only",
    agents.workspace_bucket(empty, host),
    "done"
  )
  eq("rail: and the row says the same", require("paseo.ui.rail").bucket(quiet), "done")
  eq("rail: a workspace lists its own agents", #agents.for_workspace(quiet, host), 2)
  eq(
    "rail: by id, plus the agent with no id to match",
    vim.tbl_map(function(a)
      return a.id
    end, require("paseo.ui.tree").workspace_agents(quiet, host)),
    { "legacy", "quiet" }
  )
  eq("rail: the picker's summary is the workspace's", agents.summary(quiet, host), "2 idle")
  agents._apply { kind = "snapshot", hostId = host, entries = {} }

  -- The status slot, by bucket: one cell, one plain character -- never a
  -- nerd-font icon, which a terminal like Ghostty spills over the gap after it.
  local rail = require "paseo.ui.rail"
  local icons = require "paseo.ui.icons"
  eq(
    "rail: waiting is a warning-coloured !",
    { rail.badge "needs_input" },
    { "!", "PaseoTreeWaiting" }
  )
  eq(
    "rail: failed is an error-coloured cross",
    { rail.badge "failed" },
    { "✗", "PaseoTreeFailed" }
  )
  eq("rail: unread is a coloured dot", { rail.badge "attention" }, { "•", "PaseoTreeUnread" })
  eq("rail: done keeps a dot, nearly background", { rail.badge "done" }, { "•", "PaseoTreeIdle" })
  truthy(
    "rail: running is a spinner frame",
    vim.tbl_contains(icons.spinner, (rail.badge "running"))
  )
  for _, bucket in ipairs { "running", "needs_input", "failed", "attention", "done", "none" } do
    eq(("rail: %s is one cell"):format(bucket), vim.fn.strdisplaywidth((rail.badge(bucket))), 1)
  end
end

local function test_layout()
  local layout = require "paseo.ui.layout"

  eq("rail: none below the minimum surface", layout.rail_width(89, 28), 0)
  eq("rail: the configured width where it fits", layout.rail_width(160, 28), 28)
  eq("rail: never more than a quarter of the surface", layout.rail_width(100, 60), 25)
  eq("rail: zero asked is zero given", layout.rail_width(200, 0), 0)

  for _, border in ipairs { true, false } do
    local g = { row = 2, col = 3, width = 120, height = 40, composer = 7, border = border }
    local bare = layout.panes(g)
    eq("rail: no rail, no rail rect", bare.rail, nil)
    g.rail = 28
    local panes = layout.panes(g)
    eq("rail: it sits where the panes used to start", panes.rail.col, bare.col)
    eq("rail: and spans the body", panes.rail.height, bare.body.height)
    eq("rail: the panes move right of it and its gap", panes.col, bare.col + 28 + layout.RAIL_GAP)
    eq("rail: by exactly what they lose in width", panes.width, bare.width - 28 - layout.RAIL_GAP)
    eq("rail: the terminal shares the conversation's left edge", panes.body.col, panes.col)
    -- The rule is the middle of the gap, on screen. Text column 0 of the
    -- chrome is one `xpad` in from the content edge, which is one in from
    -- `g.col` under a frame.
    local text0 = g.col + (border and 1 or 0) + 1
    eq("rail: the rule lands in the middle of the gap", text0 + panes.rail.rule, panes.col - 2)
  end
end

local function test_toggle()
  local native = require "paseo.ui.native"
  local rail = require "paseo.ui.rail"
  local bridge = require "paseo.bridge"
  local agents = require "paseo.agents"
  local workspaces = require "paseo.workspaces"
  local transcript = require "paseo.ui.transcript"

  local saved = {
    columns = vim.o.columns,
    lines = vim.o.lines,
    running = bridge.running,
    watch = agents.watch,
    list = workspaces.list,
    here = workspaces.here,
    open = workspaces.open,
    open_workspace = native.open_workspace,
    state = vim.env.XDG_STATE_HOME,
  }
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  rail.reset()

  local root = vim.fn.tempname()
  local host = require("paseo.hosts").selected()
  local opened
  local ok, failure = pcall(function()
    vim.o.columns, vim.o.lines = 160, 50
    bridge.running = function()
      return true
    end
    agents.watch = function() end
    workspaces.here = function()
      return root
    end
    workspaces.list = function(cb)
      cb({
        { name = "alpha", directory = root .. "/a", projectRoot = root, hostId = host },
        { name = "beta", directory = root .. "/b", projectRoot = root, hostId = host },
      }, nil)
    end
    workspaces.open = function(ws)
      opened = ws
    end
    -- On a native tab a workspace opens its agent in a tab of its own.
    native.open_workspace = function(ws)
      opened = ws
    end

    local chat = {
      root = vim.uv.cwd(),
      agent_id = "rail-agent",
      provider = "test",
      streaming = false,
      pending = {},
      conversation = api.nvim_create_buf(false, true),
      composer = api.nvim_create_buf(false, true),
    }
    transcript.reset(chat)

    truthy("rail: shown by default", rail.visible())
    native.open(chat)
    -- The list lands on the next tick.
    vim.wait(200, function()
      return rail.current() ~= nil
        or (rail.win() and api.nvim_buf_line_count(api.nvim_win_get_buf(rail.win())) > 3)
    end)
    local win = rail.win()
    truthy("rail: the window is up", win ~= nil)
    eq("rail: and the cursor stayed in the composer", api.nvim_get_current_buf(), chat.composer)

    local rail_col = api.nvim_win_get_position(win)[2]
    local composer_col = api.nvim_win_get_position(chat.win_composer)[2]
    local composer_width = api.nvim_win_get_width(chat.win_composer)
    truthy("rail: left of the conversation", rail_col + api.nvim_win_get_width(win) < composer_col)
    local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n")
    truthy(
      "rail: lists the project's workspaces",
      text:find("alpha", 1, true) and text:find("beta", 1, true),
      text
    )

    -- Into it, down a row, and open.
    native.focus_rail()
    eq("rail: the focus key lands in it", api.nvim_get_current_win(), win)
    local first = rail.current()
    truthy("rail: on a workspace, not the heading", first ~= nil)
    vim.api.nvim_feedkeys("j", "x", false)
    truthy("rail: j moves to the next workspace", rail.current() and rail.current() ~= first)
    -- A workspace is a folder: <CR> folds it, as nvim-tree's does, and `O`
    -- opens it as a place.
    local was_open = rail.is_expanded(rail.current(), false)
    rail.open_current()
    eq("rail: <CR> on a workspace folds it", rail.is_expanded(rail.current(), false), not was_open)
    eq("rail: and opens nothing", opened, nil)
    rail.open_workspace()
    eq("rail: O opens the one under the cursor", opened and opened.name, rail.current().name)
    api.nvim_set_current_win(chat.win_composer)

    -- Toggle off: the window goes, the panes take the room back, and the
    -- choice is remembered for the next session.
    native.toggle_rail()
    truthy("rail: toggled off, the window is gone", not (win and api.nvim_win_is_valid(win)))
    truthy("rail: and focus went back to the composer", api.nvim_get_current_buf() == chat.composer)
    truthy(
      "rail: the composer moved left into the room",
      api.nvim_win_get_position(chat.win_composer)[2] < composer_col
        and api.nvim_win_get_width(chat.win_composer) > composer_width
    )
    rail.reset()
    eq("rail: the toggle is remembered across restarts", rail.visible(), false)

    native.toggle_rail()
    truthy("rail: and back on", rail.win() ~= nil and api.nvim_win_is_valid(rail.win()))
    eq(
      "rail: and remembered as on",
      (function()
        rail.reset()
        return rail.visible()
      end)(),
      true
    )
    native.close(chat)
  end)

  vim.o.columns, vim.o.lines = saved.columns, saved.lines
  bridge.running, agents.watch = saved.running, saved.watch
  workspaces.list, workspaces.here, workspaces.open = saved.list, saved.here, saved.open
  native.open_workspace = saved.open_workspace
  vim.env.XDG_STATE_HOME = saved.state
  rail.reset()
  pcall(native.reset)
  if not ok then
    error(failure, 0)
  end
end

local function test_current()
  local rail = require "paseo.ui.rail"
  local native = require "paseo.ui.native"
  local agents = require "paseo.agents"
  local saved = { chat = native.chat, get = agents.get }
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local list = {
    { id = "ws-1", name = "main", directory = dir },
    { id = "ws-2", name = "main", directory = dir },
    { id = "ws-3", name = "other", directory = dir .. "-other" },
  }
  local ok, failure = pcall(function()
    native.chat = function()
      return { agent_id = "a", host_id = "local", root = dir }
    end
    agents.get = function()
      return { id = "a", cwd = dir, workspaceId = "ws-2" }
    end
    eq(
      "rail: the agent's own workspace, not the first on its directory",
      rail.current_index(list),
      2
    )
    agents.get = function()
      return { id = "a", cwd = dir }
    end
    eq(
      "rail: without an id, the first on the directory -- and only it",
      rail.current_index(list),
      1
    )
    native.chat = function()
      return { host_id = "local", root = dir .. "-other" }
    end
    eq("rail: a draft is on the directory it was opened in", rail.current_index(list), 3)
  end)
  native.chat, agents.get = saved.chat, saved.get
  if not ok then
    error(failure, 0)
  end
end

local function test_sessions()
  local native = require "paseo.ui.native"
  local rail = require "paseo.ui.rail"
  local bridge = require "paseo.bridge"
  local agents = require "paseo.agents"
  local subagents = require "paseo.subagents"
  local terminals = require "paseo.terminals"
  local workspaces = require "paseo.workspaces"
  local transcript = require "paseo.ui.transcript"

  local saved = {
    columns = vim.o.columns,
    lines = vim.o.lines,
    running = bridge.running,
    watch = agents.watch,
    get = agents.get,
    all = agents.all,
    for_root = agents.for_root,
    sub_list = subagents.list,
    track = subagents.track,
    term_watch = terminals.watch,
    list = workspaces.list,
    here = workspaces.here,
    state = vim.env.XDG_STATE_HOME,
  }
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  rail.reset()

  local root = vim.fn.tempname()
  local host = require("paseo.hosts").selected()
  local listed = {
    {
      id = "s-1",
      title = "first agent",
      status = "idle",
      workspaceId = "ws-a",
      cwd = root .. "/a",
      createdAt = "1",
    },
    {
      id = "s-2",
      title = "second agent",
      status = "idle",
      workspaceId = "ws-a",
      cwd = root .. "/a",
      createdAt = "2",
    },
    {
      id = "s-3",
      title = "other agent",
      status = "idle",
      workspaceId = "ws-b",
      cwd = root .. "/b",
      createdAt = "3",
    },
  }
  local ok, failure = pcall(function()
    vim.o.columns, vim.o.lines = 160, 50
    bridge.running = function()
      return true
    end
    agents.watch = function() end
    terminals.watch = function() end
    subagents.track = function() end
    agents.get = function(id)
      for _, a in ipairs(listed) do
        if a.id == id then
          return a
        end
      end
    end
    agents.all = function()
      return listed
    end
    agents.for_root = function(dir)
      return vim.tbl_filter(function(a)
        return a.cwd == dir
      end, listed)
    end
    subagents.list = function(parent)
      if parent == "s-1" then
        return {
          {
            kind = "provider",
            id = "task",
            parent = "s-1",
            title = "child task",
            status = "running",
            running = true,
          },
        }
      end
      return {}
    end
    workspaces.here = function()
      return root
    end
    workspaces.list = function(cb)
      cb({
        {
          id = "ws-a",
          name = "alpha",
          directory = root .. "/a",
          projectRoot = root,
          hostId = host,
        },
        { id = "ws-b", name = "beta", directory = root .. "/b", projectRoot = root, hostId = host },
      }, nil)
    end

    local chat = {
      root = root .. "/a",
      host_id = host,
      agent_id = "s-1",
      provider = "test",
      streaming = false,
      pending = {},
      conversation = api.nvim_create_buf(false, true),
      composer = api.nvim_create_buf(false, true),
    }
    transcript.reset(chat)
    native.open(chat)
    local function text()
      return rail.win()
          and table.concat(
            api.nvim_buf_get_lines(api.nvim_win_get_buf(rail.win()), 0, -1, false),
            "\n"
          )
        or ""
    end
    vim.wait(300, function()
      return text():find("first agent", 1, true) ~= nil
    end)
    local drawn = text()
    truthy(
      "rail: the workspace on screen is open, its agents under it",
      drawn:find("first agent", 1, true) and drawn:find("second agent", 1, true),
      drawn
    )
    truthy(
      "rail: with each agent's subagents nested under it",
      drawn:find("child task", 1, true),
      drawn
    )
    truthy("rail: and the others closed", not drawn:find("other agent", 1, true), drawn)
    local alpha_at, child_at = drawn:find("alpha", 1, true), drawn:find("child task", 1, true)
    truthy("rail: the sessions come after their workspace's row", alpha_at < child_at, drawn)

    -- <C-s>: into the rail, on the session on screen.
    native.focus_rail()
    eq("rail: the sessions key lands in the rail", api.nvim_get_current_win(), rail.win())
    eq(
      "rail: on the agent on screen",
      rail.current_session() and rail.current_session().item.id,
      "s-1"
    )
    vim.api.nvim_feedkeys("j", "x", false)
    eq(
      "rail: j walks into its subagents",
      rail.current_session() and rail.current_session().item.id,
      "task"
    )
    eq(
      "rail: which belong to the workspace",
      rail.current_workspace() and rail.current_workspace().id,
      "ws-a"
    )

    -- Open the other workspace from its row.
    local _, rows = rail.lines(32)
    for line, ws in pairs(rows) do
      if ws.id == "ws-b" then
        api.nvim_win_set_cursor(rail.win(), { line, 0 })
      end
    end
    rail.expand(true)
    truthy(
      "rail: l opens another workspace's sessions",
      text():find("other agent", 1, true),
      text()
    )
    rail.expand(false)
    truthy("rail: and h closes them", not text():find("other agent", 1, true), text())
    native.close(chat)
  end)

  vim.o.columns, vim.o.lines = saved.columns, saved.lines
  bridge.running, agents.watch = saved.running, saved.watch
  agents.get, agents.all, agents.for_root = saved.get, saved.all, saved.for_root
  subagents.list, subagents.track, terminals.watch = saved.sub_list, saved.track, saved.term_watch
  workspaces.list, workspaces.here = saved.list, saved.here
  vim.env.XDG_STATE_HOME = saved.state
  rail.reset()
  pcall(native.reset)
  if not ok then
    error(failure, 0)
  end
end

local function test_tree()
  local native = require "paseo.ui.native"
  local rail = require "paseo.ui.rail"
  local bridge = require "paseo.bridge"
  local agents = require "paseo.agents"
  local subagents = require "paseo.subagents"
  local terminals = require "paseo.terminals"
  local workspaces = require "paseo.workspaces"
  local transcript = require "paseo.ui.transcript"
  local icons = require "paseo.ui.icons"

  -- What a workspace's row and the line under it say, from the descriptor
  -- the sidecar sends.
  local function text_of(chunks)
    return table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks or {}))
  end
  eq(
    "tree: lines changed, as the app writes them",
    text_of(rail.diff_stat { diffStat = { additions = 120, deletions = 7 } }),
    "+120 -7"
  )
  eq(
    "tree: and nothing for nothing changed",
    rail.diff_stat { diffStat = { additions = 0, deletions = 0 } },
    {}
  )
  eq("tree: or no stat at all", rail.diff_stat {}, {})
  eq("tree: no pull request, no line under the row", rail.meta {}, nil)
  local meta = text_of(rail.meta {
    pr = { number = 42, state = "open", checks = "running", checksDone = 1, checksTotal = 3 },
  })
  truthy("tree: the pull request's number", meta:find("#42", 1, true), meta)
  truthy("tree: and how far CI has got", meta:find("1/3", 1, true), meta)
  meta = text_of(rail.meta { pr = { number = 7, state = "open", checks = "failed" } })
  truthy("tree: a failed run says so", meta:find("failed", 1, true), meta)
  meta = text_of(rail.meta { pr = { number = 7, state = "merged", checks = "failed" } })
  truthy("tree: a merged one says merged", meta:find("merged", 1, true), meta)
  truthy("tree: and its CI is history", not meta:find("failed", 1, true), meta)

  local saved = {
    columns = vim.o.columns,
    lines = vim.o.lines,
    running = bridge.running,
    watch = agents.watch,
    get = agents.get,
    all = agents.all,
    for_workspace = agents.for_workspace,
    sub_list = subagents.list,
    track = subagents.track,
    term_watch = terminals.watch,
    list = workspaces.list,
    here = workspaces.here,
    state = vim.env.XDG_STATE_HOME,
  }
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  rail.reset()

  local root = vim.fn.tempname()
  local host = require("paseo.hosts").selected()
  local listed = {
    {
      id = "t-1",
      title = "on screen",
      status = "idle",
      workspaceId = "ws-a",
      cwd = root .. "/a",
      createdAt = "1",
    },
    {
      id = "t-2",
      title = "finished parent",
      status = "idle",
      workspaceId = "ws-a",
      cwd = root .. "/a",
      createdAt = "2",
    },
  }
  local kids = {
    ["t-2"] = {
      { kind = "provider", id = "k1", parent = "t-2", title = "kid one", status = "completed" },
      { kind = "provider", id = "k2", parent = "t-2", title = "kid two", status = "completed" },
    },
  }
  local ok, failure = pcall(function()
    vim.o.columns, vim.o.lines = 160, 50
    bridge.running = function()
      return true
    end
    agents.watch = function() end
    terminals.watch = function() end
    subagents.track = function() end
    agents.get = function(id)
      for _, a in ipairs(listed) do
        if a.id == id then
          return a
        end
      end
    end
    agents.all = function()
      return listed
    end
    agents.for_workspace = function(ws)
      return vim.tbl_filter(function(a)
        return a.workspaceId == ws.id
      end, listed)
    end
    subagents.list = function(parent)
      return kids[parent] or {}
    end
    workspaces.here = function()
      return root
    end
    workspaces.list = function(cb)
      cb({
        {
          id = "ws-a",
          name = "alpha",
          directory = root .. "/a",
          projectRoot = root,
          hostId = host,
          diffStat = { additions = 5, deletions = 2 },
          pr = { number = 9, state = "open", checks = "passed" },
        },
        { id = "ws-b", name = "beta", directory = root .. "/b", projectRoot = root, hostId = host },
      }, nil)
    end

    local chat = {
      root = root .. "/a",
      host_id = host,
      agent_id = "t-1",
      provider = "test",
      streaming = false,
      pending = {},
      conversation = api.nvim_create_buf(false, true),
      composer = api.nvim_create_buf(false, true),
    }
    transcript.reset(chat)
    native.open(chat)
    vim.wait(300, function()
      return rail.win() and api.nvim_buf_line_count(api.nvim_win_get_buf(rail.win())) >= 5
    end)
    local win = rail.win()
    local buf = api.nvim_win_get_buf(win)
    local function lines()
      return api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    local function line_of(needle)
      for i, l in ipairs(lines()) do
        if l:find(needle, 1, true) then
          return i
        end
      end
    end

    -- EVERY REAL LINE IS A ROW, past the root: the PR line and the hints are
    -- virtual, so plain `j` never lands on decoration.
    eq("tree: the root, two workspaces, two agents -- and nothing else", #lines(), 5)
    local virt = api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local right, below = {}, {}
    for _, mark in ipairs(virt) do
      local d = mark[4]
      if d.virt_text_pos == "right_align" then
        right[#right + 1] = text_of(d.virt_text)
      end
      if d.virt_lines then
        for _, vl in ipairs(d.virt_lines) do
          below[#below + 1] = text_of(vl)
        end
      end
    end
    truthy(
      "tree: the diff stat is right-aligned on its row",
      vim.tbl_contains(right, "+5 -2 "),
      vim.inspect(right)
    )
    truthy("tree: the pull request is a line under it", #vim.tbl_filter(function(l)
      return l:find("#9", 1, true) ~= nil
    end, below) == 1, vim.inspect(below))

    -- KEY HINTS ARE OPT-IN: no `a new  w worktree` line unless asked for.
    local function hint_line()
      for _, l in ipairs(rail.build(32).below[#rail.build(32).lines] or {}) do
        if text_of(l):find("worktree", 1, true) then
          return true
        end
      end
      return false
    end
    local cfg = require("paseo.config").get().ui.native
    eq("tree: no key hints under the rail by default", hint_line(), false)
    cfg.hints.rail = true
    eq("tree: and the line is there when asked for", hint_line(), true)
    cfg.hints.rail = false

    -- A FINISHED AGENT'S SUBAGENTS ARE FOLDED, with how many on its row.
    truthy(
      "tree: folded, its subagents are not drawn",
      not line_of "kid one",
      table.concat(lines(), "\n")
    )
    truthy(
      "tree: and the row says how many it holds",
      lines()[line_of "finished parent"]:find("+2", 1, true)
    )

    native.focus_rail()
    eq(
      "tree: <C-s> lands on the agent on screen",
      rail.current_session() and rail.current_session().item.id,
      "t-1"
    )
    -- On the name, as nvim-tree's hijack_cursor puts it.
    local cur = api.nvim_win_get_cursor(win)
    truthy(
      "tree: the cursor sits on the name",
      lines()[cur[1]]:sub(cur[2] + 1):find "^on screen",
      lines()[cur[1]]
    )

    -- l unfolds, l again steps in, h from inside folds the parent and lands
    -- on it.
    api.nvim_win_set_cursor(win, { line_of "finished parent", 0 })
    vim.api.nvim_feedkeys("l", "x", false)
    truthy("tree: l unfolds", line_of "kid one", table.concat(lines(), "\n"))
    vim.api.nvim_feedkeys("l", "x", false)
    eq(
      "tree: and l again steps onto the first one",
      rail.current_session() and rail.current_session().item.id,
      "k1"
    )
    vim.api.nvim_feedkeys(">", "x", false)
    eq("tree: > is the next sibling", rail.current_session().item.id, "k2")
    vim.api.nvim_feedkeys("P", "x", false)
    eq("tree: P is the parent", rail.current_session().item.id, "t-2")
    vim.api.nvim_feedkeys("j", "x", false)
    vim.api.nvim_feedkeys("h", "x", false)
    eq(
      "tree: h on a leaf folds the one it is in and lands on it",
      rail.current_session() and rail.current_session().item.id,
      "t-2"
    )
    truthy("tree: folded again", not line_of "kid one")

    -- THE CURSOR STAYS ON ITS ROW when the rows above it move.
    api.nvim_win_set_cursor(win, { line_of "beta", 0 })
    listed[#listed + 1] = {
      id = "t-3",
      title = "a new one",
      status = "running",
      workspaceId = "ws-a",
      cwd = root .. "/a",
      createdAt = "3",
    }
    rail.draw()
    eq(
      "tree: a row added above does not move the cursor off beta",
      rail.current() and rail.current().id,
      "ws-b"
    )

    -- W folds everything and leaves the cursor in the workspace it was in.
    api.nvim_win_set_cursor(win, { line_of "on screen", 0 })
    vim.api.nvim_feedkeys("W", "x", false)
    eq("tree: W folds everything", #lines(), 3)
    eq("tree: on the workspace the cursor was in", rail.current() and rail.current().id, "ws-a")
    vim.api.nvim_feedkeys("E", "x", false)
    truthy(
      "tree: E unfolds everything, subagents too",
      line_of "kid two",
      table.concat(lines(), "\n")
    )

    -- <CR> on a workspace folds it.
    api.nvim_win_set_cursor(win, { line_of "alpha", 0 })
    rail.open_current()
    truthy("tree: <CR> on a workspace folds it", not line_of "on screen")

    -- A PUSHED UPSERT is written over its row; one that moves the row is not.
    truthy(
      "tree: an upsert patches its row",
      rail.patch(
        { id = "ws-a", name = "alpha", diffStat = { additions = 50, deletions = 1 } },
        host
      )
    )
    eq("tree: with the new stat", text_of(rail.diff_stat(rail.current())), "+50 -1")
    eq("tree: and a field it no longer has is gone", rail.current().pr, nil)
    eq("tree: a rename is a refetch", rail.patch({ id = "ws-a", name = "renamed" }, host), false)
    eq(
      "tree: so is a workspace that is not here",
      rail.patch({ id = "ws-zzz", name = "x" }, host),
      false
    )
    native.close(chat)
  end)

  vim.o.columns, vim.o.lines = saved.columns, saved.lines
  bridge.running, agents.watch = saved.running, saved.watch
  agents.get, agents.all, agents.for_workspace = saved.get, saved.all, saved.for_workspace
  subagents.list, subagents.track, terminals.watch = saved.sub_list, saved.track, saved.term_watch
  workspaces.list, workspaces.here = saved.list, saved.here
  vim.env.XDG_STATE_HOME = saved.state
  rail.reset()
  pcall(native.reset)
  if not ok then
    error(failure, 0)
  end
end

return {
  { "ui.rail.buckets", test_buckets },
  { "ui.rail.layout", test_layout },
  { "ui.rail.toggle", test_toggle },
  { "ui.rail.current", test_current },
  { "ui.rail.sessions", test_sessions },
  { "ui.rail.tree", test_tree },
}
