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

local function test_meter()
  local composer = require "paseo.ui.composer"
  local widgets = require "paseo.ui.widgets"
  local chat = fresh()

  -- THE ROOM IS NOT SILENT. This microphone reads 0.17 RMS with nobody in the
  -- room -- measured -- so a meter with any fixed gain either pins at full
  -- before you speak or never moves at all. It tracks the room instead: a
  -- steady reading, however loud, settles to nothing.
  for _ = 1, 40 do
    composer.push_level(chat, 0.17)
  end
  local room = chat.voice_levels[#chat.voice_levels]
  truthy("composer: a steady room reads as silence whatever its level", room < 0.1, room)

  -- And speaking over it moves immediately.
  composer.push_level(chat, 0.45)
  local speech = chat.voice_levels[#chat.voice_levels]
  truthy("composer: speaking over it fills the bar", speech > 0.5, speech)

  -- AT EVERY SCALE. This is the one that matters and the one that was wrong:
  -- the gate was an absolute 0.02 RMS and the floor crept up by a fixed
  -- 0.0008 a reading, which is nothing against a room that reads 0.17 and is
  -- the entire signal on a microphone whose speech reads 0.03. On those, the
  -- meter either never moved or flattened out halfway through the sentence --
  -- "the waveform doesn't come when I am speaking", on a dictation that was
  -- otherwise working.
  -- `least` is what the wave has to be worth at its quietest, as a fraction:
  -- an ordinary voice has to FILL it, and a soft one over a noisy room only
  -- has to be visibly more than nothing -- two glyphs of eight, which is the
  -- difference between "it can hear you" and a flat line.
  for _, mic in ipairs {
    { name = "a loud laptop mic", room = 0.17, voice = 0.40, least = 0.6 },
    { name = "a soft voice on one", room = 0.17, voice = 0.24, least = 0.15 },
    { name = "a quiet headset", room = 0.002, voice = 0.03, least = 0.9 },
    { name = "a very quiet input", room = 0.0004, voice = 0.006, least = 0.9 },
  } do
    local mic_chat = {}
    for _ = 1, 40 do
      composer.push_level(mic_chat, mic.room)
    end
    local quiet = mic_chat.voice_levels[#mic_chat.voice_levels]
    -- Four seconds of it, because the failure was a wave that DIED while you
    -- were still talking rather than one that never started.
    local lowest = 1
    for _ = 1, 80 do
      composer.push_level(mic_chat, mic.voice)
      lowest = math.min(lowest, mic_chat.voice_levels[#mic_chat.voice_levels])
    end
    truthy(("composer: %s reads as silent when the room is"):format(mic.name), quiet < 0.1, quiet)
    truthy(
      ("composer: and %s still reads as speech four seconds in"):format(mic.name),
      lowest >= mic.least,
      lowest
    )
  end

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
