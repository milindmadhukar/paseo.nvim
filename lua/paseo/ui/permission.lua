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
---
--- THREE KINDS, TWO SURFACES. A request to ACT gets the allow/deny float below.
--- A question and a plan are not approvals -- you are composing a reply, not
--- pressing yes -- and they go to |paseo.ui.answer|, which takes over the chat
--- window. This module keeps what is common to all three and is not about
--- pixels: the queue, the inline transcript card, and the one response each
--- request gets.

local bridge = require "paseo.bridge"
local icons = require "paseo.ui.icons"
local hl = require "paseo.ui.hl"
local plan = require "paseo.ui.plan"
local questions = require "paseo.ui.questions"
local render = require "paseo.ui.render"
local timeline = require "paseo.ui.timeline"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.permission"

---|paseo.ui.answer|, if it can be loaded.
---
---Required lazily, and not because of a cycle -- `answer` requires nothing of
---this module, which is the point of it taking callbacks. It is because it draws
---with `paseo.ui.widgets`, which requires `volt.ui` outright, and neither the
---sidebar nor the dashboard does. So a tree without volt still gets this file,
---and still gets the plain allow/deny float below, rather than failing to load
---the module that answers permissions at all.
---@return table|nil
local function overlay()
  local ok, module = pcall(require, "paseo.ui.answer")
  return ok and module or nil
