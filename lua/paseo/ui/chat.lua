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
local sidebar = require "paseo.ui.sidebar"
local transcript = require "paseo.ui.transcript"

local M = {}

---@class paseo.Chat
---@field root string        Directory the agent works in.
---@field agent_id string|nil
---@field provider string|nil
---@field conversation integer  bufnr
---@field composer integer      bufnr
---@field win_conversation integer|nil
---@field win_composer integer|nil
---@field streaming boolean
---@field spinner uv.uv_timer_t|nil  Ticking only while `streaming`.
---@field frame integer|nil     Index into FRAMES.
---@field since integer|nil     `vim.uv.now()` when the turn began.
---@field pending string[]   Context blocks queued for the next send.
---@field images paseo.Image[] Pasted images, in placeholder order.
---@field seq integer|nil    Highest timeline seq rendered.
---@field epoch string|nil   The epoch those seqs belong to.
---@field initialised boolean  Subscribed, history fetched, settings loaded.

---Chats are keyed by AGENT, falling back to the directory until the agent is
---known. A workspace can hold several sessions, so keying on the directory
---alone meant the second session took over the first one's window.
---@type table<string, paseo.Chat>
local chats = {}

---@type paseo.Chat|nil
local current

---Forward declaration: `initialise` is defined below but referenced by `open`.
local initialise

-- ------------------------------------------------------------------ buffers

---Repaint the header.
---
---The header itself lives in `ui/sidebar.lua`, and the float draws the same
---cells, so the two surfaces cannot drift into disagreeing about which mode the
---session is in.
---@param chat paseo.Chat
local function set_winbar(chat)
  sidebar.refresh(chat)
end

-- ------------------------------------------------------------------ spinner

