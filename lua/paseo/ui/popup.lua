--- The host every settings popup is opened by.
---
--- A volt popup is not "open a window and draw in it". The sequence below is
--- volt's, in volt's order, and the order is not negotiable:
---
---   `gen_data`, and only THEN read the height back out of `volt.state` -- the
---   layout measures itself, so a window sized before the layout is built is
---   sized against a guess. `volt.run` after the window exists, because it
---   writes the empty lines the extmarks anchor to. `volt.events.add` last,
---   because it is per buffer and a buffer volt has not been told about
---   silently ignores every click.
---
--- That sequence, the clamping either side of it and the teardown after it
--- used to live in `ui/settings.lua` and nowhere else, which is why the screen
--- shown before an agent exists was a plain buffer instead of a second popup:
--- the alternative was copying a hundred and twenty lines of it. This is that
--- hundred and twenty lines, once.
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
---The LAYOUT is clamped, not just the window. Clamping only the window is
---worse than not clamping at all: `nvim_open_win` shrinks quietly, but volt
---goes on emitting extmarks at the rows `gen_data` recorded, and
---`nvim_buf_set_extmark` raises "Invalid 'line': out of range" past the last
---line of the buffer. That throw lands between opening the window and binding
---`q` to close it, which leaves an empty popup over a full-screen backdrop
---with no key that dismisses either.
---@return integer
local function body_rows()
  return math.max(3, (vim.o.lines - 4) - TITLE_ROWS)
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
  local volt = require "volt"

  require("paseo.ui.hl").setup()

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

  ---Measure the layout into volt and report the height it wants.
  local function measure()
    volt.gen_data {
      {
        buf = handle.buf,
        ns = handle.ns,
        xpad = XPAD,
        layout = {
          -- Fresh tables every call: volt's `draw` strips the third element
          -- from every cell it is handed, so a cached line list loses its
          -- click targets after the first draw.
          {
            name = "title",
            lines = function()
              return render.to_volt(title_lines())
            end,
          },
          {
            name = "session",
            lines = function()
              return render.to_volt(body_lines())
            end,
          },
        },
      },
    }
    return math.max(6, require("volt.state")[handle.buf].h)
  end

  ---Rebuild, resize and repaint. All three, always: volt stores each
  ---section's starting row when `gen_data` runs and clears nothing on redraw,
  ---so a layout that grew -- switching model replaces the whole thinking list
  ----- leaves the previous draw's rows under the new ones unless the window
  ---and the buffer's empty lines grow with it.
  function handle.rebuild()
    if handle.closed or not api.nvim_buf_is_valid(handle.buf) then
      return
    end

    -- `nvim_buf_set_lines` does not delete extmarks, it COLLAPSES them onto
    -- the last remaining line -- so a layout that shrank leaves every row it
    -- no longer has stacked on the popup's bottom row, overprinting each
    -- other forever.
    api.nvim_buf_clear_namespace(handle.buf, handle.ns, 0, -1)

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

    vim.bo[handle.buf].modifiable = true
    volt.set_empty_lines(handle.buf, handle.h, handle.w)
    vim.bo[handle.buf].modifiable = false

    volt.redraw(handle.buf, "all")
  end

  function handle.close()
    if handle.closed then
      return
    end
    handle.closed = true

    pcall(function()
      handle.view:unbind(handle.buf)
    end)

    -- volt's own teardown: it deletes the buffers, clears `volt.state` and
    -- takes them off the global key handler's list. Doing that by hand is
    -- what leaked clickable tables for the session before.
    pcall(function()
      require("volt.utils").close { bufs = { handle.buf, handle.backdrop } }
    end)

    for _, win in ipairs { handle.win, handle.backdrop_win } do
      if win and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
      end
    end

    if opts.on_close then
      opts.on_close()
    end
  end

  handle.backdrop = api.nvim_create_buf(false, true)
  handle.backdrop_win = api.nvim_open_win(handle.backdrop, false, {
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
    zindex = (opts.zindex or 60) - 5,
  })
  vim.wo[handle.backdrop_win].winblend = 20

  -- Measure first: `gen_data` runs every section's `lines()` and records the
  -- total, which is the only honest height for a layout whose size depends on
  -- how many models this provider has.
  handle.h = measure()

  handle.win = api.nvim_open_win(handle.buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - handle.h) / 2)),
    col = math.max(0, math.floor((vim.o.columns - handle.w) / 2)),
    width = handle.w,
    height = handle.h,
    style = "minimal",
    border = "rounded",
    zindex = opts.zindex or 60,
  })

  -- The card look: the border glyphs are drawn in the surface's own colour, so
  -- what you see is a padding ring rather than a box. Window-local, so nothing
  -- else in the editor is repainted.
  api.nvim_win_set_hl_ns(handle.win, handle.ns)
  api.nvim_set_hl(handle.ns, "Normal", { link = "PaseoNormal" })
  api.nvim_set_hl(handle.ns, "NormalFloat", { link = "PaseoNormal" })
  api.nvim_set_hl(handle.ns, "FloatBorder", { link = "PaseoNormalBorder" })

  volt.run(handle.buf, { h = handle.h, w = handle.w })
  -- After `volt.run`, which sets `VoltWindow`.
  vim.bo[handle.buf].filetype = opts.filetype or "paseo-settings"

  -- volt binds `q` and `<Esc>` itself and routes them through
  -- `volt.utils.close`, which force-deletes the buffer -- so the close path
  -- has to hang off `after_close` rather than off our own keymaps, or a `q`
  -- would take the window away without ever answering the caller.
  volt.mappings {
    bufs = { handle.buf, handle.backdrop },
    winclosed_event = true,
    after_close = handle.close,
  }

  -- The half that makes a cell clickable with a mouse: `events.add` binds
  -- `<CR>` and `<Tab>`, and `enable` -- which `volt.run` already called -- is
  -- what routes `LeftMouse` and `MouseMove` here.
  require("volt.events").add(handle.buf)

  handle.view:bind(handle.buf)

  for _, mapping in ipairs(opts.keys or {}) do
    vim.keymap.set("n", mapping[1], mapping[2], {
      buffer = handle.buf,
      nowait = true,
      silent = true,
      desc = mapping[3] or "paseo: popup",
    })
  end

  return handle
end

return M
