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

---Readings the room is measured over, at one every 50ms: twenty seconds, which
---outlives any one sentence. See `push_level`.
local FLOOR_WINDOW = 400

---And the window full scale follows, at five seconds. Short, because it tracks
---the voice rather than the room: it should be over within a sentence or two
---of your moving closer to the microphone, and one cough should not flatten
---the meter for the rest of the minute.
local PEAK_WINDOW = 100

---What the room's own wobble is worth, as a multiple of the part of it that
---can be measured while someone is talking.
---
---A room is not one level, it is a spread: a fan, a fridge, a road, the
---microphone's own hiss. The gate has to clear the WHOLE of that spread or an
---empty room draws a wave, and no single number does that on every machine --
---an empty study on the laptop this was fixed on swings ten decibels from its
---quietest 50ms to its loudest, while a clean line is steady to two. So the
---spread is measured, and this is the constant that turns the part which can
---be measured into the part which cannot: the distance from the 5th percentile
---of the window to the 50th, times this, is where the gate sits.
---
---It is a fact about the SHAPE of a distribution and not about any microphone,
---which is the whole reason it is allowed to be a constant when nothing else
---here is. A level in dB is the log of a mean of squares over hundreds of
---samples, so chunk to chunk a steady room is near enough normal, where p5 to
---p50 is 1.65 standard deviations and the full range of a few hundred draws is
---about 5.15 -- a ratio of 3.1. Rooms that WANDER are flatter than normal and
---want less, which is why the number that holds across every input this was
---checked against is 2.5 rather than the 3.1 the theory alone would give.
local SPREAD_K = 2.5

---And the ends of it, because a measured number still needs a bound.
---
---`GATE_MIN` is the margin even a dead-steady input gets. Something has to
---separate "the quietest thing this microphone has heard" from "a sound", or
---the last digit of a silent line draws a wave.
---
---`GATE_MAX` is the point past which a gate stops protecting the meter and
---starts eating the speech, and it is also what makes a MEDIAN safe to measure
---the spread from. Half a window of solid talking is half a window the median
---sits inside, and with no ceiling the gate would climb after your voice and
---the wave would die while you were still using it -- a complaint this meter
---has already had once. With one, the worst a talkative window can do is pin
---the gate here, and speech runs twenty to thirty decibels over a room floor,
---so it still clears it. The clamp errs LOW for the same reason: this fails as
---a noisy room drawing a little, which is true, rather than as a voice drawing
---nothing, which is the bug.
local GATE_MIN = 6
local GATE_MAX = 12

---The narrowest the scale above the gate is ever allowed to get.
---
---Above the gate the top of the meter is whatever the LOUDEST thing recently
---heard was, rather than a fixed number of decibels -- and that is the half
---that stops it pinning on one machine and crawling on another. How far speech
---sits over a room floor is a fact about the room, the gain and how far away
---you are sitting, and any fixed full scale is reached on every syllable by
---one microphone and never by the next. Following the loudest recent reading
---makes the bar full when you are as loud as you have been, which is the
---question it is actually being asked, on any input. `SPAN_DB` only stops the
---scale collapsing onto the gate in a room where nothing has happened yet.
local SPAN_DB = 8

---How far BELOW the gate the drawn range opens, once the gate has been cleared.
---
---The gate answers "is this a room or a voice". It is not, and never was, the
---right bottom for the drawn range, and using it as both is what made the
---meter read a working microphone as silence -- see `push_level`. Applied in
---proportion to how far the peak clears the gate, never as a step.
local PULL_DB = 8

---What the peak must clear the gate by before the range opens downward at all.
---
---Without it the pull is a step function on a comparison that is decided by a
---fraction of a decibel, and a silent room strobes between empty and full.
local MARGIN_DB = 3

-- ---------------------------------------------------------------- the meter

---@param chat table
---@return number[]
local function levels(chat)
  chat.voice_levels = chat.voice_levels or {}
  return chat.voice_levels
end

