--- The overlay that answers the agent when the agent asks YOU.
---
--- Two kinds of request end up here -- a question and a finished plan -- and
--- they have one thing in common that the ordinary allow/deny float does not:
--- you are not approving an action, you are composing a REPLY. That is a
--- different shape of UI, and it used to be crammed into the same box.
---
--- What was wrong with the box:
---
---   * It drew every question in the request AT ONCE. Four questions with five
---     options each is forty rows of radio buttons with a `▸` somewhere in the
---     middle marking the one the keys act on. No sense of progress, and the
---     fourth question off the bottom of the screen.
---   * It was centred on the EDITOR, not on the conversation it belongs to, so
---     it read as a modal interruption rather than as the agent's turn to speak.
---   * Typing an answer opened `vim.ui.input` -- a popup, over a float, over a
---     backdrop.
---   * A plan was rendered TRUNCATED, against a `vim.o.lines - 16` budget,
---     because the window was sized once from its content and the Implement
---     buttons had to stay on screen. You approved what you could see.
---
--- So: one card that takes over the chat window, one question at a time with
--- `x of N` on it, free text typed into a box that is part of the card, and a
--- plan in a real scrollable buffer.
---
--- THE RULES ARE NOT HERE, AND NEITHER IS THE DAEMON. |paseo.ui.questions| owns
--- what a tick does and when a set of answers is complete; |paseo.ui.plan| owns
--- which buttons exist and what each means; |paseo.ui.permission| owns the queue
--- and the one response each request gets, and hands this module three callbacks
--- rather than being called back into. That is deliberate: it keeps the
--- dependency one-way -- `permission` requires `answer`, never the reverse -- and it
--- means the overlay can be driven in a test with stub handlers and no socket.

local plan = require "paseo.ui.plan"
local questions = require "paseo.ui.questions"
local render = require "paseo.ui.render"
local icons = require "paseo.ui.icons"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.answer"

---One overlay at a time. The queue in |paseo.ui.permission| is what makes that
---safe: an agent blocks on one thing, and stacking two cards over the same
---conversation would be unanswerable.
---@type paseo.Answer|nil
local open_overlay

---What the overlay does instead of talking to the daemon itself.
---@class paseo.AnswerHandlers
---@field submit fun(state: paseo.QuestionState)   Send the whole answer set.
---@field choose fun(action: table)                Press one of a plan's buttons.
---@field reject fun(interrupt: boolean)           Decline; `interrupt` also
---                                                stops the turn.

---@class paseo.Answer
---@field chat table
---@field request table
---@field view paseo.PermissionView
---@field handlers paseo.AnswerHandlers
---@field kind "question"|"plan"
---@field state paseo.QuestionState|nil
---@field focus table<integer, integer>   Option focus, per question. Ours, not
---                                       the cursor's: volt resets the cursor
---                                       to {1,1} after every click.
---@field w integer
---@field h integer
---@field card_buf integer
---@field card_win integer
---@field backdrop_buf integer|nil
---@field backdrop_win integer|nil
---@field box_buf integer|nil     The answer box, while one is open.
---@field box_win integer|nil
---@field box_row integer|nil     Window row the box covers, 0-indexed.
---@field body_buf integer|nil    The plan's markdown.
---@field body_win integer|nil
---@field body_row integer|nil
---@field body_h integer|nil
---@field anchor integer|nil      The chat window we are anchored to, if any.
---@field volt boolean            False once volt has failed to draw and the
---                               card is plain text instead.
---@field augroup integer
---@field busy boolean|nil        Re-entry guard for the resize handlers.
---@field resize_pending boolean|nil

-- Below either of these the overlay stops trying to fit inside the chat window.
-- 48 columns is where an option label plus its keycap and marker stops fitting
-- at all; 14 rows is where the option list itself starts being cut. A question
-- you cannot read is worse than one that is not where you expected it.
local MIN_W, MIN_H = 48, 14

-- ------------------------------------------------------------------ geometry

---The box the overlay gets to live in, before its content is known.
---
---`relative = "win"` is the whole trick, and it is the one place in this plugin
---that uses it. Neovim repositions a win-relative float against its parent on
---every redraw, so the sidebar's real splits and the dashboard's floated panes
---need no branch and no arithmetic here -- shrink the chat window and the card
---moves with it.
---
---Two things it does NOT do, both handled below: it does not close when its
---parent closes (hence the `WinClosed` autocmd in `M.open`), and it does not
---rescale (hence `M.refresh` recomputing this).
---@param chat table|nil
---@return table
local function frame(chat)
  local ui = require("paseo.config").get().ui.answer
  local anchor = chat and chat.win_conversation

  if anchor and api.nvim_win_is_valid(anchor) then
    local aw = api.nvim_win_get_width(anchor)
    local ah = api.nvim_win_get_height(anchor)
    if aw >= math.max(MIN_W, ui.min_width) and ah >= MIN_H then
      return {
        anchor = anchor,
        relative = "win",
        win = anchor,
        -- Inset rather than flush: an overlay touching the conversation's edges
        -- reads as a repaint of it, not as a card laid on top.
        w = math.min(ui.width, aw - 4),
        avail = ah - 2,
        parent_w = aw,
        parent_h = ah,
        z = ui.zindex,
        backdrop = ui.backdrop,
      }
    end
  end

  return {
    relative = "editor",
    w = math.max(MIN_W, math.min(ui.width, vim.o.columns - 8)),
    avail = math.max(8, vim.o.lines - 4),
    parent_w = vim.o.columns,
    parent_h = vim.o.lines,
    z = ui.zindex,
    backdrop = ui.backdrop,
  }
