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

return {
  { "archive: agents leaving the directory", test_gone },
  { "archive: an archived agent's chat goes", test_chat_goes },
}
