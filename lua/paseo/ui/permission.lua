--- The permission dialog.
---
--- Until now this did not exist. `pendingPermissions` was reduced to a boolean
--- at the sidecar boundary, so the plugin could tell you an agent needed you
--- and could not tell you what for, let alone let you answer -- which meant
--- opening the Paseo desktop app, the one thing this plugin exists to avoid.
---
--- The dialog shows `request.detail` through the SAME card builder the
--- transcript uses, so you approve a command having seen the command, and a
--- diff having seen the diff.

local bridge = require "paseo.bridge"
local hl = require "paseo.ui.hl"
local render = require "paseo.ui.render"
local timeline = require "paseo.ui.timeline"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.permission"

---The dialog is a singleton: one agent blocks at a time, and stacking floats
---for several would be unanswerable.
---@type table|nil
local open_dialog

-- ------------------------------------------------------------------ geometry

local function dimensions(lines)
  local w = math.min(100, math.max(50, vim.o.columns - 10))
  local h = math.min(#lines, math.max(8, vim.o.lines - 8))
  return w, h
end

-- --------------------------------------------------------------------- lines

---Everything the dialog shows, as `{text, hl}` lines.
---@param chat table
---@param request table
---@param width integer
---@return table[][]
local function build(chat, request, width)
  local inner = width - 4
  local lines = {}

  lines[#lines + 1] = {
    { "  ", "PaseoDanger" },
    { request.title or request.name or "Permission required", "PaseoDanger" },
  }
  if request.kind and request.kind ~= "tool" then
    lines[#lines + 1] = { { "  " .. request.kind, "PaseoDim" } }
  end
  lines[#lines + 1] = {}

  if request.description and request.description ~= "" then
    vim.list_extend(
      lines,
      render.wrap(request.description, inner, "PaseoDim", { { "  ", nil } })
    )
    lines[#lines + 1] = {}
  end

  -- THE POINT OF THE DIALOG. The same builder the transcript uses, so what you
  -- are approving is shown rather than named.
  local body = timeline.detail_body(request.detail, inner)
  if #body > 0 then
    local card = render.card(
      { { request.name or "tool", "PaseoToolName" } },
      body,
      { width = inner }
    )
    for _, line in ipairs(card) do
      local row = { { "  ", nil } }
      vim.list_extend(row, line)
      lines[#lines + 1] = row
    end
    lines[#lines + 1] = {}
  end

  -- Actions. The sidecar guarantees this is non-empty -- a provider that sends
  -- none gets a synthesised Allow/Deny -- so there is no empty-list branch.
  local buttons = { { "  ", nil } }
  for i, action in ipairs(request.actions or {}) do
    local group = action.variant == "danger" and "PaseoDanger"
      or action.behavior == "allow" and "PaseoToolOk"
      or "PaseoDim"
    buttons[#buttons + 1] = { (" %d "):format(i), "PaseoKey" }
    buttons[#buttons + 1] = { action.label or action.id, group }
    buttons[#buttons + 1] = { "   ", nil }
  end
  lines[#lines + 1] = buttons
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  y", "PaseoKey" },
    { " allow · ", "PaseoDim" },
    { "n", "PaseoKey" },
    { " deny · ", "PaseoDim" },
    { "<Esc>", "PaseoKey" },
    { " later (stays pending)", "PaseoDim" },
  }

  return lines
end

-- ------------------------------------------------------------------ answering

---@param chat table
---@param request table
---@param action table
local function answer(chat, request, action)
  M.close()

  bridge.request("agent.respondToPermission", {
    agentId = chat.agent_id,
    requestId = request.id,
    behavior = action.behavior,
    selectedActionId = action.id,
  }, function(err)
    if err then
      vim.schedule(function()
        transcript.upsert(chat, {
          kind = "notice",
          level = "error",
          message = "permission answer failed: " .. err,
        })
      end)
    end
  end)

  -- Mark it locally straight away. `permission_resolved` will confirm, but the
  -- round trip is visible and leaving the card reading "awaiting" in the
  -- meantime makes the keypress look ignored.
  M.resolved(chat, request.id, { behavior = action.behavior, label = action.label })
end

-- ---------------------------------------------------------------- the window

function M.close()
  if not open_dialog then
    return
  end
  local dialog = open_dialog
  open_dialog = nil

  for _, win in ipairs { dialog.win, dialog.backdrop_win } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs { dialog.buf, dialog.backdrop } do
    if buf and api.nvim_buf_is_valid(buf) then
      -- Volt keys its state by buffer and never clears it itself; leaving the
      -- entry behind leaks this dialog's clickable tables for the session.
      pcall(function()
        require("volt.state")[buf] = nil
      end)
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---@param chat table
---@param request table
local function open(chat, request)
  M.close()

  local width = math.min(100, math.max(50, vim.o.columns - 10))
  local lines = build(chat, request, width)
  local w, h = dimensions(lines)

  -- A dimmed backdrop, so the dialog reads as modal. typr does the same for
  -- its stats window.
  local backdrop = api.nvim_create_buf(false, true)
  local backdrop_win = api.nvim_open_win(backdrop, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    focusable = false,
    style = "minimal",
    border = "none",
    zindex = 190,
  })
  vim.wo[backdrop_win].winblend = 30

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
    col = math.floor((vim.o.columns - w) / 2),
    width = w,
    height = h,
    style = "minimal",
    border = "rounded",
    -- Above the big float, which sits at 100.
    zindex = 200,
  })

  open_dialog = {
    buf = buf,
    win = win,
    backdrop = backdrop,
    backdrop_win = backdrop_win,
    chat = chat,
    request = request,
  }

  -- Volt owns this buffer entirely: it is chrome, nothing is typed into it,
  -- and it is ours to delete. That is exactly the case volt is for -- unlike
  -- the composer, which must never be handed to it.
  local ok = pcall(function()
    local volt = require "volt"
    volt.gen_data {
      {
        buf = buf,
        ns = ns,
        xpad = 1,
        layout = {
          {
            name = "permission",
            -- A FRESH table every call: `volt.draw` does
            -- `table.remove(marks, 3)` on what it is handed, so a cached line
            -- list loses its actions after the first draw.
            lines = function()
              return render.to_volt(build(chat, request, width))
            end,
          },
        },
      },
    }
    volt.run(buf, { h = h, w = w })
  end)

  if not ok then
    -- Volt missing or unhappy is not a reason to be unable to answer: draw the
    -- same lines as real text instead.
    render.to_buffer(buf, hl.ns, 0, -1, lines)
    vim.bo[buf].modifiable = false
  end

  local map = function(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  for i, action in ipairs(request.actions or {}) do
    if i <= 9 then
      map(tostring(i), function()
        answer(chat, request, action)
      end)
    end
  end

  ---@param behavior string
  local function first(behavior)
    for _, action in ipairs(request.actions or {}) do
      if action.behavior == behavior then
        return action
      end
    end
  end

  map("y", function()
    local action = first "allow"
    if action then
      answer(chat, request, action)
    end
  end)
  map("n", function()
    local action = first "deny"
    if action then
      answer(chat, request, action)
    end
  end)
  -- Deny AND stop the turn, for "no, and don't try something else either".
  map("N", function()
    local action = first "deny" or { id = "__deny", behavior = "deny" }
    M.close()
    bridge.request("agent.respondToPermission", {
      agentId = chat.agent_id,
      requestId = request.id,
      behavior = "deny",
      selectedActionId = action.id,
      interrupt = true,
    }, function() end)
    M.resolved(chat, request.id, { behavior = "deny", label = "denied, interrupted" })
  end)

  -- <Esc> and q DISMISS, they do not deny. Silently denying on a stray keypress
  -- throws away whatever the agent was doing, and the request is still
  -- answerable from the transcript with `gp`.
  map("<Esc>", M.close)
  map("q", M.close)
end

-- ----------------------------------------------------------------- the queue

---A request has arrived (live, or found pending when the chat opened).
---@param chat table
---@param request table
function M.offer(chat, request)
  chat.permissions = chat.permissions or {}

  -- The same request can reach us twice: once from `pendingPermissions` on
  -- open and once from the live event. Answering a request that is already
  -- answered is an error, so de-duplicate on id.
  for _, existing in ipairs(chat.permissions) do
    if existing.id == request.id then
      return
    end
  end
  chat.permissions[#chat.permissions + 1] = request

  -- ALWAYS log it inline first. The request is then part of the conversation
  -- and survives dismissing the dialog.
  local block = transcript.upsert(chat, { kind = "permission", request = request })
  chat.permission_blocks = chat.permission_blocks or {}
  chat.permission_blocks[request.id] = block.id

  -- Not thinking -- waiting. Through the setter, so the spinner's timer stops
  -- with it rather than ticking on against a flag that says otherwise.
  if chat.streaming ~= nil then
    require("paseo.ui.chat").set_streaming(chat, false)
  end

  -- Only steal focus if this chat is the window you are looking at. Yanking
  -- the cursor out of insert mode in another buffer is hostile.
  local win = api.nvim_get_current_win()
  local mine = win == chat.win_conversation or win == chat.win_composer
  if mine then
    open(chat, request)
  else
    vim.notify(
      ("paseo: %s needs permission — `gp` in the chat to answer"):format(
        request.title or request.name or "the agent"
      ),
      vim.log.levels.WARN
    )
  end
end

---Answered, by whoever answered it -- including the Paseo desktop app.
---@param chat table
---@param request_id string
---@param resolution table|nil
function M.resolved(chat, request_id, resolution)
  chat.permissions = chat.permissions or {}
  for i, request in ipairs(chat.permissions) do
    if request.id == request_id then
      table.remove(chat.permissions, i)
      break
    end
  end

  -- Close the dialog if it is showing THIS request. Answering on the desktop
  -- must not leave a dead prompt open here.
  if open_dialog and open_dialog.request and open_dialog.request.id == request_id then
    M.close()
  end

  local blocks = chat.permission_blocks or {}
  local block = blocks[request_id] and chat.blocks and chat.blocks[blocks[request_id]]
  if block then
    local label = resolution
      and (resolution.label or (resolution.behavior == "allow" and "allowed" or "denied"))
    block.item.resolution = label or "answered"
    transcript.rerender(chat, block)
  end

  -- Next in the queue, if the agent blocked on more than one thing.
  local next_request = chat.permissions[1]
  if next_request then
    vim.schedule(function()
      open(chat, next_request)
    end)
  elseif resolution and resolution.behavior == "allow" then
    -- Allowed means the turn carries on, so the agent is working again. It was
    -- the request that stopped it; nothing else says when it restarts, and a
    -- header frozen at idle through the rest of a long turn reads as a hang.
    require("paseo.ui.chat").set_streaming(chat, true)
  end
end

---Reopen the pending prompt. Bound to `gp` in the conversation.
---@param chat table
function M.reopen(chat)
  local request = (chat.permissions or {})[1]
  if not request then
    vim.notify("paseo: nothing is waiting on you", vim.log.levels.INFO)
    return
  end
  open(chat, request)
end

return M
