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
  eq("rail: a pending permission is waiting on you", agents.bucket { status = "running", pendingPermissionCount = 1 }, "needs_input")
  eq("rail: so is our own permission flag, from an older sidecar", agents.bucket { status = "idle", requiresAttention = true }, "needs_input")
  eq("rail: a failed agent is failed", agents.bucket { status = "error" }, "failed")
  eq("rail: and so is one the daemon flagged for an error", agents.bucket { status = "idle", attentionReason = "error", daemonAttention = true }, "failed")
  eq("rail: running is running", agents.bucket { status = "running" }, "running")
  eq("rail: and booting spins too", agents.bucket { status = "initializing" }, "running")
  eq("rail: finished unseen is news", agents.bucket { status = "idle", attentionReason = "finished", daemonAttention = true }, "attention")
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
  eq("rail: a workspace answers with its most urgent agent", agents.workspace_bucket(root, host), "needs_input")
  eq("rail: and a sibling directory is not inside it", agents.workspace_bucket(root .. "-other", host), "failed")
  eq("rail: no agents is none", agents.workspace_bucket(root .. "-nobody", host), "none")
  agents._apply { kind = "snapshot", hostId = host, entries = {} }

  -- The glyphs the user asked for, by bucket.
  local rail = require "paseo.ui.rail"
  local icons = require "paseo.ui.icons"
  eq("rail: waiting is a yellow exclamation", { rail.status "needs_input" }, { icons.status.waiting, "PaseoBadge" })
  eq("rail: failed is a red dot", { rail.status "failed" }, { icons.status.idle, "PaseoToolFail" })
  eq("rail: done is a green dot", { rail.status "done" }, { icons.status.idle, "PaseoToolOk" })
  truthy("rail: running is a spinner frame", vim.tbl_contains(icons.spinner, (rail.status "running")))
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
  local float = require "paseo.ui.float"
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
    float.open(chat)
    -- The list lands on the next tick.
    vim.wait(200, function()
      return rail.current() ~= nil or (rail.win() and api.nvim_buf_line_count(api.nvim_win_get_buf(rail.win())) > 3)
    end)
    local win = rail.win()
    truthy("rail: the window is up", win ~= nil)
    eq("rail: and the cursor stayed in the composer", api.nvim_get_current_buf(), chat.composer)

    local config = api.nvim_win_get_config(win)
    local composer = api.nvim_win_get_config(chat.win_composer)
    truthy("rail: left of the conversation", config.col + config.width < composer.col)
    local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n")
    truthy("rail: lists the project's workspaces", text:find("alpha", 1, true) and text:find("beta", 1, true), text)

    -- Into it, down a row, and open.
    float.focus_rail()
    eq("rail: the focus key lands in it", api.nvim_get_current_win(), win)
    local first = rail.current()
    truthy("rail: on a workspace, not the heading", first ~= nil)
    vim.api.nvim_feedkeys("j", "x", false)
    truthy("rail: j moves to the next workspace", rail.current() and rail.current() ~= first)
    rail.open_current()
    eq("rail: <CR> opens the one under the cursor", opened and opened.name, rail.current().name)

    -- Toggle off: the window goes, the panes take the room back, and the
    -- choice is remembered for the next session.
    float.toggle_rail()
    eq("rail: toggled off, the window is gone", rail.win(), nil)
    truthy("rail: and focus went back to the composer", api.nvim_get_current_buf() == chat.composer)
    local wide = api.nvim_win_get_config(chat.win_composer)
    truthy("rail: the composer moved left into the room", wide.col < composer.col and wide.width > composer.width)
    rail.reset()
    eq("rail: the toggle is remembered across restarts", rail.visible(), false)

    float.toggle_rail()
    truthy("rail: and back on", rail.win() ~= nil)
    float.close()
    eq("rail: closing the dashboard takes the rail with it", rail.win(), nil)

    -- Too narrow: no rail at all, and the panes keep their old geometry.
    vim.o.columns = 80
    float.open(chat)
    eq("rail: none on a narrow surface", rail.win(), nil)
    float.close()
  end)

  vim.o.columns, vim.o.lines = saved.columns, saved.lines
  bridge.running, agents.watch = saved.running, saved.watch
  workspaces.list, workspaces.here, workspaces.open = saved.list, saved.here, saved.open
  vim.env.XDG_STATE_HOME = saved.state
  rail.reset()
  pcall(float.close)
  if not ok then
    error(failure, 0)
  end
end

return {
  { "ui.rail.buckets", test_buckets },
  { "ui.rail.layout", test_layout },
  { "ui.rail.toggle", test_toggle },
}
