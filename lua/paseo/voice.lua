--- Dictation: speak into the composer.
---
--- NEOVIM CANNOT RECORD AUDIO, so this shells out. That is the whole reason
--- this file exists and it is not a workaround for something -- there is no
--- microphone API to reach for, and the alternative is not having the feature.
---
--- What the daemon wants is RAW PCM16, mono, base64, with the sample rate in
--- the format string. Not a container -- no wav header, no webm, no opus -- so
--- every recorder below is asked for headerless little-endian signed 16-bit,
--- which all three can produce, and nothing has to parse anything.
---
--- Chunked rather than recorded-then-sent, because the daemon transcribes as
--- it goes: by the time you stop talking most of the work is done, and the
--- text comes back in about as long as it takes to lift your finger. A
--- record-to-a-file-then-upload version would be simpler and would feel like
--- waiting.

local bridge = require "paseo.bridge"

local M = {}

---Send at about this size. 32KB of 16kHz mono PCM16 is a second of audio --
---frequent enough that the daemon is never idle, large enough that a long
---dictation is not thousands of round trips.
local CHUNK_BYTES = 32 * 1024

---The recorders worth trying, best first.
---
---`arecord` is ALSA and is on essentially every Linux box with sound.
---`sox`/`rec` and `ffmpeg` are the portable fallbacks -- `ffmpeg` is asked for
---PulseAudio on Linux and `avfoundation` on macOS, since there is no one input
---backend that works on both.
---@param rate integer
---@return { name: string, cmd: string[] }[]
local function candidates(rate)
  local out = {
    {
      name = "arecord",
      cmd = { "arecord", "-q", "-f", "S16_LE", "-c", "1", "-r", tostring(rate), "-t", "raw" },
    },
    {
      name = "rec",
      cmd = {
        "rec",
        "-q",
        "-b",
        "16",
        "-e",
        "signed-integer",
        "-c",
        "1",
        "-r",
        tostring(rate),
        "-t",
        "raw",
        "-",
      },
    },
  }
  if vim.fn.has "mac" == 1 then
    out[#out + 1] = {
      name = "ffmpeg",
      cmd = {
        "ffmpeg",
        "-loglevel",
        "quiet",
        "-f",
        "avfoundation",
        "-i",
        ":0",
        "-ac",
        "1",
        "-ar",
        tostring(rate),
        "-f",
        "s16le",
        "-",
      },
    }
  else
    out[#out + 1] = {
      name = "ffmpeg",
      cmd = {
        "ffmpeg",
        "-loglevel",
        "quiet",
        "-f",
        "pulse",
        "-i",
        "default",
        "-ac",
        "1",
        "-ar",
        tostring(rate),
        "-f",
        "s16le",
        "-",
      },
    }
  end
  return out
end

