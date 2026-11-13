--- The host every settings popup is opened by.
---
--- A centred window drawn as real lines (`render.to_buffer`), sized to its
--- layout: measured first, opened at that height, and re-fitted whenever the
--- layout grows or shrinks -- switching model replaces the whole thinking list.
---
--- It used to live in `ui/settings.lua` and nowhere else, which is why the
--- screen shown before an agent exists was a plain buffer instead of a second
--- popup. This is that code, once.
---
--- STATE LIVES ON THE HANDLE, not in this module. `settings.lua` can afford a
--- singleton -- there is one settings popup -- but |paseo.ui.create|'s review
--- is asynchronous and answers a callback, and a second popup opening over it
--- must not be able to cancel it.

local render = require "paseo.ui.render"

local api = vim.api

local M = {}

local XPAD = 2

---Rows the title section occupies: the heading, the rule under it, and a
---blank. A constant because the body has to subtract it before anything has
---been drawn.
local TITLE_ROWS = 3

---Rows the body may use.
---
---The LAYOUT is clamped, not just the window: a window shrunk quietly by
---`nvim_open_win` over a buffer drawn for more rows hides the rows that carry
---the keys you need to dismiss it.
---@return integer
local function body_rows()
  return math.max(3, (vim.o.lines - 4) - TITLE_ROWS)
end

---The window every Paseo popup and chooser is drawn in: centred, a rounded
---edge in the surface's own colour (a padding ring rather than a box), over a
---dimmed backdrop. Entered.
---@param buf integer
---@param opts { width: integer, height: integer, zindex?: integer, ns?: integer }
---@return integer win, integer backdrop_win, integer backdrop_buf
function M.frame(buf, opts)
  local zindex = opts.zindex or 60
  local backdrop = api.nvim_create_buf(false, true)
  vim.bo[backdrop].bufhidden = "wipe"
  local backdrop_win = api.nvim_open_win(backdrop, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    focusable = false,
    style = "minimal",
    border = "none",
    -- Under this window, over everything else. The permission dialog asks for
    -- 200 and must stay on top of both.
    zindex = zindex - 5,
  })
  vim.wo[backdrop_win].winblend = 20

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - opts.height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - opts.width) / 2)),
    width = opts.width,
    height = opts.height,
    style = "minimal",
    border = "rounded",
    zindex = zindex,
  })
  require("paseo.ui.style").pin(win)

  local ns = opts.ns or api.nvim_create_namespace "paseo.popup"
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "Normal", { link = "PaseoNormal" })
  api.nvim_set_hl(ns, "NormalFloat", { link = "PaseoNormal" })
  api.nvim_set_hl(ns, "FloatBorder", { link = "PaseoNormalBorder" })
  api.nvim_set_hl(ns, "CursorLine", { link = "PaseoRowHover" })
  return win, backdrop_win, backdrop
end

---Move a frame to fit a new height, still centred.
---@param win integer
---@param width integer
---@param height integer
function M.refit(win, width, height)
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_set_config, win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
    })
  end
end

---@class paseo.Popup
---@field buf integer
---@field ns integer
---@field win integer|nil
---@field w integer
---@field h integer
---@field view paseo.AgentSettingsView
---@field rebuild fun()
---@field close fun()

