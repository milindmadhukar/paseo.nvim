--- The ask box.
---
--- A small float you type a question into, which then sends and gets out of
--- the way. The alternative -- and what this replaced -- was opening the whole
--- chat surface with the reference attached to its composer, which is a lot of
--- window for one sentence, and puts you in the conversation before you have
--- said anything.
---
--- IT IS A REAL BUFFER, NOT `vim.ui.input`, and that is the whole design. A
--- one-line input field throws away your insert-mode keymaps, completion,
--- abbreviations and undo, and it cannot hold a question with a blank line in
--- it -- which is the difference between writing a prompt and filling in a
--- form. This is the same reasoning the chat composer is built on; the box is
--- just a smaller instance of it.

local api = vim.api

local M = {}

---@type { buf: integer, win: integer, width: integer, done: fun(text: string|nil) }|nil
local state = nil

local MIN_HEIGHT = 3
local MAX_HEIGHT = 14

---Fit the box to what is in it, between MIN and MAX.
---
---Grown rather than fixed because the two things you type here have very
---different shapes: "why?" and a paragraph about an invariant. A fixed three
---rows makes the second unreadable and a fixed twelve makes the first look
---like an essay is expected.
local function fit()
  if not state or not api.nvim_win_is_valid(state.win) then
    return
  end
  local lines = api.nvim_buf_line_count(state.buf)
  local height = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, lines))
  if api.nvim_win_get_height(state.win) == height then
    return
  end

  -- Re-centred, not just resized: a box that grows downwards walks off the
  -- bottom of a short editor. Row and col are recomputed from `state.width`
  -- rather than read back from `nvim_win_get_config`, whose `col` has been
  -- both a number and a `{ [false] = n }` table across versions.
  api.nvim_win_set_config(state.win, {
    relative = "editor",
    width = state.width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - state.width) / 2)),
  })
end

---Tear the box down and answer the caller exactly once.
---@param text string|nil  nil cancels.
local function finish(text)
  local held = state
  state = nil
  if not held then
    return
  end

  if api.nvim_win_is_valid(held.win) then
    pcall(api.nvim_win_close, held.win, true)
  end
  if api.nvim_buf_is_valid(held.buf) then
    pcall(api.nvim_buf_delete, held.buf, { force = true })
  end

  held.done(text)
end

---@param width integer
---@param text string
---@return string
local function ellipsis(width, text)
  if #text <= width then
    return text
  end
  -- From the LEFT: a reference's informative half is its tail. Cutting
  -- `clm_api/app/handlers/auth.py:42-58` at the front keeps the file and the
  -- lines; cutting at the back keeps `clm_api/app/han…`, which names nothing.
  return "…" .. text:sub(#text - width + 2)
end

---Ask for a question.
---
---`callback` receives the text, or nil if you cancelled. It is called exactly
---once, and asynchronously -- the box is a window, not a blocking prompt, so
---the caller must not expect a return value.
---@param opts { title?: string, root?: string }
---@param callback fun(question: string|nil)
function M.open(opts, callback)
  opts = opts or {}
  finish(nil)

  require("paseo.ui.hl").setup()

  local width = math.max(20, math.min(vim.o.columns - 4, 78))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  -- markdown, like the composer: the question is prose with code in it, and
  -- whatever completion and keymaps you have there should work here too.
  vim.bo[buf].filetype = "markdown"
  pcall(api.nvim_buf_set_name, buf, "paseo://ask/" .. vim.fs.basename(opts.root or vim.uv.cwd()))

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = MIN_HEIGHT,
    row = math.max(0, math.floor((vim.o.lines - MIN_HEIGHT) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    -- Above the dashboard's 30, below the settings popup's 60 and well below
    -- the permission dialog's 200 -- a permission request must never end up
    -- behind a box you are typing in.
    zindex = 40,
    title = { { " ask · " .. ellipsis(width - 12, opts.title or "here") .. " ", "PaseoHeader" } },
    title_pos = "center",
    footer = { { " <CR> send · <Esc> cancel ", "PaseoDim" } },
    footer_pos = "center",
  })

  -- The card look, as everywhere else: the border glyphs are drawn in the
  -- surface's own colour, so the box reads as a padding ring rather than a
  -- framed rectangle.
  vim.wo[win].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal,FloatBorder:PaseoNormalBorder"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  state = { buf = buf, win = win, width = width, done = vim.schedule_wrap(callback) }

  local function accept()
    if not state then
      return
    end
    local text = table.concat(api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    -- An empty box is a cancel, not an empty question. Sending one costs a
    -- turn and gets you "what would you like to know?".
    if text:gsub("%s+", "") == "" then
      return finish(nil)
    end
    finish(text)
  end

  local map = function(mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, silent = true })
  end

  -- The composer's keys, so there is one thing to learn: <CR> from normal
  -- mode, <C-s> from either. <CR> is NOT bound in insert mode -- that is how
  -- you write a second paragraph.
  map("n", "<CR>", accept)
  map("n", "<C-s>", accept)
  map("i", "<C-s>", function()
    vim.cmd.stopinsert()
    accept()
  end)
  map("n", "<Esc>", function()
    finish(nil)
  end)
  map("n", "q", function()
    finish(nil)
  end)

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = fit,
    desc = "paseo: grow the ask box with the question",
  })

  -- Closed by something other than us -- `:q`, a window command, the editor
  -- resizing it out of existence -- still has to answer the caller, or the
  -- reference is queued and nothing ever sends it.
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state and state.win == win then
        finish(nil)
      end
    end,
    desc = "paseo: cancel the ask box if its window goes away",
  })

  vim.cmd.startinsert { bang = true }
end

---@return boolean
function M.is_open()
  return state ~= nil and api.nvim_win_is_valid(state.win)
end

return M
