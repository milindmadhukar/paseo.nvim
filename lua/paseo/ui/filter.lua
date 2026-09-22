--- The search box over a list.
---
--- One row you type into, floated over the top of the panel it is filtering,
--- which redraws under you at every keystroke. That is the whole feature: a
--- list of sessions is short enough that seeing it narrow as you type IS the
--- result, and a box that made you press `<CR>` before showing you anything
--- would be a worse telescope rather than a better list.
---
--- IT IS A REAL BUFFER, NOT `vim.ui.input`, for the reason |paseo.ui.prompt|
--- gives and one more: `vim.ui.input` is modal and blocking-shaped -- it hands
--- you the text once, at the end -- so there is no "as you type" to hang the
--- filter off, and under a custom `vim.ui.input` (dressing, noice, snacks) it
--- is somebody else's window entirely, opened wherever they put it.
---
--- The window is ONE ROW and never grows. The panel underneath is drawn by
--- volt, which records each section's start row when the layout is measured
--- and writes extmarks at those rows without clearing anything -- but this is
--- a window of our own floated over it, so it cannot disturb that. What it
--- must not do is take the panel's keys: `<Esc>` and `<CR>` end it, and
--- everything else is text.

local api = vim.api

local M = {}

---@type { buf: integer, win: integer, back: integer|nil, done: fun(text: string|nil) }|nil
local state

---Close the box and answer the caller exactly once.
---@param text string|nil  nil means cancelled -- the query goes back to what
---            it was, which is what `<Esc>` means everywhere else.
local function finish(text)
  local held = state
  state = nil
  if not held then
    return
  end

  -- Out of insert BEFORE the window goes. A window closed from insert mode
  -- leaves the editor in insert in whatever window it lands on next, which
  -- here is the chrome -- a buffer that is not modifiable, so the next
  -- keystroke answers with `E21`.
  if api.nvim_get_mode().mode ~= "n" then
    pcall(vim.cmd.stopinsert)
  end
  if api.nvim_win_is_valid(held.win) then
    pcall(api.nvim_win_close, held.win, true)
  end
  if api.nvim_buf_is_valid(held.buf) then
    pcall(api.nvim_buf_delete, held.buf, { force = true })
  end
  -- Back where the keys were. Neovim picks a window for you when a float
  -- closes and the one it picks is not reliably the one you came from -- and
  -- coming back to anything but the list means `j` after a search goes
  -- somewhere else.
  if held.back and api.nvim_win_is_valid(held.back) then
    pcall(api.nvim_set_current_win, held.back)
  end

  held.done(text)
end

---Is a box open right now?
---@return boolean
function M.active()
  return state ~= nil
end

function M.close()
  finish(nil)
end

---Open the box.
---
---`on_change` is called on every keystroke with the text as it stands, and
---`done` once at the end -- with the text on `<CR>`, with nil on `<Esc>` or on
---leaving the window. A caller that filters live wants both: the first to
---narrow the list, the second to know whether to keep the narrowing.
---`anchor` is the AREA the box floats over, not the box's own corner: it sits
---on the last three rows of it. At the top it would cover the best matches,
---which is where a fuzzy search puts the row you are aiming at. At the foot it
---covers the hint bar, and while the box is open the box IS the hint.
---@param opts { title?: string, anchor?: { row: integer, col: integer, width: integer, height?: integer }, initial?: string }
---@param handlers { on_change?: fun(text: string), done?: fun(text: string|nil) }
function M.open(opts, handlers)
  opts = opts or {}
  handlers = handlers or {}
  finish(nil)

  require("paseo.ui.hl").setup()

  local icons = require "paseo.ui.icons"
  local anchor = opts.anchor
  local width = math.max(20, math.min(anchor and anchor.width or 60, vim.o.columns - 4))
  -- Three rows: the border, the row you type on, the border.
  local ROWS = 3
  local row = anchor and (anchor.row + math.max(0, (anchor.height or ROWS) - ROWS))
    or math.max(0, math.floor(vim.o.lines / 3))
  local col = anchor and anchor.col or math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  local initial = opts.initial or ""
  api.nvim_buf_set_lines(buf, 0, -1, false, { initial })

  local back = api.nvim_get_current_win()
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    -- Above the dashboard's panes -- it is floated over the list it filters --
    -- and below the permission dialog, which must never end up behind a box
    -- somebody is typing in.
    zindex = 60,
    title = { { " " .. icons.ui.search .. " " .. (opts.title or "search") .. " ", "PaseoHeader" } },
  })
  pcall(function()
    vim.wo[win].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal,FloatBorder:PaseoBorder"
  end)

  state = { buf = buf, win = win, back = back, done = handlers.done or function() end }

  local function text()
    return (api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""):gsub("\n", "")
  end

  -- TextChangedP is in the list for the same reason the composer's grow is:
  -- a completion popup can change the buffer without either of the other two
  -- firing, and a filter that ignored that would show a list that does not
  -- match what is written above it.
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    buffer = buf,
    desc = "paseo: filter as you type",
    callback = function()
      if handlers.on_change then
        handlers.on_change(text())
      end
    end,
  })

  -- Leaving the window KEEPS the filter rather than dropping it. You left by
  -- clicking a row of the list you had just narrowed down to, and throwing the
  -- narrowing away at that moment would put the row you were aiming at back in
  -- the middle of forty others.
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    desc = "paseo: keep the filter when the box loses focus",
    callback = function()
      if state and state.buf == buf then
        local held = text()
        state.back = nil
        finish(held)
      end
    end,
  })

  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for _, mode in ipairs { "n", "i" } do
    map(mode, "<CR>", function()
      finish(text())
    end)
    map(mode, "<Esc>", function()
      finish(nil)
    end)
    map(mode, "<C-c>", function()
      finish(nil)
    end)
  end
  -- `<C-u>` clears the line rather than deleting back a word, which is what a
  -- search box does everywhere else you have used one.
  map("i", "<C-u>", function()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(win, { 1, 0 })
    if handlers.on_change then
      handlers.on_change ""
    end
  end)

  vim.cmd.startinsert()
  api.nvim_win_set_cursor(win, { 1, #initial })
  if #initial > 0 then
    -- `startinsert` puts the cursor BEFORE the character it is on; typing at
    -- the end of what is already there is what you meant by reopening it.
    vim.cmd "startinsert!"
  end
end

return M
