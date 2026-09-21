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

  bridge.ensure, bridge.request = old_ensure, old_request
  config.setup {}
end

return {
  { "voice", test_voice },
}