---Open a popup around a settings view.
---@param opts { view: paseo.AgentSettingsView, width: fun(): integer, title: fun(handle: paseo.Popup): table[][], filetype?: string, zindex?: integer, keys?: table[], on_close?: fun() }
---@return paseo.Popup
function M.open(opts)
  -- Real lines, drawn by `render.to_buffer`; every view's keys are its own
  -- (|paseo.ui.keys|).
  local plain_ns = require("paseo.ui.hl").ns

  require("paseo.ui.hl").tokens()

  local handle
  handle = {
    buf = api.nvim_create_buf(false, true),
    ns = api.nvim_create_namespace "paseo.popup",
    w = opts.width(),
    h = 1,
    view = opts.view,
    closed = false,
  }

  local function title_lines()
    return opts.title(handle)
  end

  local function body_lines()
    local rows = body_rows()
    local lines = handle.view:lines(handle.w - (2 * XPAD), rows)
    -- `View:lines` tightens itself to fit and usually succeeds; this is the
    -- backstop for the layout that still does not -- forty models on a
    -- twenty-row editor. Cut, rather than draw off the end of the buffer.
    while #lines > rows do
      table.remove(lines)
    end
    return lines
  end

  ---The whole popup as one list of lines, for the plain path.
  local function all_lines()
    local lines = {}
    local pad = { string.rep(" ", XPAD) }
    for _, list in ipairs { title_lines(), body_lines() } do
      for _, line in ipairs(list) do
        local row = { pad }
        vim.list_extend(row, render.flatten(line))
        lines[#lines + 1] = row
      end
    end
    return lines
  end

  ---The height the layout wants.
  local function measure()
    return math.max(6, #all_lines())
  end

  ---Rebuild, resize and repaint.
  function handle.rebuild()
    if handle.closed or not api.nvim_buf_is_valid(handle.buf) then
      return
    end

    -- `nvim_buf_set_lines` does not delete extmarks, it COLLAPSES them onto
    -- the last remaining line -- so a layout that shrank leaves every row it
    -- no longer has stacked on the popup's bottom row, overprinting each
    -- other forever.
    api.nvim_buf_clear_namespace(handle.buf, plain_ns, 0, -1)

    local h = measure()
    if h ~= handle.h then
      handle.h = h
      if handle.win and api.nvim_win_is_valid(handle.win) then
        api.nvim_win_set_config(handle.win, {
          relative = "editor",
          row = math.max(0, math.floor((vim.o.lines - h) / 2)),
          col = math.max(0, math.floor((vim.o.columns - handle.w) / 2)),
          width = handle.w,
          height = h,
        })
      end
    end

    render.to_buffer(handle.buf, plain_ns, 0, -1, all_lines())
    vim.bo[handle.buf].modifiable = false
  end

  function handle.close()
    if handle.closed then
      return
    end
    handle.closed = true

    pcall(function()
      handle.view:unbind(handle.buf)
    end)

    for _, win in ipairs { handle.win, handle.backdrop_win } do
      if win and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
      end
    end

    for _, buf in ipairs { handle.buf, handle.backdrop } do
      if buf and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end

    if opts.on_close then
      opts.on_close()
    end
  end

  -- Measure first: the only honest height for a layout whose size depends on
  -- how many models this provider has.
  handle.h = measure()

  handle.win, handle.backdrop_win, handle.backdrop =
    M.frame(handle.buf, { width = handle.w, height = handle.h, zindex = opts.zindex, ns = handle.ns })

  render.to_buffer(handle.buf, plain_ns, 0, -1, all_lines())
  vim.bo[handle.buf].modifiable = false
  vim.bo[handle.buf].filetype = opts.filetype or "paseo-settings"

  -- `q`/`<Esc>` close, and so does closing the window any other way.
  do
    for _, lhs in ipairs { "q", "<Esc>" } do
      vim.keymap.set("n", lhs, handle.close, { buffer = handle.buf, nowait = true, silent = true })
    end
    api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(handle.win),
      once = true,
      callback = function()
        vim.schedule(handle.close)
      end,
    })
  end

  handle.view:bind(handle.buf)

  for _, mapping in ipairs(opts.keys or {}) do
    vim.keymap.set("n", mapping[1], mapping[2], {
      buffer = handle.buf,
      nowait = true,
      silent = true,
      desc = mapping[3] or "paseo: popup",
    })
  end

  -- A POPUP THAT IS ASKING YOU SOMETHING TAKES THE CURSOR, AND KEEPS IT
  -- ACROSS THE TICK IT OPENED ON. `nvim_open_win` above enters the window,
  -- but every one of these is opened from an asynchronous callback -- the
  -- daemon answering `providers` -- and whatever the editor was in the middle
  -- of lands after it: a surface re-fitting itself, a picker restoring the
  -- window it was opened from, a composer that takes focus when its panes are
  -- rebuilt. The screen was then up with the cursor somewhere else, and the
  -- only way to answer it was to click it first. Claimed once, on the next
  -- tick, and never afterwards: a window you moved out of on purpose stays
  -- moved out of.
  vim.schedule(function()
    if handle.closed or not (handle.win and api.nvim_win_is_valid(handle.win)) then
      return
    end
    if api.nvim_get_current_win() ~= handle.win then
      -- Insert mode belongs to the window we are leaving -- a composer, or a
      -- PTY -- and the popup is not modifiable: carrying it in means every
      -- key answers `E21` instead of the question on screen.
      if api.nvim_get_mode().mode ~= "n" then
        pcall(vim.cmd.stopinsert)
      end
      pcall(api.nvim_set_current_win, handle.win)
    end
  end)

  return handle
end

return M
