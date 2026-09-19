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
local plan = require "paseo.ui.plan"
local questions = require "paseo.ui.questions"
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

-- ----------------------------------------------------------------- questions

---Has this question an answer that is not one of its options?
---@param question paseo.Question
---@param picked string[]
---@return string[]
local function typed_answers(question, picked)
  local labels, typed = {}, {}
  for _, option in ipairs(question.options) do
    labels[option.label] = true
  end
  for _, chosen in ipairs(picked) do
    if not labels[chosen] then
      typed[#typed + 1] = chosen
    end
  end
  return typed
end

---The questions, as the dialog draws them.
---
---ALL of them, not one at a time: a request may carry four, and a dialog that
---showed only the first would teach you that answering it was the whole reply.
---The keys act on the question marked `▸`, and `<Tab>` moves the mark.
---
---The line COUNT is deliberately constant across redraws -- the free-text row
---is drawn as a hint when nothing has been typed -- because volt lays sections
---out by row and a section that grows writes over the one below it.
---@param state paseo.QuestionState
---@param inner integer
---@return table[][]
local function question_body(state, inner)
  local lines = {}

  for index, question in ipairs(state.questions) do
    local here = index == state.current
    local picked = state.picked[index]

    if index > 1 then
      lines[#lines + 1] = {}
    end
    vim.list_extend(
      lines,
      render.wrap(question.question, inner - 4, here and "PaseoHeader" or "PaseoDim", {
        { here and "  ▸ " or "    ", "PaseoKey" },
      })
    )

    for at, option in ipairs(question.options) do
      local chosen = vim.tbl_contains(picked, option.label)
      local row = {
        { "    ", nil },
        { here and at <= 9 and (" %d "):format(at) or "   ", "PaseoKey" },
        { chosen and " ● " or " ○ ", chosen and "PaseoToolOk" or "PaseoDim" },
        { option.label, chosen and "PaseoToolOk" or nil },
      }
      if option.description then
        row[#row + 1] = { " — " .. option.description, "PaseoDim" }
      end
      lines[#lines + 1] = render.truncate(row, inner)
    end

    -- An answer typed rather than picked has to be visible, or `i` looks like
    -- it did nothing. Drawn as the key hint until there is one.
    if question.free then
      local typed = typed_answers(question, picked)
      lines[#lines + 1] = render.truncate(
        #typed > 0 and {
          { "       ● ", "PaseoToolOk" },
          { table.concat(typed, ", "), "PaseoToolOk" },
          { "  typed", "PaseoDim" },
        } or {
          { "     i ", "PaseoKey" },
          { "something else — type it", "PaseoDim" },
        },
        inner
      )
    end

    local notes = {}
    if question.multi then
      notes[#notes + 1] = "choose as many as apply"
    end
    if question.optional then
      notes[#notes + 1] = "may be skipped"
    end
    if #notes > 0 then
      lines[#lines + 1] = { { "       ", nil }, { table.concat(notes, " · "), "PaseoDim" } }
    end
  end

  return lines
end

-- --------------------------------------------------------------------- lines

---Everything the dialog shows, as `{text, hl}` lines.
---@param chat table
---@param request table
---@param width integer
---@param view paseo.PermissionView
---@return table[][]
local function build(chat, request, width, view)
  local state = view.state
  local inner = width - 4
  local lines = {}

  -- Neither a question nor a plan is a danger: the agent is ASKING, not
  -- reaching for the filesystem, and painting all three red teaches you to
  -- dismiss the colour.
  local group = (state or view.plan) and "PaseoQuestion" or "PaseoDanger"
  local title = request.title or request.name or "Permission required"
  if state then
    title = #state.questions > 1 and ("The agent is asking %d things"):format(#state.questions)
      or "The agent is asking"
  elseif view.plan then
    title = "The agent has a plan"
  end
  lines[#lines + 1] = {
    { "  ", group },
    { title, group },
  }
  if request.kind and request.kind ~= "tool" and not (state or view.plan) then
    lines[#lines + 1] = { { "  " .. request.kind, "PaseoDim" } }
  end
  lines[#lines + 1] = {}

  if state then
    vim.list_extend(lines, question_body(state, inner))
    lines[#lines + 1] = {}
    lines[#lines + 1] = {
      { "  1-9", "PaseoKey" },
      { " pick · ", "PaseoDim" },
      { "<Tab>", "PaseoKey" },
      { " next question · ", "PaseoDim" },
      { "<CR>", "PaseoKey" },
      { " send the answers", "PaseoDim" },
    }
    lines[#lines + 1] = {
      { "  <Esc>", "PaseoKey" },
      { " later (stays pending) · ", "PaseoDim" },
      { "N", "PaseoKey" },
      { " decline, and stop the turn", "PaseoDim" },
    }
    return lines
  end

  -- A plan carries no `detail` AT ALL -- the daemon leaves it undefined and
  -- puts the markdown in `input.plan` -- so the card below drew an empty box
  -- and asked you to approve it. This is the thing being decided; it has to be
  -- on screen while you decide.
  if view.plan then
    -- Budgeted against the screen rather than the request, because
    -- `dimensions` sizes the window to these lines and volt draws exactly `h`
    -- of them: a plan longer than the terminal would push the buttons off the
    -- bottom and leave nothing to press.
    local body = {}
    for _, line in ipairs(plan.render(request, math.max(6, vim.o.lines - 16))) do
      body[#body + 1] = { { line, nil } }
    end
    local card = render.card({ { "the plan", "PaseoToolName" } }, body, { width = inner })
    for _, line in ipairs(card) do
      local row = { { "  ", nil } }
      vim.list_extend(row, line)
      lines[#lines + 1] = row
    end
    lines[#lines + 1] = {}
  else
    -- `description` for a question is the FIRST question and its labels, which
    -- is why it is above the question branch and not below it.
    if request.description and request.description ~= "" then
      vim.list_extend(
        lines,
        render.wrap(request.description, inner, "PaseoDim", { { "  ", nil } })
      )
      lines[#lines + 1] = {}
    end

    -- THE POINT OF THE DIALOG. The same builder the transcript uses, so what
    -- you are approving is shown rather than named.
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
  end

  -- Actions. The sidecar guarantees this is non-empty -- a provider that sends
  -- none gets a synthesised Allow/Deny -- so there is no empty-list branch. For
  -- a plan they are `plan.actions`, which is the same list with one Implement
  -- per mode you could land in.
  local buttons = { { "  ", nil } }
  for i, action in ipairs(view.actions) do
    local group = action.variant == "danger" and "PaseoDanger"
      or action.behavior == "allow" and "PaseoToolOk"
      or "PaseoDim"
    buttons[#buttons + 1] = { (" %d "):format(i), "PaseoKey" }
    buttons[#buttons + 1] = { action.label or action.id, group }
    buttons[#buttons + 1] = { "   ", nil }
    -- Four Implement buttons plus a Reject do not fit on one 100-column row.
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
    { view.plan and " implement · " or " allow · ", "PaseoDim" },
    { "n", "PaseoKey" },
    { view.plan and " reject · " or " deny · ", "PaseoDim" },
    { "<Esc>", "PaseoKey" },
    { " later (stays pending)", "PaseoDim" },
  }

  return lines
end

-- ------------------------------------------------------------------ answering

---@param chat table
---@param request table
---@param action paseo.PlanAction|table
---@param view paseo.PermissionView
local function answer(chat, request, action, view)
  M.close()

  bridge.request("agent.respondToPermission", {
    agentId = chat.agent_id,
    requestId = request.id,
    behavior = action.behavior,
    selectedActionId = action.id,
    -- The second half of a plan approval. It cannot ride in the response --
    -- `AgentPermissionResponse` has no field for a mode -- so the sidecar
    -- applies it after the daemon has finished applying its own. See
    -- |paseo.ui.plan|.
    thenModeId = action.mode,
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
  M.resolved(chat, request.id, {
    behavior = action.behavior,
    label = view.plan and plan.label(action) or action.label,
  })
end

---Send every answer, in the ONE response the request gets.
---
---A question is allowed AND answered in the same message: the answers ride in
---`updatedInput`, and an allow without them reaches the agent as "The user did
---not answer the questions" -- approved, and silent.
---@param chat table
---@param request table
---@param state paseo.QuestionState
---@return boolean sent
local function send(chat, request, state)
  -- Half a reply is not a smaller answer, it is a wrong one: the unanswered
  -- question would come back as though you had nothing to say about it.
  local missing = questions.missing(state)
  if missing then
    state.current = missing
    vim.notify("paseo: that question still needs an answer", vim.log.levels.WARN)
    return false
  end

  local answers = questions.answers(state)
  M.close()

  bridge.request("agent.respondToPermission", {
    agentId = chat.agent_id,
    requestId = request.id,
    behavior = "allow",
    updatedInput = questions.input(request, state.questions, answers),
  }, function(err)
    if err then
      vim.schedule(function()
        transcript.upsert(chat, {
          kind = "notice",
          level = "error",
          message = "answer failed: " .. err,
        })
      end)
    end
  end)

  M.resolved(chat, request.id, {
    behavior = "allow",
    label = questions.label(state.questions, answers),
  })
  return true
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

---@param chat table
---@param request table
local function open(chat, request)
  M.close()

  local view = viewer(chat, request)
  local state = view.state

  local width = math.min(100, math.max(50, vim.o.columns - 10))
  local lines = build(chat, request, width, view)
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
    state = state,
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
              return render.to_volt(build(chat, request, width, view))
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

  -- Answering a question CHANGES the dialog -- a tick appears, the `▸` moves
  -- on -- so unlike a permission it has to be drawn more than once. Volt
  -- re-runs the section's `lines`; the plain fallback is rewritten by hand.
  local function redraw()
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    if ok then
      pcall(function()
        require("volt").redraw(buf, "permission")
      end)
      return
    end
    vim.bo[buf].modifiable = true
    render.to_buffer(buf, hl.ns, 0, -1, build(chat, request, width, view))
    vim.bo[buf].modifiable = false
  end

  local map = function(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  if state then
    for at = 1, 9 do
      map(tostring(at), function()
        questions.choose(state, at)
        redraw()
      end)
    end

    map("<Tab>", function()
      questions.move(state, 1)
      redraw()
    end)
    map("<S-Tab>", function()
      questions.move(state, -1)
      redraw()
    end)

    -- `i`, because it is the key that starts typing everywhere else. A
    -- question that takes only its options says so rather than swallowing it.
    map("i", function()
      local question = state.questions[state.current]
      if not question.free then
        return vim.notify("paseo: that question takes one of its options", vim.log.levels.INFO)
      end
      vim.ui.input({ prompt = question.question .. " " }, function(typed)
        questions.write(state, typed or "")
        redraw()
      end)
    end)

    -- `y` sends as well as `<CR>`: the muscle memory from every other dialog
    -- is that `y` is the affirmative key, and on a question the affirmative
    -- answer is the one you just picked.
    for _, key in ipairs { "<CR>", "y" } do
      map(key, function()
        if not send(chat, request, state) then
          redraw()
        end
      end)
    end
  else
    for i, action in ipairs(view.actions) do
      if i <= 9 then
        map(tostring(i), function()
          answer(chat, request, action, view)
        end)
      end
    end
  end

  ---@param behavior string
  local function first(behavior)
    for _, action in ipairs(view.actions) do
      if action.behavior == behavior then
        return action
      end
    end
  end

  -- Not on a question: `y` there sends the answers, and a bare allow -- which
  -- is what this sends -- is exactly the bug. See the `state` branch above.
  --
  -- On a plan this takes the FIRST Implement, which `plan.actions` orders
  -- least-rope-first: the reflex key is the cautious one.
  if not state then
    map("y", function()
      local action = first "allow"
      if action then
        answer(chat, request, action, view)
      end
    end)
  end
  map("n", function()
    local action = first "deny"
    if action then
      answer(chat, request, action, view)
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
