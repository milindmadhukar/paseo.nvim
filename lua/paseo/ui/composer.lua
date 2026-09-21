--- The box you type in, and the one row above it.
---
--- THE ROW ABOVE THE BOX IS THE POINT. What the agent session is -- its model,
--- its mode, its thinking level, how much context is left and which directory
--- it is working in -- used to live at the very top of whichever surface was
--- open: a winbar over the transcript in the sidebar, the first row of the
--- chrome on the dashboard. Both are as far from the cursor as it is possible
--- to get on that screen. You decide what to type with those five facts, and
--- you decide it while looking at the box; so they belong against the box,
--- which is where they are now.
---
--- That also gives the composer the one thing it was missing under `plate`:
--- a title row. A card in this UI is a title row and a body one elevation tier
--- above the surface -- see |paseo.ui.style| -- so a composer with a bar above
--- it IS a card, and the drawn box it used to have (in every style, including
--- the ones where nothing else has an edge) can go.
---
--- ONE BUILDER, TWO SURFACES. The bar is a `winbar` on the composer window in
--- both, rather than volt on the dashboard and a winbar in the sidebar: a
--- winbar repaints without going through volt's layout, which matters at
--- twenty frames a second when the microphone is open.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local style = require "paseo.ui.style"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---The overlay's own namespace. Nothing else may clear it: the composer is a
---real buffer and other things put marks in it.
local ns = api.nvim_create_namespace "paseo.composer.voice"

---How many level samples are kept. `ffmpeg` hands over 50ms at a time, so 48
---columns is about two and a half seconds of history -- long enough to see a
---word go past, short enough that the wave is still moving while you speak.
local HISTORY = 48

---Columns the elapsed count is given, whatever it currently needs. See `bar`.
local STATUS_W = 10

---The shortest run of hairline that still reads as one. Reserved out of the
---row before the header is asked what it can fit, because a divider the
---header has squeezed down to two cells is not a divider, it is a typo.
local RULE_MIN = 10

---Readings the room's floor is measured over, at one every 50ms: twenty
---seconds, which outlives any one sentence. See `push_level`.
local FLOOR_WINDOW = 400

---Full scale, and the room's own wobble, in dB over that floor. Four times the
---room is an ordinary voice at arm's length; two and a half decibels is what a
---room does on its own -- measured on a laptop microphone at 91% gain, where
---an empty study drifts between 0.143 and 0.197 RMS all by itself.
local RANGE_DB = 12
local GATE_DB = 2.5

-- ---------------------------------------------------------------- the meter

---@param chat table
---@return number[]
local function levels(chat)
  chat.voice_levels = chat.voice_levels or {}
  return chat.voice_levels
end

