--- The terminal directory.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures

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

  -- Terminals are SESSIONS now, listed beside the agents the way Paseo lists
  -- them, and the surface is `:Paseo term`. A seventh tab holding a list is
  -- the thing that was replaced, so its absence is the assertion.
  local float = require "paseo.ui.float"
  eq("terminals: the dashboard has five tabs", #float.TABS, 5)
  truthy("terminals: and none of them is the Sessions tab -- the tree is", not vim.tbl_contains(float.TABS, "Sessions"))
  truthy(
    "terminals: and none of them is a Terminals tab",
    not vim.tbl_contains(float.TABS, "Terminals")
  )

  -- The registry: several terminals alive at once is the whole point, and one
  -- `terminal_output` listener routing by id is how they are fed.
  local view = require "paseo.ui.terminal"
  local bridge = require "paseo.bridge"
  local old_request = bridge.request
  local attaches = {}
  bridge.request = function(op, args, callback)
    if op == "terminals.attach" then
      attaches[#attaches + 1] = args.terminalId
    end
    (callback or function() end)(nil, {})
  end
  local ok_registry, registry_err = pcall(function()
    apply {
      kind = "snapshot",
      cwd = root,
      entries = { { id = "r1", name = "one" }, { id = "r2", name = "two" } },
    }
    local a = view.ensure(terminals.get "r1")
    local again = view.ensure(terminals.get "r1")
    eq("terminals: ensure is idempotent", a, again)
    eq("terminals: so the scrollback is replayed once", #attaches, 1)

    local b = view.ensure(terminals.get "r2")
    truthy("terminals: two are alive at once", a.buf ~= b.buf)
    eq("terminals: and both are attached", #attaches, 2)

    -- One listener, routed by id: bytes for r2 must not land in r1.
    vim.api.nvim_chan_send(b.chan, "hello from two")
    vim.wait(200)
    local text = table.concat(vim.api.nvim_buf_get_lines(b.buf, 0, -1, false), "")
    truthy(
      "terminals: output reaches the terminal it belongs to",
      text:find("hello from two", 1, true) ~= nil
    )
    local other = table.concat(vim.api.nvim_buf_get_lines(a.buf, 0, -1, false), "")
    truthy("terminals: and not the other one", other:find("hello", 1, true) == nil)

    -- Death arrives as a snapshot that no longer lists it.
    view.detach "r2"
    eq("terminals: a detached one is gone", view.view "r2", nil)
    truthy("terminals: and leaves the other alone", view.view "r1" ~= nil)
    view.detach_all()
    eq("terminals: detach_all empties the registry", vim.tbl_count(view.views()), 0)
  end)
  bridge.request = old_request
  apply { kind = "snapshot", cwd = root, entries = {} }
  truthy("terminals: the registry cases ran", ok_registry, registry_err)

  -- THE SESSION TREE: agents and terminals in one column, each agent with
  -- its subagents under it, and the session on screen marked.
  local tree = require "paseo.ui.tree"
  local agents = require "paseo.agents"
  local subagents = require "paseo.subagents"
  local old = { for_root = agents.for_root, get = agents.get, list = subagents.list }
  agents.get = function()
    return nil
  end
  agents.for_root = function()
    return {
      { id = "a1", title = "reviewer", provider = "claude/opus", status = "idle", createdAt = "1" },
      {
        id = "a2",
        title = "child",
        status = "running",
        createdAt = "2",
        labels = { [subagents.PARENT_LABEL] = "a1" },
      },
    }
  end
  subagents.list = function(parent)
    if parent == "a1" then
      return {
        { kind = "provider", id = "task", parent = "a1", title = "Map the auth flow", status = "running", running = true },
        { kind = "paseo", id = "a2", parent = "a1", title = "child", status = "running", running = true },
      }
    end
    return {}
  end
  local ok_tree, tree_err = pcall(function()
    apply {
      kind = "snapshot",
      cwd = root,
      entries = { { id = "t1", name = "shell" } },
    }
    local chat = { root = root, agent_id = "a1" }
    local lines, rows = tree.lines(chat, 40)
    local text = {}
    for i, line in ipairs(lines) do
      local parts = {}
      for _, cell in ipairs(line) do
        parts[#parts + 1] = cell[1]
      end
      text[i] = table.concat(parts)
    end
    local joined = table.concat(text, "\n")
    truthy("tree: agents are listed", joined:find("reviewer", 1, true) ~= nil, joined)
    truthy("tree: and terminals below them", joined:find("shell", 1, true) ~= nil, joined)

    local order = {}
    for line = 1, #lines do
      local node = rows[line]
      if node then
        order[#order + 1] = ("%s:%s:%d"):format(node.kind, node.item.id, node.depth)
      end
    end
    -- The Paseo subagent is listed ONCE, under its parent, not again at the
    -- top level beside it.
    eq("tree: subagents hang off their parent", order, {
      "agent:a1:0",
      "subagent:task:1",
      "subagent:a2:1",
      "terminal:t1:0",
    })
    truthy("tree: drawn as a tree", joined:find("├", 1, true) and joined:find("└", 1, true), joined)
    truthy("tree: the parent says how many are running", joined:find("2/2", 1, true) ~= nil, joined)
    truthy("tree: and its provider, short", joined:find("claude", 1, true) and not joined:find("opus", 1, true), joined)
  end)
  agents.for_root, agents.get, subagents.list = old.for_root, old.get, old.list
  apply { kind = "snapshot", cwd = root, entries = {} }
  truthy("tree: the cases ran", ok_tree, tree_err)
end

return {
  { "terminals", test_terminals },
}
