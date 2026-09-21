--- The sidebar: a pane beside your code, the conversation above its composer.
---
--- One of the plugin's two surfaces. This is the everyday one -- narrow, beside
--- your code, always answerable. The other is `ui/float.lua`, which trades the
--- code view for room to show everything about the agent session at once.
---
--- Both are views onto the SAME `paseo.Chat`: the same conversation buffer, the
--- same composer buffer, the same block table. Switching surface therefore
--- preserves your draft and your scroll position for free, because neither
--- lives in the window.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

---Window options shared by both panes. `wrap` matters: a long reply in a 60
---column pane is unreadable without it, and the transcript is real text, so it
---actually wraps.
local WINDOW = {
  wrap = true,
  linebreak = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  -- Following the agent means the last line sits ON the last row. With a
  -- global `scrolloff` of 8 it cannot: the view stops eight rows early and the
  -- transcript never looks like it reached the bottom.
  scrolloff = 0,
  foldcolumn = "0",
  cursorline = false,
  list = false,
}

---@param win integer
local function style(win)
  for option, value in pairs(WINDOW) do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
end

-- -------------------------------------------------------------------- header

---How much of the context window is LEFT.
---
---This was a bare `42%` in `PaseoDim`, and two things were wrong with it that
---compound: nothing said what the number counted, and it counted the wrong
---direction -- it was the fraction USED, so the figure you watched climbing
---was the one you wanted to watch falling, and a reader who assumed the
---obvious read it exactly backwards at the one moment it matters. So it counts
---DOWN and says so: `42% left`.
---
---NO BAR BESIDE IT. There was a six-cell gauge here, and a gauge earns its
---place by being readable at a glance in a way a number is not -- which is
---true on the Usage panel, where it sits in a card with room to be a real
---readout, and false in six cells wedged into a row of text. Two glyphs of
---difference between 58% and 71% is not a reading; `58% left` is, and it was
---already right there. The pressure colour goes with it for the same reason:
---it lived on the filled run of a bar that no longer exists, and a number that
---changes colour in a row of dim text is a twitch rather than a warning. The
---Usage tab is where a context window in trouble is worth looking at.
---@param chat table
---@return table[]  Cells; empty until the daemon has reported any usage.
function M.context(chat)
  local usage = chat.usage
  local used, max = nil, nil
  if usage then
    used, max = usage.contextWindowUsedTokens, usage.contextWindowMaxTokens
  end
  if not (used and max and max > 0) then
    return {}
  end

  -- Clamped: a context window can report over 100% once the overhead is
  -- counted, and "-4% left" is a worse answer than "0% left".
  local spent = math.max(0, math.min(100, (used / max) * 100))
  return {
    { " · ", "PaseoDim" },
    { ("%d%% left"):format(math.floor(100 - spent)), "PaseoDim" },
  }
end

---The status line above the conversation, as cells.
---
---Exposed because the float draws the same information through volt, and two
---headers that drift apart is how a UI starts lying about which mode it is in.
---@param chat table
---@return table[]
---Is it working, and for how long -- as cells, or nothing when it is idle.
---
---A spinner and an elapsed count rather than a static dot: `●` looked the same
---at two seconds and at two minutes, so a wedged turn was indistinguishable
---from a working one without opening the app to check.
---
---It is drawn ON THE COMPOSER'S BAR, at the right-hand end -- see
---|paseo.ui.composer|. A progress readout is the thing your eye goes back to
---while you wait, and what you are waiting for is the answer to whatever is in
---that box, so the box is where it belongs. It sits in a fixed-width slot
---there: the count grows from `9s` to `28m 49s` while you watch it, and a row
---measured against its true width would reflow every time it crossed a
---threshold, which is the twitch that had this at the bottom of the screen in
---the first place.
---
---The dashboard's footer keeps it for the tabs that have no composer on them.
---A turn runs on while you read the Changes panel, and that is exactly when
---"is it still going" is hard to answer: nothing else on those tabs moves.
---@param chat table
---@return table[]
function M.status(chat)
  local frame, seconds = require("paseo.ui.chat").progress(chat)
  if frame then
    return {
      { frame .. " ", "PaseoToolRunning" },
      -- Humanised, because `1729s` is arithmetic homework rather than a
      -- duration -- see |paseo.ui.render|'s `duration`.
      { render.duration(seconds), "PaseoDim" },
    }
  end
  if chat.streaming then
    return { { "● ", "PaseoToolRunning" } }
  end
  return {}
end

