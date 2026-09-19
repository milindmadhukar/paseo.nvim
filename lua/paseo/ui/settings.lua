--- The session settings, on their own.
---
--- `:Paseo mode` used to be a `vim.ui.select` listing five strings with a `●`
--- glued to the front of one of them. This is the same four settings drawn the
--- same way the dashboard draws them -- because it IS the dashboard's view
--- object, at a different width, with its own window.
---
--- The open sequence below is volt's, in volt's order, and the order is not
--- negotiable:
---
---   gen_data, and only THEN read the height back out of `volt.state` -- the
---   layout measures itself, so a window sized before the layout is built is
---   sized against a guess. `volt.run` after the window exists, because it
---   writes the empty lines the extmarks anchor to. `volt.events.add` last,
---   because it is per buffer and a buffer volt has not been told about
---   silently ignores every click.

local panel = require "paseo.ui.panels.session"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---@type table|nil
local state

local XPAD = 2

---Wide enough for five permission-mode chips on one row, and never wider than
---the editor has room for.
---@return integer
local function width()
  return math.max(48, math.min(88, vim.o.columns - 8))
end

---Rows the title section occupies: the heading, the rule under it, and a
---blank. A constant because `body_lines` has to subtract it before it has
---drawn anything.
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

-- ------------------------------------------------------------------ drawing

---@return table[][]
local function title_lines()
  if not state then
    return { {} }
  end
  local chat = state.view.chat
  local inner = state.w - (2 * XPAD)

  local left = { { "󰒓  Session", "PaseoHeader" } }
  local right = {}
  if chat.provider then
    right[#right + 1] = { chat.provider, "PaseoDim" }
  end

  return {
    render.truncate(widgets.row(left, right, inner, "PaseoNormal"), inner),
    { { string.rep("─", inner), "PaseoBorder" } },
    {},
  }
end

---@return table[][]
local function body_lines()
  if not state then
    return { {} }
  end
  local rows = body_rows()
  local lines = state.view:lines(state.w - (2 * XPAD), rows)
  -- `View:lines` tightens itself to fit and usually succeeds; this is the
  -- backstop for the layout that still does not -- forty models on a
  -- twenty-row editor. Cut, rather than draw off the end of the buffer.
  while #lines > rows do
    table.remove(lines)
  end
  return lines
end

---Measure the layout into volt and report the height it wants.
---@return integer
local function measure()
  local volt = require "volt"
  volt.gen_data {
    {
      buf = state.buf,
      ns = state.ns,
      xpad = XPAD,
      layout = {
        -- Fresh tables every call: volt's `draw` strips the third element from
        -- every cell it is handed, so a cached line list loses its click
        -- targets after the first draw.
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
  return require("volt.state")[state.buf].h
end

---Measure the fitted layout.
---
---`body_lines` has already clamped itself to `body_rows()`, so what comes back
---is what will actually be drawn -- window height and buffer length agree with
---the extmark rows by construction rather than by a second clamp that the
---renderer knows nothing about.
---@return integer
local function measure_fitted()
  return math.max(6, measure())
end

---Rebuild, resize and repaint.
---
---All three, always. Volt stores each section's starting row when `gen_data`
---runs and clears nothing on redraw, so a layout that grew -- switching model
---replaces the whole thinking list -- leaves the previous draw's rows sitting
---under the new ones unless the window and the buffer's empty lines grow with
---it.
local function rebuild()
  if not (state and api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local volt = require "volt"

  -- `nvim_buf_set_lines` does not delete extmarks, it COLLAPSES them onto the
  -- last remaining line -- so a layout that shrank leaves every row it no
  -- longer has stacked on the popup's bottom row, overprinting each other
  -- forever. `float.rebuild` has always cleared; this never did.
  api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)

  local h = measure_fitted()
  if h ~= state.h then
    state.h = h
    if state.win and api.nvim_win_is_valid(state.win) then
      api.nvim_win_set_config(state.win, {
        relative = "editor",
        row = math.max(0, math.floor((vim.o.lines - h) / 2)),
        col = math.max(0, math.floor((vim.o.columns - state.w) / 2)),
        width = state.w,
        height = h,
      })
    end
  end

  vim.bo[state.buf].modifiable = true
  volt.set_empty_lines(state.buf, state.h, state.w)
  vim.bo[state.buf].modifiable = false

  volt.redraw(state.buf, "all")
end

-- ------------------------------------------------------------ open / close

function M.close()
  if not state then
    return
  end
  local held = state
  state = nil

  pcall(function()
    held.view:unbind(held.buf)
  end)

  -- volt's own teardown: it deletes the buffers, clears `volt.state` and takes
  -- them off the global key handler's list. Doing it by hand is what leaked
  -- clickable tables for the session before.
  pcall(function()
    require("volt.utils").close { bufs = { held.buf, held.backdrop } }
  end)

  for _, win in ipairs { held.win, held.backdrop_win } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

---@param chat table
---@param only? string  A group id -- draw just that one.
function M.open(chat, only)
  local volt = require "volt"

  M.close()
  require("paseo.ui.hl").setup()

  local w = width()
  local buf = api.nvim_create_buf(false, true)
  local ns = api.nvim_create_namespace "paseo.settings"

  local backdrop = api.nvim_create_buf(false, true)
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
    zindex = 55,
  })
  vim.wo[backdrop_win].winblend = 20

  state = {
    buf = buf,
    ns = ns,
    w = w,
    h = 1,
    backdrop = backdrop,
    backdrop_win = backdrop_win,
    view = panel.new(chat, {
      only = only,
      section = "session",
      hints = { { "q", "close" } },
      redraw = function()
        rebuild()
      end,
    }),
  }

  -- Measure first: `gen_data` runs every section's `lines()` and records the
  -- total, which is the only honest height for a layout whose size depends on
  -- how many models this provider has.
  state.h = measure_fitted()

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - state.h) / 2)),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    width = w,
    height = state.h,
    style = "minimal",
    border = "rounded",
    zindex = 60,
  })
  state.win = win

  -- The card look: the border glyphs are drawn in the surface's own colour, so
  -- what you see is a padding ring rather than a box. Window-local, so nothing
  -- else in the editor is repainted.
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "Normal", { link = "PaseoNormal" })
  api.nvim_set_hl(ns, "NormalFloat", { link = "PaseoNormal" })
  api.nvim_set_hl(ns, "FloatBorder", { link = "PaseoNormalBorder" })

  volt.run(buf, { h = state.h, w = w })
  -- After `volt.run`, which sets `VoltWindow`.
  vim.bo[buf].filetype = "paseo-settings"

  volt.mappings {
    bufs = { buf, backdrop },
    winclosed_event = true,
    after_close = function()
      state = nil
    end,
  }

  -- The half that makes a cell clickable with a mouse: `events.add` binds
  -- `<CR>` and `<Tab>`, and `enable` -- which `volt.run` already called -- is
  -- what routes `LeftMouse` and `MouseMove` here.
  require("volt.events").add(buf)

  state.view:bind(buf)
  vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", M.close, { buffer = buf, nowait = true, silent = true })

  -- Fetch fresh: modes, models and thinking levels are per provider and the
  -- Paseo app may have changed one under us since the last look.
  state.view:reload()
end

---@return boolean
function M.is_open()
  return state ~= nil and state.win ~= nil and api.nvim_win_is_valid(state.win)
end

return M
