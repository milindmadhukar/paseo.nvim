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
---@field pending string[]   Context blocks queued for the next send.

---Chats are keyed by AGENT, falling back to the directory until the agent is
---known. A workspace can hold several sessions, so keying on the directory
---alone meant the second session took over the first one's window.
---@type table<string, paseo.Chat>
local chats = {}

---@type paseo.Chat|nil
local current

local ns = vim.api.nvim_create_namespace "paseo.chat"

-- ------------------------------------------------------------------ buffers

---@param chat paseo.Chat
local function set_winbar(chat)
  if not (chat.win_conversation and vim.api.nvim_win_is_valid(chat.win_conversation)) then
    return
  end
  local where = chat.title or vim.fn.fnamemodify(chat.root, ":~")
  local who = chat.provider or "…"
  local state = chat.streaming and "  ●" or ""
  vim.wo[chat.win_conversation].winbar = ("  %s   %s%s"):format(who, where, state)
end

---@param chat paseo.Chat
---@param lines string[]
local function append(chat, lines)
  if not vim.api.nvim_buf_is_valid(chat.conversation) then
    return
  end
  vim.bo[chat.conversation].modifiable = true
  local count = vim.api.nvim_buf_line_count(chat.conversation)
  local first = count == 1 and vim.api.nvim_buf_get_lines(chat.conversation, 0, 1, false)[1] == ""
  vim.api.nvim_buf_set_lines(chat.conversation, first and 0 or count, -1, false, lines)
  vim.bo[chat.conversation].modifiable = false

  -- Follow only when already at the bottom, so scrolling back to reread
  -- something is not yanked away by the next chunk.
  local win = chat.win_conversation
  if win and vim.api.nvim_win_is_valid(win) then
    local total = vim.api.nvim_buf_line_count(chat.conversation)
    if vim.api.nvim_win_get_cursor(win)[1] >= total - #lines - 1 then
      pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
    end
  end
end

---Append streamed text, continuing the last line.
---
---Assistant messages arrive in PIECES -- a reply delivered as "READ" + "Y" must
---render as READY, not as two lines.
---@param chat paseo.Chat
---@param text string
local function stream(chat, text)
  if not vim.api.nvim_buf_is_valid(chat.conversation) then
    return
  end
  vim.bo[chat.conversation].modifiable = true

  local last = vim.api.nvim_buf_line_count(chat.conversation)
  local tail = vim.api.nvim_buf_get_lines(chat.conversation, last - 1, last, false)[1] or ""
  local incoming = vim.split(text, "\n", { plain = true })

  local replacement = { tail .. incoming[1] }
  for i = 2, #incoming do
    replacement[#replacement + 1] = incoming[i]
  end
  vim.api.nvim_buf_set_lines(chat.conversation, last - 1, last, false, replacement)
  vim.bo[chat.conversation].modifiable = false

  local win = chat.win_conversation
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(chat.conversation), 0 })
  end
end

-- ------------------------------------------------------------------ sending

---@param chat paseo.Chat
local function send(chat)
  local body = vim.api.nvim_buf_get_lines(chat.composer, 0, -1, false)
  local text = vim.trim(table.concat(body, "\n"))

  if text == "" and #chat.pending == 0 then
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

  append(chat, { "", "### you", "" })
  append(chat, vim.split(prompt, "\n"))
  append(chat, { "", "### agent", "" })

  vim.api.nvim_buf_set_lines(chat.composer, 0, -1, false, { "" })
  chat.pending = {}
  chat.streaming = true
  set_winbar(chat)

  bridge.request("agent.send", { agentId = chat.agent_id, prompt = prompt }, function(err)
    if err then
      chat.streaming = false
      vim.schedule(function()
        append(chat, { "", "_send failed: " .. err .. "_", "" })
        set_winbar(chat)
      end)
    end
  end)
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
    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", opts, { desc = "paseo: close chat" }))
    vim.keymap.set("n", "gq", function()
      M.close()
    end, vim.tbl_extend("force", opts, { desc = "paseo: close chat" }))
  end
end

