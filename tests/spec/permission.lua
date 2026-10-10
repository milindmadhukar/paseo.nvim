--- Keeping the held permissions in step with the daemon.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

--- Answering somewhere else must not desync this side.
---
--- `permission_resolved` is a real event and it does fire, but it is not the
--- only way a request stops being pending: the daemon replaces its pending map
--- wholesale on a session refresh with no resolution for what vanished, and a
--- resolution that lands while the socket is down is never replayed. The list
--- held here used to have exactly one add and one remove and no way to be told
--- it was wrong, so any of those left a prompt that `gp` would reopen and the
--- daemon would refuse.
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

--- A request that could not open when it arrived is HELD, not dropped: it
--- opens the moment the chat is in front of you. It used to get one passing
--- notification and nothing else -- arriving while you typed, or during the
--- reconcile that runs before a chat's windows exist -- and the agent sat
--- blocked behind a winbar saying `needs you`.
local function test_permission_held()
  local permission = require "paseo.ui.permission"
  local transcript = require "paseo.ui.transcript"

  local chat = { agent_id = "held", conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(chat)
  permission.offer(chat, { id = "h", kind = "tool", name = "Bash", title = "Run h", actions = {} })
  vim.wait(50)
  eq("held: no chat window yet, nothing opens", permission._showing(), nil)

  vim.cmd "split"
  vim.api.nvim_win_set_buf(0, chat.conversation)
  chat.win_conversation = vim.api.nvim_get_current_win()
  vim.cmd "wincmd p"
  vim.cmd "wincmd p"
  truthy("held: entering the chat opens it", vim.wait(500, function()
    return permission._showing() == "h"
  end))

  permission.close()
  vim.cmd "wincmd p"
  vim.cmd "wincmd p"
  vim.wait(100)
  eq("held: once -- dismissed stays dismissed until `gp`", permission._showing(), nil)
  vim.api.nvim_win_close(chat.win_conversation, true)
end

return {
  { "sync", test_permission_sync },
  { "held", test_permission_held },
}