end

---Window config for a frame and a settled height.
---
---The height is CLAMPED to the frame, never merely taken from the content: a
---card taller than the chat window would hang out of it, and a negative height
---is an `nvim_open_win` error -- which would make the request unanswerable from
---Neovim entirely.
---@param f table
---@param h integer
---@return table
local function placement(f, h)
  h = math.max(4, math.min(h, f.avail))
  local config = {
    relative = f.relative,
    width = f.w,
    height = h,
    row = math.max(0, math.floor((f.parent_h - h) / 2)),
    col = math.max(0, math.floor((f.parent_w - f.w) / 2)),
    style = "minimal",
    border = "none",
    zindex = f.z + 10,
  }
  if f.relative == "win" then
    config.win = f.win
  else
    -- Centred a row high, the way the dialog it replaces was: the optical
    -- centre of a card you read top-down is above the geometric one.
    config.row = math.max(0, config.row - 1)
  end
  return config
end

-- --------------------------------------------------------------------- lines

local ICON = { question = "󰘦", plan = "󰙨" }

---Pack key hints into as few rows as fit `w`.
---@param pairs_ table[]
---@param w integer
---@return table[][]
local function hint_rows(pairs_, w)
  local rows, batch = {}, {}
  for _, pair in ipairs(pairs_) do
    local candidate = vim.list_extend(vim.deepcopy(batch), { pair })
    if #batch > 0 and render.width(widgets.hints(candidate)) + 2 > w then
      rows[#rows + 1] = widgets.hints(batch)
      batch = { pair }
    else
      batch = candidate
    end
  end
  if #batch > 0 then
    rows[#rows + 1] = widgets.hints(batch)
  end
  for i, row in ipairs(rows) do
    rows[i] = render.truncate(vim.list_extend({ { " ", nil } }, row), w)
  end
  return rows
end

---@param o paseo.Answer
---@param index integer
---@return fun()
local function goto_question(o, index)
  return function()
    o.state.current = math.max(1, math.min(#o.state.questions, index))
    o.focus[o.state.current] = o.focus[o.state.current] or 1
    M.refresh()
  end
end

---@param o paseo.Answer
---@param at integer
---@return fun()
local function pick(o, at)
  return function()
    questions.choose(o.state, at)
    -- `choose` may have moved on; the question we land on needs a focus of its
    -- own or `j` would start from nowhere.
    o.focus[o.state.current] = o.focus[o.state.current] or 1
    M.refresh()
  end
end

---`● ◉ ○` -- how far through the set you are, at a glance.
---
---Three states, which is the whole argument for dots over a bare "2 of 3":
---solid is answered, hollow is not, and the blue one is where the keys act. A
---SKIPPED optional question stays hollow, because skipped and answered are
---different things and should not look the same.
---
---Foreground-only groups on the card's own background: a group carrying a
---background of its own would punch a hole in the card for one character.
---@param o paseo.Answer
---@return table[]
local function stepper(o)
  local cells = {}
  for index = 1, #o.state.questions do
    local here = index == o.state.current
    local answered = #o.state.picked[index] > 0
    cells[#cells + 1] = {
      (index > 1 and " " or "")
        .. (
          here and icons.marker.radio_on
          or answered and icons.marker.bullet
          or icons.marker.radio_off
        ),
      here and "PaseoCardTitle" or answered and "PaseoCardText" or "PaseoCardDim",
      { click = goto_question(o, index) },
    }
  end
  return cells
end

---One question, as card rows, in at most `avail` of them.
---@param o paseo.Answer
---@param w integer  The card's inner width.
---@param avail integer
---@return table[][]
local function question_body(o, w, avail)
  local state = o.state
  local index = state.current
  local question = state.questions[index]
  local picked = state.picked[index]
  local focus = math.max(1, math.min(math.max(1, #question.options), o.focus[index] or 1))

  local head, tail = {}, {}

  if #state.questions > 1 then
    head[#head + 1] = widgets.row(
      stepper(o),
      { { ("%d of %d"):format(index, #state.questions), "PaseoCardDim" } },
      w
    )
    head[#head + 1] = { { "", "PaseoCardText" } }
  end
  vim.list_extend(head, render.wrap(question.question, w, "PaseoHeader"))
  head[#head + 1] = { { "", "PaseoCardText" } }

  -- An answer TYPED has to be visible, or `i` looks like it did nothing.
  if question.free then
    local typed = questions.typed(question, picked)
    tail[#tail + 1] = render.truncate(#typed > 0 and {
      widgets.keycap "i",
      { " " .. widgets.icons.radio_on .. " ", "PaseoCardTitle" },
      { table.concat(typed, ", "), "PaseoCardTitle" },
      { "  typed", "PaseoCardDim" },
    } or {
      widgets.keycap "i",
      { "   ", "PaseoCardText" },
      {
        #question.options > 0 and "something else — type it" or "type an answer",
        "PaseoCardDim",
      },
    }, w)
  end

  local notes = {}
  if question.multi then
    notes[#notes + 1] = "choose as many as apply"
  end
  if question.optional then
    notes[#notes + 1] = "may be skipped"
  end
  if #question.options > 9 then
    notes[#notes + 1] = "j k reaches the rest"
  end
  if #notes > 0 then
    tail[#tail + 1] = render.truncate(
      { { "   ", "PaseoCardText" }, { table.concat(notes, " · "), "PaseoCardDim" } },
      w
    )
  end

  -- The focused option's description, on ONE row drawn under the option it
  -- belongs to and reserved whether or not that option has one: volt lays a
  -- section out by row, and a row that comes and goes as you move shifts
  -- everything under it. One line that changes is one you read; a line per
  -- option is a wall, and a line under the whole list describes whichever
  -- option you were not looking at.
  local function description_row()
    local described = question.options[focus]
    return render.truncate({
      { "      ", "PaseoCardText" },
      { described and described.description or "", "PaseoCardDim" },
    }, w)
  end

  -- The description row is reserved only when some option actually HAS one: a
  -- blank line in the middle of a list of bare labels reads as a gap, not as a
  -- slot waiting to be filled.
  local has_description = 0
  for _, option in ipairs(question.options) do
    if option.description then
      has_description = 1
      break
    end
  end

  -- Options get whatever rows are left, and when there are more options than
  -- rows the list is WINDOWED around the focus. The two alternatives are both
  -- wrong: drawing all fifteen pushes the hint bar off the card, and cutting the
  -- list off makes the fifteenth unreachable however the keys are bound.
  local room = math.max(1, avail - #head - #tail - has_description)
  local from, to = 1, #question.options
  local more_above, more_below = 0, 0
  if #question.options > room then
    -- The `n more` markers cost a row each -- unless the room is so small that
    -- spending two rows on them would leave nowhere to draw an option, in which
    -- case the list scrolls silently rather than becoming two counts and
    -- nothing to choose from.
    local visible = room > 2 and room - 2 or room
    from = math.max(1, math.min(focus - math.floor(visible / 2), #question.options - visible + 1))
    to = from + visible - 1
    if room > 2 then
      more_above, more_below = from - 1, #question.options - to
    end
  end

  local lines = head
  if more_above > 0 then
    lines[#lines + 1] = render.truncate(
      { { "   ↑ ", "PaseoCardDim" }, { ("%d more"):format(more_above), "PaseoCardDim" } },
      w
    )
  end
  for at = from, to do
    local option = question.options[at]
    local chosen = vim.tbl_contains(picked, option.label)
    -- A checkbox where a second pick ADDS and a radio where it REPLACES. The
    -- shape says which, so "choose as many as apply" is a reminder rather than
    -- the only clue.
    local marker = question.multi and (chosen and widgets.icons.check_on or widgets.icons.check_off)
      or (chosen and widgets.icons.radio_on or widgets.icons.radio_off)
    local action = {
      click = pick(o, at),
      hover = { id = ("paseo:answer:%d:%d"):format(index, at), redraw = "answer" },
    }
    lines[#lines + 1] = render.truncate({
      at <= 9 and widgets.keycap(tostring(at)) or { "   ", "PaseoCardDim" },
      { " " .. marker .. " ", chosen and "PaseoCardTitle" or "PaseoCardDim", action },
      {
        option.label,
        at == focus and "PaseoChipFocus" or chosen and "PaseoCardTitle" or "PaseoCardText",
        action,
      },
    }, w)
    if at == focus and has_description == 1 then
      lines[#lines + 1] = description_row()
    end
  end
  if more_below > 0 then
    lines[#lines + 1] = render.truncate(
      { { "   ↓ ", "PaseoCardDim" }, { ("%d more"):format(more_below), "PaseoCardDim" } },
      w
    )
  end

  vim.list_extend(lines, tail)
  return lines
end

---The answer box's own rows: a rule, then blanks for the real window to cover.
---
---The box is a REAL buffer floated over these -- see `open_box` -- so what the
---card draws here is the space it lives in. Inside the card's border rather
---than below it, so there is one frame on screen and not two.
---@param w integer
---@return table[][]
local function box_body(w)
  local lines = {
    widgets.row(
      { { widgets.icons.radio_on .. " your answer ", "PaseoCardTitle" } },
      { { "⏎ save · ␛␛ discard ", "PaseoCardDim" } },
      w,
      "PaseoCardRule"
    ),
  }
  for _ = 1, 3 do
    lines[#lines + 1] = { { "", "PaseoCardText" } }
  end
  return lines
end

---Everything the overlay shows. Also records where its child windows go.
---@param o paseo.Answer
---@param f table
---@return table[][]
local function build(o, f)
  local w = f.w
  -- `xpad` is 0 and the margin is drawn: one column of the overlay's own
  -- background on each side is what makes the card read as a card rather than
  -- as the window.
  local card_w = w - 2
  local inner = math.max(12, card_w - 4)

  local title, hints, body = {}, {}, {}

  if o.kind == "question" then
    local state = o.state
    local question = state.questions[state.current]
    local missing = questions.missing(state)
    local nothing = true
    for i = 1, #state.questions do
      nothing = nothing and #state.picked[i] == 0
    end

    title = {
      { ICON.question .. "  ", "PaseoCardTitle" },
      {
        #state.questions > 1 and ("The agent is asking %d things"):format(#state.questions)
          or "The agent is asking",
        "PaseoCardTitle",
      },
    }

    -- Budget: the card's two borders, a blank and the hint rows, plus the box's
    -- four rows when one is open.
    local overhead = 2 + 1 + 2 + (o.box_buf and 4 or 0)
    body = question_body(o, inner, math.max(4, f.avail - overhead))
    if o.box_buf then
      vim.list_extend(body, box_body(inner))
      -- The box covers the three blank rows `box_body` ends with. Buffer line N
      -- is window row N - 1, and the card's top border is line 1.
      o.box_row = (1 + #body - 3) - 1
    end

    if #question.options > 0 then
      hints[#hints + 1] = { "1-9", "pick" }
    end
    if #question.options > 9 then
      hints[#hints + 1] = { "j k", "move" }
    end
    -- `<CR>` sends the moment nothing is missing and otherwise takes you to
    -- what is, so the hint has to say which of the two it is about to do --
    -- including that it may jump BACKWARDS, or a send that does not send reads
    -- as a broken key.
    hints[#hints + 1] = {
      "<CR>",
      missing
          and (missing ~= state.current and ("question %d"):format(missing) or #state.questions == 1 and "answer it first" or "answer this one")
        or (nothing and "send (nothing answered)" or "send the answers"),
    }
    if #state.questions > 1 then
      hints[#hints + 1] = { "<Tab>", "question" }
    end
    if question.free then
      hints[#hints + 1] = { "i", "type" }
    end
    if question.optional then
      hints[#hints + 1] = { "s", "skip" }
    end
    hints[#hints + 1] = { "n", "decline" }
    hints[#hints + 1] = { "<Esc>", "later" }
  else
    title = {
      { ICON.plan .. "  ", "PaseoCardTitle" },
      { "The agent has a plan", "PaseoCardTitle" },
    }

    local chips = {}
    for i, action in ipairs(o.view.actions or {}) do
      local tone = action.behavior == "deny" and "danger"
        or action.variant == "primary" and "focus"
        or "off"
      chips[#chips + 1] = widgets.chip(("%d  %s"):format(i, action.label or action.id), tone, {
        click = function()
          M.act(i)
        end,
      })
    end
    local buttons = widgets.chiprow(chips, inner, " ")

    -- The body gets everything the buttons and chrome do not: a plan is a
    -- document, and the fix for "approved half-read" is that it SCROLLS rather
    -- than that it is cut off.
    local overhead = 2 + #buttons + 1 + 1 + 2
    o.body_h = math.max(3, f.avail - overhead)
    for _ = 1, o.body_h do
      body[#body + 1] = { { "", "PaseoCardText" } }
    end
    o.body_row = 1

    body[#body + 1] = { { "", "PaseoCardText" } }
    vim.list_extend(body, buttons)

    hints = {
      { "1-9", "choose" },
      { "y", "implement" },
      { "n", "reject" },
      { "j k ^D", "scroll" },
      { "<Esc>", "later" },
    }
  end

  local lines = widgets.card { title = title, lines = body, w = card_w }
  for i, line in ipairs(lines) do
    lines[i] = vim.list_extend({ { " ", nil } }, line)
  end
  lines[#lines + 1] = {}
  vim.list_extend(lines, hint_rows(hints, w))

  return lines
end

-- --------------------------------------------------------------------- volt

---@param o paseo.Answer
---@param f table
---@param lines table[][]
local function paint(o, f, lines)
  o.h = math.max(4, math.min(#lines, f.avail))

  local ok = o.volt
    and pcall(function()
      local volt = require "volt"
      api.nvim_buf_clear_namespace(o.card_buf, ns, 0, -1)
      volt.gen_data {
        {
          buf = o.card_buf,
          ns = ns,
          xpad = 0,
          layout = {
            {
              name = "answer",
              -- A FRESH table every call: `volt.draw` does
              -- `table.remove(marks, 3)` on what it is handed, so a cached line
              -- list loses its click actions after the first draw.
              lines = function()
                local built = build(o, frame(o.chat))
                -- Never more rows than the buffer has. volt writes an extmark
                -- per row at a precomputed line, and a row past the end raises
                -- `Invalid 'line': out of range` -- from inside `vim.on_key`,
                -- when it happens on hover.
                return render.to_volt(vim.list_slice(built, 1, math.min(#built, o.h)))
              end,
            },
          },
        },
      }
      vim.bo[o.card_buf].modifiable = true
      volt.set_empty_lines(o.card_buf, o.h, f.w)
      vim.bo[o.card_buf].modifiable = false
      volt.redraw(o.card_buf, "all")
    end)

  if not ok then
    -- Volt is a hard dependency -- `paseo.ui.widgets` requires `volt.ui` at the
    -- top -- so this is not the "volt is missing" path, which cannot be reached
    -- from here. It is the "volt threw" path, and being unable to answer at all
    -- is worse than an unstyled card.
    o.volt = false
    vim.bo[o.card_buf].modifiable = true
    render.to_buffer(
      o.card_buf,
      require("paseo.ui.hl").ns,
      0,
      -1,
      vim.list_slice(lines, 1, math.min(#lines, o.h))
    )
    vim.bo[o.card_buf].modifiable = false
  end
end

-- ------------------------------------------------------------- child windows

---@param o paseo.Answer
---@param buf integer
---@param row integer
---@param height integer
---@param win integer|nil
---@param focusable boolean
---@return integer
local function child(o, buf, row, height, win, focusable)
  local config = {
    relative = "win",
    win = o.card_win,
    row = row,
    -- One for the margin, two for the card's own `│ `.
    col = 3,
    width = math.max(8, o.w - 6),
    height = math.max(1, height),
    focusable = focusable,
    style = "minimal",
    border = "none",
    zindex = require("paseo.config").get().ui.answer.zindex + 15,
  }
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_set_config, win, config)
    return win
  end
  win = api.nvim_open_win(buf, false, config)
  pcall(function()
    vim.wo[win].winhl = "Normal:PaseoCardText,NormalFloat:PaseoCardText"
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].scrolloff = 0
  end)
  return win
end

---@param o paseo.Answer
local function place_children(o)
  if not api.nvim_win_is_valid(o.card_win) then
    return
  end
  if o.box_buf and o.box_row then
    o.box_win = child(o, o.box_buf, o.box_row, 3, o.box_win, true)
  end
  if o.body_buf and o.body_row then
    -- Unfocusable: the plan is scrolled from the card with `nvim_win_call`, so
    -- `<C-w>w` landing in it would only create a window you cannot answer from.
    o.body_win = child(o, o.body_buf, o.body_row, o.body_h or 3, o.body_win, false)
  end
end

-- ------------------------------------------------------------------- redraw

---Draw again, resizing first if the content changed height.
---
---Volt computes each section's row and the buffer height once, in `gen_data`,
---and `redraw` writes extmarks at those rows without clearing anything first.
---A card that grew -- stepped onto a question with more options, or opened the
---answer box -- therefore has to go all the way back through `gen_data` and
---`set_empty_lines`, or rows from the previous draw survive underneath the new
---ones. That is why there is no "keep the line count constant" trick here: the
---whole point of one question at a time is that the count changes.
function M.refresh()
  local o = open_overlay
  if not o or o.busy or not api.nvim_buf_is_valid(o.card_buf) then
    return
  end
  o.busy = true

  local f = frame(o.chat)
  o.w = f.w
  local lines = build(o, f)

  if api.nvim_win_is_valid(o.card_win) then
    pcall(api.nvim_win_set_config, o.card_win, placement(f, #lines))
  end
  paint(o, f, lines)
  place_children(o)

  if o.backdrop_win and api.nvim_win_is_valid(o.backdrop_win) then
    pcall(api.nvim_win_set_config, o.backdrop_win, {
      relative = f.relative,
      win = f.win,
      row = 0,
      col = 0,
      width = f.parent_w,
      height = f.parent_h,
    })
  end

  o.busy = false
end

-- ---------------------------------------------------------------- answering

---Send every answer, in the ONE response the request gets.
---
---`<CR>` sends the moment nothing is missing, and otherwise TAKES YOU TO what
---is -- which is strictly better than the warning it replaces. "That question
---still needs an answer" never said which question, and with three of them on a
---stepper that is the only part you needed.
---@param o paseo.Answer
local function enter(o)
  local missing = questions.missing(o.state)
  if not missing then
    -- Half a reply is not a smaller answer, it is a wrong one -- but a set that
    -- is entirely optional has nothing missing and is legitimately sendable
    -- empty, which is why the hint bar says so before you press this.
    return o.handlers.submit(o.state)
  end
  if missing == o.state.current then
    return vim.notify("paseo: that question still needs an answer", vim.log.levels.WARN)
  end
  o.state.current = missing
  o.focus[missing] = o.focus[missing] or 1
  M.refresh()
end

---Press one of a plan's buttons. Exposed because a chip's click action is built
---during a draw, when the index is all there is to close over.
---@param index integer
function M.act(index)
  local o = open_overlay
  if not o or o.kind ~= "plan" then
    return
  end
  local action = (o.view.actions or {})[index]
  if action then
    o.handlers.choose(action)
  end
end

-- ------------------------------------------------------------- the text box

---@param o paseo.Answer
local function close_box(o)
  local buf, win = o.box_buf, o.box_win
  o.box_buf, o.box_win, o.box_row = nil, nil, nil
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  if api.nvim_win_is_valid(o.card_win) then
    pcall(api.nvim_set_current_win, o.card_win)
  end
end

---An answer in your own words, typed where you are looking.
---
---A REAL buffer, never volt's: insert-mode keymaps, completion, abbreviations
---and undo are the difference between writing an answer and filling in a text
---field, and `volt.run` would set `modifiable = false` on it. It is floated over
---rows the card reserves for it, so there is one frame on screen rather than a
---popup over a float over a backdrop -- which is what `vim.ui.input` was.
---@param o paseo.Answer
---@param insert boolean
local function open_box(o, insert)
  local question = o.state.questions[o.state.current]
  if not question.free then
    return vim.notify("paseo: that question takes one of its options", vim.log.levels.INFO)
  end
  if o.box_buf then
    if o.box_win and api.nvim_win_is_valid(o.box_win) then
      api.nvim_set_current_win(o.box_win)
      if insert then
        vim.cmd.startinsert { bang = true }
      end
    end
    return
  end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  -- `markdown`, and named, for the same reason the composer is: whatever
  -- insert-mode configuration you have for writing a prompt applies to writing
  -- an answer, because it is the same act.
  vim.bo[buf].filetype = "markdown"
  pcall(api.nvim_buf_set_name, buf, "paseo://answer/" .. vim.fs.basename(o.chat.root or "paseo"))
  -- Seeded with whatever is already typed, so an answer can be edited rather
  -- than retyped from nothing.
  local typed = questions.typed(question, o.state.picked[o.state.current])
  api.nvim_buf_set_lines(buf, 0, -1, false, { table.concat(typed, ", ") })
  o.box_buf = buf

  local function commit()
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    -- Flattened to one line: the answer travels back as one string in
    -- `updatedInput`, and a newline inside it is not something any provider
    -- parses. Typing on several lines is still fine -- they join.
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), " ")
    text = vim.trim((text:gsub("%s+", " ")))
    close_box(o)
    questions.write(o.state, text)
    o.focus[o.state.current] = o.focus[o.state.current] or 1
    M.refresh()
  end

  local function map(mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, silent = true })
  end

  -- The composer's contract, verbatim, so there is one thing to learn for both
  -- of the boxes in this plugin you type into: `<C-s>` sends from either mode,
  -- `<CR>` in normal mode sends, `<CR>` in insert mode is a newline.
  map("i", "<C-s>", function()
    vim.cmd.stopinsert()
    commit()
  end)
  map("n", "<C-s>", commit)
  map("n", "<CR>", commit)
  -- `<Esc>` in INSERT mode is left alone -- it leaves insert, the way it does
  -- everywhere. In normal mode it backs out without answering, and because these
  -- are buffer-local it does not fight the card's `<Esc>`, which closes the
  -- whole overlay.
  for _, key in ipairs { "<Esc>", "q", "<C-c>" } do
    map("n", key, function()
      close_box(o)
      M.refresh()
    end)
  end

  M.refresh()
  if o.box_win and api.nvim_win_is_valid(o.box_win) then
    api.nvim_set_current_win(o.box_win)
    pcall(
      api.nvim_win_set_cursor,
      o.box_win,
      { 1, #(api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") }
    )
    if insert then
      vim.cmd.startinsert { bang = true }
    end
  end
end

-- ---------------------------------------------------------------- the keys

---@param o paseo.Answer
---@param buf integer
local function bind(o, buf)
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  if o.kind == "question" then
    for at = 1, 9 do
      map(tostring(at), pick(o, at))
    end

    for key, delta in pairs { j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 } do
      map(key, function()
        local index = o.state.current
        local n = #o.state.questions[index].options
        if n > 0 then
          -- Clamped rather than wrapped: wrapping a three-item list is
          -- disorienting, and the focus is the only thing that says where you
          -- are in a windowed list.
          o.focus[index] = math.max(1, math.min(n, (o.focus[index] or 1) + delta))
          M.refresh()
        end
      end)
    end

    -- The only way to reach a tenth option, and the reason there is a focus at
    -- all.
    map("<Space>", function()
      pick(o, o.focus[o.state.current] or 1)()
    end)

    map("<CR>", function()
      enter(o)
    end)
    -- `y` sends as well, when there is something to send: the muscle memory from
    -- every other dialog is that `y` is the affirmative key, and on a question
    -- the affirmative answer is the one you just picked.
    map("y", function()
      enter(o)
    end)

    for key, delta in pairs { ["<Tab>"] = 1, ["<S-Tab>"] = -1 } do
      map(key, function()
        questions.move(o.state, delta)
        o.focus[o.state.current] = o.focus[o.state.current] or 1
        M.refresh()
      end)
    end

    for _, key in ipairs { "i", "o", "a" } do
      map(key, function()
        open_box(o, true)
      end)
    end

    map("s", function()
      if not questions.skip(o.state) then
        return vim.notify("paseo: that question needs an answer", vim.log.levels.WARN)
      end
      o.focus[o.state.current] = o.focus[o.state.current] or 1
      M.refresh()
    end)

    -- Changed your mind rather than changed your pick. Without this a
    -- single-select question can be un-answered only by answering it again.
    map("x", function()
      o.state.picked[o.state.current] = {}
      M.refresh()
    end)
  else
    for i = 1, math.min(9, #(o.view.actions or {})) do
      map(tostring(i), function()
        M.act(i)
      end)
    end
    -- The FIRST allow, which `plan.actions` orders least-rope-first: the reflex
    -- key is the cautious one.
    map("y", function()
      for i, action in ipairs(o.view.actions or {}) do
        if action.behavior == "allow" then
          return M.act(i)
        end
      end
    end)

    -- Scrolling happens IN the body but is driven from here, so the card never
    -- has to give up focus and there is never a "which window am I in"
    -- question. `<C-f>` deliberately shadows the chat's fullscreen toggle: the
    -- overlay owns the keys while it is up.
    for _, key in ipairs { "j", "k", "<C-d>", "<C-u>", "<C-f>", "<C-b>", "gg", "G" } do
      map(key, function()
        if o.body_win and api.nvim_win_is_valid(o.body_win) then
          api.nvim_win_call(o.body_win, function()
            pcall(vim.cmd, "normal! " .. vim.keycode(key))
          end)
        end
      end)
    end
  end

  map("n", function()
    o.handlers.reject(false)
  end)
  -- Decline AND stop the turn, for "no, and don't try something else either".
  map("N", function()
    o.handlers.reject(true)
  end)

  -- `<Esc>` and `q` DISMISS, they do not deny. Silently denying on a stray
  -- keypress throws away whatever the agent was doing, and the request is still
  -- answerable from the transcript with `gp` -- with your picks, which are held
  -- on the chat.
  for _, key in ipairs { "<Esc>", "q" } do
    map(key, M.close)
  end
end

-- ------------------------------------------------------------------ opening

---Forget volt's per-buffer bookkeeping.
---
---It keys state by buffer and never clears it itself, and a buffer left on its
---key handler goes on being dispatched to for the rest of the session. Both
---halves, which only `paseo.ui.float` was doing.
---@param buf integer|nil
local function forget(buf)
  if not buf then
    return
  end
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
end

function M.close()
  local o = open_overlay
  if not o then
    return
  end
  open_overlay = nil

  pcall(api.nvim_del_augroup_by_id, o.augroup)

  -- Children FIRST. A win-relative float outlives its parent, and once the card
  -- is gone anything still naming it fails with `Invalid window id`.
  --
  -- NOT `ipairs` over a table literal: the box and the body are usually nil, and
  -- `ipairs` stops at the first hole -- so a list written that way cleaned up
  -- nothing at all whenever there was no answer box open. Which was almost
  -- always.
  for _, win in pairs { o.box_win, o.body_win, o.card_win, o.backdrop_win } do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in pairs { o.box_buf, o.body_buf, o.card_buf, o.backdrop_buf } do
    forget(buf)
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---The request the overlay is showing, if any. What `permission.resolved` tests
---against so answering on the desktop closes this too.
---@return string|nil
function M.showing()
  return open_overlay and open_overlay.request.id or nil
end

---Answer a question, or decide a plan.
---@param chat table
---@param request table
---@param view paseo.PermissionView
---@param handlers paseo.AnswerHandlers
function M.open(chat, request, view, handlers)
  M.close()

  ---@type paseo.Answer
  local o = {
    chat = chat,
    request = request,
    view = view,
    handlers = handlers,
    kind = view.state and "question" or "plan",
    focus = {},
    volt = true,
    augroup = api.nvim_create_augroup("paseo.answer", { clear = true }),
  }

  -- A half-answered set survives being dismissed, or the chat window being
  -- swapped out from under it: the picks are held on the chat, so `gp` reopens
  -- where you left off rather than at the first question again. Dismiss-and-
  -- resume is the whole reason `<Esc>` does not deny, and without this it threw
  -- the answers away.
  if view.state then
    chat.answer_state = chat.answer_state or {}
    local held = chat.answer_state[request.id]
    if held and #held.state.questions == #view.state.questions then
      o.state, o.focus = held.state, held.focus
    else
      o.state = view.state
      chat.answer_state[request.id] = { state = o.state, focus = o.focus }
    end
    o.focus[o.state.current] = o.focus[o.state.current] or 1
  end

  local f = frame(chat)
  o.anchor = f.anchor
  o.w = f.w

  -- On a TRANSPARENT theme there is no background to dim with -- `hl.lua`
  -- deliberately leaves `PaseoNormal` empty there -- and an opaque rectangle
  -- over someone's wallpaper is worse than no backdrop at all.
  local opaque = not vim.tbl_isempty(api.nvim_get_hl(0, { name = "PaseoNormal" }))
  if f.backdrop and opaque then
    o.backdrop_buf = api.nvim_create_buf(false, true)
    o.backdrop_win = api.nvim_open_win(o.backdrop_buf, false, {
      relative = f.relative,
      win = f.win,
      row = 0,
      col = 0,
      width = f.parent_w,
      height = f.parent_h,
      focusable = false,
      style = "minimal",
      border = "none",
      zindex = f.z,
    })
    vim.wo[o.backdrop_win].winblend = 30
  end

  o.card_buf = api.nvim_create_buf(false, true)
  vim.bo[o.card_buf].buftype = "nofile"
  vim.bo[o.card_buf].bufhidden = "wipe"

  -- Measured before the window exists, because the window's height IS the
  -- content's height.
  local lines = build(o, f)
  -- The card holds focus for a question -- the options are drawn in it -- and is
  -- unfocusable chrome for a plan, where the keys are bound on the body.
  o.card_win = api.nvim_open_win(o.card_buf, true, placement(f, #lines))
  pcall(function()
    vim.wo[o.card_win].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal"
  end)

  open_overlay = o

  if o.kind == "plan" then
    o.body_buf = api.nvim_create_buf(false, true)
    vim.bo[o.body_buf].buftype = "nofile"
    vim.bo[o.body_buf].bufhidden = "wipe"
    -- `plan.text`, not `plan.render`: the truncation IS the bug. `plan.render`
    -- keeps its one remaining caller, the inline transcript card, which does
    -- want a capped excerpt.
    api.nvim_buf_set_lines(
      o.body_buf,
      0,
      -1,
      false,
      vim.split(plan.text(request), "\n", { plain = true })
    )
    vim.bo[o.body_buf].modifiable = false
    vim.bo[o.body_buf].filetype = "markdown"
  end

  paint(o, f, lines)
  place_children(o)
  vim.bo[o.card_buf].filetype = "paseo-answer"

  -- The mouse half. `events.add` binds `<CR>`/`<Tab>`/`<S-Tab>` on the buffer
  -- and `enable` is what routes `LeftMouse` to a cell's click action. Our own
  -- maps go on AFTER, so they win the three keys we care about. `volt.mappings`
  -- is deliberately NOT called: it binds `q`/`<Esc>` to a teardown that knows
  -- nothing about our child windows.
  if o.volt then
    pcall(function()
      local events = require "volt.events"
      events.add(o.card_buf)
      if not vim.g.extmarks_events then
        events.enable()
      end
    end)
  end

  bind(o, o.card_buf)

  -- A win-relative float does NOT close with its parent -- it is left valid,
  -- frozen at its old position, holding a stale window id. So `<C-f>` or a tab
  -- switch would leave this hanging over the new surface. Scheduled, because
  -- `WinClosed` fires during the close.
  if o.anchor then
    api.nvim_create_autocmd("WinClosed", {
      group = o.augroup,
      pattern = tostring(o.anchor),
      callback = function()
        vim.schedule(M.close)
      end,
      desc = "paseo: close the answer overlay with its chat window",
    })
  end
  -- Debounced: a drag-resize fires this per column, and each one is a
  -- `gen_data` plus a window reconfigure.
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = o.augroup,
    callback = function()
      if o.resize_pending then
        return
      end
      o.resize_pending = true
      vim.defer_fn(function()
        o.resize_pending = false
        M.refresh()
      end, 50)
    end,
    desc = "paseo: resize the answer overlay",
  })

  -- A question with nothing but free text has one thing to do; do it. Making
  -- you press `i` on a field is the friction that makes people press `<Esc>`.
  if o.kind == "question" then
    local question = o.state.questions[o.state.current]
    if #question.options == 0 and question.free then
      open_box(o, true)
    end
  end
end

return M
