--- The box you type in: the bar above it, and the microphone meter.
---
--- The bar is where the session's model, mode and directory live now -- see
--- |paseo.ui.composer| for why they moved off the top of the screen -- so what
--- is worth pinning here is the DEGRADATION: a sixty-column sidebar cannot say
--- all of it, and which half it gives up is the whole of whether the row was
--- worth moving.
---
--- The meter is pinned because it is the part that cannot be eyeballed from a
--- screenshot: whether it reads "silent" in a room that is not silent depends
--- on numbers, and the numbers depend on a microphone nobody in CI has.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local render = require "paseo.ui.render"

---@return table  A chat with a composer buffer and no windows.
local function fresh()
  return {
    root = vim.uv.cwd(),
    agent_id = "composer-test",
    provider = "claude/claude-opus-5",
    mode = "Plan Mode",
    thinking = "high",
    usage = { contextWindowUsedTokens = 58000, contextWindowMaxTokens = 200000 },
    streaming = false,
    pending = {},
    composer = vim.api.nvim_create_buf(false, true),
    conversation = vim.api.nvim_create_buf(false, true),
  }
end

local function test_bar()
  local composer = require "paseo.ui.composer"
  local chat = fresh()

  local wide = render.concat(composer.bar(chat, 120))
  truthy("composer: the bar says which model", wide:find("opus", 1, true) ~= nil, wide)
  truthy("composer: and which mode", wide:find("Plan Mode", 1, true) ~= nil, wide)
  truthy(
    "composer: and where the agent is working",
    wide:find(vim.fs.basename(chat.root), 1, true) ~= nil,
    wide
  )
  truthy("composer: and how to send it", wide:find("send", 1, true) ~= nil, wide)

  -- WHAT GOES FIRST WHEN THERE IS NO ROOM. A sidebar is sixty columns and the
  -- row cannot have everything; it gives up the readouts -- the thinking
  -- level, the context gauge, the model -- and keeps the mode and the
  -- directory, which are the two facts you check before telling an agent to
  -- change something on disk. `truncate` would have cut from the right and
  -- taken exactly those two.
  local narrow = render.concat(composer.bar(chat, 58))
  truthy(
    "composer: a narrow bar still names the mode",
    narrow:find("Plan Mode", 1, true) ~= nil,
    narrow
  )
  truthy(
    "composer: and still says where it is working",
    narrow:find(vim.fs.basename(chat.root), 1, true) ~= nil,
    narrow
  )
  truthy("composer: and still says how to send", narrow:find("send", 1, true) ~= nil, narrow)
  truthy(
    "composer: the row never overflows the box",
    render.width(composer.bar(chat, 58)) <= 58,
    render.width(composer.bar(chat, 58))
  )

  -- `<C-s>` IS THE SESSION LIST, everywhere. The composer used to send on it
  -- while the session strip four rows above advertised it as the way to the
  -- session list -- one key, two meanings, both on screen at once.
  eq("composer: the send hint does not claim <C-s>", wide:find("Ctrl + s", 1, true), nil)
  truthy("composer: it names the alt chord instead", wide:find("Alt", 1, true) ~= nil, wide)

  -- NO WIDTH OVERFLOWS THE BOX, recording or not. A winbar wider than its
  -- window is cut from the LEFT by Neovim -- which takes the microphone glyph
  -- and the word `listening` and leaves `discard`, the least useful third of
  -- the row. Every cluster on it degrades instead, and this is the assertion
  -- that says so at every width a composer can have.
  local overflow = {}
  for _, recording in ipairs { false, true } do
    chat.dictating = recording or nil
    chat.dictating_since = recording and vim.uv.now() or nil
    for w = 20, 200 do
      if render.width(composer.bar(chat, w)) > w then
        overflow[#overflow + 1] = ("%s at %d"):format(recording and "recording" or "idle", w)
      end
    end
  end
  chat.dictating, chat.dictating_since = nil, nil
  eq("composer: no width overflows the box", overflow, {})

  -- A permission request outranks everything and is never dropped.
  chat.permissions = { { id = "p1" } }
  local blocked = render.concat(composer.bar(chat, 40))
  truthy(
    "composer: something waiting on you survives any width",
    blocked:find("needs you", 1, true) ~= nil,
    blocked
  )
  chat.permissions = nil
end

---A microphone, as the meter sees one.
---
---`push_level` takes RMS readings, one per 50ms, so a microphone in this suite
---is a sequence of them -- which is the only way to test this at all, since
---nothing here may open an input device.
---
---The two things it has to get right are the two the old numbers got wrong. A
---ROOM WANDERS: it is not one level but a spread of them, and a meter tested
---against a constant passes while being unable to tell a fan from a voice. A
---VOICE IS NOT STEADY EITHER: it swings twenty decibels between a vowel and
---the stop after it, several times a second, and a meter tested against four
---seconds of an unvarying tone is being asked a question nobody ever asks it.
---
---Its own generator, rather than `math.random`, so a failure here is the same
---failure on every machine and every Lua.
---@param opts { room: number, wobble?: number, snr?: number, seconds: number }
---@return number[]
local function mic(opts)
  local seed = 20260922
  local function rand()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  end

  local out = {}
  for i = 1, math.floor(opts.seconds * 20) do
    -- The room, wandering over `wobble` decibels.
    local level = opts.room * 10 ^ ((opts.wobble or 8) * rand() / 20)
    if opts.snr then
      -- And a voice over it, at `snr` decibels, syllable by syllable.
      local env = 0.03 + 0.97 * math.sin(2 * math.pi * 3.2 * i / 20) ^ 2
      local voice = opts.room * 10 ^ (opts.snr / 20) * env
      -- Sound adds in power, not in amplitude.
      level = math.sqrt(level * level + voice * voice)
    end
    out[#out + 1] = level
  end
  return out
end

---@param chat table
---@param levels number[]
---@return integer[]  One glyph height, 1..8, per reading.
local function feed(chat, levels)
  local composer = require "paseo.ui.composer"
  local out = {}
  for _, level in ipairs(levels) do
    composer.push_level(chat, level)
    out[#out + 1] =
      math.max(1, math.min(8, math.floor(chat.voice_levels[#chat.voice_levels] * 8) + 1))
  end
  return out
end

---@param steps integer[]
---@param from? integer  Only from this reading on.
---@return integer highest, integer lowest, number mean
local function summarise(steps, from)
  local high, low, sum, count = 0, 9, 0, 0
  for i = from or 1, #steps do
    high, low = math.max(high, steps[i]), math.min(low, steps[i])
    sum, count = sum + steps[i], count + 1
  end
  return high, low, sum / math.max(1, count)
end

local function test_meter()
  local composer = require "paseo.ui.composer"
  local widgets = require "paseo.ui.widgets"
  local chat = fresh()

  -- NOTHING HERE IS CALIBRATED TO A MICROPHONE, and this is the block that
  -- says so. The meter is handed a level and has to work out for itself what
  -- counts as silence and what counts as full, because the numbers differ by a
  -- factor of a hundred between a headset and a laptop across the desk -- and
  -- a meter tuned to either one answers "is it hearing me" with the same
  -- picture whatever the answer is on the other.
  --
  -- `least` is what a voice has to be worth at its quietest, as a fraction of
  -- the bar. An ordinary one has to FILL it; the soft one over a loud room
  -- only has to be visibly more than nothing.
  for _, case in ipairs {
    { name = "a laptop microphone", room = 0.006, wobble = 10, snr = 22, least = 0.75 },
    { name = "a soft voice on one", room = 0.006, wobble = 10, snr = 12, least = 0.35 },
    { name = "a headset", room = 0.002, wobble = 3, snr = 30, least = 0.85 },
    { name = "a very quiet input", room = 0.0004, wobble = 3, snr = 30, least = 0.85 },
    { name = "a hot input in a loud room", room = 0.06, wobble = 12, snr = 20, least = 0.7 },
  } do
    local room = {}
    -- SILENCE FIRST. A room reads as nothing however loud the room is, or the
    -- meter is a meter that says "yes" before you have said a word.
    local quiet = feed(room, mic { room = case.room, wobble = case.wobble, seconds = 6 })
    local quiet_high = summarise(quiet, 20)
    ---@cast quiet_high integer
    truthy(
      ("composer: %s reads as silent when nobody is talking"):format(case.name),
      quiet_high <= 2,
      quiet_high
    )

    -- THEN TEN SECONDS OF TALKING, which is the half that used to die. The
    -- floor tracked the voice upwards and the wave flattened out mid-sentence
    -- -- "the waveform doesn't come when I am speaking" -- so what is asserted
    -- is the LAST four seconds of it and not the first.
    local speech =
      feed(room, mic { room = case.room, wobble = case.wobble, snr = case.snr, seconds = 10 })
    local high, low = summarise(speech, #speech - 80)
    truthy(
      ("composer: and %s still reads as speech ten seconds in"):format(case.name),
      high >= math.floor(case.least * 8),
      high
    )
    -- MOVING, which is a range and not an average. The gaps between syllables
    -- on a soft voice are genuinely quieter than the room around it, so the
    -- mean of a wave that is working perfectly well sits near the floor; what
    -- says it is working is that the row has a shape. A wave pinned at either
    -- end has none, and both ends look like a meter that is doing its job
    -- until you speak.
    truthy(
      ("composer: with %s moving rather than pinned"):format(case.name),
      high - low >= 3,
      ("%d..%d"):format(low, high)
    )
  end

  -- LOUDER READS HIGHER. Three voices over the same room, and the meter has to
  -- put them in that order: a scale that saturates on the quietest of them is
  -- as useless as one that never leaves the floor, and both look like working.
  local heights = {}
  for _, snr in ipairs { 10, 18, 30 } do
    local mic_chat = {}
    feed(mic_chat, mic { room = 0.005, wobble = 8, seconds = 6 })
    local _, _, mean =
      summarise(feed(mic_chat, mic { room = 0.005, wobble = 8, snr = snr, seconds = 6 }))
    heights[#heights + 1] = mean
  end
  truthy(
    "composer: a louder voice reads higher than a quieter one",
    heights[1] < heights[2] and heights[2] < heights[3],
    vim.inspect(heights)
  )

  -- AND THE GAIN KNOB IS NOT THE SUBJECT. The same room and the same voice
  -- fifty times louder is the same picture, because what is being drawn is the
  -- difference between them -- which is the whole reason a fixed scale had to
  -- go.
  local soft, loud = {}, {}
  feed(soft, mic { room = 0.001, wobble = 8, seconds = 6 })
  feed(loud, mic { room = 0.05, wobble = 8, seconds = 6 })
  local soft_steps = feed(soft, mic { room = 0.001, wobble = 8, snr = 24, seconds = 6 })
  local loud_steps = feed(loud, mic { room = 0.05, wobble = 8, snr = 24, seconds = 6 })
  eq("composer: fifty times the gain draws the same wave", soft_steps, loud_steps)

  -- The waveform is a glyph per reading, newest last, and quiet columns are
  -- drawn in the track colour rather than left blank -- a blank meter and a
  -- meter that is not running are the same picture.
  local wave = widgets.waveform({ 0, 0.5, 1 }, { w = 3 })
  eq("composer: one column per reading", #wave, 3)
  eq("composer: the quietest is the floor glyph", wave[1][1], require("paseo.ui.style").WAVE[1])
  eq("composer: the loudest is the full block", wave[3][1], require("paseo.ui.style").WAVE[8])
  eq("composer: and silence is drawn in the track colour", wave[1][2], "PaseoVoiceIdle")
  truthy("composer: while a loud column is not", wave[3][2] ~= "PaseoVoiceIdle", wave[3][2])

  -- Asked for more columns than it has readings, it pads on the LEFT: the
  -- wave grows in from the right rather than jumping across the row when it
  -- fills up.
  local short = widgets.waveform({ 1 }, { w = 4 })
  eq("composer: a short history is right-aligned", #short, 4)
  eq("composer: with the newest column last", short[4][1], require("paseo.ui.style").WAVE[8])

  -- WHILE THE MICROPHONE IS OPEN THE BAR IS THE RECORDER. Nothing else on it
  -- is worth the row for those ten seconds.
  composer.dictating(chat, true)
  local recording = render.concat(composer.bar(chat, 90))
  truthy(
    "composer: the bar says it is listening",
    recording:find("listening", 1, true) ~= nil,
    recording
  )
  truthy("composer: with a clock", recording:find("0:0", 1, true) ~= nil, recording)
  truthy("composer: and how to stop", recording:find("stop", 1, true) ~= nil, recording)

  -- THE BOX ITSELF BECOMES THE VISUALISER, as virtual text -- never as
  -- written lines. The composer holds your draft, and a visualiser that typed
  -- itself into the buffer would be indistinguishable from one that ate it.
  vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, { "half a question" })
  composer.push_level(chat, 0.4)
  local ns = vim.api.nvim_create_namespace "paseo.composer.voice"
  local marks = vim.api.nvim_buf_get_extmarks(chat.composer, ns, 0, -1, { details = true })
  truthy("composer: the box carries the wave while recording", #marks == 1, #marks)
  eq(
    "composer: and the draft is untouched",
    vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false),
    { "half a question" }
  )

  -- THE BOX IS SHUT WHILE THE MICROPHONE OPENS, and open the rest of the time.
  -- The wait is two round trips to a daemon that may be cold, and for the
  -- length of it anything typed is racing the transcript that is about to land
  -- on top of it. `"starting"` is also drawn differently -- a spinner and a
  -- sentence rather than a wave -- because a box that ignores your keys has to
  -- say that it is doing so.
  composer.dictating(chat, "starting")
  eq(
    "composer: the box will not take keys while the microphone opens",
    vim.bo[chat.composer].modifiable,
    false
  )
  local waking = render.concat(composer.bar(chat, 90))
  truthy(
    "composer: and the bar says what it is waiting for",
    waking:find("opening", 1, true) ~= nil,
    waking
  )
  eq("composer: and does not yet claim to be listening", waking:find("listening", 1, true), nil)
  truthy("composer: with a way out of the wait", waking:find("cancel", 1, true) ~= nil, waking)
  local waiting = vim.api.nvim_buf_get_extmarks(chat.composer, ns, 0, -1, { details = true })
  truthy(
    "composer: and the box itself says typing is off",
    (waiting[1] and render.concat(waiting[1][4].virt_text) or ""):find("typing is off", 1, true)
      ~= nil,
    waiting[1] and render.concat(waiting[1][4].virt_text)
  )

  composer.dictating(chat, "listening")
  eq("composer: the box takes keys again once it opens", vim.bo[chat.composer].modifiable, true)

  -- AND IT IS GIVEN BACK WHEN THE START FAILS TOO, which is the path that
  -- matters: `"starting"` straight to nothing, with no microphone in between.
  -- A lock that only lifted on success would leave a box that cannot be typed
  -- into after a daemon that has no speech models said so.
  composer.dictating(chat, "starting")
  composer.dictating(chat, false)
  eq("composer: a start that fails hands the box back", vim.bo[chat.composer].modifiable, true)

  composer.dictating(chat, true)
  composer.dictating(chat, false)
  eq(
    "composer: stopping takes the wave out of the box",
    #vim.api.nvim_buf_get_extmarks(chat.composer, ns, 0, -1, {}),
    0
  )
  local idle = render.concat(composer.bar(chat, 90))
  truthy(
    "composer: and the bar goes back to the session",
    idle:find("Plan Mode", 1, true) ~= nil,
    idle
  )
end

return {
  { "ui.composer", test_bar },
  { "ui.meter", test_meter },
}