---A new reading from the microphone, scaled against the room it is in.
---
---NOTHING HERE IS CALIBRATED TO A MICROPHONE, and that is the requirement
---rather than a nicety. |paseo.voice| reports the sound it heard and nothing
---more, because what a number means depends entirely on the input: a headset
---an inch from your mouth and a laptop across the desk are fifty times apart
---on the same sentence, and the same room is twenty times apart on two sound
---cards. Any constant with a level in it is therefore right on one machine and
---wrong on the next -- pinned at full before you speak, or flat while you do
---- and a meter that is wrong in either direction answers "is it hearing me"
---with the same picture whichever the answer is.
---
---So all three of the numbers this needs are measured from the signal, every
---reading, and the only constants are ratios and bounds:
---
---THE FLOOR is the 5th percentile of the last `FLOOR_WINDOW`. A percentile
---rather than the minimum, which one glitched 50ms drags down, and a WINDOW
---rather than a decay: an early version crept the floor upwards at a fixed
---rate and a few seconds into a sentence it had climbed over the voice, so the
---wave flattened while you were still talking. Twenty seconds outlives any one
---phrase, and speech has gaps, so the floor stays the room's.
---
---THE GATE is the room's own spread over that floor, measured from the median
---of the same window and clamped -- see `SPREAD_K` and `GATE_MAX`. Under it is
---the room, and is drawn as silence.
---
---THE TOP is the loudest thing heard in the last `PEAK_WINDOW`, never less
---than `SPAN_DB` over the gate -- see `SPAN_DB`. This is what keeps a loud
---input off the ceiling and a quiet one off the floor: the scale is the range
---this microphone is actually working over, not one chosen for some other.
---@param chat table
---@param level number  RMS about the mean, 0..1, from |paseo.voice|.
function M.push_level(chat, level)
  local raw = math.max(0, math.min(1, level or 0))

  local seen = chat.voice_raw or {}
  seen[#seen + 1] = raw
  while #seen > FLOOR_WINDOW do
    table.remove(seen, 1)
  end
  chat.voice_raw = seen

  -- Sorted, for the two order statistics below. Sorting the whole window on
  -- every reading is 56us of the 50ms it has -- about a thousandth of a core,
  -- measured -- which is worth not having to keep two running estimators
  -- correct against a window that slides out from under both of them.
  local ranked = vim.deepcopy(seen)
  table.sort(ranked)
  ---@param p number  0..1
  ---@return number
  local function percentile(p)
    return ranked[math.max(1, math.min(#ranked, math.floor(p * (#ranked - 1)) + 1))]
  end

  -- A digitally silent input has no ratio to take. Anything at all over the
  -- noise floor of a 16-bit sample is a signal there.
  local floor = math.max(percentile(0.05), 1e-4)

  ---@param value number
  ---@return number  dB of `value` over the floor.
  local function over(value)
    return 20 * math.log(math.max(value, 1e-4) / floor, 10)
  end

  -- THE PEAK FIRST: what the scale does below depends on whether the gate has
  -- been cleared at all.
  local peak = 0
  for i = math.max(1, #seen - PEAK_WINDOW + 1), #seen do
    peak = math.max(peak, over(seen[i]))
  end

  local gate = math.max(GATE_MIN, math.min(GATE_MAX, SPREAD_K * over(percentile(0.5))))

  -- WHERE THE BAR STARTS, and the whole of the fix for "it barely moves when I
  -- speak".
  --
  -- The gate is sized to reject a ROOM -- a floor that wanders, with no voice
  -- in it -- and at that job it is right. The bug was using it as the bottom
  -- of the DRAWN RANGE as well. `dictating` clears the window on every
  -- transition, so it holds only the seconds since you pressed the key: start
  -- talking straight away and there is no silence in it anywhere. The floor is
  -- then measured from your own quietest syllable and the median from your own
  -- voice, which puts a gate a dozen decibels above the floor most of the way
  -- up your actual signal. Ordinary speech drew one glyph and the odd stressed
  -- vowel spiked -- measured, on a soft voice the peak of a ten-second window
  -- landed at 11.8dB against a gate of 12.0, so the row never moved at all.
  --
  -- So once the peak has CLEARED the gate -- which a room never does, by
  -- construction, and that is what keeps silence silent -- the window holds
  -- signal rather than noise, and the range opens downward to put mid-speech
  -- in the middle of the bar instead of underneath it.
  --
  -- PROPORTIONAL, and that matters more than the size of it. A step -- pull
  -- the moment `peak > gate` -- swung the whole scale on a hair: measured on a
  -- quiet room the gate sits at 9.65 against a peak of 9.69, so a single loud
  -- sample flipped the bar from silent to full and back twenty times a second.
  -- `MARGIN_DB` is what the peak must clear before any of this starts, and
  -- `reach` then fades the pull in over `SPAN_DB` rather than switching it.
  local reach = math.max(0, math.min(1, (peak - gate - MARGIN_DB) / SPAN_DB))
  local low = math.max(0, gate - PULL_DB * reach)
  local top = math.max(peak, low + SPAN_DB)

  -- Square-rooted, because the question is "can it hear me" and not "how many
  -- decibels". Linear in dB, a voice three decibels over a noisy room is one
  -- glyph tall -- which on a row of one-eighth blocks is indistinguishable
  -- from silence, and silence is the one answer it must not give when the
  -- microphone is working.
  local ratio = math.max(0, math.min(1, (over(raw) - low) / (top - low)))
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

---Which spinner frame this moment is on.
---
---Off the clock rather than off a counter, so every surface drawing the same
---wait draws the same frame, and a repaint that happens for some other reason
---does not shunt the animation forward a step.
---@return string
local function spin()
  return widgets.spinner()
end

---And the colour it is drawn in: `PaseoToolRunning`, this UI's "in flight",
---and pointedly NOT `PaseoVoiceOn`. That red means the microphone is open, and
---it means it nowhere else -- a red glyph on a row that exists to say the
---microphone is NOT open yet would be the indicator lying, which is the thing
---the separate state was added to stop.
local SPIN_HL = "PaseoToolRunning"

---The bar while the microphone is opening.
---
---SAYS WHAT IS HAPPENING AND THAT THE BOX IS SHUT, because those are the two
---things you cannot otherwise tell. This wait is two round trips -- the
---sidecar, then the daemon accepting the stream, which on a cold daemon is
---where the speech models load -- and it used to be drawn as nothing at all:
---the bar still said which model the session was on, the box still took
---keystrokes, and the only evidence the key had done anything was that some
---seconds later a recorder appeared.
---
---Degrades the same way `recorder` does, and gives up the same things in the
---same order: the sentence first, then the way out, and the spinner last. A
---spinner alone still says "something is happening", which is most of the job.
---@param chat table
---@param width integer
---@return table[]
function M.waking(chat, width)
  local head = { { " " .. spin() .. " ", SPIN_HL } }
  if width >= 52 then
    head[#head + 1] = { "opening the microphone  ", "PaseoComposerHint" }
  elseif width >= 34 then
    head[#head + 1] = { "opening  ", "PaseoComposerHint" }
  end

  -- THE COUNT, on a row whose whole subject is a wait. A spinner says the
  -- editor has not hung; it does not say whether this is the ordinary two
  -- seconds or the daemon fetching a speech model, and that is the difference
  -- between waiting and giving up on it. Same `dictating_since` the recorder's
  -- clock uses, restarted when the microphone actually opens.
  local clock = { { "  " .. elapsed(chat) .. "  ", "PaseoComposerHint" } }
  local keys = {
    { icons.spell "<Esc>", "PaseoComposerKey" },
    { " cancel ", "PaseoComposerHint" },
  }
  local tail
  for _, candidate in ipairs { { clock, keys }, { keys }, { clock }, {} } do
    tail = {}
    for _, part in ipairs(candidate) do
      vim.list_extend(tail, vim.deepcopy(part))
    end
    if width - render.width(head) - render.width(tail) - 2 >= 0 then
      break
    end
  end
  return render.truncate(M.rule(head, tail, width), width)
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

  -- THE meter, now -- there is no longer one in the box for this to be the
  -- compact echo of, so it takes whatever room the row has rather than the
  -- sixteen columns it kept while it was the second copy. `HISTORY` is the
  -- ceiling because that is how many readings there are to draw: asking for
  -- more pads the left with idle glyphs, which reads as silence that happened.
  local MIN_WAVE, MAX_WAVE = 6, HISTORY
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

  if chat.dictating == "starting" then
    return M.waking(chat, width)
  end
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

---The wait before the microphone opens.
---
---ONE thing, and it is not the meter: why the box is not taking your keys.
---The meter lives one row up, beside the microphone. There used to be a second
---full-width copy of it in here, and two rows of blocks answering the same
---voice is the same information twice in the same glance -- so the one you
---were not looking at went.
---
---Virtual text rather than written lines, and that is not a detail: the
---composer holds your draft, and a notice that TYPED itself into the buffer
---would be indistinguishable from one that ate it. So it is an extmark on the
---last line -- drawn after whatever you have written, and gone the moment the
---microphone opens without anything having been undone.
---
---It is drawn IN THE BOX rather than only on the bar because the box is where
---you are looking and where the keystrokes were going to go; a lock explained
---one row up is a lock you find out about by typing into a buffer that
---ignores you.
---@param chat table
local function draw_overlay(chat)
  local buf = chat.composer
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if chat.dictating ~= "starting" then
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

  -- WHY THE BOX IS NOT TAKING KEYS, and only that. What is happening is the
  -- bar's job one row up; this row has one thing to say and it is the thing
  -- that is otherwise indistinguishable from a wedged editor -- so it is what
  -- survives into the short form rather than what gets dropped from it.
  local said = "typing is off until the microphone opens"
  if room < api.nvim_strwidth(said) + 2 then
    said = "typing is off"
  end
  local virt = {
    { "  ", "PaseoCard" },
    { spin() .. " ", SPIN_HL },
    { said, "PaseoComposerHint" },
  }

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

---Put the top of the draft back on the top row of the box.
---
---THE BUG THIS IS. The box is resized from `TextChanged`, which fires AFTER
---the text changed and therefore after Neovim has already scrolled: press
---`<CR>` in a one-row box and line 1 goes above the top of the window to keep
---the cursor on screen, and only then does the box grow to two rows. Neovim
---does not scroll back -- `update_topline` scrolls only as far as it must to
---keep the cursor visible, and the cursor is visible -- so the box grew and
---the line you had just typed stayed the only one you could see. Everything
---above it was still in the buffer, still in the send, and invisible.
---
---ONLY WHEN THE WHOLE DRAFT FITS. Past the ceiling the box is a viewport onto
---something longer than itself, the cursor is what has to stay on screen, and
---Neovim's own behaviour is the right one -- so the fix there is to do
---nothing.
---
---Measured rather than passed in: `nvim_win_text_height` counts the rows the
---content actually occupies in THIS window, wrapping and all, which is the
---same question "does it fit" asks. A caller handing us its own idea of the
---row count would be a second copy of |paseo.ui.layout|.composer_rows.
---@param win integer|nil
function M.reveal(win)
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local ok, measured = pcall(api.nvim_win_text_height, win, {})
  if not (ok and measured and measured.all) then
    return
  end
  -- `nvim_win_get_height` INCLUDES the winbar row, and the composer always
  -- carries one -- the session's model, mode and directory are drawn on it.
  local bar = (vim.wo[win].winbar or "") ~= "" and 1 or 0
  if measured.all > api.nvim_win_get_height(win) - bar then
    return
  end

  api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    if view.topline > 1 or (view.skipcol or 0) > 0 then
      vim.fn.winrestview { topline = 1, skipcol = 0 }
    end
  end)
end

-- ---------------------------------------------------------------- dictation

---Typing, while the microphone is still opening.
---
---OFF, and that is the answer to a box that silently took keys it was about to
---have a transcript dropped into. The wait is real -- the sidecar has to be up
---and the daemon has to accept the stream -- and for the length of it anything
---typed is a race between what you wrote and what you said.
---
---`stopinsert` FIRST, not `modifiable` alone. A buffer left in insert mode with
---'modifiable' off rejects every keystroke one at a time, each with its own
---`E21`, which is a worse answer than a box that simply is not taking them --
---and it is a stream of errors over the row explaining why. Out of insert, the
---same lock is one message the first time you ask for it, and the mode comes
---back when the microphone does: a key pressed from insert mode returns you to
---insert mode, where you were, so the wait costs you nothing but the wait.
---@param chat table
---@param allowed boolean
local function typing(chat, allowed)
  local buf = chat.composer
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end

  if not allowed then
    if chat.dictating_locked ~= nil then
      return
    end
    chat.dictating_locked = vim.bo[buf].modifiable
    chat.dictating_insert = api.nvim_get_current_buf() == buf and vim.fn.mode():sub(1, 1) == "i"
    if chat.dictating_insert then
      chat.dictating_col = api.nvim_win_get_cursor(0)
      vim.cmd.stopinsert()
    end
    vim.bo[buf].modifiable = false
    return
  end

  if chat.dictating_locked == nil then
    return
  end
  vim.bo[buf].modifiable = chat.dictating_locked
  local resume, at = chat.dictating_insert, chat.dictating_col
  chat.dictating_locked, chat.dictating_insert, chat.dictating_col = nil, nil, nil
  if not (resume and api.nvim_get_current_buf() == buf) then
    return
  end
  -- Back to the column it was in, which `startinsert` alone cannot promise:
  -- bare, it puts the cursor BEFORE the character under it, which is right
  -- everywhere except the end of a line -- and the end of a line is where the
  -- cursor is whenever you have just finished typing the draft.
  local row = at and at[1] or api.nvim_buf_line_count(buf)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if at and at[2] < #line then
    pcall(api.nvim_win_set_cursor, 0, at)
    vim.cmd.startinsert()
  else
    pcall(api.nvim_win_set_cursor, 0, { row, math.max(0, #line) })
    vim.cmd "startinsert!"
  end
end

---The microphone opened, is opening, or closed.
---
---Owns the whole visible side of it: the state the header reads, the clock the
---bar counts, the level history, the overlay and the lock on the box. The one
---place `chat.dictating` is written, so a recording that ends -- by finishing,
---by being cancelled, because the recorder died, or because it never started
---at all -- cannot leave the indicator lit or the box shut.
---@param chat table
---@param state paseo.VoiceState|boolean  `true` is still `"listening"`, which
---              is what the suites and any older caller pass.
function M.dictating(chat, state)
  if state == true then
    state = "listening"
  end
  chat.dictating = state or nil
  chat.dictating_since = chat.dictating and vim.uv.now() or nil
  chat.voice_levels = {}
  -- The room is measured fresh each time. A floor learned in a quiet study is
  -- wrong on a train, and the first thing you do on the train is press the key.
  chat.voice_raw = nil

  typing(chat, chat.dictating ~= "starting")

  -- The bar has to tick on its own: the microphone only speaks when it has
  -- audio, and a silent room produces a reading every 50ms but an unchanging
  -- one, so nothing would move. A spinner is the whole of what is moving while
  -- the microphone opens, so that half runs ten times as often -- and stops
  -- being a timer at all once the wave is what the row is drawing.
  if chat.dictating_timer then
    chat.dictating_timer:stop()
    chat.dictating_timer:close()
    chat.dictating_timer = nil
  end
  if chat.dictating then
    local every = chat.dictating == "starting" and 100 or 1000
    local timer = vim.uv.new_timer()
    chat.dictating_timer = timer
    timer:start(
      every,
      every,
      vim.schedule_wrap(function()
        if chat.dictating then
          M.refresh(chat)
        end
      end)
    )
  end

  M.refresh(chat)
  -- Away from the Chat tab there is no box to draw a meter over: the
  -- dashboard's footer says "listening" instead, so it gets the news too.
  require("paseo.ui.sidebar").refresh(chat)
end

return M
