--- Dictation: the half of it that runs in Neovim.
---
--- Nothing here opens a microphone. What is worth pinning is the wire format
--- and the bookkeeping around it, because both are the kind of thing that
--- fails silently -- a chunk split down the middle of a sample is rejected by
--- the daemon with a message you will never see, and an off-by-one in `seq`
--- loses audio rather than erroring.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_voice()
  local voice = require "paseo.voice"
  local bridge = require "paseo.bridge"
  local config = require "paseo.config"

  truthy("voice: the module loads", (pcall(require, "paseo.voice")))

  -- An explicit recorder wins outright, and is taken as a full argv: a machine
  -- with two sound cards has to be able to say which.
  config.setup { voice = { recorder = { "my-rec", "--device", "hw:1" } } }
  local recorder = voice.recorder()
  eq("voice: a configured recorder is used verbatim", recorder.cmd, {
    "my-rec",
    "--device",
    "hw:1",
  })

  -- Otherwise one is found, and NOT having one is a sentence rather than a
  -- silent no-op: the failure mode is a key that appears to do nothing.
  config.setup { voice = { rate = 24000 } }
  local found, why = voice.recorder()
  truthy("voice: a recorder is found, or refused with a reason", (found or why) ~= nil)
  if found then
    truthy(
      "voice: and it is asked for the configured rate",
      vim.tbl_contains(found.cmd, "24000"),
      table.concat(found.cmd, " ")
    )
    truthy(
      "voice: as raw PCM16, never a container",
      table.concat(found.cmd, " "):find("s16", 1, true) ~= nil
        or table.concat(found.cmd, " "):find("S16", 1, true) ~= nil,
      table.concat(found.cmd, " ")
    )
  end

  -- The stream, driven by hand: `start` is stubbed at the bridge, so the only
  -- thing missing is the process, and `recording()` reports what the module
  -- believes rather than what the microphone is doing.
  config.setup {}
  local old_ensure, old_request = bridge.ensure, bridge.request
  local sent = {}
  bridge.ensure = function(fn)
    fn(nil)
  end
  bridge.request = function(op, args, callback)
    sent[#sent + 1] = { op = op, args = args }
    if op == "dictation.finish" and callback then
      callback(nil, { text = "hello there" })
    elseif callback then
      callback(nil, {})
    end
  end

  eq("voice: nothing is recording to begin with", voice.recording(), false)

  -- `finish` with nothing open is a no-op, not an error: the key is a toggle
  -- and a double tap must not raise.
  voice.finish(function() end)
  eq("voice: finishing nothing asks the daemon nothing", #sent, 0)
  voice.cancel()
  eq("voice: and neither does cancelling nothing", #sent, 0)

  -- The format string is what the daemon parses the sample rate out of, with
  -- `rate\s*=\s*(\d+)`. Spelling it any other way loses the rate silently and
  -- the audio is transcribed at the wrong speed.
  --
  -- `true` as the recorder: a real process, so the spawn path is genuinely
  -- exercised, that produces no audio and exits at once. Nothing here should
  -- open a microphone on a machine running the suite.
  config.setup { voice = { rate = 16000, recorder = { "true" } } }
  local failed
  voice.start({}, function(err)
    failed = err
  end)
  vim.wait(1000, function()
    return voice.recording() or failed ~= nil
  end)
  eq("voice: the stream starts without complaint", failed, nil)
  truthy("voice: and the module knows it is recording", voice.recording())
  local start = sent[1]
  eq("voice: a stream is opened before the microphone is", start and start.op, "dictation.start")
  eq(
    "voice: at a format the daemon can parse the rate out of",
    start and start.args.format,
    "pcm16;rate=16000"
  )
  truthy("voice: with an id of its own", (start and start.args.dictationId or ""):find "nvim%-")

  voice.cancel()
  eq("voice: cancelling tells the daemon to forget it", sent[#sent].op, "dictation.cancel")
  eq("voice: and nothing is left recording", voice.recording(), false)

  -- CHUNKS ARE NUMBERED FROM ZERO. This is the bug that made dictation from
  -- this editor fail against a daemon whose own app dictates fine: the daemon
  -- acks the stream with `ackSeq = -1` and reassembles by sequence, so a first
  -- chunk numbered 1 leaves a hole at 0 that never fills. Nothing is ever
  -- transcribed and `dictation.finish` gives up with "Timed out waiting for
  -- final transcription" -- verified against a live daemon, which returns the
  -- transcript for the same audio the moment the numbering starts at 0.
  --
  -- Driven through `flush` rather than through a microphone: the numbering is
  -- the thing under test, and nothing in the suite may open an input device.
  sent = {}
  voice.start({}, function() end)
  vim.wait(1000, function()
    return voice.recording()
  end)
  voice._feed(("\0\1"):rep(40 * 1024))
  local chunks = {}
  for _, message in ipairs(sent) do
    if message.op == "dictation.chunk" then
      chunks[#chunks + 1] = message.args.seq
    end
  end
  truthy("voice: audio reaches the daemon in chunks", #chunks > 0, vim.inspect(chunks))
  eq("voice: and the first of them is seq 0, never 1", chunks[1], 0)

  voice.finish(function() end)
  vim.wait(1000, function()
    return not voice.recording()
  end)
  -- Recollected: `finish` flushes the tail, so the last chunk on the wire is
  -- sent by the finish itself.
  local final, all = nil, {}
  for _, message in ipairs(sent) do
    if message.op == "dictation.chunk" then
      all[#all + 1] = message.args.seq
    elseif message.op == "dictation.finish" then
      final = message.args.finalSeq
    end
  end
  -- The LAST seq sent, which with 0-based numbering is one less than the
  -- count. Off by one here and the daemon waits for a chunk that never comes.
  eq("voice: and the finish names the last chunk, not the count", final, all[#all])
  local contiguous = true
  for i, seq in ipairs(all) do
    contiguous = contiguous and seq == i - 1
  end
  truthy("voice: with no gap in the numbering", contiguous, vim.inspect(all))

  -- THE METER IS UNSCALED RMS ABOUT THE MEAN -- see `paseo.voice`. Silence is
  -- silence on any microphone; how loud a quiet ROOM reads is a property of
  -- the microphone, which is why the scaling lives with the history in
  -- |paseo.ui.composer| and not here.
  local silence = voice._level_of(("\0\0"):rep(800))
  eq("voice: digital silence reads as nothing", silence, 0)
  -- Alternating +8192/-8192 as bytes: a loud square wave.
  local loud = voice._level_of(("\0\32\0\224"):rep(400))
  truthy("voice: and a loud signal reads as loud", loud > 0.2, loud)
  truthy("voice: never over one", loud <= 1, loud)
  eq("voice: an empty read is not an error", voice._level_of "", 0)

  -- OPENING THE MICROPHONE IS A STATE, not an instant. Two round trips stand
  -- between the key and the first sample -- the sidecar, then the daemon
  -- accepting the stream, which on a cold one is where the speech models load
  -- -- and none of it used to be visible: the key looked dead, the obvious
  -- response was to press it again, and what you typed in the meantime was
  -- still in the box when the transcript landed on top of it.
  --
  -- Held open here rather than timed, so the assertions are about the sequence
  -- and not about how fast this machine is.
  local release
  bridge.request = function(op, args, callback)
    sent[#sent + 1] = { op = op, args = args }
    if op == "dictation.start" then
      release = function(err)
        callback(err)
      end
    elseif op == "dictation.finish" and callback then
      callback(nil, { text = "hello there" })
    elseif callback then
      callback(nil, {})
    end
  end

  config.setup { voice = { recorder = { "sleep", "60" } } }
  sent = {}
  local states = {}
  voice.start {
    on_state = function(state)
      states[#states + 1] = state
    end,
  }
  eq("voice: the wait is announced before anything can block", states, { "starting" })
  truthy("voice: and the module knows it is starting", voice.starting())
  eq("voice: which is not yet recording", voice.recording(), false)
  truthy("voice: though it is busy either way", voice.busy())

  release(nil)
  vim.wait(1000, function()
    return voice.recording()
  end)
  eq("voice: and listening is only said once there is a microphone", states, {
    "starting",
    "listening",
  })
  eq("voice: which ends the wait", voice.starting(), false)
  voice.cancel()

  -- A START THAT FAILS TAKES THE WAIT DOWN WITH IT. The composer shuts the box
  -- on `starting` and reopens it on anything else, so a failure that forgot to
  -- say so would leave you with a box that will not take keys and nothing on
  -- screen explaining why.
  sent, states = {}, {}
  local failure
  voice.start({
    on_state = function(state)
      states[#states + 1] = state
    end,
  }, function(err)
    failure = err
  end)
  release "speech models are not downloaded"
  vim.wait(1000, function()
    return failure ~= nil
  end)
  eq(
    "voice: a refused stream is reported in the daemon's own words",
    failure,
    "speech models are not downloaded"
  )
  eq("voice: and the wait comes down with it", states, { "starting", false })
  eq("voice: leaving nothing busy", voice.busy(), false)

  -- PRESSING THE KEY AGAIN WHILE IT OPENS IS A CHANGE OF MIND. It used to be a
  -- second START: the guard refused it as "already recording" over a bar that
  -- did not say anything was recording, so the key you pressed to stop waiting
  -- put an error on the screen instead.
  sent, states = {}, {}
  voice.toggle {
    insert = function() end,
    on_state = function(state)
      states[#states + 1] = state
    end,
  }
  truthy("voice: a press opens the microphone", voice.starting())
  voice.toggle {
    insert = function() end,
    on_state = function(state)
      states[#states + 1] = state
    end,
  }
  eq("voice: a second press while it opens gives up on it", voice.busy(), false)
  eq("voice: and says so", states, { "starting", false })
  eq("voice: telling the daemon to forget the stream", sent[#sent].op, "dictation.cancel")
  -- The reply the daemon was always going to send, arriving after nobody is
  -- listening for it any more. It must not start a microphone.
  release(nil)
  vim.wait(200, function()
    return voice.recording()
  end)
  eq("voice: and a reply that lands afterwards starts nothing", voice.recording(), false)

  -- A BIAS IS NOT A SOUND, and this is the bug that made the waveform a flat
  -- line rather than a meter. A microphone is not obliged to centre its
  -- samples on zero -- the default source on the machine this was fixed on
  -- sits at a constant +5642, a sixth of full scale -- and RMS taken about
  -- zero reports that bias instead of the sound riding on it. The room read
  -- 0.1693 to 0.1776 across eleven seconds, four tenths of a decibel of swing,
  -- against a gate of several; and speech could not rescue it either, because
  -- energy adds in quadrature and an ordinary voice over that bias moves the
  -- total by a third of a decibel. Measured about the mean, the same silence
  -- swings ten and a half.
  ---@param dc integer  Sample value everything is offset by.
  ---@param amplitude integer  Zero for a dead-steady line.
  ---@return string
  local function biased(dc, amplitude)
    local out = {}
    for i = 1, 800 do
      local sample = dc + (i % 2 == 0 and amplitude or -amplitude)
      if sample < 0 then
        sample = sample + 65536
      end
      out[#out + 1] = string.char(sample % 256, math.floor(sample / 256) % 256)
    end
    return table.concat(out)
  end

  eq(
    "voice: a steady bias with no sound on it reads as nothing",
    voice._level_of(biased(5642, 0)),
    0
  )
  local biased_quiet = voice._level_of(biased(5642, 256))
  local centred_quiet = voice._level_of(biased(0, 256))
  truthy(
    "voice: and the same quiet sound reads the same whether it is biased or not",
    math.abs(biased_quiet - centred_quiet) < 1e-9,
    ("%s vs %s"):format(biased_quiet, centred_quiet)
  )
  truthy(
    "voice: which a meter about zero could not say",
    voice._level_of(biased(5642, 0)) < biased_quiet,
    biased_quiet
  )

  bridge.ensure, bridge.request = old_ensure, old_request
  config.setup {}
end

return {
  { "voice", test_voice },
}