---@type string[]
local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

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
      chat.frame = (chat.frame % #FRAMES) + 1
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
  return FRAMES[chat.frame], math.floor((vim.uv.now() - (chat.since or vim.uv.now())) / 1000)
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

---@param chat paseo.Chat
local function send(chat)
  local body = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
  local text = vim.trim(table.concat(body, "\n"))

  if text == "" and #chat.pending == 0 and #chat.images == 0 then
    return
  end

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
  chat.pending = {}
  chat.images = {}
  M.set_streaming(chat, true)

  bridge.request("agent.send", {
    agentId = chat.agent_id,
    prompt = prompt,
    -- Absent rather than empty: an empty list is still a list on the wire, and
    -- the daemon should see a plain text message as a plain text message.
    images = #images > 0 and images or nil,
  }, function(err)
    if err then
      vim.schedule(function()
        M.set_streaming(chat, false)
        notice(chat, "send failed: " .. err, "error")
      end)
    end
  end)
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
local function make_buffers(chat)
  if not (chat.conversation and vim.api.nvim_buf_is_valid(chat.conversation)) then
    chat.conversation = vim.api.nvim_create_buf(false, true)
    vim.bo[chat.conversation].buftype = "nofile"
    vim.bo[chat.conversation].bufhidden = "hide"
    vim.bo[chat.conversation].filetype = "markdown"
    vim.bo[chat.conversation].modifiable = false
    pcall(
      vim.api.nvim_buf_set_name,
      chat.conversation,
      "paseo://chat/" .. vim.fs.basename(chat.root)
    )

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
    vim.keymap.set("n", "<C-f>", M.fullscreen, vim.tbl_extend("force", conv, {
      desc = "paseo: sidebar <-> full screen",
    }))

    -- Cards are drawn to the window width, so a resize leaves every box either
    -- short or wrapped. Re-render rather than live with it.
    vim.api.nvim_create_autocmd("WinResized", {
      buffer = chat.conversation,
      callback = function()
        transcript.redraw(chat)
      end,
      desc = "paseo: re-render the transcript at the new width",
    })
  end

  if not (chat.composer and vim.api.nvim_buf_is_valid(chat.composer)) then
    chat.composer = vim.api.nvim_create_buf(false, true)
    vim.bo[chat.composer].buftype = "nofile"
    vim.bo[chat.composer].bufhidden = "hide"
    vim.bo[chat.composer].filetype = "markdown"
    pcall(
      vim.api.nvim_buf_set_name,
      chat.composer,
      "paseo://compose/" .. vim.fs.basename(chat.root)
    )

    -- The composer is an ordinary buffer on purpose: your insert-mode
    -- keymaps, completion, abbreviations and undo all work, which is the
    -- difference between writing a prompt and filling in a text field.
    local opts = { buffer = chat.composer, nowait = true }
    vim.keymap.set("n", "<CR>", function()
      send(chat)
    end, vim.tbl_extend("force", opts, { desc = "paseo: send" }))
    vim.keymap.set("i", "<C-s>", function()
      vim.cmd.stopinsert()
      send(chat)
    end, vim.tbl_extend("force", opts, { desc = "paseo: send" }))
    vim.keymap.set("n", "<C-s>", function()
      send(chat)
    end, vim.tbl_extend("force", opts, { desc = "paseo: send" }))
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
      vim.keymap.set("n", key, paste(key), vim.tbl_extend("force", opts, {
        desc = "paseo: paste (an image, if the clipboard has one)",
      }))
    end
    vim.keymap.set({ "n", "i" }, "<C-v>", paste "<C-v>", vim.tbl_extend("force", opts, {
      desc = "paseo: paste (an image, if the clipboard has one)",
    }))
    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", opts, { desc = "paseo: close chat" }))
    vim.keymap.set("n", "gq", function()
      M.close()
    end, vim.tbl_extend("force", opts, { desc = "paseo: close chat" }))
    for _, mode in ipairs { "n", "i" } do
      vim.keymap.set(mode, "<C-f>", function()
        vim.cmd.stopinsert()
        M.fullscreen()
      end, vim.tbl_extend("force", opts, { desc = "paseo: sidebar <-> full screen" }))
    end
  end
end

---Put the chat on screen, on whichever surface it belongs to.
---
---`chat.surface` is where this chat WAS -- reopening keeps the surface you
---switched it to. With no answer there it is the configured default, which is
---the full-screen dashboard: that is the surface with everything on it, and
---`<C-f>` is how you get the narrow one beside your code.
---@param chat paseo.Chat
local function layout(chat)
  make_buffers(chat)
  local surface = chat.surface or require("paseo.config").get().ui.surface
  if surface == "float" then
    require("paseo.ui.float").open(chat)
  else
    sidebar.open(chat)
  end
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

---@param chat paseo.Chat
local function load_history(chat)
  bridge.request("timeline.history", { agentId = chat.agent_id, limit = 60 }, function(err, result)
    if err or not result then
      return
    end
    vim.schedule(function()
      -- History now carries the SAME item shape as the live subscription --
      -- tool calls, reasoning, todos and all -- so reopening a chat shows the
      -- work the agent did, not just the sentences it ended with.
      for _, item in ipairs(result.items or {}) do
        transcript.upsert(chat, item)
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
      -- not listening. Without this the session looks idle when it is actually
      -- waiting on an answer.
      for _, request in ipairs(result.pendingPermissions or {}) do
        require("paseo.ui.permission").offer(chat, request)
      end
    end)
  end)
end

---Everything a chat needs once its agent is known: a clean buffer, the live
---subscription, the conversation so far, and the session's current settings.
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

  -- The agent directory carries feature changes; the timeline has no feature
  -- event. Start its stream even when no workspace picker has been opened.
  require("paseo.agents").watch()

  -- Subscribe BEFORE fetching history, so nothing said in between is lost.
  -- The seq comparison in `fresh` is what stops the overlap rendering twice.
  bridge.request("timeline.subscribe", { agentId = chat.agent_id }, function()
    load_history(chat)
  end)
  M.load_settings(chat)
end

-- --------------------------------------------------------------------- API

---Open (or focus) a chat.
---@param opts? { root?: string, focus?: boolean, agent_id?: string, title?: string }
---@param callback? fun(chat: paseo.Chat|nil, err: string|nil)
function M.open(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local root = opts.root
  if not root then
    local ref = require("paseo.ref").file() or require("paseo.ref").cursor()
    root = ref and ref.root or assert(vim.uv.cwd())
  end

  local key = opts.agent_id or root
  local chat = chats[key]
  if not chat then
    chat = {
      root = root,
      agent_id = opts.agent_id,
      title = opts.title,
      streaming = false,
      pending = {},
      images = {},
    }
    chats[key] = chat
  end
  current = chat

  layout(chat)
  if opts.focus ~= false and chat.win_composer and vim.api.nvim_win_is_valid(chat.win_composer) then
    -- Not unconditional: the dashboard on any tab but Chat has no composer
    -- window at all, and `nvim_set_current_win(nil)` is an error rather than a
    -- no-op.
    vim.api.nvim_set_current_win(chat.win_composer)
  end

  -- An agent we were HANDED still needs everything an agent we created needs.
  --
  -- This used to return early when `chat.agent_id` was already set, which is
  -- exactly the case when you open an existing session from the sessions
  -- picker -- so it never subscribed, never fetched the conversation, and
  -- never loaded the mode. You got an empty window onto a session with
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
    end)
  end

  notice(chat, "connecting…")
  bridge.ensure(function(err)
    if err then
      vim.schedule(function()
        notice(chat, err, "error")
      end)
      return callback(nil, err)
    end

    local preferred = config.get().paseo.provider
    local function adopt(result)
      local known = chats[result.id]
      if known and known ~= chat then
        chats[root] = nil
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
      chats[root] = nil
      chats[result.id] = chat
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
      notice(chat, "choose session settings…")
      require("paseo.ui.create").review({ cwd = root, preferred = preferred }, function(draft, review_err)
        if review_err then
          notice(chat, review_err, "error")
          return callback(nil, review_err)
        end
        if not draft then
          chats[root] = nil
          if current == chat then
            M.close()
          end
          return callback(nil, "cancelled")
        end
        bridge.request("agent.ensure", {
          cwd = root,
          provider = draft.provider,
          modeId = draft.modeId,
          thinkingOptionId = draft.thinkingOptionId,
          featureValues = draft.featureValues,
          title = "paseo.nvim · " .. vim.fs.basename(root),
        }, function(agent_err, result)
          if agent_err then
            notice(chat, agent_err, "error")
            return callback(nil, agent_err)
          end
          config.get().paseo.provider = draft.provider
          adopt(result)
        end)
      end)
    end)
  end)
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
  require("paseo.ui.float").close()
  sidebar.close(chat)
