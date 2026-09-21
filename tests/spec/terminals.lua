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
  eq("terminals: the dashboard is back to six tabs", #float.TABS, 6)
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

  -- The merged list. Selection is held BY ID, so what has to survive is not a
  -- line number but the list moving under it -- which, for a directory fed by
  -- push, it does constantly.
  local panel = require "paseo.ui.panels.sessions"
  local agents = require "paseo.agents"
  local old_for_root, old_watch = agents.for_root, agents.watch
  agents.watch = function() end
  agents.for_root = function()
    return { { id = "a1", title = "reviewer", provider = "claude", status = "idle" } }
  end
  local ok_merged, merged_err = pcall(function()
    apply {
      kind = "snapshot",
      cwd = root,
      entries = { { id = "t1", name = "shell" }, { id = "t2", name = "zzz-last" } },
    }
    local chat = { root = root, agent_id = nil }
    local text = {}
    for _, line in ipairs(panel.lines(chat, 80)) do
      local parts = {}
      for _, cell in ipairs(line) do
        parts[#parts + 1] = cell[1]
      end
      text[#text + 1] = table.concat(parts)
    end
    local joined = table.concat(text, "\n")
    truthy("sessions: agents are listed", joined:find("reviewer", 1, true) ~= nil)
    truthy("sessions: and terminals beside them", joined:find("shell", 1, true) ~= nil)

    -- Focus lands on a row without anyone moving first: arriving at a tab
    -- whose first <CR> does nothing is the bug this panel actually had.
    local view = panel._view(chat)
    local focused = view:resolve()
    truthy("sessions: focus is seeded on a real row", focused ~= nil and focused.id ~= nil)

    -- Walk to the terminal and stand on it.
    for _ = 1, 8 do
      if (view:resolve()).id == "terminal.t1" then
        break
      end
      view:move(1)
    end
    eq("sessions: and the keyboard reaches a terminal row", (view:resolve()).id, "terminal.t1")

    -- REORDER, REDRAW, AND FOCUS MUST NOT WANDER. Sorted by name, so renaming
    -- `shell` to `aaa` moves `t1` below `t2` -- a row that held selection by
    -- position would now be pointing at the other terminal, silently, while
    -- you were reading.
    apply {
      kind = "snapshot",
      cwd = root,
      entries = { { id = "t1", title = "zzz-renamed" }, { id = "t2", name = "aaa" } },
    }
    panel.lines(chat, 80)
    eq(
      "sessions: a reordered list keeps focus on the same session",
      (view:resolve()).id,
      "terminal.t1"
    )

    -- And a row that DIES hands focus on rather than dropping it.
    apply { kind = "snapshot", cwd = root, entries = { { id = "t2", name = "aaa" } } }
    panel.lines(chat, 80)
    local after = view:resolve()
    truthy("sessions: killing the focused row leaves focus somewhere real", after ~= nil, after)
    truthy(
      "sessions: and not on the row that went",
      after and after.id ~= "terminal.t1",
      after and after.id
    )
  end)
  agents.for_root, agents.watch = old_for_root, old_watch
  apply { kind = "snapshot", cwd = root, entries = {} }
  truthy("sessions: the merged-list cases ran", ok_merged, merged_err)
end

return {
  { "terminals", test_terminals },
}
