--- The chat window: two buffers, a conversation and a composer.
---
--- This is the point of the plugin. Paseo's app is a fine UI; the whole reason
--- this exists is not to need it. So the composer is a real Neovim buffer --
--- your keymaps, your completion, your undo -- rather than a one-line
--- `vim.ui.input`, and the conversation is the agent's actual timeline, fetched
--- on open, so reopening a chat shows what was said before. The agent lives on
--- the daemon and outlives the editor; the window is just a view onto it.

local bridge = require "paseo.bridge"
local config = require "paseo.config"
local hosts = require "paseo.hosts"
local sidebar = require "paseo.ui.sidebar"
local transcript = require "paseo.ui.transcript"
local widgets = require "paseo.ui.widgets"

local M = {}

---@class paseo.Chat
---@field root string        Directory the agent works in.
---@field local_root string|nil Local counterpart, when the daemon is remote.
---@field host_id string
---@field agent_id string|nil
---@field provider string|nil
---@field conversation integer  bufnr
---@field composer integer      bufnr
---@field win_conversation integer|nil
---@field win_composer integer|nil
---@field streaming boolean
---@field spinner uv.uv_timer_t|nil  Ticking only while `streaming`.
---@field frame integer|nil     Set while a spinner timer is live. Not a frame
---                            index: the glyph is off the clock.
---@field since integer|nil     `vim.uv.now()` when the turn began.
---@field pending string[]   Context blocks queued for the next send.
---@field images paseo.Image[] Pasted images, in placeholder order.
---@field seq integer|nil    Highest timeline seq rendered.
---@field epoch string|nil   The epoch those seqs belong to.
---@field initialised boolean  Subscribed, history fetched, settings loaded.
---@field rendered_width integer|nil  Width the transcript is currently drawn at.
---@field resize_group integer|nil    Augroup holding the debounced resize watch.
---@field resize_pending boolean|nil  A redraw is already scheduled.
---@field last_turn_usage table|nil   Tokens and cost from the last completed turn.
---@field dictating paseo.VoiceState|nil  `"starting"` while the microphone is
---              being opened, `"listening"` once it is. Drawn on the header,
---              and `"starting"` also shuts the box -- see |paseo.ui.composer|.
---@field config_snapshot table|nil  Last `agent.config`; the Session panel draws it.
---@field available_modes table[]|nil  `{id, label}`, per provider. Ids to labels.
---@field answer_state table<string, table>|nil  Half-answered question sets, by
---                         request id. What makes dismissing the overlay with
---                         <Esc> and reopening it with `gp` resume rather than
---                         start again. See |paseo.ui.answer|.

---Chats are keyed by AGENT, falling back to the directory until the agent is
---known. A workspace can hold several agent sessions, so keying on the directory
---alone meant the second agent session took over the first one's window.
---@type table<string, paseo.Chat>
local chats = {}

---@type paseo.Chat|nil
local current

---Forward declaration: `initialise` is defined below but referenced by `open`.
local initialise

-- ------------------------------------------------------------------ buffers

---Repaint the header.
---
---The header itself lives in `ui/sidebar.lua`, and the native surface draws
---from the same builders, so the two surfaces cannot drift into disagreeing
---about which mode the agent session is in.
---@param chat paseo.Chat
local function set_winbar(chat)
  sidebar.refresh(chat)
end

---The human name for an id, out of a list of `{id, label}`.
---
---The header shows LABELS -- "Plan Mode", not "plan" -- and there are two
---routes into it, a pulled `agent.config` and a pushed `settings` event. The
---pushed one used to store the raw id, so the same agent session read "Plan Mode"
---or "plan" in the header depending on which had spoken last.
---@param entries table[]|nil
---@param id any
---@return string|nil
local function labelled(entries, id)
  if id == nil then
    return nil
  end
  for _, entry in ipairs(entries or {}) do
    if entry.id == id then
      return entry.label or entry.id
    end
  end
  return nil
end

---Fold a settings payload into a chat, and repaint.
---
---Also patches `config_snapshot`, which the Settings panel draws its `●` from.
---Leaving that stale meant the header could report a mode the panel below it
---still marked as something else.
---
---Public because the `settings` event is the ONLY route mode, model and
---thinking level take into this plugin -- the daemon suppresses them on the
---wire and the sidecar reconstructs them from the agent snapshot -- so what
---this does with one is worth being able to assert directly.
---@param chat paseo.Chat
---@param payload table
function M.apply_settings(chat, payload)
  local snapshot = chat.config_snapshot
  -- The Settings panel draws modes, thinking levels, models and features, and
  -- redrawing it rebuilds the whole panel. It is gated on a real CHANGE
  -- rather than on a field being present, because this payload arrives on
  -- every usage tick -- seven times in one short turn, measured -- and the
  -- mode is in all of them.
  local panel = false

  if payload.availableModes and #payload.availableModes > 0 then
    chat.available_modes = payload.availableModes
    if snapshot then
      snapshot.availableModes = payload.availableModes
    end
  end

  if payload.modeId ~= nil then
    local mode = labelled(payload.availableModes or chat.available_modes, payload.modeId)
      or payload.modeId
    panel = panel or chat.mode ~= mode
    chat.mode = mode
    if snapshot then
      snapshot.modeId = payload.modeId
    end
  end

  if payload.thinkingOptionId ~= nil then
    local thinking = labelled(snapshot and snapshot.thinkingOptions, payload.thinkingOptionId)
      or payload.thinkingOptionId
    panel = panel or chat.thinking ~= thinking
    chat.thinking = thinking
    if snapshot then
      snapshot.thinkingOptionId = payload.thinkingOptionId
    end
  end

  if payload.model then
    local provider = (payload.provider or (snapshot and snapshot.provider) or "?")
      .. "/"
      .. payload.model
    panel = panel or chat.provider ~= provider
    chat.provider = provider
    if snapshot then
      snapshot.model = payload.model
      snapshot.provider = payload.provider or snapshot.provider
    end
  end

  if payload.features then
    local features = {}
    for _, feature in ipairs(payload.features) do
      features[feature.id] = feature.value
    end
    panel = panel or not vim.deep_equal(chat.features, features)
    chat.features = features
    -- The header draws each enabled toggle by its label, so it needs the list
    -- and not just the id->value map.
    chat.feature_list = payload.features
    if snapshot then
      snapshot.features = payload.features
    end
  end

  if payload.usage then
    chat.usage = payload.usage
    if snapshot then
      snapshot.usage = payload.usage
    end
  end

  -- The pending list rides this payload now, and it is AUTHORITATIVE -- it is
  -- the daemon's own, it arrives on reconnect, and it is the only thing that
  -- reports a request cleared by an agent-session refresh or answered while the
  -- socket was down. Nil means the sidecar is older than this field; an empty
  -- table means "nothing is pending" and must still be acted on.
  if payload.pendingPermissions then
    if snapshot then
      snapshot.pendingPermissions = payload.pendingPermissions
    end
    require("paseo.ui.permission").reconcile(chat, payload.pendingPermissions)
  end

  set_winbar(chat)
  -- The panels draw from the snapshot above, and nothing else asks them to
  -- redraw. Cheap when none is up.
  if panel then
    pcall(function()
      require("paseo.ui.native").redraw_panels()
    end)
  end
end

-- ------------------------------------------------------------------ spinner

---@param chat paseo.Chat
local function stop_spinner(chat)
  if not chat.spinner then
    return
  end
  chat.spinner:stop()
  if not chat.spinner:is_closing() then
    chat.spinner:close()
  end
  chat.spinner = nil
  chat.frame = nil
end

---Working, and visibly so.
---
---The header used to say `●` and nothing else, so a turn that had been running
---for two minutes looked exactly like one that had died. The elapsed count is
---the other half of the answer: a spinner says "busy", `⠹ 14s` says "busy, and
---you have been waiting 14 seconds", which is the thing you actually wanted to
---know before reaching for the app.
---@param chat paseo.Chat
local function start_spinner(chat)
  if chat.spinner then
    return
  end
  chat.frame = 1
  chat.since = vim.uv.now()
  chat.spinner = vim.uv.new_timer()
  chat.spinner:start(
    0,
    100,
    vim.schedule_wrap(function()
      -- A timer outliving its turn is the leak that matters: it would redraw
      -- the header forever on a chat nobody is looking at.
      if not chat.streaming then
        return stop_spinner(chat)
      end
      -- No frame counter to advance: the glyph comes off the clock in
      -- `widgets.spinner`, so every surface drawing this same wait draws the
      -- same one and a repaint for some other reason does not shunt the
      -- animation forward a step. `chat.frame` survives as the flag saying a
      -- timer is live, which is all `M.progress` reads it for.
      set_winbar(chat)
    end)
  )
end

---The single place `streaming` changes, so the timer can never disagree with
---the flag it is following.
---
---Exposed because `ui/permission.lua` clears it too: the agent asking a
---question is not the agent working, and a spinner left up there blames it for
---a delay that is entirely yours.
---@param chat paseo.Chat
---@param on boolean
function M.set_streaming(chat, on)
  chat.streaming = on
  if on then
    start_spinner(chat)
  else
    stop_spinner(chat)
  end
  set_winbar(chat)
end

---The spinner frame and how long this turn has been running, for the header.
---@param chat paseo.Chat
---@return string|nil frame, integer|nil seconds
function M.progress(chat)
  if not (chat.streaming and chat.frame) then
    return nil, nil
  end
  return widgets.spinner(), math.floor((vim.uv.now() - (chat.since or vim.uv.now())) / 1000)
end

