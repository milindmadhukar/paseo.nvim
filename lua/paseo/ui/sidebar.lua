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
function M.header(chat)
  local line = {}

  -- RECORDING FIRST, because while it is true it is the only thing on this bar
  -- that is about you rather than about the agent -- and it is the state most
  -- worth being certain of. Drawn on the header rather than on the composer's
  -- own hint bar so it works on both surfaces: the dashboard's composer has no
  -- winbar at all.
  if chat.dictating then
    line[#line + 1] = { " " .. icons.ui.mic .. " ", "PaseoToolFail" }
    line[#line + 1] = { "listening ", "PaseoDim" }
  end

  -- A spinner and an elapsed count rather than a static dot: `●` looked the
  -- same at two seconds and at two minutes, so a wedged turn was
  -- indistinguishable from a working one without opening the app to check.
  local frame, seconds = require("paseo.ui.chat").progress(chat)
  if frame then
    line[#line + 1] = { " " .. frame .. " ", "PaseoToolRunning" }
    line[#line + 1] = { seconds .. "s ", "PaseoDim" }
  elseif chat.streaming then
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
  -- question, not where you write a document. It opens at its FLOOR and grows
  -- with what you type -- see `M.fit_composer`.
  vim.cmd(("belowright %dsplit"):format(math.max(1, math.floor(ui.min_composer or 3))))
  chat.win_composer = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_composer, chat.composer)
  style(chat.win_composer)
  -- No `^V image` hint. Pasting an image is now what `p` does, so it is not a
  -- key you have to be told about -- and a hint you do not need is a hint that
  -- costs you the width it occupies.
  M.refresh_hints(chat)

  -- An unrelated `:split` -- or a user's `winheight` -- must not reflow the box
  -- out from under the fit. Explicit `nvim_win_set_height` still works on a
  -- `winfixheight` window; only automatic equalisation is blocked.
  vim.wo[chat.win_composer].winfixheight = true

  chat.surface = "sidebar"
  M.refresh(chat)
  -- Cards were drawn at whatever width was current when they arrived, which for
  -- history fetched before the split existed is the fallback width.
  transcript.redraw(chat)
  -- Reopening onto a draft -- or onto a queued ref, which writes a whole
  -- prompt into the composer before you ever touch it -- should show it.
  M.fit_composer(chat)
  api.nvim_set_current_win(from)
end

---The composer's hint bar, sized to the pane.
---
---DEGRADES RATHER THAN TRUNCATES. A winbar wider than its window is cut, and
---the cut takes the LEFT -- so a sixty-column sidebar with five hints on the
---bar showed `<nd · <C-f> full screen · …`, having eaten the one thing you
---most need to know. `widgets.hints` drops whole hints off the end instead,
---which puts `send` first and leaves `close` to be the one that goes.
---@param chat table
function M.refresh_hints(chat)
  local win = chat.win_composer
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  vim.wo[win].winbar = render.to_winbar(require("paseo.ui.widgets").hints({
    { "<CR>", "send" },
    { "<C-f>", "screen" },
    { "<C-c>", "stop" },
    { "<C-t>", "speak" },
    { "q", "close" },
  }, nil, api.nvim_win_get_width(win) - 2))
end

---Grow the composer to what is in it, and shrink it back.
---
---Early-returns when the height is already right, like `ui/prompt.lua`'s
---`fit`: this runs on every keystroke in insert mode.
---
---`nvim_win_get_height` INCLUDES the winbar row -- measured -- and this
---composer carries a hint bar, so the bar is added back on top of the rows
---asked for. Without that, `min_composer = 3` would mean three rows of typing
---in the dashboard and two here, and one config key would mean two things.
---
---The `at_bottom`/`to_bottom` pair is not a nicety. Growing the composer takes
---its rows from the BOTTOM of the conversation, so without it typing a fourth
---line scrolls the agent's last sentence off the screen.
---@param chat table
function M.fit_composer(chat)
  local win, conv = chat.win_composer, chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end

  local ui = require("paseo.config").get().ui.sidebar
  local bar = (vim.wo[win].winbar or "") ~= "" and 1 or 0
  local total = api.nvim_win_get_height(win)
    + ((conv and api.nvim_win_is_valid(conv)) and api.nvim_win_get_height(conv) or 0)

  local rows = require("paseo.ui.layout").composer_rows {
    buf = chat.composer,
    win = win,
    min = math.max(1, math.floor(ui.min_composer or 3)),
    -- Never so tall that the conversation has nothing left. `total` counts the
    -- conversation's own winbar, so the five here is four lines of transcript.
    max = math.max(1, math.min(math.floor(ui.composer or 12), total - 5 - bar)),
  }

  if api.nvim_win_get_height(win) == rows + bar then
    return
  end
  local stick = transcript.at_bottom(chat)
  api.nvim_win_set_height(win, rows + bar)
  if stick then
    transcript.to_bottom(chat)
  end
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