end

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
---
---A request to ACT only. Questions and plans never reach here -- `open` hands
---those to |paseo.ui.answer| -- which is why there is no branch for them and no
---`question_body`: one question at a time needs a window that can change
---height, and this one is sized once from its content.
---@param request table
---@param width integer
---@param view paseo.PermissionView
---@return table[][]
local function build(request, width, view)
  local inner = render.card_inner(width)
  local lines = {}

  lines[#lines + 1] = {
    { icons.status.permission .. "  ", "PaseoDanger" },
    { request.title or request.name or "Permission required", "PaseoDanger" },
  }
  if request.kind and request.kind ~= "tool" then
    lines[#lines + 1] = { { "  " .. request.kind, "PaseoDim" } }
  end
  lines[#lines + 1] = {}

  if request.description and request.description ~= "" then
    vim.list_extend(lines, render.wrap(request.description, inner, "PaseoDim", { { "  ", nil } }))
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
  for i, action in ipairs(view.actions) do
    local group = action.variant == "danger" and "PaseoDanger"
      or action.behavior == "allow" and "PaseoToolOk"
      or "PaseoDim"
    buttons[#buttons + 1] = { (" %d "):format(i), "PaseoKey" }
    buttons[#buttons + 1] = { action.label or action.id, group }
    buttons[#buttons + 1] = { "   ", nil }
    if i % 2 == 0 and i < #view.actions then
      lines[#lines + 1] = render.truncate(buttons, width)
      buttons = { { "  ", nil } }
    end
  end
  if #buttons > 1 then
    lines[#lines + 1] = render.truncate(buttons, width)
  end
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

---The one response a request gets, whichever surface produced it.
---
---There is exactly one of these because there is exactly one response: an allow
---for a tool, an allow carrying `updatedInput` for a question, an allow plus a
---follow-up mode for a plan, a deny with or without an interrupt. Three surfaces
---composing their own bridge call is how they drift, and the drift that actually
---happened -- a question answered with a bare allow, which reaches the agent as
---"The user did not answer the questions" -- is the reason this module exists.
---@param chat table
---@param request table
---@param opts { behavior: string, selectedActionId?: string, thenModeId?: string, updatedInput?: table, interrupt?: boolean, label?: string }
function M.respond(chat, request, opts)
  M.close()

  bridge.request("agent.respondToPermission", {
    agentId = chat.agent_id,
    requestId = request.id,
    behavior = opts.behavior,
    selectedActionId = opts.selectedActionId,
    -- The second half of a plan approval. It cannot ride in the response --
    -- `AgentPermissionResponse` has no field for a mode -- so the sidecar
    -- applies it after the daemon has finished applying its own. See
    -- |paseo.ui.plan|.
    thenModeId = opts.thenModeId,
    updatedInput = opts.updatedInput,
    interrupt = opts.interrupt,
  }, function(err, result)
    vim.schedule(function()
      if err then
        return transcript.upsert(chat, {
          kind = "notice",
          level = "error",
          message = "permission answer failed: " .. err,
        })
      end
      -- A provider may accept a mode and still have something to say about it.
      local notice = result and result.notice
      notice = type(notice) == "table" and notice.message or notice
      if type(notice) == "string" and notice ~= "" then
        vim.notify("paseo: " .. notice, vim.log.levels.WARN)
      end
    end)
  end)

  -- Mark it locally straight away. `permission_resolved` will confirm, but the
  -- round trip is visible and leaving the card reading "awaiting" in the
  -- meantime makes the keypress look ignored.
  M.resolved(chat, request.id, { behavior = opts.behavior, label = opts.label })
end

-- ---------------------------------------------------------------- the window

function M.close()
  local overlay_ = overlay()
  if overlay_ then
    overlay_.close()
  end

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
      -- Volt keys its state by buffer and never clears it itself, and it also
      -- keeps the buffer on its global key handler's list -- so BOTH halves,
      -- or this dialog's clickable tables leak and a dead buffer goes on being
      -- dispatched to for the rest of the session.
      pcall(function()
        require("volt.state")[buf] = nil
        local bufs = require("volt.events").bufs
        for i, id in ipairs(bufs) do
          if id == buf then
            table.remove(bufs, i)
            break
          end
        end
      end)
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---Which of the three dialogs this request wants.
---
---A question is answered, never approved; a plan is approved with a choice of
---what happens next; everything else is the plain allow/deny. `state` and
---`plan` are what the keys branch on, and building them ONCE here rather than
---re-deriving them per redraw is what keeps the three from drifting apart.
---@class paseo.PermissionView
---@field actions table[]                   The buttons, in key order.
---@field state paseo.QuestionState|nil     Set when the request is questions.
---@field plan boolean|nil                  Set when the request is a plan.

---@param chat table
---@param request table
---@return paseo.PermissionView
local function viewer(chat, request)
  local view = { actions = request.actions or {} }

  local asked = questions.parse(request)
  if asked then
    view.state = questions.state(asked)
    return view
  end

  if plan.parse(request) then
    view.plan = true
    -- `availableModes` is per PROVIDER and loaded with the rest of the session
    -- settings, so the buttons are the modes this agent can actually be put
    -- into. Without a snapshot there is nothing honest to offer and the
    -- request's own Implement/Reject stands.
    local config = chat.config_snapshot or {}
    view.actions = plan.actions(request, config.availableModes) or view.actions
  end

  return view
end

---The three callbacks |paseo.ui.answer| drives its keys with.
---
---Handed in rather than reached for, so the dependency stays one-way: this
---module requires `answer`, `answer` requires nothing of this. That is also what makes
---the overlay drivable in a test with stubs and no daemon.
---@param chat table
---@param request table
---@param view paseo.PermissionView
---@return paseo.AnswerHandlers
local function handlers(chat, request, view)
  ---@param behavior string
  local function first(behavior)
    for _, action in ipairs(view.actions or {}) do
      if action.behavior == behavior then
        return action
      end
    end
  end

  return {
    submit = function(state)
      local answers = questions.answers(state)
      M.respond(chat, request, {
        behavior = "allow",
        -- A question is allowed AND answered in the same message: the answers
        -- ride in `updatedInput`, and an allow without them reaches the agent as
        -- "The user did not answer the questions" -- approved, and silent.
        updatedInput = questions.input(request, state.questions, answers),
        label = questions.label(state.questions, answers),
      })
    end,

    choose = function(action)
      M.respond(chat, request, {
        behavior = action.behavior,
        selectedActionId = action.id,
        thenModeId = action.mode,
        label = view.plan and plan.label(action) or action.label,
      })
    end,

    reject = function(interrupt)
      -- The synthetic id survives: the sidecar strips `__`-prefixed action ids
      -- before it talks to the daemon, so this is the "provider offered no deny"
      -- fallback rather than an id anybody has to recognise.
      local action = first "deny" or { id = "__deny" }
      -- The badge says what was decided, and for each of the three that is a
      -- different sentence: a plan was rejected and is still being planned, a
      -- question was declined rather than answered, and a tool was simply
      -- denied -- in its own words, because the provider chose them.
      local label = view.plan and plan.label { behavior = "deny" }
        or view.state and "declined to answer"
        or action.label
        or "denied"
      M.respond(chat, request, {
        behavior = "deny",
        selectedActionId = action.id,
        interrupt = interrupt or nil,
        label = interrupt and (label .. ", interrupted") or label,
      })
    end,
  }
end

---@param chat table
---@param request table
local function open(chat, request)
  M.close()

  local view = viewer(chat, request)

  -- A question and a plan are not approvals, and the overlay is where they are
  -- answered. See |paseo.ui.answer|.
  if view.state or view.plan then
    local overlay_ = overlay()
    if overlay_ then
      return overlay_.open(chat, request, view, handlers(chat, request, view))
    end
    -- No overlay means no volt. It does NOT mean fall through to the float
    -- below: that answers with a bare allow, which for a question is the exact
    -- bug this whole path exists to avoid. So say so and leave it pending --
    -- still answerable in the Paseo app, and still in the transcript.
    return vim.notify(
      "paseo: answering a question needs nvzone/volt; the request is still pending",
      vim.log.levels.ERROR
    )
  end

  local width = math.min(100, math.max(50, vim.o.columns - 10))
  local lines = build(request, width, view)
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
              return render.to_volt(build(request, width, view))
            end,
          },
        },
      },
    }
    volt.run(buf, { h = h, w = w })
  end)

  if not ok then
    -- This one CAN run without volt -- it builds with `render` alone -- so
    -- unlike the overlay, whose `paseo.ui.widgets` requires `volt.ui` outright,
    -- the fallback here is reachable and worth keeping.
    render.to_buffer(buf, hl.ns, 0, -1, lines)
    vim.bo[buf].modifiable = false
  end

  local map = function(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  local act = handlers(chat, request, view)

  for i, action in ipairs(view.actions) do
    if i <= 9 then
      map(tostring(i), function()
        act.choose(action)
      end)
    end
  end

  map("y", function()
    for _, action in ipairs(view.actions) do
      if action.behavior == "allow" then
        return act.choose(action)
      end
    end
  end)
  map("n", function()
    act.reject(false)
  end)
  -- Deny AND stop the turn, for "no, and don't try something else either".
  map("N", function()
    act.reject(true)
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
  chat.permission_blocks = chat.permission_blocks or {}
  for _, existing in ipairs(chat.permissions) do
    if existing.id == request.id then
      -- Held already -- but "held" and "drawn" are not the same thing. A
      -- `replaced` epoch empties the block table out from under us, and this
      -- early return then meant the inline card was never rebuilt: the winbar
      -- went on saying `needs you`, `gp` went on opening a dialog, and the
      -- conversation had no record of the request at all. So confirm the card
      -- still exists before taking the shortcut.
      local held = chat.permission_blocks[request.id]
      if held and chat.blocks and chat.blocks[held] then
        return
      end
      local redrawn = transcript.upsert(chat, { kind = "permission", request = request })
      chat.permission_blocks[request.id] = redrawn.id
      return
    end
  end
  chat.permissions[#chat.permissions + 1] = request

  -- ALWAYS log it inline first. The request is then part of the conversation
  -- and survives dismissing the dialog.
  local block = transcript.upsert(chat, { kind = "permission", request = request })
  chat.permission_blocks[request.id] = block.id

  -- Not thinking -- waiting. Through the setter, so the spinner's timer stops
  -- with it rather than ticking on against a flag that says otherwise.
  if chat.streaming ~= nil then
    require("paseo.ui.chat").set_streaming(chat, false)
  end

  -- Only steal the screen if this chat is the window you are looking at, you are
  -- not mid-sentence in the composer, and nothing else is already waiting on
  -- you. That last one is the important addition: this used to open
  -- unconditionally, so a second request arriving tore down a half-answered
  -- question and threw the answers away. The queue already reopens in order from
  -- `M.resolved`, so holding it costs nothing.
  local win = api.nvim_get_current_win()
  local mine = win == chat.win_conversation or win == chat.win_composer
  local typing = api.nvim_get_mode().mode:find "i" ~= nil
  local showing = overlay() and overlay().showing() or nil
  local busy = showing or (open_dialog and open_dialog.request.id)

  if mine and not typing and not busy then
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

  -- Answered, so the picks are spent. Held until now so that dismissing with
  -- <Esc> and reopening with `gp` resumed where you left off.
  if chat.answer_state then
    chat.answer_state[request_id] = nil
  end

  -- Close whichever surface is showing THIS request. Answering on the desktop
  -- must not leave a dead prompt open here.
  local overlay_ = overlay()
  local showing = (open_dialog and open_dialog.request and open_dialog.request.id)
    or (overlay_ and overlay_.showing())
  if showing == request_id then
    M.close()
  end

  local blocks = chat.permission_blocks or {}
  local block = blocks[request_id] and chat.blocks and chat.blocks[blocks[request_id]]
  if block then
    local label = resolution
      and (resolution.label or (resolution.behavior == "allow" and "allowed" or "denied"))
    block.item.resolution = label or "answered"
    -- Written onto the item the transcript already holds, so the rendered card
    -- it cached against that table is now a lie. Say so before redrawing.
    transcript.invalidate(block)
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

---Make the held list match the daemon's, in both directions.
---
---`M.resolved` handles the one case the event stream covers: somebody answered
---and the daemon said so. It is not the only case. The daemon replaces its
---pending map wholesale on a session refresh and emits no resolution for what
---vanished; a resolution that lands while the socket is down is never
---replayed; and a request that arrived while no chat was open was dropped on
---the floor. Each of those leaves this side holding a prompt that is already
---dead -- `gp` reopens it, the winbar keeps saying `needs you`, and answering
---it is an error, because it was answered on the desktop ten minutes ago.
---
---The fix is to stop treating the stream as the whole truth. The agent
---snapshot carries the real list, it arrives on reconnect and on every
---refresh, and this reconciles against it.
---@param chat table
---@param list table[]|nil the daemon's pending requests, authoritative
function M.reconcile(chat, list)
  chat.permissions = chat.permissions or {}
  list = list or {}

  local authoritative = {}
  for _, request in ipairs(list) do
    if request.id then
      authoritative[request.id] = request
    end
  end

  -- Gone: answered by somebody, somewhere, and we never heard.
  for i = #chat.permissions, 1, -1 do
    local request = chat.permissions[i]
    if not authoritative[request.id] then
      M.resolved(chat, request.id, { label = "answered elsewhere" })
    end
  end

  -- Arrived: the two reads of this list used to be additive, which made them
  -- half a reconciliation. Offering here is the other half, and `M.offer`
  -- already de-duplicates, so a list that agrees with us costs nothing.
  for _, request in ipairs(list) do
    M.offer(chat, request)
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
