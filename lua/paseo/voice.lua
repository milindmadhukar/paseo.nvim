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

---@type { id: string, proc: vim.SystemObj, seq: integer, held: string, format: string,
---        on_state: fun(recording: boolean)|nil, on_level: fun(level: number)|nil,
---        finishing: boolean, stderr: string }|nil
local live

---How loud the last few hundred samples were, as 0..1.
---
---THIS IS WHAT THE VISUALISER DRAWS, and it is computed here rather than in the
---UI because this is the only place the audio exists -- the bytes are handed
---to `vim.base64.encode` and forgotten a line later.
---
---Decimated: `step` takes every eighth sample, which at 16kHz is still 2kHz of
---envelope and is plenty for a bar that moves twenty times a second. Reading
---all 800 samples of every chunk would be 16,000 `string.byte` calls a second
---for a readout whose whole job is to twitch.
---
---RMS rather than peak. A peak meter is pinned by one click of the desk and
---reads the same for a whisper as for a sentence; RMS is the one that tracks
---your voice.
---
---RAW, and deliberately not scaled to anything. There is no useful constant to
---scale it BY: this laptop's microphone sits at 91% gain and reads 0.17 in a
---silent room, which any fixed gain that makes a quiet mic visible turns into
---a meter pinned at full before anyone has said a word -- measured, on the
---machine this was written on. What a bar has to show is the difference
---between the room and your voice, and only something watching the last few
---seconds can know where that line is. So the scaling lives with the history,
---in |paseo.ui.composer|, and this reports what it heard.
---@param pcm string  Raw little-endian signed 16-bit mono.
---@return number  RMS, 0..1. A quiet room is whatever this microphone's quiet
---        room is; it is not necessarily near zero.
local function level_of(pcm)
  local n = #pcm
  if n < 2 then
    return 0
  end

  local step = 16 -- every eighth sample: two bytes each
  local sum, count = 0, 0
  for i = 1, n - 1, step do
    local lo, hi = pcm:byte(i, i + 1)
    if not hi then
      break
    end
    local sample = lo + hi * 256
    if sample >= 32768 then
      sample = sample - 65536
    end
    local scaled = sample / 32768
    sum = sum + scaled * scaled
    count = count + 1
  end
  if count == 0 then
    return 0
  end

  return math.min(1, math.sqrt(sum / count))
end

---Exposed for the suite: the meter is the feature, so it is worth asserting
---that silence reads as silence and a loud tone does not.
M._level_of = level_of

---@return boolean
function M.recording()
  return live ~= nil
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
function M.cancel()
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
---`on_state` is called with `true` once the daemon has accepted the stream --
---NOT when the process starts. A recording indicator that appears before the
---daemon has agreed to listen is an indicator that lies for as long as it
---takes to find out the speech models are not installed.
---@param opts? { on_state?: fun(recording: boolean), on_level?: fun(level: number) }
---@param on_error? fun(err: string)
function M.start(opts, on_error)
  opts = opts or {}
  on_error = on_error or function(err)
    vim.notify("paseo: " .. err, vim.log.levels.ERROR)
  end

  if live then
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

  bridge.ensure(function(err)
    if err then
      return vim.schedule(function()
        on_error(err)
      end)
    end

    bridge.request("dictation.start", {
      dictationId = session.id,
      format = session.format,
    }, function(start_err)
      if start_err then
        return vim.schedule(function()
          -- The daemon's own sentence, not ours: "speech models are not
          -- downloaded" is an answer, and "dictation failed" is not.
          on_error(start_err)
        end)
      end

      vim.schedule(function()
        -- Raced by a cancel while the start was in flight.
        if live ~= nil then
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
          return on_error(("could not start %s: %s"):format(recorder.name, tostring(proc)))
        end
        session.proc = proc
        live = session
        if opts.on_state then
          opts.on_state(true)
        end
      end)
    end)
  end)
end

---`<C-t>`: start, or stop and insert what was said.
---@param opts { insert: fun(text: string), on_state?: fun(recording: boolean), on_level?: fun(level: number) }
function M.toggle(opts)
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