---@param chat paseo.Chat
local function layout(chat)
  make_buffers(chat)

  if chat.win_conversation and vim.api.nvim_win_is_valid(chat.win_conversation) then
    vim.api.nvim_set_current_win(chat.win_composer)
    return
  end

  local from = vim.api.nvim_get_current_win()
  local width = math.max(60, math.floor(vim.o.columns * 0.4))

  vim.cmd("botright " .. width .. "vsplit")
  chat.win_conversation = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat.win_conversation, chat.conversation)
  for option, value in pairs {
    wrap = true,
    linebreak = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
  } do
    vim.wo[chat.win_conversation][option] = value
  end

  -- The composer sits under the conversation, small: it is where you type one
  -- question, not where you write a document.
  vim.cmd "belowright 8split"
  chat.win_composer = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat.win_composer, chat.composer)
  for option, value in pairs {
    wrap = true,
    linebreak = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
  } do
    vim.wo[chat.win_composer][option] = value
  end
  vim.wo[chat.win_composer].winbar = "  ↵ send · q close"

  set_winbar(chat)
  vim.api.nvim_set_current_win(from)
end

-- ------------------------------------------------------------------- history

---@param chat paseo.Chat
local function load_history(chat)
  bridge.request("timeline.history", { agentId = chat.agent_id, limit = 60 }, function(err, result)
    if err or not result then
      return
    end
    vim.schedule(function()
      local lines = {}
      for _, item in ipairs(result.items or {}) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = item.role == "user" and "### you" or "### agent"
        lines[#lines + 1] = ""
        vim.list_extend(lines, vim.split(item.text or "", "\n"))
      end
      if #lines > 0 then
        append(chat, lines)
        append(chat, { "", "---", "" })
      end
    end)
  end)
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
    chat =
      { root = root, agent_id = opts.agent_id, title = opts.title, streaming = false, pending = {} }
    chats[key] = chat
  end
  current = chat

  layout(chat)
  if opts.focus ~= false then
    vim.api.nvim_set_current_win(chat.win_composer)
  end

  if chat.agent_id then
    return callback(chat, nil)
  end

  append(chat, { "_connecting…_" })
  bridge.ensure(function(err)
    if err then
      vim.schedule(function()
        append(chat, { "", "_" .. err .. "_", "" })
      end)
      return callback(nil, err)
    end

    bridge.request("agent.ensure", {
      cwd = root,
      provider = config.get().paseo.provider,
      title = "paseo.nvim · " .. vim.fs.basename(root),
    }, function(agent_err, result)
      if agent_err then
        vim.schedule(function()
          append(chat, { "", "_" .. agent_err .. "_", "" })
        end)
        return callback(nil, agent_err)
      end

      chat.agent_id = result.id
      chat.provider = result.provider
      -- Re-key now that the agent is known, so a second session on the same
      -- directory gets its own chat rather than replacing this one.
      chats[root] = nil
      chats[result.id] = chat
      vim.schedule(function()
        -- Replace the placeholder with the real conversation.
        vim.bo[chat.conversation].modifiable = true
        vim.api.nvim_buf_set_lines(chat.conversation, 0, -1, false, {})
        vim.bo[chat.conversation].modifiable = false
        set_winbar(chat)
        load_history(chat)
      end)

      bridge.request("timeline.subscribe", { agentId = result.id }, function() end)
      callback(chat, nil)
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
  for _, win in ipairs { chat.win_composer, chat.win_conversation } do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, false)
    end
  end
  chat.win_composer, chat.win_conversation = nil, nil
end

function M.toggle()
  local chat = current
  if chat and chat.win_conversation and vim.api.nvim_win_is_valid(chat.win_conversation) then
    return M.close()
  end
  M.open {}
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

  bridge.on("text", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      stream(chat, payload.text or "")
    end
  end)

  -- Turn completion comes from `turn_*`, never from a status transition to
  -- idle: idle is reached for other reasons too.
  bridge.on("turn", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      chat.streaming = false
      append(chat, { "" })
      set_winbar(chat)
    end
  end)

  bridge.on("stream_error", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      chat.streaming = false
      append(chat, { "", "_stream error: " .. tostring(payload.error) .. "_", "" })
      set_winbar(chat)
    end
  end)

  -- Reconnected, and nothing is replayed. Say so, rather than letting the
  -- window look like the agent simply stopped talking.
  bridge.on("restored", function(payload)
    local chat = by_agent(payload.agentId)
    if chat then
      append(chat, { "", "_(reconnected — anything said during the gap was not replayed)_", "" })
    end
  end)
end

---@return paseo.Chat|nil
function M.current()
  return current
end

return M