---What the header says, as droppable parts.
---
---WHY PARTS AND NOT A LINE. This row now lives on the composer's bar, one row
---above the box, which in a sixty-column sidebar is a third of the space the
---top of the screen had. Handing that to `render.truncate` cuts the RIGHT --
---so the first things to go were the working directory and the mode, which
---are the two facts the row is most worth having. A `rank` per part lets the
---row give up the readouts it can spare, in order, and keep those.
---
---`rank` is what it is worth, lowest first: nothing outranks something waiting
---on you, then the mode you are in, then where you are, then which model, and
---the three readouts after that are the ones that go when the pane is narrow.
---@param chat table
---@return { rank: integer, cells: table[], shrink?: fun(): table[] }[]
local function parts(chat)
  local out = {}

  ---@param rank integer
  ---@param cells table[]
  ---@param shrink? fun(): table[]
  local function part(rank, cells, shrink)
    out[#out + 1] = { rank = rank, cells = cells, shrink = shrink }
  end

  part(4, { { chat.provider or "…", "PaseoHeader" } })

  if chat.mode then
    part(2, { { chat.mode, "PaseoAgent" } })
  end
  if chat.thinking then
    part(6, { { icons.ui.thinking .. " " .. chat.thinking, "PaseoThinking" } })
  end
  -- The daemon supplies feature names; Codex Plan and Fast are separate
  -- toggles, and future providers may add others.
  for _, feature in ipairs(chat.feature_list or {}) do
    if feature.type == "toggle" and chat.features and chat.features[feature.id] then
      part(7, { { feature.label or feature.id, "PaseoKey" } })
    end
  end

  local context = M.context(chat)
  if #context > 0 then
    -- `context` builds its own leading separator, for the callers that append
    -- it to a line of their own; here the separator is the assembler's job.
    part(5, vim.list_slice(context, 2))
  end

  -- Something is waiting on you. Worth shouting about: the agent is blocked
  -- until it is answered, so this is the one part that is never dropped.
  if chat.permissions and #chat.permissions > 0 then
    part(1, { { icons.status.permission .. " needs you (gp)", "PaseoDanger" } })
  end

  -- THE DIRECTORY, not the session's title. Which agent session this is gets
  -- said twice already -- by the dashboard's session strip and by the
  -- sidebar's own top bar -- and neither of them says WHERE it is working,
  -- which is the fact you want when you are about to tell it to change
  -- something on disk.
  local path = vim.fn.fnamemodify(chat.root, ":~")
  part(3, { { path, "PaseoDim" } }, function()
    -- The last component, when the whole path will not fit. `~/Code/openfin/
    -- clm_api` says more than nothing does, and `clm_api` says most of it.
    return { { vim.fs.basename(path), "PaseoDim" } }
  end)

  return out
end

---The status line above the conversation -- or, on the composer's bar, above
---the box you type in.
---@param chat table
---@param opts? { bar?: boolean, width?: integer }
---            `bar`: drawn over the box, where the recording readout has the
---            whole row to itself and saying it twice would be noise.
---            `width`: degrade to fit this many columns. Absent means say
---            everything and let the caller cut it.
---@return table[]
function M.header(chat, opts)
  opts = opts or {}

  -- On the composer's bar the lead-in is the RULE's, not ours: the row starts
  -- with a hairline running into the text -- see |paseo.ui.composer|.
  local lead = opts.bar and {} or { { "  ", "PaseoDim" } }

  -- RECORDING FIRST, because while it is true it is the only thing on this row
  -- that is about you rather than about the agent, and it is the state most
  -- worth being certain of. Drawn here as well as over the box because the
  -- dashboard puts this row on every tab, and the box is only on one of them.
  if chat.dictating and not opts.bar then
    lead[#lead + 1] = { icons.ui.mic .. " ", "PaseoToolFail" }
    lead[#lead + 1] = { "listening · ", "PaseoDim" }
  end

  local chosen = parts(chat)

  ---@param list table[]
  ---@param shrunk boolean
  ---@return table[]
  local function assemble(list, shrunk)
    local line = vim.deepcopy(lead)
    for i, item in ipairs(list) do
      if i > 1 then
        line[#line + 1] = { " · ", "PaseoDim" }
      end
      vim.list_extend(line, (shrunk and item.shrink) and item.shrink() or item.cells)
    end
    return line
  end

  if not opts.width then
    return assemble(chosen, false)
  end

  ---@param list table[]
  ---@param shrunk boolean
  ---@return boolean
  local function fits(list, shrunk)
    return render.width(assemble(list, shrunk)) <= opts.width
  end

  -- WHOLE BEFORE SHORTENED, SHORTENED BEFORE DROPPED. At each width the row
  -- prefers to say everything it still has in full; failing that, to say the
  -- same things with the path shortened to its last component; and only then
  -- to give up the cheapest part it is carrying and try again.
  --
  -- The order matters in both directions. Shortening too eagerly gives you
  -- `~/Code/pas…` while the row is still carrying a thinking level -- three
  -- facts half-said instead of two said properly. Dropping too eagerly loses
  -- the working directory entirely in a sixty-column sidebar, where
  -- `paseo.nvim` would have fitted with room to spare, and the directory is
  -- the second most valuable thing on the row.
  ---The cheapest part that could be shortened instead of dropped.
  local shrinkable = math.huge
  for _, item in ipairs(chosen) do
    if item.shrink then
      shrinkable = math.min(shrinkable, item.rank)
    end
  end

  while true do
    if fits(chosen, false) then
      return assemble(chosen, false)
    end

    local worst, at = -1, 1
    for i, item in ipairs(chosen) do
      if item.rank > worst then
        worst, at = item.rank, i
      end
    end

    -- Shortening is tried only once there is nothing cheaper left to give up.
    -- `~/Code/paseo.nvim` beats `paseo.nvim`, so the thinking level and the
    -- context figure go first -- but `paseo.nvim` beats no directory at all,
    -- so once the row is down to the things worth keeping it shortens rather
    -- than dropping another one.
    if worst <= shrinkable and fits(chosen, true) then
      return assemble(chosen, true)
    end
    if #chosen <= 1 then
      break
    end
    table.remove(chosen, at)
  end
  return render.truncate(assemble(chosen, true), opts.width)
end

---Repaint the header of whichever windows this chat currently has.
---
---On the full-screen surface the header is not a winbar at all -- it is a volt
---section in the chrome, so that it is drawn on every tab rather than only on
---the one that has a conversation window. Route to it rather than writing a
---winbar nobody would see.
---@param chat table
function M.refresh(chat)
  -- The bar over the box, on whichever surface owns the composer right now.
  -- First, because it is the row carrying the session's settings on both of
  -- them and it does not go through volt.
  require("paseo.ui.composer").refresh(chat)

  local float = require "paseo.ui.float"
  -- `showing` rather than `is_open`. The question here is "is the dashboard
  -- drawing this chat", not "can you see it from where you are standing" --
  -- and `is_open` is tab-aware, so with the dashboard on another tab page it
  -- answered no and the fallback below wrote a winbar onto the dashboard's
  -- OWN conversation pane. That pane's winbar is emptied deliberately (the
  -- header is a volt section in the chrome), so the result was the header
  -- drawn twice, one row apart, and a row stolen from the conversation --
  -- ten times a second for the length of every turn.
  --
  -- Latent while the dashboard floated, because living on another tab page
  -- was the exception. On the buffer mount it is the point.
  if float.showing(chat) then
    return float.refresh_header(chat)
  end

  -- What is left for the top of the sidebar: WHICH session this is, and
  -- whether it is working. The settings cluster that used to be here has moved
  -- down to the composer's bar -- see |paseo.ui.composer| -- and the status
  -- stayed, because a spinner belongs beside the thing it is a spinner for.
  -- The float, which has a footer, draws the status there instead.
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end

  local widgets = require "paseo.ui.widgets"
  local width = api.nvim_win_get_width(win)
  local line = {
    { "  ", "PaseoDim" },
    { chat.title or vim.fn.fnamemodify(chat.root, ":~"), "PaseoHeader" },
  }

  -- The surface's own keys on the right. NOT the spinner, which used to be
  -- here: the elapsed count belongs against the box -- see |paseo.ui.composer|
  -- -- because the thing you are waiting on is the answer to what you typed
  -- in it, and a readout at the top of a pane you are not looking at is a
  -- readout you check by moving your eyes off the work.
  local right = widgets.hints({
    { "<C-f>", "screen" },
    { "<C-t>", "speak" },
    { "q", "close" },
  }, nil, math.max(0, width - 24))

  pcall(function()
    vim.wo[win].winbar = render.to_winbar(
      widgets.row(render.truncate(line, math.max(4, width - render.width(right) - 2)), right, width)
    )
  end)
end

-- -------------------------------------------------------------------- layout

---Open the sidebar, or focus it if it is already up.
---@param chat table
function M.open(chat)
  if chat.win_conversation and api.nvim_win_is_valid(chat.win_conversation) then
    if chat.win_composer and api.nvim_win_is_valid(chat.win_composer) then
      api.nvim_set_current_win(chat.win_composer)
    end
    return
  end

  local from = api.nvim_get_current_win()
  local config = require "paseo.config"
  local ui = config.get().ui.sidebar

  -- A percentage of the editor, read exactly as the float's is -- but floored
  -- in CELLS, because 40% of a 100-column terminal is a pane too narrow to
  -- read a tool card in, and a percentage has no way to know that.
  local floor = math.floor(type(ui.min_width) == "number" and ui.min_width or 60)
  local width = math.max(floor, config.cells(ui.width, vim.o.columns, 40))
  -- ...and never more than `winwidth` leaves for the window you came from.
  -- Neovim claws the difference back the instant focus returns there, so a
  -- bigger number is not a wider sidebar -- it is a number that quietly does
  -- not happen, and a 64 that silently becomes 59 is the kind of thing you
  -- spend an evening on.
  width = math.min(width, math.max(20, vim.o.columns - math.max(vim.o.winwidth, 10) - 1))

  vim.cmd(("%s %dvsplit"):format(ui.position == "left" and "topleft" or "botright", width))
  chat.win_conversation = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_conversation, chat.conversation)
  style(chat.win_conversation)

  -- The composer sits under the conversation, small: it is where you type one
  -- question, not where you write a document. It opens at its FLOOR and grows
  -- with what you type -- see `M.fit_composer`.
  vim.cmd "belowright 1split"
  chat.win_composer = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_composer, chat.composer)
  style(chat.win_composer)
  -- The box is a CARD here too, at the same elevation the dashboard gives it,
  -- so "where you type" is the same object on both surfaces. Its bar carries
  -- the session's settings -- and, while you dictate, the microphone meter.
  require("paseo.ui.composer").style(chat)

  -- An unrelated `:split` -- or a user's `winheight` -- must not reflow the box
  -- out from under the fit. Explicit `nvim_win_set_height` still works on a
  -- `winfixheight` window; only automatic equalisation is blocked.
  vim.wo[chat.win_composer].winfixheight = true

  chat.surface = "sidebar"
  M.refresh(chat)
  -- Cards were drawn at whatever width was current when they arrived, which for
  -- history fetched before the split existed is the fallback width.
  transcript.redraw(chat)
  -- Reopening onto a draft -- or onto a queued ref, which writes a whole
  -- prompt into the composer before you ever touch it -- should show it.
  M.fit_composer(chat)
  api.nvim_set_current_win(from)
end

---The composer's bar, sized to the pane.
---
---Kept as a name of its own because `ui/chat.lua` and the tests call it, but
---the row it draws is |paseo.ui.composer|'s now: the session's model, mode and
---directory with the send keys on the end, or the microphone meter while you
---are dictating. What it used to be -- five hints, one of which was `send` --
---said nothing about the session at all, which is the row this surface had
---least of and the one place there was room for it.
---@param chat table
function M.refresh_hints(chat)
  require("paseo.ui.composer").refresh(chat)
end

---Grow the composer to what is in it, and shrink it back.
---
---Early-returns when the height is already right, like `ui/prompt.lua`'s
---`fit`: this runs on every keystroke in insert mode.
---
---The dashboard has had this since `float.resize_composer`; the sidebar had
---not, and the sidebar is the surface that sits beside your code all day. A
---fixed eight rows there is a third of a narrow pane spent on whitespace for
---the whole of a session.
---
---`nvim_win_get_height` INCLUDES the winbar row -- measured -- and this
---composer carries a hint bar, so the bar is added back on top of the rows
---asked for. Without that, `ui.sidebar.composer` would mean one thing here
---and another on the dashboard, whose composer has no winbar.
---
---The `at_bottom`/`to_bottom` pair is not a nicety. Growing the composer takes
---its rows from the BOTTOM of the conversation, so without it typing a fourth
---line scrolls the agent's last sentence off the screen.
---@param chat table
function M.fit_composer(chat)
  local win, conv = chat.win_composer, chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end

  local ui = require("paseo.config").get().ui.sidebar
  local bar = (vim.wo[win].winbar or "") ~= "" and 1 or 0
  local total = api.nvim_win_get_height(win)
    + ((conv and api.nvim_win_is_valid(conv)) and api.nvim_win_get_height(conv) or 0)

  local rows = require("paseo.ui.layout").composer_rows {
    buf = chat.composer,
    win = win,
    -- One row over an empty buffer, as the dashboard's does.
    min = 1,
    -- Never so tall that the conversation has nothing left. `total` counts the
    -- conversation's own winbar, so the five here is four lines of transcript.
    max = math.max(1, math.min(math.floor(ui.composer or 8), total - 5 - bar)),
  }

  if api.nvim_win_get_height(win) == rows + bar then
    return
  end
  local stick = transcript.at_bottom(chat)
  api.nvim_win_set_height(win, rows + bar)
  if stick then
    transcript.to_bottom(chat)
  end
end

---@param chat table
function M.close(chat)
  for _, win in ipairs { chat.win_composer, chat.win_conversation } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, false)
    end
  end
  chat.win_composer, chat.win_conversation = nil, nil
end

---@param chat table
---@return boolean
function M.is_open(chat)
  return (chat.win_conversation and api.nvim_win_is_valid(chat.win_conversation)) and true or false
end

return M