end

function M.toggle()
  local chat = current
  if chat and (sidebar.is_open(chat) or require("paseo.ui.float").is_open(chat)) then
    return M.close()
  end
  M.open {}
end

---Put the chat on a named surface, keeping the conversation and the draft.
---
---Both live on the chat rather than in a window, so this is genuinely just a
---matter of closing one set of windows and opening another.
---@param name "float"|"sidebar"
function M.surface(name)
  local chat = current
  if not chat then
    return M.open({}, function(opened)
      if opened then
        M.surface(name)
      end
    end)
  end

  local float = require "paseo.ui.float"
  if name == "sidebar" then
    float.close()
    chat.surface = "sidebar"
    sidebar.open(chat)
  else
    sidebar.close(chat)
    chat.surface = "float"
    float.open(chat)
  end
end

---`<C-f>`: swap to the other surface.
function M.fullscreen()
  local chat = current
  if chat and require("paseo.ui.float").is_open(chat) then
    return M.surface "sidebar"
  end
  return M.surface "float"
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
  local function by_agent(agent_id)
    for _, chat in pairs(chats) do
      if chat.agent_id == agent_id then
        return chat
      end
    end
    return nil
  end

  ---Render an item, if it is not something history already covered.
  ---@param payload table
  local function ingest(payload)
    local chat = by_agent(payload.agentId)
    if chat and fresh(chat, payload) then
      transcript.upsert(chat, payload)
    end
  end

  -- A user message, from wherever it was typed: here, the Paseo app, another
  -- client. This is what makes the two views the same conversation.
  bridge.on("user", function(payload)
    local chat = by_agent(payload.agentId)
    if not chat or not fresh(chat, payload) then
      return
    end
    transcript.upsert(chat, { kind = "user", text = payload.text or "" })
    M.set_streaming(chat, true)
  end)

  bridge.on("text", function(payload)
    local chat = by_agent(payload.agentId)
    if chat and fresh(chat, payload) then
      transcript.stream(chat, payload.text or "")
    end
  end)

  -- THE MISSING HALF. Reasoning, tool calls, todos, notices and compaction all
  -- reach Neovim now; before this they were dropped at the sidecar and the
  -- window showed a long silence while the agent read files and ran commands.
  for _, event in ipairs { "thinking", "tool", "todo", "notice", "compaction" } do
    bridge.on(event, ingest)
  end

  -- A permission request. The agent is BLOCKED until this is answered.
  bridge.on("permission", function(payload)
    local chat = by_agent(payload.agentId)
    if chat and payload.request then
      require("paseo.ui.permission").offer(chat, payload.request)
    end
  end)

  bridge.on("permission_resolved", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      require("paseo.ui.permission").resolved(chat, payload.requestId, payload.resolution)
    end
  end)

  -- Mode, model and thinking can be changed from the Paseo app too. Without
  -- this the header shows whatever we last set ourselves and quietly lies.
  bridge.on("settings", function(payload)
    local chat = by_agent(payload.agentId)
    if not chat then
      return
    end
    if payload.modeId then
      chat.mode = payload.modeId
    end
    if payload.thinkingOptionId then
      chat.thinking = payload.thinkingOptionId
    end
    if payload.model then
      chat.provider = (payload.provider or chat.provider or "?") .. "/" .. payload.model
    end
    set_winbar(chat)
  end)

  -- Feature toggles have no timeline event. Agent updates arrive separately;
  -- debounce the config read because one turn can produce many updates.
  bridge.on("agent_updated", function(payload)
    local chat = by_agent(payload.agentId)
    if not chat or chat.settings_refresh_pending then
      return
    end
    chat.settings_refresh_pending = true
    vim.defer_fn(function()
      chat.settings_refresh_pending = false
      if chat.agent_id then
        M.load_settings(chat)
      end
    end, 150)
  end)

  bridge.on("usage", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      chat.usage = payload.usage
      set_winbar(chat)
    end
  end)

  -- Turn completion comes from `turn_*`, never from a status transition to
  -- idle: idle is reached for other reasons too.
  bridge.on("turn", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      M.set_streaming(chat, false)
      -- The open assistant block is finished; the next reply starts a new one
      -- rather than being appended to this answer.
      chat.open_text = nil
      if payload.error then
        transcript.upsert(chat, { kind = "notice", level = "error", message = payload.error })
      end
    end
  end)

  bridge.on("stream_error", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      M.set_streaming(chat, false)
      transcript.upsert(
        chat,
        { kind = "notice", level = "error", message = "stream error: " .. tostring(payload.error) }
      )
    end
  end)

  -- Reconnected, and nothing is replayed. Say so, rather than letting the
  -- window look like the agent simply stopped talking.
  bridge.on("restored", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      notice(chat, "reconnected — anything said during the gap was not replayed", "warning")
    end
  end)

  -- The epoch was replaced, so EVERYTHING on screen is stale.
  --
  -- The sidecar has always emitted this and nothing ever listened, so a
  -- replacement left a transcript of messages that no longer exist. Throw the
  -- buffer away and refetch rather than appending to a lie.
  bridge.on("replaced", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      transcript.reset(chat)
      load_history(chat)
    end
  end)
end

---Redraw the winbar after a session setting changed.
---@param chat paseo.Chat
function M.refresh(chat)
  set_winbar(chat)
end

---Load the session's current mode, thinking level and features into the
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
        chat.provider = config.model and (config.provider .. "/" .. config.model)
          or config.provider
      end
      chat.usage = config.usage or chat.usage
      chat.config_snapshot = config

      for _, mode in ipairs(config.availableModes or {}) do
        if mode.id == config.modeId then
          chat.mode = mode.label or mode.id
        end
      end
      for _, option in ipairs(config.thinkingOptions or {}) do
        if option.id == config.thinkingOptionId then
          chat.thinking = option.label or option.id
        end
      end
      chat.features = {}
      chat.feature_list = config.features or {}
      for _, feature in ipairs(config.features or {}) do
        chat.features[feature.id] = feature.value
      end

      for _, request in ipairs(config.pendingPermissions or {}) do
        require("paseo.ui.permission").offer(chat, request)
      end

      set_winbar(chat)
    end)
  end)
end

---@return paseo.Chat|nil
function M.current()
  return current
end

return M