---A new reading from the microphone, scaled against the room it is in.
---
---THE ROOM IS NOT SILENT AND THE GAIN IS NOT KNOWN. |paseo.voice| reports raw
---RMS, and what that means depends entirely on the microphone: the laptop this
---was written on reads 0.16 with nobody in the room, while a headset a foot
---away reads a hundredth of that. Any fixed scaling is therefore wrong for one
---of them -- pinned at full, or flat at nothing -- and a meter that is wrong
---in either direction answers "is it hearing me" with the same picture
---whatever the answer is.
---
---SO IT IS A RATIO, IN DECIBELS, AGAINST THE ROOM. That is the fix for a meter
---that would not move: measuring the DIFFERENCE between this reading and the
---floor, and then gating on a fraction of the floor, is a test a loud room can
---never pass -- on a microphone whose room reads 0.16, a sound that genuinely
---doubles the input moves the number by 0.16, while the same doubling on a
---quiet headset moves it by 0.002. As a ratio both are the same event, which
---is what your ear says too: loudness is logarithmic, and a meter built on
---subtraction is a meter calibrated for exactly one microphone.
---
---`RANGE_DB` is what counts as full scale -- four times the room, which is an
---ordinary speaking voice at an arm's length -- and `GATE_DB` is the wobble a
---room makes on its own.
---
---The floor is the quietest reading in the last `FLOOR_WINDOW`. A WINDOW
---rather than a decay, because the first version crept the floor upwards at a
---fixed rate and a few seconds into a sentence it had climbed over the voice:
---the wave flattened while you were still talking. Twenty seconds of window
---outlives any one phrase, and speech has gaps, so the floor stays the room's.
---@param chat table
---@param level number  Raw RMS, 0..1.
function M.push_level(chat, level)
  local raw = math.max(0, math.min(1, level or 0))

  local seen = chat.voice_raw or {}
  seen[#seen + 1] = raw
  while #seen > FLOOR_WINDOW do
    table.remove(seen, 1)
  end
  chat.voice_raw = seen

  local floor = math.huge
  for _, value in ipairs(seen) do
    floor = math.min(floor, value)
  end
  -- A digitally silent input has no ratio to take. Anything at all over the
  -- noise floor of a 16-bit sample is a signal there.
  floor = math.max(floor, 1e-4)

  local over = 20 * math.log(math.max(raw, 1e-4) / floor, 10)
  -- Square-rooted, because the question is "can it hear me" and not "how many
  -- decibels". Linear in dB, a voice three decibels over a noisy room is one
  -- glyph tall -- which on a row of one-eighth blocks is indistinguishable
  -- from silence, and silence is the one answer it must not give when the
  -- microphone is working.
  local ratio = math.max(0, math.min(1, (over - GATE_DB) / (RANGE_DB - GATE_DB)))
  local scaled = math.sqrt(ratio)

  local history = levels(chat)
  history[#history + 1] = scaled
  while #history > HISTORY do
    table.remove(history, 1)
  end
  M.refresh(chat)
end

---How long the microphone has been open, as `0:07`.
---@param chat table
---@return string
local function elapsed(chat)
  local since = chat.dictating_since
  if not since then
    return "0:00"
  end
  local seconds = math.floor((vim.uv.now() - since) / 1000)
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

---The recording readout: a dot, the wave, the clock, and the way out.
---
---It takes the WHOLE bar while it is up, rather than sharing the row with the
---model and the path. Those are true all the time; this is true for ten
---seconds and is the only thing you want to know during them.
---@param chat table
---@param width integer
---@return table[]
function M.recorder(chat, width)
  local stop = (require("paseo.config").get().voice or {}).key or "<C-t>"
  local head = {
    { " " .. icons.ui.mic .. " ", "PaseoVoiceOn" },
    { "listening  ", "PaseoComposerHint" },
  }
  -- In a pane too narrow for the word, the glyph alone still says it: a red
  -- microphone is not something this UI draws for any other reason.
  if width < 46 then
    head = { { " " .. icons.ui.mic .. " ", "PaseoVoiceOn" } }
  end

  -- DEGRADES, like every other row on this surface. A winbar wider than its
  -- window is cut from the LEFT, so a sixty-column sidebar lost the
  -- microphone glyph and the word `listening` -- the two things the row exists
  -- to say -- and kept `discard`. The keys go first, then the clock, and the
  -- meter is what is left: it is the part you are actually watching.
  local clock = { { "  " .. elapsed(chat) .. "  ", "PaseoComposerHint" } }
  local keys = {
    { icons.spell(stop), "PaseoComposerKey" },
    { " stop  ", "PaseoComposerHint" },
    { icons.spell "<Esc>", "PaseoComposerKey" },
    { " discard ", "PaseoComposerHint" },
  }
  local short_keys = {
    { icons.spell(stop), "PaseoComposerKey" },
    { " stop ", "PaseoComposerHint" },
  }

  -- A COMPACT meter here, not the full waveform. The long one is inside the
  -- box, which is where you are looking and which is the thing that is
  -- supposed to have turned into a visualiser; a second full-width copy of it
  -- one row up is the same information twice in the same glance.
  local MIN_WAVE, MAX_WAVE = 6, 16
  local tail
  for _, candidate in ipairs { keys, short_keys, {} } do
    tail = vim.list_extend(vim.deepcopy(clock), candidate)
    if width - render.width(head) - render.width(tail) - 2 >= MIN_WAVE then
      break
    end
  end

  local room = width - render.width(head) - render.width(tail) - 2
  local line = vim.deepcopy(head)
  if room >= MIN_WAVE then
    vim.list_extend(line, widgets.waveform(levels(chat), { w = math.min(MAX_WAVE, room) }))
  end
  -- The last guard, for a box narrower than the clock and the glyph together.
  -- A winbar wider than its window is cut from the LEFT by Neovim, which takes
  -- the microphone with it; cutting it here takes the keys instead.
  return render.truncate(M.rule(line, tail, width), width)
end

-- ------------------------------------------------------------------ the rule

---Join the two ends of the bar with a HAIRLINE across the gap between them.
---
---THE EDGE OF THE BOX. Without a frame the composer was a slab of card colour
---with a row of text on top of it, and on a theme whose elevation tiers are
---close together that is not a box -- it is the same screen, slightly
---different. The obvious fix is a rule of its own, and a rule of its own costs
---a row of the transcript for something that is true the whole time.
---
---So the bar IS the rule: the text sits on it, the way a title sits on a
---section divider, and the gap that was empty padding does the work of the
---frame. One row, a visible top edge, and the words are still where they were.
---@param left table[]
---@param right table[]
---@param width integer
---@return table[]
function M.rule(left, right, width)
  local line = vim.deepcopy(left)
  -- The row ENDS on the rule as well as starting on it. Running it only
  -- between the two clusters reads as a separator inside the row; carrying it
  -- out to both edges is what makes the same glyph read as the top of a box,
  -- with the words sitting on it the way a title sits on a frame.
  local tail = { { " " .. style.BOX.square.h, "PaseoComposerBorder" } }
  local gap = width - render.width(left) - render.width(right) - render.width(tail)

  if gap >= 4 then
    -- A space either side, so the hairline never runs into a word. Drawn in
    -- the composer's own border group -- it IS the border now, and a theme
    -- that moves one should move the other.
    line[#line + 1] = {
      " " .. string.rep(style.BOX.square.h, gap - 2) .. " ",
      "PaseoComposerBorder",
    }
  elseif gap > 0 then
    -- Too tight to be a rule; a rule of two cells reads as a typo.
    line[#line + 1] = { string.rep(" ", gap), "PaseoComposerBar" }
  end

  vim.list_extend(line, right)
  vim.list_extend(line, tail)
  return line
end

-- ------------------------------------------------------------------ the bar

---How to send, as a hint.
---
---BOTH keys, because they are not interchangeable: `<CR>` sends from normal
---mode and opens a line from insert mode, so the key that works while you are
---still typing is the other one. `<C-s>` is deliberately not either of them --
---it means "the session list" everywhere in this plugin, and a composer that
---quietly meant something else by it was the one place the keyboard
---contradicted itself.
---@return table[]
function M.send_hint()
  return {
    { " ", "PaseoComposerHint" },
    { icons.spell "<CR>", "PaseoComposerKey" },
    { " / ", "PaseoComposerHint" },
    { icons.spell "<M-CR>", "PaseoComposerKey" },
    { " send ", "PaseoComposerHint" },
  }
end

---The row above the box, sized to the box.
---
---Degrades rather than truncates: the session header is dropped to its most
---important half before the send hint is dropped, because a composer that
---does not say how to send it is a composer you cannot use, while one that
---does not say which model it is on is merely one you have to ask.
---@param chat table
---@param width integer
---@return table[]
function M.bar(chat, width)
  width = math.max(10, width)

  if chat.dictating then
    return M.recorder(chat, width)
  end

  local sidebar = require "paseo.ui.sidebar"

  -- WHAT THE TURN IS DOING, against the box. A spinner and an elapsed count
  -- belong beside the thing you are waiting on, and the thing you are waiting
  -- on is the answer to what is in this box -- not a footer two panels away,
  -- and not the top of a sidebar you are not looking at.
  --
  -- Padded to a FIXED width rather than measured: the count grows from `9s` to
  -- `28m 49s` while you watch it, and a header sized against the true width
  -- would drop and re-add a part as it crossed each threshold. The row would
  -- twitch, which is the exact complaint that put this at the bottom of the
  -- screen in the first place.
  local status = sidebar.status(chat)
  local tail = {}
  if #status > 0 then
    vim.list_extend(tail, status)
    render.pad(tail, math.max(render.width(status), STATUS_W), "PaseoComposerBar")
    -- Joined to the send keys by the rule as well, so the row reads as ONE
    -- line with labels sitting on it rather than as three clusters that
    -- happen to share a row.
    tail[#tail + 1] = { " " .. style.BOX.square.h .. " ", "PaseoComposerBorder" }
  end
  vim.list_extend(tail, M.send_hint())

  -- The tail first: it is the fixed cost, and what is left is the width the
  -- header is asked to fit -- ASKED, not cut to. A sixty-column sidebar has
  -- room for about half of what this row can say, and `header` knows which
  -- half is worth keeping; `truncate` only knows which end it can reach.
  local lead = { { style.BOX.square.h .. " ", "PaseoComposerBorder" } }
  -- The reserve is a WIDE-ROW nicety. In a sixty-column sidebar those ten
  -- columns are the working directory, and a long divider is not worth the
  -- fact it would push off the row -- the lead-in and the tail tick are enough
  -- to say where the box starts there.
  local reserve = width >= 90 and RULE_MIN or 2
  local room = width - render.width(tail) - render.width(lead) - reserve
  if room < 12 then
    return render.truncate(sidebar.header(chat, { bar = true, width = width }), width)
  end

  local line = vim.deepcopy(lead)
  vim.list_extend(line, render.truncate(sidebar.header(chat, { bar = true, width = room }), room))
  return M.rule(line, tail, width)
end

-- ---------------------------------------------------------------- the box

---The visualiser inside the box.
---
---Virtual text rather than written lines, and that is not a detail: the
---composer holds your draft, and a visualiser that TYPED itself into the
---buffer would be indistinguishable from a visualiser that ate it. So the
---wave is an extmark on the last line -- drawn after whatever you have
---written, or filling an empty box outright, and gone the moment recording
---stops without anything having been undone.
---@param chat table
local function draw_overlay(chat)
  local buf = chat.composer
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not chat.dictating then
    return
  end

  local win = chat.win_composer
  local width = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_width(win) or 60

  local last = math.max(0, api.nvim_buf_line_count(buf) - 1)
  local text = api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
  local room = width - api.nvim_strwidth(text) - 4
  if room < 8 then
    return
  end

  local wave = widgets.waveform(levels(chat), { w = math.min(HISTORY, room) })
  local virt = { { "  ", "PaseoCard" } }
  for _, cell in ipairs(wave) do
    virt[#virt + 1] = { cell[1], cell[2] }
  end

  pcall(api.nvim_buf_set_extmark, buf, ns, last, 0, {
    virt_text = virt,
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

-- -------------------------------------------------------------------- paint

---Repaint the bar and the overlay for whichever windows this chat has.
---
---Cheap and idempotent, because the microphone calls it twenty times a second.
---@param chat table
function M.refresh(chat)
  local win = chat.win_composer
  if win and api.nvim_win_is_valid(win) then
    local bar = render.to_winbar(M.bar(chat, api.nvim_win_get_width(win)))
    pcall(function()
      vim.wo[win].winbar = bar
    end)
  end
  draw_overlay(chat)
end

---Paint the composer window itself: its background, and its bar.
---
---Called once when the window opens. The bar is a winbar, so it costs one row
---of the window's height -- which both surfaces account for, the dashboard in
---|paseo.ui.layout| and the sidebar in `fit_composer`.
---@param chat table
---@param opts? { border?: string }  Group for a drawn edge, where the style
---                has one. Absent means the box has no frame, which is what
---                `plate` and `rule` give it.
function M.style(chat, opts)
  local win = chat.win_composer
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  opts = opts or {}

  local parts = {
    "Normal:PaseoCard",
    "NormalFloat:PaseoCard",
    "WinBar:PaseoComposerBar",
    "WinBarNC:PaseoComposerBar",
  }
  if opts.border then
    parts[#parts + 1] = "FloatBorder:" .. opts.border
  end
  pcall(function()
    vim.wo[win].winhl = table.concat(parts, ",")
  end)
  M.refresh(chat)
end

-- ---------------------------------------------------------------- dictation

---The microphone opened, or closed.
---
---Owns the whole visible side of it: the state flag the header reads, the
---clock the bar counts, the level history, and the overlay. The one place
---`chat.dictating` is written, so a recording that ends -- by finishing, by
---being cancelled, or because the recorder died -- cannot leave the indicator
---lit.
---@param chat table
---@param recording boolean
function M.dictating(chat, recording)
  chat.dictating = recording or nil
  chat.dictating_since = recording and vim.uv.now() or nil
  chat.voice_levels = {}
  -- The room is measured fresh each time. A floor learned in a quiet study is
  -- wrong on a train, and the first thing you do on the train is press the key.
  chat.voice_raw = nil

  -- The clock has to tick on its own: the microphone only speaks when it has
  -- audio, and a silent room produces a reading every 50ms but an unchanging
  -- one, so nothing would move.
  if chat.dictating_timer then
    chat.dictating_timer:stop()
    chat.dictating_timer:close()
    chat.dictating_timer = nil
  end
  if recording then
    local timer = vim.uv.new_timer()
    chat.dictating_timer = timer
    timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        if chat.dictating then
          M.refresh(chat)
        end
      end)
    )
  end

  M.refresh(chat)
  -- The header is drawn on every tab of the dashboard, not only over the box,
  -- so it gets the news too.
  require("paseo.ui.sidebar").refresh(chat)
end

return M
