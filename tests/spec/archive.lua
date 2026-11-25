--- An archived agent's chat goes: whoever archived it, however the news came.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_gone()
  local agents = require "paseo.agents"
  local host = require("paseo.hosts").selected()
  local seen = {}
  agents.on_gone(function(gone, host_id)
    for _, a in ipairs(gone) do
      seen[#seen + 1] = a.id .. "@" .. tostring(host_id == host)
    end
  end)
  agents._apply {
    kind = "snapshot",
    hostId = host,
    entries = { { id = "g1", title = "one" }, { id = "g2", title = "two" }, { id = "g3", title = "three" } },
  }
  eq("gone: a first snapshot is not news", #seen, 0)
  agents._apply { kind = "remove", hostId = host, id = "g1" }
  agents._apply { kind = "remove", hostId = host, id = "g1" }
  eq("gone: a removal is, once, however often the daemon says it", seen, { "g1@true" })
  agents._apply { kind = "snapshot", hostId = host, entries = { { id = "g3", title = "three" } } }
  eq("gone: missing from a fresh snapshot is gone too", seen, { "g1@true", "g2@true" })
  agents._apply { kind = "snapshot", hostId = host, entries = {} }
end

local function test_chat_goes()
  local agents = require "paseo.agents"
  local chat = require "paseo.ui.chat"
  local host = require("paseo.hosts").selected()
  agents._apply { kind = "snapshot", hostId = host, entries = { { id = "arch-1", title = "Doomed" } } }
  local c = chat.prepare { agent_id = "arch-1", host_id = host, root = vim.fn.getcwd(), title = "Doomed" }
  truthy("chat: prepared", c ~= nil)
  local buf = c.conversation
  local notified
  local notify = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  agents._apply { kind = "remove", hostId = host, id = "arch-1" }
  vim.wait(500, function()
    return not vim.api.nvim_buf_is_valid(buf)
  end)
  vim.notify = notify
  truthy("chat: the archived agent's buffer is wiped", not vim.api.nvim_buf_is_valid(buf))
  truthy("chat: and the chat forgotten", not vim.tbl_contains(chat.all(), c))
  truthy("chat: and you are told which", notified and notified:find("Doomed", 1, true) ~= nil)
end

local function test_undo()
  local bridge = require "paseo.bridge"
  local workspaces = require "paseo.workspaces"
  local old_request, old_notify = bridge.request, vim.notify
  local old_archive = workspaces.archive
  local requests = {}
  local ok, failure = pcall(function()
    vim.notify = function() end
    bridge.request = function(op, args, callback)
      requests[#requests + 1] = { op = op, args = args }
      callback(nil, {})
    end

    workspaces.archived = nil
    eq("undo: nothing archived, nothing to undo", workspaces.undo_archive(), false)

    -- `d` on the rail archives through here.
    workspaces.confirm_archive { id = "w9", name = "feature", directory = "/x" }
    eq("undo: an archive is remembered", workspaces.archived and workspaces.archived.id, "w9")
    local done
    eq("undo: and taken back", workspaces.undo_archive(function(err)
      done = err or true
    end), true)
    vim.wait(200, function()
      return done ~= nil
    end, 10)
    eq("undo: by the daemon's undo", requests[#requests].op, "workspace.archive.undo")
    eq("undo: of that workspace", requests[#requests].args.workspaceId, "w9")
    eq("undo: once", workspaces.undo_archive(), false)

    -- Too late: the app's toast has gone.
    workspaces.confirm_archive { id = "w8", name = "old", directory = "/y" }
    workspaces.archived.at = vim.uv.now() - workspaces.UNDO_WINDOW - 1
    local before = #requests
    eq("undo: not after the window", workspaces.undo_archive(), false)
    eq("undo: and nothing is sent", #requests, before)

    -- One we assembled: its worktrees went by our hand; no undo is offered.
    workspaces.archive = (function(real)
      return function(ws, opts, cb)
        if ws.assembled then
          return cb(nil)
        end
        return real(ws, opts, cb)
      end
    end)(workspaces.archive)
    workspaces.confirm_archive { id = "w7", name = "ws", directory = "/z", assembled = true }
    eq("undo: never for an assembled workspace", workspaces.archived, nil)
  end)
  workspaces.archive = old_archive
  workspaces.archived = nil
  bridge.request, vim.notify = old_request, old_notify
  if not ok then
    error(failure, 0)
  end
end

return {
  { "archive: undo a workspace archive", test_undo },
  { "archive: agents leaving the directory", test_gone },
  { "archive: an archived agent's chat goes", test_chat_goes },
}
