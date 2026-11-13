--- The one chooser: every "pick one of these" the plugin asks.
---
--- A real buffer in the popup frame (|paseo.ui.popup|.frame), one line per
--- choice, and THE CURSOR IS THE SELECTION -- `j`/`k`, `/` and `n`, `gg`/`G`,
--- a count, the mouse: whatever moves a cursor in Neovim moves it here. `<CR>`
--- or `l` picks, `1`-`9` pick directly, `q`/`<Esc>` cancel. Verbs a list
--- offers beside picking (archive, new, review) are plain keys, listed in the
--- footer.
---
--- `select` has `vim.ui.select`'s signature, so a call site can be switched
--- by changing its module and nothing else.

local popup = require "paseo.ui.popup"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

M.FILETYPE = "paseo-choose"

---Over an ordinary popup (60) -- a chooser opened from a settings card has to
---be on top of it -- and under the permission dialog (200).
M.ZINDEX = 70

---@class paseo.ChooseItem
---@field id? any           Stable across `update`; the cursor follows it.
---@field text? string      The line. Or:
---@field cells? table[]    A line, as |paseo.ui.render| means one.
---@field right? table[]    Right-aligned cells.
---@field hl? string        Highlight for `text`. Default `PaseoText`.
---@field value? any        Handed back to `on_pick`; defaults to the item.

---@class paseo.ChooseVerb
---@field [1] string         The key.
---@field [2] string         Its label, for the footer.
---@field [3] fun(item: paseo.ChooseItem|nil, handle: paseo.Chooser)

---@class paseo.ChooseOpts
---@field title string
---@field prompt? string     A sentence under the title.
---@field items paseo.ChooseItem[]
---@field verbs? paseo.ChooseVerb[]
---@field on_pick fun(item: paseo.ChooseItem, index: integer)
---@field on_cancel? fun()
---@field empty? string      What to say when there is nothing to choose.
---@field width? integer
---@field numbers? boolean   `1`-`9` pick directly. Default: on.
---@field current? any       The id the cursor starts on.

---@class paseo.Chooser
---@field buf integer
---@field win integer
---@field update fun(items: paseo.ChooseItem[], patch?: { title?: string, prompt?: string })
---@field rows table<integer, integer>  line -> item index
---@field closed boolean
---@field close fun()
---@field current fun(): paseo.ChooseItem|nil

local ns = api.nvim_create_namespace "paseo.choose"

---@param item paseo.ChooseItem
---@return table[]
local function cells(item)
  if item.cells then
    return item.cells
  end
  return { { item.text or tostring(item.value or ""), item.hl or "PaseoText" } }
end