---A status line in the transcript -- "connecting…", "send failed: …".
---
---These used to be italic markdown written straight into the buffer. They are
---now ordinary timeline items, so they are highlighted like everything else and
---the buffer has exactly one writer.
---@param chat paseo.Chat
---@param message string
---@param level? "info"|"warning"|"error"
local function notice(chat, message, level)
  transcript.upsert(chat, { kind = "notice", level = level or "info", message = message })
end

-- ------------------------------------------------------------------ sending

---Interrupt the turn this chat's agent is running.
---
---What the app's stop button does and what `paseo agent stop` does: one
---`cancelAgent`. Nothing local is torn down, because nothing local is what is
---running -- the agent lives on the daemon, and the cancellation comes back
---as a `turn_canceled` on the timeline like any other turn outcome.
---
---A no-op when nothing is running, deliberately not an error. `<C-c>` is a key
---you hit reflexively, and telling you off for stopping something that had
---already stopped is noise.
---@param chat? paseo.Chat
function M.stop(chat)
  chat = chat or current
  if not (chat and chat.agent_id) then
    return
  end
  if not chat.streaming then
    return
  end

  bridge.request("agent.cancel", { agentId = chat.agent_id }, function(err)
    if err then
      vim.schedule(function()
        notice(chat, "stop failed: " .. err, "error")
      end)
    end
  end, chat.host_id)

  -- Optimistic, and it has to be: the header is the only thing that says a
  -- turn is running, and leaving the spinner going until the daemon gets round
  -- to saying so reads as the key not having worked. A `turn_*` event puts it
  -- right either way.
  M.set_streaming(chat, false)
  notice(chat, "stopped", "warning")
end

---Hand a prompt to the agent.
---@param chat paseo.Chat
---@param prompt string
---@param images table[]
---@param behavior? "steer"|"interrupt"  Only while a turn is running.
local function deliver(chat, prompt, images, behavior)
  M.set_streaming(chat, true)
  bridge.request("agent.send", {
    agentId = chat.agent_id,
    prompt = prompt,
    -- Absent rather than empty: an empty list is still a list on the wire, and
    -- the daemon should see a plain text message as a plain text message.
    images = #images > 0 and images or nil,
    activeTurnBehavior = behavior,
  }, function(err)
    if err then
      vim.schedule(function()
        M.set_streaming(chat, false)
        notice(chat, "send failed: " .. err, "error")
      end)
    end
  end, chat.host_id)
end

