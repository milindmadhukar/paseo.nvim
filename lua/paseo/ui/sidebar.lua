--- The sidebar: a pane on the right, the conversation above its composer.
---
--- One of the plugin's two surfaces. This is the everyday one -- narrow, beside
--- your code, always answerable. The other is `ui/float.lua`, which trades the
--- code view for room to show everything about the session at once.
---
--- Both are views onto the SAME `paseo.Chat`: the same conversation buffer, the
--- same composer buffer, the same block table. Switching surface therefore
--- preserves your draft and your scroll position for free, because neither
--- lives in the window.

local render = require "paseo.ui.render"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

---Window options shared by both panes. `wrap` matters: a long reply in a 60
---column pane is unreadable without it, and the transcript is real text, so it
---actually wraps.
local WINDOW = {
  wrap = true,
  linebreak = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = false,
  list = false,
}

---@param win integer
local function style(win)
  for option, value in pairs(WINDOW) do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
end

-- -------------------------------------------------------------------- header

---The status line above the conversation, as cells.
---
---Exposed because the float draws the same information through volt, and two
---headers that drift apart is how a UI starts lying about which mode it is in.
---@param chat table
---@return table[]
function M.header(chat)
  local line = {}

  if chat.streaming then
    line[#line + 1] = { " ● ", "PaseoToolRunning" }
  else
    line[#line + 1] = { "  ", "PaseoDim" }
  end

  line[#line + 1] = { chat.provider or "…", "PaseoHeader" }

  if chat.mode then
    line[#line + 1] = { " · ", "PaseoDim" }
    line[#line + 1] = { chat.mode, "PaseoAgent" }
  end
  if chat.thinking then
    line[#line + 1] = { " · ", "PaseoDim" }
    line[#line + 1] = { "󰧑 " .. chat.thinking, "PaseoThinking" }
  end
  -- The lightning bolt, same as the app's.
  if chat.features and chat.features.fast_mode then
    line[#line + 1] = { " ⚡", "PaseoKey" }
  end

  -- Context-window fill, once the daemon has reported any. This is the number
  -- you actually want in front of you during a long session.
  local usage = chat.usage
  if usage and usage.contextWindowUsedTokens and usage.contextWindowMaxTokens then
    local pct = math.floor((usage.contextWindowUsedTokens / usage.contextWindowMaxTokens) * 100)
    line[#line + 1] = { " · ", "PaseoDim" }
    line[#line + 1] = {
      ("%d%%"):format(pct),
      pct >= 90 and "PaseoToolFail" or pct >= 70 and "PaseoToolRunning" or "PaseoDim",
    }
  end

  -- Something is waiting on you. Worth shouting about: the agent is blocked
  -- until it is answered.
  if chat.permissions and #chat.permissions > 0 then
    line[#line + 1] = { "   needs you (gp) ", "PaseoDanger" }
  end

  line[#line + 1] = { "  ", "PaseoDim" }
  line[#line + 1] = {
    chat.title or vim.fn.fnamemodify(chat.root, ":~"),
    "PaseoDim",
  }

  return line
end

---Repaint the header of whichever windows this chat currently has.
---@param chat table
function M.refresh(chat)
  local bar = render.to_winbar(M.header(chat))
  for _, win in ipairs { chat.win_conversation } do
    if win and api.nvim_win_is_valid(win) then
      pcall(function()
        vim.wo[win].winbar = bar
      end)
    end
  end
end

-- -------------------------------------------------------------------- layout

---Open the sidebar, or focus it if it is already up.
---@param chat table
function M.open(chat)
  if chat.win_conversation and api.nvim_win_is_valid(chat.win_conversation) then
    if chat.win_composer and api.nvim_win_is_valid(chat.win_composer) then
      api.nvim_set_current_win(chat.win_composer)
    end
    return
  end

  local from = api.nvim_get_current_win()
  local width = math.max(60, math.floor(vim.o.columns * 0.4))

  vim.cmd("botright " .. width .. "vsplit")
  chat.win_conversation = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_conversation, chat.conversation)
  style(chat.win_conversation)

  -- The composer sits under the conversation, small: it is where you type one
  -- question, not where you write a document.
  vim.cmd "belowright 8split"
  chat.win_composer = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_composer, chat.composer)
  style(chat.win_composer)
  vim.wo[chat.win_composer].winbar = render.to_winbar {
    { "  ", "PaseoDim" },
    { "↵", "PaseoKey" },
    { " send · ", "PaseoDim" },
    { "^V", "PaseoKey" },
    { " image · ", "PaseoDim" },
    { "<C-f>", "PaseoKey" },
    { " full screen · ", "PaseoDim" },
    { "q", "PaseoKey" },
    { " close", "PaseoDim" },
  }

  chat.surface = "sidebar"
  M.refresh(chat)
  -- Cards were drawn at whatever width was current when they arrived, which for
  -- history fetched before the split existed is the fallback width.
  transcript.redraw(chat)
  api.nvim_set_current_win(from)
end

---@param chat table
function M.close(chat)
  for _, win in ipairs { chat.win_composer, chat.win_conversation } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, false)
    end
  end
  chat.win_composer, chat.win_conversation = nil, nil
end

---@param chat table
---@return boolean
function M.is_open(chat)
  return (chat.win_conversation and api.nvim_win_is_valid(chat.win_conversation)) and true or false
end

return M
