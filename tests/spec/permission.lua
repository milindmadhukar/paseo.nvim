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

  -- The dialog takes the cursor, so the next "go to the next buffer" key runs
  -- in it. That used to load an agent INTO the dialog's floating window.
  local dialog = vim.api.nvim_get_current_win()
  local dialog_buf = vim.api.nvim_win_get_buf(dialog)
  eq("held: the dialog has the cursor", vim.api.nvim_win_get_config(dialog).zindex, 200)
  truthy("held: the dialog is pinned to its buffer", vim.wo[dialog].winfixbuf)
  local listed = vim.api.nvim_create_buf(true, false)
  eq("held: switching buffer inside it is refused", pcall(vim.api.nvim_set_current_buf, listed), false)
  eq("held: :bnext inside it is refused", pcall(vim.cmd.bnext), false)
  eq("held: and the dialog still shows the question", vim.api.nvim_win_get_buf(dialog), dialog_buf)
  vim.api.nvim_buf_delete(listed, { force = true })

  permission.close()
  vim.cmd "wincmd p"
  vim.cmd "wincmd p"
  vim.wait(100)
  eq("held: once -- dismissed stays dismissed until `gp`", permission._showing(), nil)
  vim.api.nvim_win_close(chat.win_conversation, true)
end

--- A Paseo subagent's request is answered in its parent's chat.
---
--- The bug, reproduced against a real daemon: an agent started by another
--- agent through Paseo blocked on a Bash call and NOTHING in Neovim showed it.
--- Its requests ride its own timeline, which is only followed for an agent with
--- a chat of its own, and nobody opens one -- you are watching the parent.
local function test_permission_relay()
  local permission = require "paseo.ui.permission"
  local transcript = require "paseo.ui.transcript"
  local agents = require "paseo.agents"
  local bridge = require "paseo.bridge"
  local label = require("paseo.subagents").PARENT_LABEL
  local old_request = bridge.request

  local pending = {
    { id = "child-req", kind = "tool", name = "Bash", title = "Bash", actions = { { id = "allow", behavior = "allow", label = "Allow" } } },
  }
  local asked, answered = {}, nil
  local ok, err = pcall(function()
    bridge.request = function(op, args, callback)
      asked[#asked + 1] = op .. ":" .. tostring(args.agentId)
      if op == "agent.pendingPermissions" then
        return callback(nil, { requests = vim.deepcopy(pending) })
      end
      if op == "agent.respondToPermission" then
        answered = args
      end
      callback(nil, {})
    end

    local chat = { agent_id = "parent", conversation = vim.api.nvim_create_buf(false, true) }
    transcript.reset(chat)
    local function directory(count, extra)
      local entries = {
        { id = "parent", status = "idle" },
        { id = "child", title = "write the tests", status = "running", pendingPermissionCount = count, updatedAt = tostring(count), labels = { [label] = "parent" } },
      }
      vim.list_extend(entries, extra or {})
      agents._apply { kind = "snapshot", entries = entries }
    end
    local function none()
      return false
    end

    directory(1)
    permission.relay(chat, none)
    vim.wait(500, function()
      return #(chat.permissions or {}) == 1
    end, 10)
    eq("relay: the subagent's pending list is asked for", asked[1], "agent.pendingPermissions:child")
    eq("relay: its request is held in the parent's chat", chat.permissions[1].id, "child-req")
    eq("relay: tagged with who asked", chat.permissions[1].via, "write the tests")
    truthy("relay: and drawn in the parent's conversation", chat.permission_blocks["child-req"] ~= nil)

    -- The parent's own snapshot does not list it, and must not drop it.
    permission.reconcile(chat, {})
    eq("relay: the parent's own reconcile leaves it alone", #chat.permissions, 1)

    -- Answered to the agent that ASKED.
    permission.respond(chat, chat.permissions[1], { behavior = "allow", selectedActionId = "allow" })
    eq("relay: the answer goes to the subagent", answered and answered.agentId, "child")
    eq("relay: and it is no longer held", #chat.permissions, 0)

    -- Answered elsewhere: the count drops, and the card says so.
    pending = {
      { id = "child-req-2", kind = "tool", name = "Edit", title = "Edit", actions = {} },
    }
    directory(1, nil)
    agents._apply { kind = "snapshot", entries = {
      { id = "parent", status = "idle" },
      { id = "child", title = "write the tests", status = "running", pendingPermissionCount = 1, updatedAt = "again", labels = { [label] = "parent" } },
    } }
    permission.relay(chat, none)
    vim.wait(500, function()
      return #(chat.permissions or {}) == 1
    end, 10)
    eq("relay: a second request is relayed too", chat.permissions[1] and chat.permissions[1].id, "child-req-2")
    pending = {}
    agents._apply { kind = "snapshot", entries = {
      { id = "parent", status = "idle" },
      { id = "child", title = "write the tests", status = "running", pendingPermissionCount = 0, updatedAt = "done", labels = { [label] = "parent" } },
    } }
    permission.relay(chat, none)
    eq("relay: answered elsewhere, it is dropped", #chat.permissions, 0)
    eq(
      "relay: and the card says so",
      chat.blocks[chat.permission_blocks["child-req-2"]].item.resolution,
      "answered elsewhere"
    )

    -- A subagent with a chat of its own answers there, not here.
    asked = {}
    agents._apply { kind = "snapshot", entries = {
      { id = "parent", status = "idle" },
      { id = "child", title = "write the tests", status = "running", pendingPermissionCount = 1, updatedAt = "own", labels = { [label] = "parent" } },
    } }
    permission.relay(chat, function(id)
      return id == "child"
    end)
    eq("relay: not for a subagent with its own chat", #asked, 0)
  end)
  bridge.request = old_request
  permission.close()
  agents._apply { kind = "snapshot", entries = {} }
  if not ok then
    error(err, 0)
  end
end

--- A plan's badge says which Implement was taken, even when the only word on
--- it is the daemon's. `permission_resolved` lands after the local answer with
--- just `{behavior, selectedActionId}`, and used to overwrite the badge with a
--- bare "allowed" -- which is also all a plan approved in the app ever got.
local function test_permission_plan_badge()
  local permission = require "paseo.ui.permission"
  local transcript = require "paseo.ui.transcript"

  local chat = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(chat)

  local function plan_request(id)
    return {
      id = id,
      kind = "plan",
      name = "ExitPlanMode",
      input = { plan = "do it" },
      actions = {
        { id = "reject", label = "Reject", behavior = "deny", intent = "dismiss" },
        { id = "implement", label = "Implement", behavior = "allow", intent = "implement" },
        {
          id = "implement_resume",
          label = "Implement with Bypass",
          behavior = "allow",
          intent = "implement_resume",
        },
      },
    }
  end

  permission.reconcile(chat, { plan_request "p1", plan_request "p2", plan_request "p3" })
  local function badge(id)
    return chat.blocks[chat.permission_blocks[id]].item.resolution
  end

  permission.resolved(chat, "p1", { behavior = "allow", selectedActionId = "implement_resume" })
  eq("plan badge: the daemon's resume names its button", badge "p1", "implemented (Implement with Bypass)")
  permission.resolved(chat, "p2", { behavior = "allow", selectedActionId = "implement" })
  eq("plan badge: a plain Implement is implemented", badge "p2", "implemented")
  permission.resolved(chat, "p3", { behavior = "deny", selectedActionId = "reject" })
  eq("plan badge: a reject is still planning", badge "p3", "rejected, still planning")
  permission.close()
end

return {
  { "plan_badge", test_permission_plan_badge },
  { "relay", test_permission_relay },
  { "sync", test_permission_sync },
  { "held", test_permission_held },
}