---What you have said to this agent, oldest first, as the transcript shows it.
---Read from the blocks rather than kept on the side, so prompts sent from the
---Paseo app or another client are recalled too.
---@param chat paseo.Chat
---@return string[]
function M.sent_prompts(chat)
  local out = {}
  for _, id in ipairs(chat.order or {}) do
    local block = chat.blocks[id]
    local text = block and block.item.kind == "user" and block.item.text
    if text and text ~= "" and out[#out] ~= text then
      out[#out + 1] = text
    end
  end
  return out
end

---What a send does while the agent is mid-turn. See |paseo-config.ui|'s
---`send_behavior`; `alternate` is the other key, which does the opposite --
---the app's long-press on Send.
---@param chat paseo.Chat
---@param alternate? boolean
---@return "steer"|"interrupt"|"queue"
function M.send_behavior(chat, alternate)
  local behavior = config.get().ui.send_behavior or "steer"
  if alternate then
    behavior = behavior == "queue" and "steer" or "queue"
  end
  -- A message queued behind a turn that is waiting on YOU never goes: the
  -- turn does not end until the permission is answered. The app interrupts
  -- instead, and so does this.
  if behavior == "queue" and #(chat.permissions or {}) > 0 then
    behavior = "interrupt"
  end
  return behavior
end

---Send whatever was queued behind the turn that just ended, as one message.
---@param chat paseo.Chat
function M.flush_queue(chat)
  local queued = chat.queued
  if not queued or #queued == 0 then
    return
  end
  chat.queued = nil
  local prompts, images = {}, {}
  for _, entry in ipairs(queued) do
    prompts[#prompts + 1] = entry.prompt
    vim.list_extend(images, entry.images)
  end
  set_winbar(chat)
  deliver(chat, table.concat(prompts, "\n\n"), images)
end

---@param chat paseo.Chat
---@param alternate? boolean  The other send key: see |M.send_behavior|.
local function send(chat, alternate)
  local body = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
  local text = vim.trim(table.concat(body, "\n"))

  if text == "" and #chat.pending == 0 and #chat.images == 0 then
    return
  end
  chat.recall = nil

  -- Context blocks queued by `attach` go BEFORE the prose, so the agent reads
  -- the code first and the question second.
  local parts = {}
  vim.list_extend(parts, chat.pending)
  if text ~= "" then
    parts[#parts + 1] = text
  end
  local prompt = table.concat(parts, "\n\n")

  -- Images travel BESIDE the text, never inside it. The prompt keeps the
  -- `[Image #1]` placeholders -- which you can read, renumber by hand, or
  -- delete -- and the bytes ride in the request's own field, in the order the
  -- placeholders count.
  local images = {}
  for _, image in ipairs(chat.images) do
    images[#images + 1] = { data = image.data, mimeType = image.mime }
  end

  -- The prompt is NOT echoed locally. It comes back on the timeline as a
  -- user_message, and rendering it here as well would print it twice -- while
  -- a prompt typed in the Paseo app would appear only once. The timeline is
  -- the single source of truth for what was said, whoever said it.
  vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, { "" })
  local attached = chat.images
  chat.pending = {}
  chat.images = {}
  -- The composer grew with the prompt, so it has to shrink back with it.
  -- Explicitly rather than through the autocmd: a `nvim_buf_set_lines` is not
  -- a user edit, and leaving it to `TextChanged` is how a four-line prompt
  -- leaves a four-line empty box behind after it is sent.
  M.fit_composer(chat)
  local was_streaming = chat.streaming
  M.set_streaming(chat, true)

  -- The first message of a draft STARTS the session: the agent, and a
  -- workspace named from this prompt, in one request. See `chat.draft`.
  if chat.draft and not chat.agent_id then
    local draft = chat.draft
    local settings = draft.settings

    ---A start that failed hands the words back: it must not eat the prompt.
    local function give_back(err)
      M.set_streaming(chat, false)
      vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, vim.split(prompt, "\n"))
      chat.images = attached
      M.fit_composer(chat)
      notice(chat, "could not start: " .. tostring(err), "error")
    end

    -- A draft that knows how to start itself -- a new WORKSPACE, whose first
    -- agent rides the request that creates it. See `M.draft`.
    if draft.start then
      notice(chat, "starting…")
      return draft.start(prompt, images, function(err, agent_id)
        vim.schedule(function()
          if err then
            return give_back(err)
          end
          -- An agent HERE binds to this chat; a new workspace has already
          -- pointed the editor at a chat of its own.
          if agent_id then
            draft.bind(agent_id)
          end
        end)
      end)
    end

    notice(chat, "starting…")
    return bridge.request("agent.start", {
      cwd = chat.root,
      project = draft.project,
      provider = settings.provider,
      modeId = settings.modeId,
      thinkingOptionId = settings.thinkingOptionId,
      featureValues = settings.featureValues,
      prompt = prompt,
      images = #images > 0 and images or nil,
    }, function(err, result)
      vim.schedule(function()
        if err or not (result and result.agentId) then
          return give_back(err or "no agent")
        end
        draft.bind(result.agentId)
      end)
    end, chat.host_id)
  end

  -- MID-TURN, the daemon's own default is to INTERRUPT -- so typing a
  -- follow-up while the agent worked used to stop it. The app steers by
  -- default; so does this, and `ui.send_behavior` says otherwise.
  if was_streaming then
    local behavior = M.send_behavior(chat, alternate)
    if behavior == "queue" then
      chat.queued = chat.queued or {}
      chat.queued[#chat.queued + 1] = { prompt = prompt, images = images }
      -- On the bar (`N queued`), not in the transcript: a notice is a block,
      -- and a block landing mid-stream splits the thought it lands in.
      set_winbar(chat)
      M.refresh(chat)
      return
    end
    return deliver(chat, prompt, images, behavior)
  end
  deliver(chat, prompt, images)
end

---Put text in the composer, at the cursor when that is where you are.
---
---The same rule the image placeholder follows: at the cursor when the composer
---is focused, appended when it is not -- dictating from a code buffer should
---not need the chat focused. Multi-line because a spoken paragraph comes back
---as one, and splitting it here is what keeps the composer a buffer rather
---than a field.
---@param chat paseo.Chat
---@param text string
function M.insert(chat, text)
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  local win = chat.win_composer

  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    vim.api.nvim_buf_set_text(chat.composer, row - 1, col, row - 1, col, lines)
    local last = #lines == 1 and (col + #lines[1]) or #lines[#lines]
    pcall(vim.api.nvim_win_set_cursor, win, { row + #lines - 1, last })
  else
    local existing = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
    local tail = existing[#existing] or ""
    existing[#existing] = tail == "" and lines[1] or (tail .. " " .. lines[1])
    for i = 2, #lines do
      existing[#existing + 1] = lines[i]
    end
    vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, existing)
  end

  M.fit_composer(chat)
end

-- ---------------------------------------------------------------- dictation

---`<Esc>` throws a recording away, while there is one.
---
---Bound only for as long as the microphone is open, and only in NORMAL mode.
---In insert mode `<Esc>` is how you leave insert, and taking that over to add
---a discard key would be the worst trade in this file; in normal mode it does
---nothing, which is exactly the key a discard wants.
---
---Bound while the microphone is still OPENING too, which is the state that can
---last seconds and is therefore the one you are most likely to want out of.
---The composer leaves insert mode for the length of that wait -- see
---|paseo.ui.composer| -- so the normal-mode binding is the one in force.
---@param chat paseo.Chat
---@param state paseo.VoiceState  Truthy for either half of a recording.
local function dictation_keys(chat, state)
  if not (chat.composer and vim.api.nvim_buf_is_valid(chat.composer)) then
    return
  end
  if state then
    vim.keymap.set("n", "<Esc>", function()
      require("paseo.voice").cancel()
    end, { buffer = chat.composer, nowait = true, desc = "paseo: discard the recording" })
  else
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = chat.composer })
  end
end

---The session list, from wherever you are.
---
---`<C-s>`'s one meaning: the sessions, which are the rail. On a native tab
---that is the rail beside you; from the sidebar it is the native surface,
---opened for this chat, with the cursor in its rail.
---@param chat paseo.Chat
function M.sessions(chat)
  local native = require "paseo.ui.native"
  if not native.is_open(chat) then
    sidebar.close(chat)
    native.open(chat)
  end
  return native.focus_rail()
end

-- ------------------------------------------------------------------- images

---Put an image in the composer.
---
---What lands in the BUFFER is a placeholder -- `[Image #1]` -- and not the
---bytes. The prompt stays something you can read and edit, you can see how
---many you attached, and the number is how a sentence refers to one of them:
---"why is the second panel empty" needs the images to be numbered.
---@param chat paseo.Chat
---@param image paseo.Image
local function attach_image(chat, image)
  chat.images[#chat.images + 1] = image
  local placeholder = ("[Image #%d]"):format(#chat.images)

  -- At the cursor when the composer is where you are, appended when it is not
  -- -- `:Paseo image` from a code buffer should not need the chat focused.
  local win = chat.win_composer
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    vim.api.nvim_buf_set_text(chat.composer, row - 1, col, row - 1, col, { placeholder })
    pcall(vim.api.nvim_win_set_cursor, win, { row, col + #placeholder })
  else
    local lines = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
    local tail = lines[#lines] or ""
    lines[#lines] = tail == "" and placeholder or (tail .. " " .. placeholder)
    vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, lines)
  end
  M.fit_composer(chat)

  vim.notify(
    ("paseo: %s attached (%s)"):format(placeholder, require("paseo.image").describe(image)),
    vim.log.levels.INFO
  )
end

---The image, or nil and a word about why not.
---
---Reading is separate from attaching because |M.paste_image| has to read
---BEFORE it opens a chat: a clipboard with no image in it should not leave a
---window behind as the side effect of finding that out.
---@param path? string  A file; the clipboard when absent.
---@param quiet? boolean  Say nothing when there is no image. Set by the keys
---                       that have an ordinary job to fall back to: `p` on a
---                       clipboard holding text must paste the text, not
---                       complain that it is not a picture.
---@return paseo.Image|nil
local function read_image(path, quiet)
  local source = require "paseo.image"
  local image, err
  if path then
    image, err = source.from_file(path)
  else
    image, err = source.from_clipboard()
  end
  if not image and not quiet then
    vim.notify("paseo: " .. (err or "no image"), vim.log.levels.WARN)
  end
  return image
end

-- ------------------------------------------------------------------- layout

---@param chat paseo.Chat
---Grow the composer to what is in it, on whichever surface it is on.
---
---Routed here rather than owned by either surface for the same reason
---`sidebar.refresh` routes the header: it is one act on two windows, and a
---caller should not have to know which one is up.
---@param chat paseo.Chat
local function fit_composer(chat)
  sidebar.fit_composer(chat)
end

M.fit_composer = fit_composer

---Re-render the transcript when the window it is drawn into changes width.
---
---GLOBAL, not `buffer = chat.conversation`, and that is a bug fix rather than
---a tidy-up. `WinResized`'s pattern is matched against the window-ID of the
---FIRST window that resized, and a buffer-local autocmd is matched against
---that window's buffer -- so with the default right-hand sidebar, which sorts
---last in the layout, dragging the separator from your code resized the pane
---and fired nothing at all. Measured, not reasoned about.
---
---Debounced, because the other half of the old bug was that when it DID fire
---it fired per column of the drag, and each one re-rendered every block in the
---transcript. 50ms and the pending flag are the answer overlay's, which has
---the same problem for the same reason.
---
---The width guard in `transcript.redraw` is what makes a global autocmd
---affordable: a resize that did not change OUR width -- another split, the
---composer growing, a height-only drag -- costs one `nvim_win_get_width`.
---@param chat paseo.Chat
local function watch_size(chat)
  chat.resize_group = vim.api.nvim_create_augroup(
    "paseo.chat.resize." .. tostring(chat.conversation),
    { clear = true }
  )
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = chat.resize_group,
    callback = function()
      if chat.resize_pending then
        return
      end
      chat.resize_pending = true
      vim.defer_fn(function()
        chat.resize_pending = false
        -- Only while the transcript is on screen. Without a window
        -- `transcript.width` falls back to 72, and re-rendering a closed chat
        -- to a fallback width is both wasted work and a wrong `rendered_width`
        -- for whatever surface opens next.
        local win = chat.win_conversation
        if win and vim.api.nvim_win_is_valid(win) then
          transcript.redraw(chat)
        end
      end, 50)
    end,
    desc = "paseo: re-render the transcript at the new width",
  })
end

---How many buffers have wanted a name already taken. See `name_buffer`.
local named = 0

---Name a chat buffer, and make sure it GETS one.
---
---`paseo://chat/<dir>` is not unique: a workspace can hold several agent
---sessions, they are all in one directory, and the second one's buffer took
---`E95: Buffer with this name already exists` and stayed UNNAMED. That is not
---cosmetic. `:e file` typed in an unnamed, unmodified buffer loads the file
---into THAT buffer rather than displacing it -- so the second session's
---composer quietly became somebody's source file, with the chat still holding
---its id and still writing your draft into it.
---@param buf integer
---@param prefix string
---@param root string
local function name_buffer(buf, prefix, root)
  local base = ("paseo://%s/%s"):format(prefix, vim.fs.basename(root))
  if not pcall(vim.api.nvim_buf_set_name, buf, base) then
    named = named + 1
    pcall(vim.api.nvim_buf_set_name, buf, ("%s-%d"):format(base, named))
  end
end

local function make_buffers(chat)
  if not (chat.conversation and vim.api.nvim_buf_is_valid(chat.conversation)) then
    chat.conversation = vim.api.nvim_create_buf(false, true)
    vim.bo[chat.conversation].buftype = "nofile"
    vim.bo[chat.conversation].bufhidden = "hide"
    vim.bo[chat.conversation].filetype = "markdown"
    vim.bo[chat.conversation].modifiable = false
    name_buffer(chat.conversation, "chat", chat.root)

    -- The conversation buffer had no keymaps at all: there was nothing on it
    -- to act on. Now a tool card can be opened to see what the command
    -- actually printed, and a pending permission answered from the log.
    local conv = { buffer = chat.conversation, nowait = true }
    for _, key in ipairs { "<Tab>", "<CR>", "za" } do
      vim.keymap.set("n", key, function()
        transcript.toggle_at_cursor(chat)
      end, vim.tbl_extend("force", conv, { desc = "paseo: expand/collapse" }))
    end
    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", conv, { desc = "paseo: close chat" }))
    vim.keymap.set("n", "gp", function()
      require("paseo.ui.permission").reopen(chat)
    end, vim.tbl_extend("force", conv, { desc = "paseo: reopen permission prompt" }))
    vim.keymap.set("n", "gs", function()
      require("paseo.pickers.subagents").open(chat)
    end, vim.tbl_extend("force", conv, { desc = "paseo: this agent's subagents" }))
    vim.keymap.set("n", "f", function()
      require("paseo.fork").start(chat)
    end, vim.tbl_extend("force", conv, { desc = "paseo: fork this conversation" }))
    vim.keymap.set(
      "n",
      "<C-f>",
      M.fullscreen,
      vim.tbl_extend("force", conv, {
        desc = "paseo: sidebar <-> full screen",
      })
    )
    -- The key you already reach for. Free on both buffers: the transcript is
    -- not modifiable, so `<C-c>` here meant nothing at all, and there was no
    -- way to stop a running turn from the editor -- the only interrupt this
    -- plugin had was the permission dialog's "decline AND stop", which only
    -- works while something is waiting to be answered.
    vim.keymap.set("n", "<C-c>", function()
      M.stop(chat)
    end, vim.tbl_extend("force", conv, { desc = "paseo: stop the turn" }))

    watch_size(chat)
  end

  if not (chat.composer and vim.api.nvim_buf_is_valid(chat.composer)) then
    chat.composer = vim.api.nvim_create_buf(false, true)
    vim.bo[chat.composer].buftype = "nofile"
    vim.bo[chat.composer].bufhidden = "hide"
    vim.bo[chat.composer].filetype = "markdown"
    name_buffer(chat.composer, "compose", chat.root)

    -- The box is the size of what is in it: three rows for a question, more
    -- for a paragraph, back to three once it is sent. A fixed eight rows was
    -- a third of a sidebar spent on whitespace for the whole of every session.
    --
    -- `TextChanged` does NOT fire for `nvim_buf_set_lines`, so every
    -- programmatic write to this buffer calls `fit_composer` itself. The one
    -- that matters most is `send`, which clears it.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = chat.composer,
      callback = function()
        fit_composer(chat)
      end,
      desc = "paseo: grow the composer with the prompt",
    })

    -- The composer is an ordinary buffer on purpose: your insert-mode
    -- keymaps, completion, abbreviations and undo all work, which is the
    -- difference between writing a prompt and filling in a text field.
    local opts = { buffer = chat.composer, nowait = true }
    vim.keymap.set("n", "<CR>", function()
      send(chat)
    end, vim.tbl_extend("force", opts, { desc = "paseo: send" }))

    -- ALT-ENTER, and not `<C-s>`. `<CR>` from insert mode is a newline, so a
    -- second key is needed for "send it while I am still typing" -- and the
    -- key that used to be was `<C-s>`, which means THE SESSION LIST
    -- everywhere else -- in every terminal, on the rail, and (on the old
    -- dashboard) in the session strip drawn four rows above this box. One key
    -- with two meanings, one of them advertised on screen directly over the
    -- other. `<C-CR>` is bound beside it for terminals that
    -- speak the kitty keyboard protocol, where it is the more natural chord;
    -- terminals that do not send it simply never deliver it, and `<M-CR>` is
    -- the one that works everywhere.
    for _, key in ipairs { "<M-CR>", "<C-CR>" } do
      vim.keymap.set("i", key, function()
        vim.cmd.stopinsert()
        send(chat)
      end, vim.tbl_extend("force", opts, { desc = "paseo: send" }))
      vim.keymap.set("n", key, function()
        send(chat)
      end, vim.tbl_extend("force", opts, { desc = "paseo: send" }))
    end

    -- RECALL, as the app's composer does it: `<Up>` in an EMPTY box brings
    -- back the last thing you sent this agent, again for the one before, and
    -- `<Down>` walks forward to an empty box. Only while the box is empty or
    -- still holds exactly what was recalled -- otherwise these are just the
    -- arrow keys, moving through a prompt you are writing.
    local function recall(step)
      return function()
        local lines = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
        local text = table.concat(lines, "\n")
        local walking = chat.recall and text == chat.recall.shown
        if text ~= "" and not walking then
          return vim.api.nvim_feedkeys(vim.keycode(step < 0 and "<Up>" or "<Down>"), "n", false)
        end
        local sent = M.sent_prompts(chat)
        local at = walking and chat.recall.at or (#sent + 1)
        at = math.max(1, math.min(#sent + 1, at + step))
        local shown = sent[at] or ""
        chat.recall = { at = at, shown = shown }
        vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, vim.split(shown, "\n"))
        M.fit_composer(chat)
        local last = vim.api.nvim_buf_line_count(chat.composer)
        pcall(vim.api.nvim_win_set_cursor, 0, { last, #(vim.api.nvim_buf_get_lines(chat.composer, last - 1, last, false)[1] or "") })
      end
    end
    for _, mode in ipairs { "n", "i" } do
      vim.keymap.set(mode, "<Up>", recall(-1), vim.tbl_extend("force", opts, { desc = "paseo: recall an earlier prompt" }))
      vim.keymap.set(mode, "<Down>", recall(1), vim.tbl_extend("force", opts, { desc = "paseo: recall a later prompt" }))
    end

    -- THE OTHER SEND, the app's long-press: queue it behind the running turn
    -- when sending steers, send it now when sending queues. `g<CR>` works in
    -- every terminal; `<S-CR>` in those that can tell it from `<CR>`.
    vim.keymap.set("n", "g<CR>", function()
      send(chat, true)
    end, vim.tbl_extend("force", opts, { desc = "paseo: send the other way (queue / now)" }))
    vim.keymap.set({ "n", "i" }, "<S-CR>", function()
      if vim.fn.mode() == "i" then
        vim.cmd.stopinsert()
      end
      send(chat, true)
    end, vim.tbl_extend("force", opts, { desc = "paseo: send the other way (queue / now)" }))

    -- And `<C-s>` means here what it means everywhere else: the session list.
    -- From the sidebar's box that is a surface change: it opens the native
    -- surface with the cursor in its rail, rather than doing nothing when no
    -- rail is up.
    local sessions_key = config.get().ui.terminal.keys.sessions
    if sessions_key then
      vim.keymap.set({ "n", "i" }, sessions_key, function()
        if vim.fn.mode() ~= "n" then
          vim.cmd.stopinsert()
        end
        M.sessions(chat)
      end, vim.tbl_extend("force", opts, { desc = "paseo: the session list" }))
    end

    -- Speak it instead of typing it. Neovim cannot record audio, so this
    -- shells out to arecord/sox/ffmpeg -- see `paseo.voice` for why that is
    -- the feature rather than a workaround for it.
    --
    -- One key for both halves. A hold-to-talk key would be better and is not
    -- available: Neovim delivers a keypress, never a key RELEASE, so "while
    -- held" cannot be expressed. Press to start, press to stop and insert.
    local voice_key = (config.get().voice or {}).key
    if voice_key and (config.get().voice or {}).enabled ~= false then
      for _, mode in ipairs { "n", "i" } do
        vim.keymap.set(mode, voice_key, function()
          require("paseo.voice").toggle {
            -- The visible half of dictation is |paseo.ui.composer|'s: the
            -- meter over the box, the clock, and taking the indicator down
            -- again however the recording ends.
            on_state = function(state)
              require("paseo.ui.composer").dictating(chat, state)
              dictation_keys(chat, state)
            end,
            on_level = function(level)
              require("paseo.ui.composer").push_level(chat, level)
            end,
            insert = function(text)
              M.insert(chat, text)
            end,
          }
        end, vim.tbl_extend("force", opts, { desc = "paseo: dictate" }))
      end
    end

    -- In insert mode too: you are usually typing the next thing when you
    -- decide the current thing should stop.
    for _, mode in ipairs { "n", "i" } do
      vim.keymap.set(mode, "<C-c>", function()
        if mode == "i" then
          vim.cmd.stopinsert()
        end
        M.stop(chat)
      end, vim.tbl_extend("force", opts, { desc = "paseo: stop the turn" }))
    end
    -- PASTE IS PASTE. An image on the clipboard is invisible to Neovim's
    -- registers -- `"+p` yields nothing for a screenshot -- so the ordinary
    -- paste cannot reach it without help. The help used to be a key of its
    -- own, `<C-v>`, advertised in the composer's winbar; but a paste key you
    -- have to be taught is a worse answer than `p` simply working. So `p`,
    -- `P` and `<C-v>` all look at the clipboard for a picture first and do
    -- their ordinary job when there is not one.
    --
    -- Falling through preserves the count and the register: `3p` and `"ap` are
    -- still `3p` and `"ap`, which they would not be if this just fed the bare
    -- key back.
    ---@param key string
    local function paste(key)
      return function()
        local image = read_image(nil, true)
        if image then
          return attach_image(chat, image)
        end
        local prefix = ""
        if vim.fn.mode() == "n" then
          -- Only in normal mode: `"` and a digit typed in INSERT mode are just
          -- a quote and a digit, and prepending them there would write them
          -- into the prompt.
          prefix = (vim.v.register ~= '"' and ('"' .. vim.v.register) or "")
            .. (vim.v.count > 0 and tostring(vim.v.count) or "")
        end
        vim.api.nvim_feedkeys(prefix .. vim.keycode(key), "n", false)
      end
    end
    for _, key in ipairs { "p", "P" } do
      vim.keymap.set(
        "n",
        key,
        paste(key),
        vim.tbl_extend("force", opts, {
          desc = "paseo: paste (an image, if the clipboard has one)",
        })
      )
    end
    vim.keymap.set(
      { "n", "i" },
      "<C-v>",
      paste "<C-v>",
      vim.tbl_extend("force", opts, {
        desc = "paseo: paste (an image, if the clipboard has one)",
      })
    )
    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", opts, { desc = "paseo: close chat" }))
    vim.keymap.set("n", "gq", function()
      M.close()
    end, vim.tbl_extend("force", opts, { desc = "paseo: close chat" }))
    vim.keymap.set("n", "f", function()
      require("paseo.fork").start(chat)
    end, vim.tbl_extend("force", opts, { desc = "paseo: fork this conversation" }))
    for _, mode in ipairs { "n", "i" } do
      vim.keymap.set(mode, "<C-f>", function()
        vim.cmd.stopinsert()
        M.fullscreen()
      end, vim.tbl_extend("force", opts, { desc = "paseo: sidebar <-> full screen" }))
    end
  end
end

---Is this chat on screen, on any surface?
---
---A native tab answers for itself. The sidebar has no state object, so its
---answer is the conversation window itself.
---@param chat paseo.Chat
---@return boolean
function M.showing(chat)
  if require("paseo.ui.native").has(chat) then
    return true
  end
  return chat.surface == "sidebar" and sidebar.is_open(chat)
end

---Put the chat on screen, on the surface |paseo.ui.surface| resolves: the one
---asked for, else the one on screen, else the one you last used, else
---`ui.surface`.
---
---It used to read `chat.surface` first and the default last, and `chat.surface`
---was cleared whenever the dashboard closed -- so every path that closes one
---chat's surface and opens another's (following you to a workspace you had
---been to, adopting an agent `agent.find` already knew) fell through to the
---default and turned the buffer dashboard or the sidebar into a float.
---@param chat paseo.Chat
---@param explicit? "float"|"sidebar"|"buffer"
local function layout(chat, explicit)
  make_buffers(chat)
  local surface = M._drawable(require("paseo.ui.surface").resolve(explicit))
  if surface == "native" then
    local native = require "paseo.ui.native"
    -- `sidebar.close` closes the chat's windows WHEREVER they are, and on a
    -- native tab they are the tab.
    if not native.has(chat) then
      sidebar.close(chat)
    end
    native.open(chat)
    transcript.to_bottom(chat)
    return
  end
  sidebar.open(chat)
  -- AT THE END, NOT WHERE YOU LEFT IT. A window put back on a conversation
  -- buffer gets that buffer's last cursor position, so coming back to a
  -- workspace -- or reopening a chat at all -- showed whatever you had last
  -- scrolled to, and the newest thing the agent said was a scroll away.
  -- Opening a chat is asking what is happening NOW.
  transcript.to_bottom(chat)
end

-- ------------------------------------------------------------------- history

---Should a live event be rendered, or has history already covered it?
---
---History and the live subscription race: a message arriving between
---`timeline.subscribe` and the history fetch is delivered by BOTH, and renders
---twice. The timeline's own sequence numbers settle it -- anything at or below
---what history already covered is a duplicate.
---@param chat paseo.Chat
---@param payload table
---@return boolean
local function fresh(chat, payload)
  local seq = payload.seq
  if not seq or not chat.seq then
    return true
  end
  -- A new epoch invalidates the old numbering entirely.
  if payload.epoch and chat.epoch and payload.epoch ~= chat.epoch then
    chat.seq, chat.epoch = nil, payload.epoch
    return true
  end
  if seq <= chat.seq then
    return false
  end
  chat.seq = seq
  return true
end

---Live events that arrive while the first history fetch is in flight WAIT
---for it, and are then replayed through `fresh` like any other.
---
---Subscribing first and fetching second is right -- nothing said in between is
---lost -- but rendering the in-between at once put it ABOVE the history that
---arrived after it: a chat opened mid-turn, which is every chat whose first
---message created its agent, showed a fragment of the thought over the
---question that prompted it, and the whole thought again below. Held, the
---replay lands after history, and `fresh` drops what history already covered.
---@param chat paseo.Chat
---@param handler fun(payload: table)
---@param payload table
---@return boolean held
local function hold(chat, handler, payload)
  if not chat.backlog then
    return false
  end
  chat.backlog[#chat.backlog + 1] = { handler, payload }
  return true
end

---@param chat paseo.Chat
local function release(chat)
  local backlog = chat.backlog
  chat.backlog = nil
  for _, held in ipairs(backlog or {}) do
    held[1](held[2])
  end
end

---@param chat paseo.Chat
local function load_history(chat)
  bridge.request("timeline.history", { agentId = chat.agent_id, limit = 60 }, function(err, result)
    if err or not result then
      return vim.schedule(function()
        -- SAID, not swallowed. An agent whose provider cannot resume it --
        -- archived, its process gone after a daemon restart -- used to open
        -- onto an empty chat with no word about why, which reads as a
        -- conversation that never happened.
        notice(chat, "could not load the conversation: " .. tostring(err or "no reply"), "error")
        release(chat)
      end)
    end
    vim.schedule(function()
      -- History now carries the SAME item shape as the live subscription --
      -- tool calls, reasoning, todos and all -- so reopening a chat shows the
      -- work the agent did, not just the sentences it ended with.
      for _, item in ipairs(result.items or {}) do
        transcript.upsert(chat, item)
      end
      -- A chat opened MID-TURN -- which is every chat whose first message
      -- just created its agent -- has history ending part-way through a
      -- thought or an answer, and the rest of it arriving live. Leave that
      -- last block open so the rest extends it, as the daemon's projection
      -- would, rather than starting a second block under the first word.
      local last = chat.order and chat.blocks[chat.order[#chat.order]]
      if last and last.id and (last.item.kind == "text" or last.item.kind == "thinking") then
        chat.open = { id = last.id, kind = last.item.kind }
      end

      -- Everything up to here is now on screen, so live events at or below this
      -- point are duplicates.
      local cursor = result.endCursor
      if cursor then
        chat.seq = cursor.seq
        chat.epoch = cursor.epoch
      end

      -- An agent that blocked BEFORE this window opened never fires
      -- `permission_requested` at us -- that event fired once, while we were
      -- not listening. Without this the agent session looks idle when it is actually
      -- waiting on an answer.
      --
      -- Reconciled rather than merely offered: this also runs on a `restored`
      -- reconnect, where the interesting news is usually the opposite -- a
      -- request we are still holding that was answered during the gap.
      require("paseo.ui.permission").reconcile(chat, result.pendingPermissions or {})
      release(chat)
    end)
  end, chat.host_id)
end

---Everything a chat needs once its agent is known: a clean buffer, the live
---subscription, the conversation so far, and the agent's current settings.
---
---One function because these belong together -- an agent that is subscribed but
---whose history was never fetched looks like an empty conversation, and one
---whose settings were never read shows the wrong mode in the winbar.
---@param chat paseo.Chat
initialise = function(chat)
  if chat.initialised then
    return
  end
  chat.initialised = true

  -- Clear the placeholder before history lands on top of it. `reset` also
  -- wipes the block table, so ids from a previous agent cannot collide.
  transcript.reset(chat)
  set_winbar(chat)

  -- Subscribe BEFORE fetching history, so nothing said in between is lost.
  -- The seq comparison in `fresh` is what stops the overlap rendering twice,
  -- and `hold` is what keeps the overlap from drawing ABOVE the history.
  chat.backlog = {}
  bridge.request("timeline.subscribe", { agentId = chat.agent_id }, function()
    load_history(chat)
  end, chat.host_id)
  M.load_settings(chat)
  -- Its subagents, both kinds: the count in the header and `gs`.
  require("paseo.subagents").follow(chat.agent_id, chat.host_id)
  -- And any of them already blocked on a permission when the chat opened.
  if M.relay_permissions then
    M.relay_permissions(chat)
  end
end

-- --------------------------------------------------------------------- API

---Turn `chat` into a DRAFT: settings chosen, nothing created, the composer
---waiting for the message that will create it.
---
---Nothing is created until that message because the daemon names a workspace
---from the first prompt, and only when the prompt rides the request that
---creates it -- so an agent made empty here left every workspace started from
---the editor called `main`. `send` sees `chat.draft` and starts it.
---@param chat paseo.Chat
---@param key string  Where `chats` holds it until it is an agent.
---@param opts { settings: table, project?: string, start?: fun(prompt: string, images: table[], done: fun(err: string|nil, agent_id: string|nil)), banner?: string }
local function make_draft(chat, key, opts)
  local settings = opts.settings
  local host = hosts.get(chat.host_id)
  -- What the bar shows until the agent exists and its own settings arrive:
  -- the choices just made, rather than `…`.
  chat.provider = settings.provider
  chat.mode = settings.modeId
  chat.draft = {
    settings = settings,
    project = opts.project
      or (host and host.local_host and require("paseo.workspaces").parent_project(chat.local_root or chat.root))
      or nil,
    start = opts.start,
    ---Bind the agent the first message created.
    bind = function(agent_id)
      chat.draft = nil
      config.get().paseo.provider = settings.provider
      chat.agent_id = agent_id
      chat.provider = settings.provider
      chats[key] = nil
      chats[hosts.key(chat.host_id, agent_id)] = chat
      vim.schedule(function()
        initialise(chat)
      end)
    end,
  }
  vim.schedule(function()
    notice(chat, opts.banner or "new session — your first message starts it")
    set_winbar(chat)
    if chat.win_composer and vim.api.nvim_win_is_valid(chat.win_composer) then
      vim.api.nvim_set_current_win(chat.win_composer)
      vim.cmd.startinsert()
    end
  end)
end

---How many drafts have been opened: each gets a key of its own.
local draft_count = 0

---Open a DRAFT on the surface you are on: the ordinary conversation view,
---empty, with the composer waiting. Nothing exists on the daemon until the
---first message, which creates the agent -- and, with `start`, whatever else
---it needs, a whole workspace -- in the request that can NAME it.
---
---A chat of its own, never the one on screen: that one already has an agent,
---and a draft beside it is a second session in the same workspace.
---
---`start(prompt, images, done)` replaces the default start (`agent.start`,
---which may make a fresh directory workspace). It is handed the first message
---and answers `done(err)` on failure, `done(nil, agent_id)` to bind the agent
---it made to this chat, or `done(nil)` when it pointed the editor at a chat
---of its own.
---@param opts { root: string, local_root?: string, host_id?: string, settings: table, project?: string, start?: fun(prompt: string, images: table[], done: fun(err: string|nil, agent_id: string|nil)), banner?: string }
---@return paseo.Chat
function M.draft(opts)
  local host = assert(hosts.get(opts.host_id), "unknown Paseo host")
  draft_count = draft_count + 1
  local key = hosts.key(host.id, "draft:" .. draft_count)
  local chat = {
    root = opts.root,
    local_root = opts.local_root or opts.root,
    host_id = host.id,
    streaming = false,
    pending = {},
    images = {},
  }
  chats[key] = chat
  current = chat
  layout(chat)
  make_draft(chat, key, opts)
  return chat
end

---Throw a draft away -- its first message made something that another chat
---is now showing. Its window goes only if it is still the one up.
---@param chat paseo.Chat
function M.discard(chat)
  for k, c in pairs(chats) do
    if c == chat then
      chats[k] = nil
    end
  end
  if current == chat then
    current = nil
  end
end

---Where a chat opens when nobody said which directory.
---
---THE DIRECTORY YOU ARE STANDING IN, resolved to the unit of work that
---contains it: the workspace when the cwd is inside one, else the enclosing
---repository, else the cwd itself.
---
---This used to be `ref.file().root` -- the git toplevel of the BUFFER -- with
---the cwd reached only when that buffer had no name. That is the whole of why
---switching workspace and then opening the chat showed you the workspace you
---had just left: `workspaces.open = "tcd"` reuses the current tab, so the file
---you had open in the old worktree is still the current buffer, and its
---toplevel is still the old worktree. The cwd is the one thing the switch
---actually changed, so the cwd is what this reads.
---
---`getcwd()` rather than `vim.uv.cwd()`: the switch is a `:tcd`, and the
---tab-local directory is where the window you are looking at is standing.
---
---Resolved the same way |paseo.workspaces|.open passes a root, so
---`:Paseo chat` and an automatic |paseo.ui.chat|.follow land on the same
---agent rather than on two agents one directory apart.
---
---Callers that mean a particular FILE -- |paseo.explain|, `:Paseo ask` --
---pass `root` explicitly and never reach this.
---@return string
local function here()
  local repos = require "paseo.repos"
  local cwd = vim.fn.getcwd()
  local repo = repos.resolve(cwd)
  return repos.workspace_root(cwd) or (repo and repo.worktree) or cwd
end

---Open (or focus) a chat.
---
---`create = false` means "show me the agent in this directory, and say so if
---there is not one" -- no provider picker. That is what an AUTOMATIC open
---needs: `M.follow` re-points the window every time you change workspace, and
---a modal asking which provider to use, unbidden, on a workspace you have not
---started an agent in yet, is worse than the empty window it replaces.
---
---`surface` overrides where this chat last was, and is for the callers that
---MOVE a chat -- `M.follow`, `M.surface`. Opening a session does not need it:
---`layout` inherits the mount already on screen, because the surface you are
---looking at belongs to the window, not to the conversation you are switching
---to. Passing a literal here is how `:Paseo term` used to drag you off the
---buffer dashboard and keep you off it.
---@param opts? { root?: string, local_root?: string, host_id?: string, remote?: boolean, focus?: boolean, agent_id?: string, title?: string, create?: boolean, surface?: "float"|"sidebar"|"buffer" }
---@param callback? fun(chat: paseo.Chat|nil, err: string|nil)
function M.open(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local host = hosts.get(opts.host_id)
  if not host then
    local err = "unknown Paseo host " .. tostring(opts.host_id)
    vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    return callback(nil, err)
  end
  local local_root = opts.local_root or (opts.remote and hosts.to_local(host.id, opts.root))
  local root = opts.root or here()
  if not opts.remote then
    local_root = root
    root = hosts.to_remote(host.id, root)
    if not root then
      local err = ("%s is not mapped on Paseo host %s"):format(local_root, host.label)
      vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      return callback(nil, err)
    end
  end

  local key = hosts.key(host.id, opts.agent_id or root)
  local chat = chats[key]

  -- THE CHAT ALREADY ON SCREEN, when the caller named no agent and it is for
  -- this directory. Chats are re-keyed by agent id the moment one is bound
  -- (see `adopt` below), so a lookup by directory -- which is what `:Paseo
  -- image`, `ask` and `explain` all do -- missed the chat you were looking
  -- at, built a second one on the default surface, and then `adopt` found the
  -- real one, closed the surface and laid it out again. On the buffer mount
  -- that round trip landed you in the float: paste an image, lose the tab.
  local reused = false
  if not chat and not opts.agent_id and current and current.agent_id
    and current.host_id == host.id and current.root == root and M.showing(current)
  then
    chat, reused = current, true
  end

  if not chat then
    chat = {
      root = root,
      local_root = local_root,
      host_id = host.id,
      agent_id = opts.agent_id,
      title = opts.title,
      streaming = false,
      pending = {},
      images = {},
    }
    chats[key] = chat
  end
  current = chat

  -- Already up where it should be: laying it out again is the churn above.
  if not (reused and not opts.surface) then
    layout(chat, opts.surface)
  end
  if opts.focus ~= false and chat.win_composer and vim.api.nvim_win_is_valid(chat.win_composer) then
    -- Not unconditional: the composer window need not be up, and
    -- `nvim_set_current_win(nil)` is an error rather than a no-op. (On the old
    -- dashboard it was missing on every tab but Chat.)
    vim.api.nvim_set_current_win(chat.win_composer)
  end

  -- An agent we were HANDED still needs everything an agent we created needs.
  --
  -- This used to return early when `chat.agent_id` was already set, which is
  -- exactly the case when you open an existing agent session from the agent
  -- picker -- so it never subscribed, never fetched the conversation, and
  -- never loaded the mode. You got an empty window onto an agent session with
  -- history.
  if chat.agent_id and chat.initialised then
    M.load_settings(chat)
    return callback(chat, nil)
  end

  if chat.agent_id then
    notice(chat, "loading…")
    return bridge.ensure(function(err)
      if err then
        vim.schedule(function()
          notice(chat, err, "error")
        end)
        return callback(nil, err)
      end
      vim.schedule(function()
        initialise(chat)
      end)
      callback(chat, nil)
    end, chat.host_id)
  end

  -- Still a draft: the settings were chosen and nothing has been sent. Back to
  -- the composer, not through the start menu a second time.
  if chat.draft then
    return callback(chat, nil)
  end

  notice(chat, "connecting…")
  bridge.ensure(function(err)
    if err then
      vim.schedule(function()
        notice(chat, err, "error")
      end)
      return callback(nil, err)
    end

    local preferred = host.provider or config.get().paseo.provider
    local function adopt(result)
      local agent_key = hosts.key(host.id, result.id)
      local known = chats[agent_key]
      if known and known ~= chat then
        chats[key] = nil
        if current == chat then
          M.close()
          current = known
          layout(known)
          M.load_settings(known)
        end
        return callback(known, nil)
      end
      chat.agent_id = result.id
      chat.provider = result.provider
      chats[key] = nil
      chats[agent_key] = chat
      vim.schedule(function()
        initialise(chat)
      end)
      callback(chat, nil)
    end

    bridge.request("agent.find", { cwd = root, provider = preferred }, function(find_err, found)
      if find_err then
        notice(chat, find_err, "error")
        return callback(nil, find_err)
      end
      if found and found.id then
        return adopt(found)
      end
      if opts.create == false then
        notice(chat, "no agent in this workspace yet — :Paseo chat starts one")
        return callback(nil, nil)
      end
      -- WHAT, THEN WHERE, THEN THE SETTINGS -- see |paseo.start|. This used to
      -- open the model picker outright, which asks four questions about an
      -- agent before anything has established that an agent is the thing you
      -- came here for, and left a terminal reachable only from a tab of a
      -- surface you had to create an agent in order to see.
      notice(chat, "nothing running here yet…")
      require("paseo.start").open({
        root = root,
        local_root = local_root,
        host_id = host.id,
        preferred = preferred,
      }, function(result, err)
        if err then
          notice(chat, err, "error")
          return callback(nil, err)
        end

        ---Give this empty chat up. Nothing was ever attached to it.
        local function stand_down(reason)
          chats[key] = nil
          if current == chat then
            M.close()
          end
          return callback(nil, reason)
        end

        if not result then
          return stand_down "cancelled"
        end

        -- A TERMINAL IS A SESSION, not an agent, and this chat never becomes
        -- one. The surface is already pointed at the PTY -- `start` did that
        -- -- so the chat stays keyed on the directory, with no agent, and
        -- says so. Asking again next time is correct: there is still no
        -- agent here.
        if result.kind == "terminal" then
          notice(chat, "a terminal is running here — the rail lists it under its workspace")
          return callback(nil, nil)
        end

        -- The agent went somewhere else, and the editor is already looking at
        -- it. This chat is an empty window onto a directory nobody is working
        -- in any more.
        if result.moved then
          return stand_down(nil)
        end

        -- A DRAFT, NOT AN AGENT. Nothing is created until the first message:
        -- the daemon names a workspace from the first prompt, and only when
        -- the prompt is part of the request that creates it -- so creating the
        -- agent here, empty, is what left every workspace started from the
        -- editor called `main`. `send` sees `chat.draft` and starts it.
        make_draft(chat, key, { settings = result.draft })
        callback(chat, nil)
      end)
    end, host.id)
  end, host.id)
end

---Queue a reference as context for the next send, and open the composer on it.
---@param ref_text string
---@param opts? { root?: string, prompt?: string }
function M.attach(ref_text, opts)
  opts = opts or {}
  M.open({ root = opts.root }, function(chat)
    if not chat then
      return
    end
    vim.schedule(function()
      table.insert(chat.pending, ref_text)

      -- Shown in the composer, not hidden: you can see exactly what is about to
      -- be sent, and delete the line if you change your mind.
      local existing = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
      local note = ("> attached: %s"):format(vim.split(ref_text, "\n")[1])
      if #existing == 1 and existing[1] == "" then
        existing = {}
      end
      table.insert(existing, 1, note)
      if opts.prompt then
        vim.list_extend(existing, vim.split(opts.prompt, "\n"))
      end
      vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, existing)
      -- Before the cursor move, so the line it lands on is on screen: this
      -- path can write a whole prompt into a three-row box.
      M.fit_composer(chat)

      vim.api.nvim_set_current_win(chat.win_composer)
      vim.api.nvim_win_set_cursor(chat.win_composer, { #existing, 0 })
      if not opts.prompt then
        vim.cmd.startinsert { bang = true }
      end
    end)
  end)
end

---Paste an image into the composer: the clipboard, or `opts.path`.
---@param opts? { path?: string, root?: string }
function M.paste_image(opts)
  opts = opts or {}

  local image = read_image(opts.path)
  if not image then
    return false
  end

  M.open({ root = opts.root, focus = false }, function(chat)
    if not chat then
      return
    end
    vim.schedule(function()
      attach_image(chat, image)
    end)
  end)
  return true
end

---Send a prompt without opening the composer for editing.
---@param prompt string
---@param opts? { root?: string, context?: string }
function M.ask(prompt, opts)
  opts = opts or {}
  M.open({ root = opts.root, focus = false }, function(chat)
    if not chat then
      return
    end
    vim.schedule(function()
      if opts.context then
        table.insert(chat.pending, opts.context)
      end
      vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, vim.split(prompt, "\n"))
      send(chat)
    end)
  end)
end

function M.close()
  local chat = current
  if not chat then
    return
  end
  -- A MICROPHONE DOES NOT SURVIVE THE WINDOW IT WAS OPENED IN. Closing the
  -- chat takes the meter, the clock and the box the text was going to land in
  -- with it, so a recorder left running would be a process holding the
  -- microphone open with nothing on screen saying so and no key left to stop
  -- it.
  if chat.dictating then
    require("paseo.voice").cancel()
    require("paseo.ui.composer").dictating(chat, false)
  end
  local native = require "paseo.ui.native"
  if native.has(chat) then
    return native.close(chat)
  end
  sidebar.close(chat)
end

---Is this chat on screen on the tab page you are looking at?
---
---`sidebar.is_open` asks only whether the conversation WINDOW is valid, and a
---window on another tab page is perfectly valid -- so a chat left behind by a
---`tabnew` workspace switch counted as open, and the first press of the chat
---key closed something invisible instead of opening something here.
---@param chat table
---@return boolean
local function visible(chat)
  if require("paseo.ui.native").has(chat) then
    return require("paseo.ui.native").is_open(chat)
  end
  local win = chat.win_conversation
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  return vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
end

function M.toggle()
  local chat = current
  if chat and visible(chat) then
    return M.close()
  end
  M.open {}
end

---Stop treating any chat as the current one.
---
---Not a close: the windows, if there are any, are somebody else's business.
---This only drops the module-local pointer, so the next `M.open {}` resolves
---where it is from scratch instead of adopting whatever was last looked at.
function M.forget()
  current = nil
end

---Re-point an OPEN chat at another directory.
---
---The bug this fixed: with the old dashboard up full screen, switching
---workspace left it showing the previous workspace's agent. The window was
---the one thing on screen and it was describing somewhere you were no longer
---standing -- and since a float belongs to the tab page it was opened on, the
---`"tab"` switch did not even leave it visible.
---
---Three deliberate choices:
---
---  * NOTHING OPEN, NOTHING HAPPENS. Changing directory is not a request for a
---    chat. This only ever moves a window that is already up.
---  * It goes through `close` rather than handing the surface a new chat,
---    because a window opened on the tab you just left is still a VALID window
---    -- `is_open` says yes, `open` takes its "already up" branch, and you get
---    yanked back to the old tab. Closing first is what puts the surface on the
---    tab page you are actually on.
---  * `create = false`: an automatic re-point must never open a provider
---    picker. A workspace with no agent yet says so and waits.
---
---Focus follows the surface: a native tab is the whole screen, so you need to
---be able to type into it; the sidebar sits beside code you were editing, so it
---must not steal your cursor.
---
---`offer` is for OPENING A WORKSPACE, which is not merely changing directory:
---you picked it to work in it. One with no agent yet gets the start menu
---(|paseo.start|) rather than an empty window saying so -- on the surface that
---is up, or on the default one when none is. One that has an agent still
---opens nothing unbidden.
---@param root string
---@param opts? { focus?: boolean, offer?: boolean }
---@return boolean followed
function M.follow(root, opts)
  opts = opts or {}
  local chat = current
  if type(root) ~= "string" or root == "" then
    return false
  end
  if not chat then
    if opts.offer then
      M.offer(root)
    end
    return false
  end

  -- `showing` rather than `is_open`, which is tab-aware: following is the act
  -- of moving a surface off the tab you just left, so the one moment it
  -- matters is the moment a tab-aware test says "nothing open".
  local native = require "paseo.ui.native"
  -- A native tab is the agent's own, not a window onto "wherever you are": a
  -- workspace switch opens that workspace's agent in a tab of ITS own and
  -- leaves this one where it is.
  if native.has(chat) then
    M.open { root = root, surface = "native", focus = opts.focus ~= false, create = opts.offer == true }
    return true
  end
  if not sidebar.is_open(chat) then
    -- Declining to OPEN a window is not the same as keeping a pointer to the
    -- workspace you just left. `current` is what `toggle`, `close` and
    -- `surface` all read, and `open`'s `adopt` will hand back this very chat
    -- object -- root, transcript and header directory -- the moment
    -- `agent.find` returns an id it already knows. So the window stays shut,
    -- and the memory of where we were goes.
    M.forget()
    if opts.offer then
      M.offer(root)
    end
    return false
  end

  -- Read BEFORE the close: what is on screen is the answer, and in a moment
  -- nothing will be.
  local surface = require("paseo.ui.surface").resolve()
  local focus = opts.focus
  if focus == nil then
    -- Anything but the sidebar takes the cursor: anything else covers what
    -- you were looking at, so you need to be able to type into it. The
    -- sidebar sits BESIDE your code, which is the whole of the difference.
    focus = surface ~= "sidebar"
  end

  M.close()
  M.open { root = root, surface = surface, focus = focus, create = opts.offer == true }
  return true
end

---Offer to start something in `root` when nothing is running there yet.
---
---Asks the daemon first, so a workspace that already has an agent opens no
---window at all: opening one is not a request for a chat. Local host only, as
---`follow` is.
---@param root string
function M.offer(root)
  local host = hosts.get()
  local remote = host and hosts.to_remote(host.id, root)
  if not remote then
    return
  end
  bridge.request("agent.find", { cwd = remote }, function(err, found)
    if err or (found and found.id) then
      return
    end
    vim.schedule(function()
      M.open { root = root, host_id = host.id, create = true }
    end)
  end, host.id)
end

---Put the chat on a named surface, keeping the conversation and the draft.
---
---Both live on the chat rather than in a window, so this is genuinely just a
---matter of closing one set of windows and opening another.
---
---`toggle` makes the surface's own key answer twice: press it where you are
---and the surface comes up, press it again and it goes away. It only ever
---closes a surface that is BOTH this one and on the tab page you are looking
---at -- `is_open` asks both -- so the key never answers a surface you
---cannot see by hiding it.
---@param name "float"|"sidebar"|"buffer"
---@param opts? { toggle?: boolean }
function M.surface(name, opts)
  name = M._drawable(name)
  local chat = current
  if not chat then
    -- ON THE SURFACE THAT WAS ASKED FOR, not on the default one first.
    return M.open({ surface = name }, function(opened)
      if opened and opened.surface ~= name then
        M.surface(name)
      end
    end)
  end

  if opts and opts.toggle and name == "sidebar" and sidebar.is_open(chat) then
    return M.close()
  end

  local native = require "paseo.ui.native"
  if name == "native" then
    if opts and opts.toggle and native.is_open(chat) then
      return M.close()
    end
    if not native.has(chat) then
      sidebar.close(chat)
    end
    native.open(chat)
    return
  end
  if native.has(chat) then
    native.close(chat)
  end
  chat.surface = "sidebar"
  sidebar.open(chat)
end

---`<C-f>`: from the sidebar beside your code, to the chat's native tab.
---
---Not a key ON the native surface: a tab page is a place of its own, and
---`q` -- or `gt` -- is how you leave it. Declined silently; a notification
---for "this key does nothing here" is noise on a key people press by reflex.
function M.fullscreen()
  local chat = current
  if chat and require("paseo.ui.native").has(chat) then
    return
  end
  -- The answer overlay is anchored to the conversation WINDOW, and the swap
  -- closes it -- so without this a question you were halfway through
  -- disappears on `<C-f>`. Reopened rather than migrated.
  local pending = require("paseo.ui.answer").showing()
  local result = M.surface "native"
  if chat and pending then
    vim.schedule(function()
      require("paseo.ui.permission").reopen(chat)
    end)
  end
  return result
end

---@type boolean
local attached = false

---Wire the sidecar's streaming events into whichever chat they belong to.
---Idempotent: `setup()` calls it, and a second call would double every
---listener -- a reply streamed as "READ" + "Y" then renders as "READREADYY".
function M.attach_events()
  if attached then
    return
  end
  attached = true

  ---@param agent_id string
  ---@return paseo.Chat|nil
  local function by_agent(agent_id, host_id)
    for _, chat in pairs(chats) do
      if chat.agent_id == agent_id and (not host_id or chat.host_id == host_id) then
        return chat
      end
    end
    return nil
  end

  ---Render an item, if it is not something history already covered.
  ---@param payload table
  local function ingest(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if not chat or hold(chat, ingest, payload) then
      return
    end
    if fresh(chat, payload) then
      transcript.upsert(chat, payload)
    end
  end

  -- A user message, from wherever it was typed: here, the Paseo app, another
  -- client. This is what makes the two views the same conversation.
  local function on_user(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if not chat or hold(chat, on_user, payload) or not fresh(chat, payload) then
      return
    end
    transcript.upsert(chat, { kind = "user", text = payload.text or "" })
    M.set_streaming(chat, true)
  end
  bridge.on("user", on_user)

  local function on_text(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat and not hold(chat, on_text, payload) and fresh(chat, payload) then
      transcript.stream(chat, payload.text or "")
    end
  end
  bridge.on("text", on_text)

  -- THE MISSING HALF. Reasoning, tool calls, todos, notices and compaction all
  -- reach Neovim now; before this they were dropped at the sidecar and the
  -- window showed a long silence while the agent read files and ran commands.
  for _, event in ipairs { "tool", "agent_message", "todo", "notice", "compaction" } do
    bridge.on(event, ingest)
  end

  -- Reasoning streams in deltas exactly as the answer does, so it goes where
  -- the answer goes: into the open block, not a new one per chunk.
  local function on_thinking(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat and not hold(chat, on_thinking, payload) and fresh(chat, payload) then
      transcript.stream(chat, payload.text or "", "thinking")
    end
  end
  bridge.on("thinking", on_thinking)

  -- A Paseo subagent blocked on a permission: its request is answered HERE,
  -- in the parent's chat, because nobody opens the subagent's own. A
  -- subagent that does have an initialised chat keeps its requests.
  local function has_own_chat(agent_id)
    for _, other in pairs(chats) do
      if other.agent_id == agent_id and other.initialised then
        return true
      end
    end
    return false
  end
  M.relay_permissions = function(chat)
    require("paseo.ui.permission").relay(chat, has_own_chat)
  end
  require("paseo.agents").on_change(function()
    vim.schedule(function()
      for _, chat in pairs(chats) do
        if chat.agent_id and chat.initialised then
          M.relay_permissions(chat)
        end
      end
    end)
  end)

  -- A subagent started, moved or finished: the header counts them.
  require("paseo.subagents").on_change(function(host_id, parent)
    for _, chat in pairs(chats) do
      if chat.agent_id and (parent == nil or chat.agent_id == parent)
        and (host_id == nil or chat.host_id == host_id) then
        M.refresh(chat)
      end
    end
  end)

  -- A permission request. The agent is BLOCKED until this is answered.
  bridge.on("permission", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat and payload.request then
      require("paseo.ui.permission").offer(chat, payload.request)
    end
  end)

  bridge.on("permission_resolved", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat then
      require("paseo.ui.permission").resolved(chat, payload.requestId, payload.resolution)
    end
  end)

  -- An agent needs a human, and it is not necessarily one you have open.
  --
  -- `by_agent` above returns nil for every agent without a chat window, and
  -- both permission handlers then drop the payload silently -- so an agent
  -- blocked in a workspace you are not looking at produced no sound at all.
  -- This is the daemon's own "somebody is needed here" event; it was emitted
  -- by the sidecar and listened to by nobody.
  bridge.on("attention", function(payload)
    if payload.reason ~= "permission" or by_agent(payload.agentId, payload.hostId) then
      return
    end
    local agent = require("paseo.agents").get(payload.agentId, payload.hostId)
    vim.notify(
      ("paseo: %s needs permission — `:Paseo chat` in its worktree to answer"):format(
        (agent and agent.title) or payload.agentId
      ),
      vim.log.levels.WARN
    )
  end)

  -- Mode, model and thinking can be changed from the Paseo app too -- and the
  -- daemon changes the mode ITSELF when a plan is approved. Without this the
  -- header shows whatever we last set from here and quietly lies.
  bridge.on("settings", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if not chat then
      return
    end
    M.apply_settings(chat, payload)
  end)

  -- KEPT, not just stored, because the daemon throws these away.
  --
  -- This event rides `turn_completed`/`turn_failed`/`turn_canceled`, and it is
  -- the ONLY place the token counts and the dollar figure ever arrive: the
  -- provider's streaming `usage_updated` carries the context window and
  -- nothing else, and the daemon REPLACES `lastUsage` with it wholesale rather
  -- than merging. So the cost of a turn survives on the snapshot for about as
  -- long as it takes the next turn to start streaming, and the Usage panel
  -- spent the rest of the session drawing two empty cards. Holding the last
  -- complete turn here costs one table and is what the panel falls back to.
  bridge.on("usage", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat then
      chat.usage = payload.usage
      local turn = payload.usage or {}
      if turn.inputTokens or turn.outputTokens or turn.totalCostUsd then
        chat.last_turn_usage = turn
      end
      set_winbar(chat)
    end
  end)

  -- Turn completion comes from `turn_*`, never from a status transition to
  -- idle: idle is reached for other reasons too.
  bridge.on("turn", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat then
      -- A turn STARTING is the other half of this, and it matters because the
      -- turn need not have started here: the Paseo app, a schedule or a
      -- heartbeat can all begin one, and until the sidecar forwarded it the
      -- header stayed idle through the whole thing.
      if payload.outcome == "turn_started" then
        M.set_streaming(chat, true)
        return
      end
      M.set_streaming(chat, false)
      -- The open assistant block is finished; the next reply starts a new one
      -- rather than being appended to this answer.
      transcript.close(chat)
      -- Whatever was queued behind it goes now -- but not behind a failure
      -- or a stop, which is you or the agent saying "not like this".
      if payload.outcome == "turn_completed" then
        M.flush_queue(chat)
      elseif chat.queued then
        notice(chat, ("the turn did not finish — %d queued message(s) kept; send to deliver"):format(#chat.queued), "warning")
      end
      if payload.error then
        -- The code and the provider's own diagnostic, when it gave one: "turn
        -- failed" over nothing is a dead end, and the reason -- a session
        -- limit, a bad key -- is usually what you need to act on.
        local message = payload.error
        if payload.code and payload.code ~= vim.NIL and not tostring(message):find(payload.code, 1, true) then
          message = ("%s (%s)"):format(message, payload.code)
        end
        -- Only what the diagnostic ADDS. Daemons often restate the error and
        -- the code in it (`Usage limit reached | code=-32000`), and the same
        -- sentence twice is noise in front of the one line that matters.
        local diagnostic = payload.diagnostic ~= vim.NIL and vim.trim(tostring(payload.diagnostic or "")) or ""
        local extra = diagnostic
          :gsub(vim.pesc(tostring(payload.error)), "")
          :gsub("|?%s*code=" .. vim.pesc(tostring(payload.code or "")), "")
          :gsub("^[%s|:]+", "")
          :gsub("[%s|:]+$", "")
        if extra ~= "" then
          message = message .. "\n" .. diagnostic
        end
        transcript.upsert(chat, { kind = "notice", level = "error", message = message })
      end
    end
  end)

  bridge.on("stream_error", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat then
      M.set_streaming(chat, false)
      transcript.upsert(
        chat,
        { kind = "notice", level = "error", message = "stream error: " .. tostring(payload.error) }
      )
    end
  end)

  -- Reconnected, and nothing is replayed.
  --
  -- Saying so is not enough, and this used to say so and stop. The events
  -- missed during the gap are exactly the ones that cannot be reconstructed
  -- from what is on screen -- above all a permission ANSWERED on the desktop
  -- while the socket was down, which leaves a prompt here that is already
  -- dead and that the daemon will refuse. `replaced`, twenty lines below,
  -- always did the right thing; this is the same move, minus throwing the
  -- transcript away, because the epoch is still valid.
  bridge.on("restored", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat then
      notice(chat, "reconnected — anything said during the gap was not replayed", "warning")
      M.load_settings(chat)
      load_history(chat)
      -- The subagent stream belonged to the old socket. Follow again, and
      -- re-list: one that started or finished in the gap was never pushed.
      -- The rail's parents too, which it re-tracks as it next draws.
      require("paseo.subagents").untrack()
      require("paseo.subagents").follow(chat.agent_id, chat.host_id)
    end
  end)

  -- The epoch was replaced, so EVERYTHING on screen is stale.
  --
  -- The sidecar has always emitted this and nothing ever listened, so a
  -- replacement left a transcript of messages that no longer exist. Throw the
  -- buffer away and refetch rather than appending to a lie.
  bridge.on("replaced", function(payload)
    local chat = by_agent(payload.agentId, payload.hostId)
    if chat then
      transcript.reset(chat)
      load_history(chat)
    end
  end)
end

---Redraw the winbar after an agent setting changed.
---@param chat paseo.Chat
function M.refresh(chat)
  set_winbar(chat)
end

---Load the agent's current mode, thinking level and features into the
---winbar. Called once the agent is known, so the bar reflects reality rather
---than only what you changed from here.
---@param chat paseo.Chat
function M.load_settings(chat)
  bridge.request("agent.config", { agentId = chat.agent_id }, function(err, config)
    if err or not config then
      return
    end
    vim.schedule(function()
      -- A chat opened onto an EXISTING agent never went through
      -- `agent.ensure`, so it has no provider and the header read "…" for the
      -- whole session. The config call already knows.
      if config.provider then
        chat.provider = config.model and (config.provider .. "/" .. config.model) or config.provider
      end
      chat.usage = config.usage or chat.usage
      chat.config_snapshot = config
      chat.available_modes = config.availableModes

      chat.mode = labelled(config.availableModes, config.modeId) or chat.mode
      chat.thinking = labelled(config.thinkingOptions, config.thinkingOptionId) or chat.thinking
      chat.features = {}
      chat.feature_list = config.features or {}
      for _, feature in ipairs(config.features or {}) do
        chat.features[feature.id] = feature.value
      end

      require("paseo.ui.permission").reconcile(chat, config.pendingPermissions or {})

      set_winbar(chat)
    end)
  end, chat.host_id)
end

---@return paseo.Chat|nil
function M.current()
  return current
end

---Make `chat` the current one. For |paseo.ui.native|, whose tab pages each
---hold a chat: entering one is choosing which agent the commands act on.
---@param chat paseo.Chat|nil
function M.set_current(chat)
  current = chat
end

---The surface a name means. `"float"` and `"buffer"` were the dashboard's two
---mounts; the dashboard is gone, and both mean the native surface now -- so
---a config, a keymap or a habit that still says them lands somewhere.
---@param name string
---@return string
local function drawable(name)
  if name == "float" or name == "buffer" then
    return "native"
  end
  return name
end

M._drawable = drawable

return M