---The recorder this machine has, or nil with the reason.
---
---`config.voice.recorder` overrides it entirely -- a list of arguments, so a
---machine with two sound cards can say which. It still has to produce raw
---PCM16 mono at `voice.rate` on stdout; nothing here checks that, because
---nothing can.
---@return { name: string, cmd: string[] }|nil, string|nil
function M.recorder()
  local voice = require("paseo.config").get().voice or {}
  local rate = math.floor(voice.rate or 16000)

  if type(voice.recorder) == "table" and #voice.recorder > 0 then
    return { name = voice.recorder[1], cmd = vim.deepcopy(voice.recorder) }, nil
  end

  local tried = {}
  for _, option in ipairs(candidates(rate)) do
    if vim.fn.executable(option.cmd[1]) == 1 then
      return option, nil
    end
    tried[#tried + 1] = option.cmd[1]
  end
  return nil,
    ("no recorder found (tried %s) -- install one, or set voice.recorder"):format(
      table.concat(tried, ", ")
    )
end

---@alias paseo.VoiceState "starting"|"listening"|false

---@type { id: string, proc: vim.SystemObj, seq: integer, held: string, format: string,
---        on_state: fun(state: paseo.VoiceState)|nil, on_level: fun(level: number)|nil,
---        finishing: boolean, stderr: string }|nil
local live

---Opening the microphone, which is NOT instant and is not always quick.
---
---Two round trips stand between the key and the first sample: the sidecar has
---to be running and connected, and then the daemon has to accept the stream --
---which on a cold daemon is where the speech models are loaded, and is seconds
---rather than milliseconds. None of that used to be visible. The key looked
---dead, the obvious response was to press it again, and anything typed in the
---meantime was still in the box when the transcript landed on top of it.
---
---So it is a state of its own, with a spinner of its own on the bar and the
---composer locked while it lasts -- see |paseo.ui.composer| -- and a second
---press of the key is a change of mind rather than a second microphone.
---@type { id: string, cancelled: boolean, on_state: fun(state: paseo.VoiceState)|nil }|nil
local starting

---How loud the last few hundred samples were, as 0..1.
---
---THIS IS WHAT THE VISUALISER DRAWS, and it is computed here rather than in the
---UI because this is the only place the audio exists -- the bytes are handed
---to `vim.base64.encode` and forgotten a line later.
---
---MEASURED ABOUT THE SIGNAL'S OWN MEAN, and that is the whole of why the
---meter used to be a flat line. A microphone is not obliged to hand you a
---waveform centred on zero: the default source on the machine this was fixed
---on sits at a constant +5642, a sixth of full scale, and the AC signal rides
---on top of that. Plain RMS about zero therefore reports the BIAS and not the
---sound -- 0.1693 to 0.1776 across eleven seconds of an empty room, four
---tenths of a decibel of swing, on a meter whose gate is two and a half --
---and speech cannot rescue it either, because energy adds in quadrature:
---an ordinary voice at 0.05 over a 0.172 bias moves the total by 0.35 dB.
---The same eleven seconds measured about the mean swing 10.5 dB. So the mean
---of each chunk comes out first -- the meter is AC-coupled, in other words --
---and what is left is the sound.
---
---EVERY SAMPLE, not one in eight. Decimating is what the first version did,
---on the grounds that 16,000 `string.byte` calls a second is a lot for a
---readout whose whole job is to twitch. It is not: measured, the whole chunk
---costs 1.7us against 0.2us, which at twenty chunks a second is three
---hundredths of one per cent of a core either way. And it is not free --
---sampling every eighth one is sampling at 1kHz, so anything at a multiple of
---1kHz aliases to a constant and reads as silence. That band is the middle of
---a human voice.
---
---RMS rather than peak. A peak meter is pinned by one click of the desk and
---reads the same for a whisper as for a sentence; RMS is the one that tracks
---your voice.
---
---UNSCALED past that. There is no useful constant to scale it BY -- a headset
---an inch from your mouth and a laptop across the desk differ by a factor of
---fifty -- so what a bar has to show is the difference between the room and
---your voice, and only something watching the last few seconds can know where
---that line is. The scaling lives with the history, in |paseo.ui.composer|,
---and this reports what it heard.
---@param pcm string  Raw little-endian signed 16-bit mono.
---@return number  RMS about the mean, 0..1. Silence is near zero on any
---        microphone, however far from zero its samples sit.
local function level_of(pcm)
  local n = #pcm
  if n < 2 then
    return 0
  end

  local sum, squares, count = 0, 0, 0
  for i = 1, n - 1, 2 do
    local lo, hi = pcm:byte(i, i + 1)
    if not hi then
      break
    end
    local sample = lo + hi * 256
    if sample >= 32768 then
      sample = sample - 65536
    end
    local scaled = sample / 32768
    sum = sum + scaled
    squares = squares + scaled * scaled
    count = count + 1
  end
  if count == 0 then
    return 0
  end

  -- Variance as the mean of the squares less the square of the mean: the DC
  -- component is exactly the mean, so subtracting it here is subtracting the
  -- bias, in one pass rather than two. Clamped at zero because floating point
  -- can land a hair below it on a chunk that really is constant.
  local mean = sum / count
  local variance = math.max(0, squares / count - mean * mean)
  return math.min(1, math.sqrt(variance))
end

---Exposed for the suite: the meter is the feature, so it is worth asserting
---that silence reads as silence and a loud tone does not.
M._level_of = level_of

---@return boolean
function M.recording()
  return live ~= nil
end

---The microphone has been asked for and has not opened yet.
---@return boolean
function M.starting()
  return starting ~= nil
end

---Either: the key is busy and nothing else may drive it.
---@return boolean
function M.busy()
  return live ~= nil or starting ~= nil
end

---Stop the recorder, keeping whatever it has already given us.
---@param session table
local function kill(session)
  if session.proc then
    pcall(function()
      session.proc:kill "sigterm"
    end)
    session.proc = nil
  end
end

---@param session table
---@param force? boolean  Send a short tail rather than holding it back.
local function flush(session, force)
  while #session.held >= CHUNK_BYTES or (force and #session.held > 0) do
    local take = math.min(#session.held, CHUNK_BYTES)
    -- PCM16 is two bytes a sample, and a chunk split down the middle of one
    -- is rejected outright: "PCM16 chunk byteLength must be even".
    if take % 2 == 1 then
      take = take - 1
    end
    if take == 0 then
      return
    end
    local audio = session.held:sub(1, take)
    session.held = session.held:sub(take + 1)
    -- CHUNKS ARE NUMBERED FROM ZERO, and that is not a detail. The daemon
    -- acknowledges the stream itself with `ackSeq = -1` and then reassembles
    -- the audio by sequence, so a first chunk numbered 1 leaves a hole at 0
    -- that never fills: every chunk is held in the reorder buffer, nothing is
    -- ever transcribed, and `dictation.finish` sits there until it gives up
    -- with "Timed out waiting for final transcription". Which is exactly what
    -- dictation from this editor did, on a daemon whose own app dictates fine.
    session.seq = session.seq + 1
    bridge.request("dictation.chunk", {
      dictationId = session.id,
      seq = session.seq,
      audio = vim.base64.encode(audio),
      format = session.format,
    })
  end
end

---Push audio into the live stream as the recorder's own stdout would.
---
---A test seam, and it earns its place: the chunking and the numbering are the
---half of this file that fails silently -- a chunk split down the middle of a
---sample is refused by the daemon with a message nobody sees, and a first
---chunk numbered 1 is transcribed as nothing at all -- and the only other way
---to exercise either is to open a microphone, which no suite may do.
---@param pcm string
function M._feed(pcm)
  if not live then
    return
  end
  live.held = live.held .. pcm
  flush(live, false)
end

---Stop recording and hand the text back.
---@param on_text fun(text: string|nil, err: string|nil)
function M.finish(on_text)
  local session = live
  if not session or session.finishing then
    return
  end
  session.finishing = true
  kill(session)
  flush(session, true)

  bridge.request("dictation.finish", {
    dictationId = session.id,
    finalSeq = session.seq,
  }, function(err, result)
    live = nil
    if session.on_state then
      vim.schedule(function()
        session.on_state(false)
      end)
    end
    vim.schedule(function()
      on_text(result and result.text or nil, err)
    end)
  end)
end

---Throw the recording away. Nothing is transcribed and nothing is inserted.
---
---Also the way out of a start that has not finished starting -- which is a
---real thing to want, because that is the state that can take seconds, and it
---is the state you are in when you decide you did not mean to press the key.
---The daemon is told to forget the stream either way: `dictation.start` may
---already have been accepted, and a stream nobody ever sends a chunk to is a
---stream the daemon holds open waiting.
function M.cancel()
  local pending = starting
  if pending then
    -- Flagged as well as dropped: the callbacks still in flight hold their own
    -- reference to it and check this before doing anything at all.
    pending.cancelled = true
    starting = nil
    bridge.request("dictation.cancel", { dictationId = pending.id })
    if pending.on_state then
      pending.on_state(false)
    end
    return
  end

  local session = live
  if not session then
    return
  end
  live = nil
  kill(session)
  bridge.request("dictation.cancel", { dictationId = session.id })
  if session.on_state then
    session.on_state(false)
  end
end

---Start recording.
---
---`on_state` is called with `"starting"` straight away and with `"listening"`
---once the daemon has accepted the stream AND the recorder is running -- not
---when the key was pressed. A recording indicator that appears before the
---daemon has agreed to listen is an indicator that lies for as long as it
---takes to find out the speech models are not installed, and that is why the
---two are different states rather than one: the wait is real, so it is shown
---as a wait, and `"listening"` keeps meaning what it says.
---
---Every way out of here ends in `on_state(false)`. That is the whole contract
---the composer relies on to unlock the box it locked -- a start that fails
---silently would leave it locked with nothing on screen saying why.
---@param opts? { on_state?: fun(state: paseo.VoiceState), on_level?: fun(level: number) }
---@param on_error? fun(err: string)
function M.start(opts, on_error)
  opts = opts or {}
  on_error = on_error or function(err)
    vim.notify("paseo: " .. err, vim.log.levels.ERROR)
  end

  if M.busy() then
    return on_error "already recording"
  end

  local recorder, why = M.recorder()
  if not recorder then
    return on_error(why or "no recorder")
  end

  local voice = require("paseo.config").get().voice or {}
  local rate = math.floor(voice.rate or 16000)
  local session = {
    id = ("nvim-%d-%d"):format(vim.uv.os_getpid(), math.floor(vim.uv.hrtime() / 1e6)),
    -- The seq of the LAST chunk sent, and -1 is "none yet" -- the number the
    -- daemon acks the stream itself with. `flush` increments before it sends,
    -- so the first chunk on the wire is 0, which is the one the daemon waits
    -- for. See the note there.
    seq = -1,
    held = "",
    format = ("pcm16;rate=%d"):format(rate),
    on_state = opts.on_state,
    on_level = opts.on_level,
    finishing = false,
    -- The recorder's complaint, kept for the message we make out of its exit.
    stderr = "",
  }

  -- UP FIRST, before anything that can block. Everything below is a round trip
  -- to something that may not be running yet, and the point of the state is
  -- that it covers those round trips.
  local pending = { id = session.id, cancelled = false, on_state = opts.on_state }
  starting = pending
  if opts.on_state then
    opts.on_state "starting"
  end

  ---The start is over, one way or another.
  local function settle()
    if starting == pending then
      starting = nil
    end
  end

  ---@param err string
  local function fail(err)
    settle()
    if opts.on_state then
      opts.on_state(false)
    end
    on_error(err)
  end

  bridge.ensure(function(err)
    if pending.cancelled then
      return
    end
    if err then
      return vim.schedule(function()
        fail(err)
      end)
    end

    bridge.request("dictation.start", {
      dictationId = session.id,
      format = session.format,
    }, function(start_err)
      if pending.cancelled then
        return
      end
      if start_err then
        return vim.schedule(function()
          -- The daemon's own sentence, not ours: "speech models are not
          -- downloaded" is an answer, and "dictation failed" is not.
          fail(start_err)
        end)
      end

      vim.schedule(function()
        -- Given up on while the start was in flight. `cancel` has already told
        -- the daemon to forget the stream and taken the indicator down.
        if pending.cancelled then
          return
        end
        local ok, proc = pcall(vim.system, recorder.cmd, {
          -- `text = false`: this is audio. Decoding it as UTF-8 would corrupt
          -- every sample that happens not to be valid UTF-8, which is most.
          text = false,
          stdout = function(stream_err, data)
            if stream_err or not data then
              return
            end
            if live ~= session then
              return
            end
            session.held = session.held .. data
            flush(session, false)
            -- The meter, off the SAME bytes, before they are encoded and
            -- dropped. `ffmpeg` hands over 50ms at a time, so this fires about
            -- twenty times a second -- which is the visualiser's frame rate,
            -- and why it has no timer of its own.
            if session.on_level then
              local level = level_of(data)
              vim.schedule(function()
                if live == session then
                  session.on_level(level)
                end
              end)
            end
          end,
          -- KEPT, not discarded. It is the only thing that can say why the
          -- recorder would not start -- "Device or resource busy", say -- and
          -- the exit handler below is what puts it in front of you.
          stderr = function(_, chunk)
            if chunk and session.stderr then
              session.stderr = (session.stderr .. chunk):sub(-400)
            end
          end,
        }, function(obj)
          -- THE RECORDER DIED ON ITS OWN. Until this existed that was silent:
          -- the indicator stayed lit, no audio was ever sent, and the key
          -- appeared to have stopped working. A microphone that is busy, or
          -- missing, or refused by the portal is the ordinary way in.
          vim.schedule(function()
            if live ~= session or session.finishing then
              return
            end
            local detail = vim.trim((session.stderr or ""):gsub("%s+", " "))
            M.cancel()
            on_error(
              ("%s stopped recording (exit %s)%s"):format(
                recorder.name,
                tostring(obj.code),
                detail ~= "" and (": " .. detail) or ""
              )
            )
          end)
        end)
        if not ok then
          bridge.request("dictation.cancel", { dictationId = session.id })
          return fail(("could not start %s: %s"):format(recorder.name, tostring(proc)))
        end
        session.proc = proc
        live = session
        settle()
        if opts.on_state then
          opts.on_state "listening"
        end
      end)
    end)
  end)
end

---`<C-t>`: start, or stop and insert what was said.
---
---Three states, not two. A press while the microphone is still coming up is a
---change of mind -- the one thing it must not be is a SECOND start, which is
---what it was when the only question asked here was `recording()`: the guard
---in `start` refused it, the refusal was notified as "already recording" over
---a bar that did not yet say anything was recording, and the key you pressed
---to stop the wait instead put an error on the screen.
---@param opts { insert: fun(text: string), on_state?: fun(state: paseo.VoiceState), on_level?: fun(level: number) }
function M.toggle(opts)
  if M.starting() then
    return M.cancel()
  end
  if M.recording() then
    return M.finish(function(text, err)
      if err then
        return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      end
      if not text or vim.trim(text) == "" then
        return vim.notify("paseo: nothing was heard", vim.log.levels.WARN)
      end
      opts.insert(text)
    end)
  end
  M.start { on_state = opts.on_state, on_level = opts.on_level }
end

return M
