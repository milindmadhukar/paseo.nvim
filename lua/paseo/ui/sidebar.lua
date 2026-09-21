--- The sidebar: a pane beside your code, the conversation above its composer.
---
--- One of the plugin's two surfaces. This is the everyday one -- narrow, beside
--- your code, always answerable. The other is `ui/float.lua`, which trades the
--- code view for room to show everything about the session at once.
---
--- Both are views onto the SAME `paseo.Chat`: the same conversation buffer, the
--- same composer buffer, the same block table. Switching surface therefore
--- preserves your draft and your scroll position for free, because neither
--- lives in the window.

local icons = require "paseo.ui.icons"
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
  -- Following the agent means the last line sits ON the last row. With a
  -- global `scrolloff` of 8 it cannot: the view stops eight rows early and the
  -- transcript never looks like it reached the bottom.
  scrolloff = 0,
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
---Is it working, and for how long -- as cells, or nothing when it is idle.
---
---A spinner and an elapsed count rather than a static dot: `●` looked the same
---at two seconds and at two minutes, so a wedged turn was indistinguishable
---from a working one without opening the app to check.
---
---This lives at the BOTTOM of whichever surface is drawing, beside the hint
---bar, rather than in the header. A progress readout is the thing your eye
---goes back to while you wait, and the header is where the session's SETTINGS
---are -- putting the one changing field among five static ones made the whole
---row twitch, and pushed the provider sideways every time the count gained a
---digit.
---@param chat table
---@return table[]
function M.status(chat)
  local frame, seconds = require("paseo.ui.chat").progress(chat)
  if frame then
    return {
      { frame .. " ", "PaseoToolRunning" },
      -- Humanised, because `1729s` is arithmetic homework rather than a
      -- duration -- see |paseo.ui.render|'s `duration`.
      { render.duration(seconds), "PaseoDim" },
    }
  end
  if chat.streaming then
    return { { "● ", "PaseoToolRunning" } }
  end
  return {}
end

function M.header(chat)
  local line = { { "  ", "PaseoDim" } }

  line[#line + 1] = { chat.provider or "…", "PaseoHeader" }

  if chat.mode then
    line[#line + 1] = { " · ", "PaseoDim" }
    line[#line + 1] = { chat.mode, "PaseoAgent" }
  end
  if chat.thinking then
    line[#line + 1] = { " · ", "PaseoDim" }
    line[#line + 1] = { "󰧑 " .. chat.thinking, "PaseoThinking" }
  end
  -- The daemon supplies feature names; Codex Plan and Fast are separate
  -- toggles, and future providers may add others.
  for _, feature in ipairs(chat.feature_list or {}) do
    if feature.type == "toggle" and chat.features and chat.features[feature.id] then
      line[#line + 1] = { " · " .. (feature.label or feature.id), "PaseoKey" }
    end
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
    line[#line + 1] = { "  " .. icons.status.permission .. " needs you (gp) ", "PaseoDanger" }
  end

  line[#line + 1] = { "  ", "PaseoDim" }
  line[#line + 1] = {
    chat.title or vim.fn.fnamemodify(chat.root, ":~"),
    "PaseoDim",
  }

  return line
end

---Repaint the header of whichever windows this chat currently has.
---
---On the full-screen surface the header is not a winbar at all -- it is a volt
---section in the chrome, so that it is drawn on every tab rather than only on
---the one that has a conversation window. Route to it rather than writing a
---winbar nobody would see.
---@param chat table
function M.refresh(chat)
  local float = require "paseo.ui.float"
  if float.is_open(chat) then
    return float.refresh_header(chat)
  end

  -- The sidebar has no footer to put the status in -- it is a split, and its
  -- only chrome is this winbar -- so it goes on the end of the header instead.
  -- The float, which does have a footer, draws it there.
  local line = M.header(chat)
  local status = M.status(chat)
  if #status > 0 then
    line[#line + 1] = { "  ", "PaseoDim" }
    vim.list_extend(line, status)
  end

  local bar = render.to_winbar(line)
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
  local config = require "paseo.config"
  local ui = config.get().ui.sidebar

  -- A percentage of the editor, read exactly as the float's is -- but floored
  -- in CELLS, because 40% of a 100-column terminal is a pane too narrow to
  -- read a tool card in, and a percentage has no way to know that.
  local floor = math.floor(type(ui.min_width) == "number" and ui.min_width or 60)
  local width = math.max(floor, config.cells(ui.width, vim.o.columns, 40))
  -- ...and never more than `winwidth` leaves for the window you came from.
  -- Neovim claws the difference back the instant focus returns there, so a
  -- bigger number is not a wider sidebar -- it is a number that quietly does
  -- not happen, and a 64 that silently becomes 59 is the kind of thing you
  -- spend an evening on.
  width = math.min(width, math.max(20, vim.o.columns - math.max(vim.o.winwidth, 10) - 1))

  vim.cmd(("%s %dvsplit"):format(ui.position == "left" and "topleft" or "botright", width))
  chat.win_conversation = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_conversation, chat.conversation)
  style(chat.win_conversation)

  -- The composer sits under the conversation, small: it is where you type one
  -- question, not where you write a document.
  vim.cmd(("belowright %dsplit"):format(math.max(3, math.floor(ui.composer or 8))))
  chat.win_composer = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_composer, chat.composer)
  style(chat.win_composer)
  -- No `^V image` hint. Pasting an image is now what `p` does, so it is not a
  -- key you have to be told about -- and a hint you do not need is a hint that
  -- costs you the width it occupies.
  vim.wo[chat.win_composer].winbar = render.to_winbar {
    { "  ", "PaseoDim" },
    { icons.spell "<CR>", "PaseoKey" },
    { " send · ", "PaseoDim" },
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