---The footer's keys: pick, the list's own verbs, cancel.
---@param opts paseo.ChooseOpts
---@return { [1]: string, [2]: string }[]
function M.hints(opts)
  local hints = { { "<CR>", "pick" } }
  for _, verb in ipairs(opts.verbs or {}) do
    hints[#hints + 1] = { verb[1], verb[2] }
  end
  hints[#hints + 1] = { "q", "cancel" }
  return hints
end

---How wide the chooser wants to be for these items.
---@param opts paseo.ChooseOpts
---@return integer
local function measure_width(opts)
  if opts.width then
    return math.min(opts.width, vim.o.columns - 4)
  end
  local want = vim.fn.strdisplaywidth(opts.title) + 4
  local left, right = 0, 0
  for _, item in ipairs(opts.items) do
    left = math.max(left, render.width(cells(item)))
    right = math.max(right, render.width(item.right or {}))
  end
  want = math.max(want, left + right + 10)
  -- Room for every key in the footer: a hint that does not fit is dropped,
  -- and a dropped hint is a key nobody finds.
  want = math.max(want, render.width(widgets.hints(M.hints(opts), "PaseoDim")) + 6)
  return math.max(40, math.min(want, 96, vim.o.columns - 8))
end

---The lines, and which item each row line holds.
---@param opts paseo.ChooseOpts
---@param width integer
---@return table[][] lines, table<integer, integer> rows  line -> item index
function M.lines(opts, width)
  local inner = width - 2
  local out = {}
  out[#out + 1] = { { " " .. opts.title, "PaseoHeader" } }
  if opts.prompt and opts.prompt ~= "" then
    for _, line in ipairs(render.wrap(opts.prompt, inner, "PaseoDim", { { " " } })) do
      out[#out + 1] = line
    end
  end
  out[#out + 1] = {}

  local rows = {}
  local numbers = opts.numbers ~= false
  -- The right-hand cells start at ONE column for every row, so a list whose
  -- right side is several fields reads as columns.
  local right_w = 0
  for _, item in ipairs(opts.items) do
    right_w = math.max(right_w, render.width(item.right or {}))
  end
  if #opts.items == 0 then
    out[#out + 1] = { { "   " .. (opts.empty or "nothing here"), "PaseoDim" } }
  end
  for i, item in ipairs(opts.items) do
    local lead = (numbers and i <= 9) and (" %d  "):format(i) or "    "
    local line = { { lead, "PaseoDim" } }
    local right = item.right or {}
    local left_w = math.max(4, inner - #lead - (right_w > 0 and right_w + 2 or 0))
    vim.list_extend(line, render.pad(render.truncate(cells(item), left_w), left_w))
    if right_w > 0 then
      line[#line + 1] = { "  " }
      vim.list_extend(line, render.pad(right, right_w))
    end
    out[#out + 1] = line
    rows[#out] = i
  end

  out[#out + 1] = {}
  local footer = { { " " } }
  vim.list_extend(footer, widgets.hints(M.hints(opts), "PaseoDim", inner - 1))
  out[#out + 1] = footer
  return out, rows
end

---Open a chooser.
---@param opts paseo.ChooseOpts
---@return paseo.Chooser
function M.open(opts)
  require("paseo.ui.hl").setup()

  local from = api.nvim_get_current_win()
  if api.nvim_get_mode().mode ~= "n" then
    pcall(vim.cmd.stopinsert)
  end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local handle = { buf = buf, rows = {}, closed = false }
  local width = measure_width(opts)
  local lines, rows = M.lines(opts, width)

  local function height(n)
    return math.max(3, math.min(n, vim.o.lines - 6))
  end

  local frame_ns = api.nvim_create_namespace "paseo.choose.frame"
  local win, backdrop_win = popup.frame(buf, {
    width = width,
    height = height(#lines),
    zindex = M.ZINDEX,
    ns = frame_ns,
  })
  handle.win = win
  vim.wo[win].cursorline = true
  -- The band IS the selection: a global `cursorlineopt=number` must not
  -- reduce it to a highlighted line number in a window with none.
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].wrap = false
  vim.bo[buf].filetype = M.FILETYPE

  ---The first row line at or after `line`, looking `step` ways.
  local function row_near(line, step)
    local last = api.nvim_buf_line_count(buf)
    local l = line
    while l >= 1 and l <= last do
      if handle.rows[l] then
        return l
      end
      l = l + step
    end
    return nil
  end

  local function paint(new_lines, new_rows, keep)
    vim.bo[buf].modifiable = true
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    render.to_buffer(buf, ns, 0, -1, new_lines)
    vim.bo[buf].modifiable = false
    handle.rows = new_rows
    popup.refit(win, width, height(#new_lines))

    local target
    if keep ~= nil then
      for line, index in pairs(new_rows) do
        local item = opts.items[index]
        if item.id ~= nil and item.id == keep then
          target = line
        end
      end
    end
    target = target or row_near(1, 1)
    if target and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_set_cursor, win, { target, 0 })
    end
  end

  function handle.current()
    if handle.closed or not api.nvim_win_is_valid(win) then
      return nil
    end
    -- The NEAREST row, not just the one under the cursor: a `/` match or a
    -- click on a heading has not been snapped yet when a key acts on it.
    local line = api.nvim_win_get_cursor(win)[1]
    line = handle.rows[line] and line or row_near(line, 1) or row_near(line, -1)
    local index = line and handle.rows[line]
    return index and opts.items[index] or nil, index
  end

  ---@param settle? fun()  Runs after the window is gone and focus is back.
  local function close(settle)
    if handle.closed then
      return
    end
    handle.closed = true
    for _, w in ipairs { win, backdrop_win } do
      if api.nvim_win_is_valid(w) then
        pcall(api.nvim_win_close, w, true)
      end
    end
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    if api.nvim_win_is_valid(from) then
      pcall(api.nvim_set_current_win, from)
    end
    if settle then
      settle()
    end
  end

  function handle.close()
    close(opts.on_cancel)
  end

  ---@param items paseo.ChooseItem[]
  ---@param patch? { title?: string, prompt?: string }  Change the heading too.
  function handle.update(items, patch)
    if handle.closed then
      return
    end
    local was = handle.current()
    opts.items = items
    if patch then
      opts.title = patch.title or opts.title
      opts.prompt = patch.prompt or opts.prompt
    end
    width = math.max(width, measure_width(opts))
    local l, r = M.lines(opts, width)
    paint(l, r, was and was.id)
  end

  local function pick(index)
    local item = opts.items[index]
    if not item then
      return
    end
    close(function()
      opts.on_pick(item, index)
    end)
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc })
  end
  local function step(dir)
    return function()
      local line = api.nvim_win_get_cursor(win)[1]
      for _ = 1, math.max(1, vim.v.count) do
        line = row_near(line + dir, dir) or line
      end
      pcall(api.nvim_win_set_cursor, win, { line, 0 })
    end
  end
  map("j", step(1), "next")
  map("k", step(-1), "previous")
  map("<Down>", step(1), "next")
  map("G", function()
    local last = row_near(api.nvim_buf_line_count(buf), -1)
    if last then
      pcall(api.nvim_win_set_cursor, win, { last, 0 })
    end
  end, "last")
  map("gg", function()
    local first = row_near(1, 1)
    if first then
      pcall(api.nvim_win_set_cursor, win, { first, 0 })
    end
  end, "first")
  map("<Up>", step(-1), "previous")
  local function pick_current()
    local _, index = handle.current()
    if index then
      pick(index)
    end
  end
  map("<CR>", pick_current, "pick")
  map("l", pick_current, "pick")
  map("<2-LeftMouse>", pick_current, "pick")
  map("q", handle.close, "cancel")
  map("<Esc>", handle.close, "cancel")
  if opts.numbers ~= false then
    for n = 1, math.min(9, #opts.items) do
      map(tostring(n), function()
        if opts.items[n] then
          pick(n)
        end
      end, "pick " .. n)
    end
  end
  for _, verb in ipairs(opts.verbs or {}) do
    map(verb[1], function()
      verb[3](handle.current(), handle)
    end, verb[2])
  end

  -- The cursor never rests on a heading or the footer: `/`, `G`, a click.
  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local line = api.nvim_win_get_cursor(win)[1]
      if not handle.rows[line] then
        local near = row_near(line, 1) or row_near(line, -1)
        if near then
          pcall(api.nvim_win_set_cursor, win, { near, 0 })
        end
      end
    end,
  })
  -- Leaving it is cancelling it.
  api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        close(opts.on_cancel)
      end)
    end,
  })

  paint(lines, rows, opts.current)

  -- Opened from an async callback, whatever the editor was in the middle of
  -- can land after us and take the cursor; claim it once, on the next tick.
  vim.schedule(function()
    if not handle.closed and api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win then
      if api.nvim_get_mode().mode ~= "n" then
        pcall(vim.cmd.stopinsert)
      end
      pcall(api.nvim_set_current_win, win)
    end
  end)

  return handle
end

---`vim.ui.select`, drawn as a Paseo chooser.
---@param items any[]
---@param opts? { prompt?: string, format_item?: fun(item: any): string, kind?: string, title?: string }
---@param on_choice fun(item: any|nil, index: integer|nil)
---@return paseo.Chooser
function M.select(items, opts, on_choice)
  opts = opts or {}
  local format = opts.format_item or tostring
  local entries = {}
  for i, item in ipairs(items) do
    entries[i] = { id = i, text = format(item), value = item }
  end
  local title, prompt = opts.title, nil
  if not title then
    -- A short prompt is the title; a sentence is the prompt under a title.
    local p = vim.trim((opts.prompt or "Choose"):gsub(":%s*$", ""))
    if vim.fn.strdisplaywidth(p) <= 48 then
      title = p
    else
      title, prompt = "Paseo", p
    end
  end
  local answered = false
  return M.open {
    title = title,
    prompt = prompt,
    items = entries,
    on_pick = function(entry, index)
      answered = true
      on_choice(entry.value, index)
    end,
    on_cancel = function()
      if not answered then
        answered = true
        on_choice(nil, nil)
      end
    end,
  }
end

---Yes or no. The safe answer is first, so a stray `<CR>` does nothing.
---@param prompt string
---@param opts? { yes?: string, no?: string }
---@param callback fun(yes: boolean)
---@return paseo.Chooser
function M.confirm(prompt, opts, callback)
  opts = opts or {}
  local no, yes = opts.no or "No", opts.yes or "Yes"
  return M.select({ no, yes }, { prompt = prompt }, function(choice, index)
    callback(index == 2)
  end)
end

return M
