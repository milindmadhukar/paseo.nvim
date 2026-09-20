--- Paseo terminals, rendered as real terminals.
---
--- The daemon's terminals are PTYs, and a PTY is bytes -- escape sequences,
--- cursor moves, colour, a TUI redrawing itself. The SDK offers two ways to
--- read one: `captureTerminal`, which hands back ANSI-stripped strings, and a
--- live subscription that hands back the PTY's own output. Only the second one
--- can show you `claude` or `codex` actually running.
---
--- So this does not render a terminal; it lets Neovim do it.
--- |nvim_open_term()| gives a buffer its own libvterm instance -- the same one
--- behind `:terminal` -- so the bytes go in with `nvim_chan_send` and come out
--- as a correctly rendered screen, with colour, cursor and reflow, for free.
--- Keystrokes come back through the channel's `on_input` and go to the daemon.
---
--- This is the one surface in the plugin that is neither volt nor
--- |paseo.ui.render|. Both of those draw cells into lines; a terminal draws
--- itself, and the right amount of code between the daemon and the screen is
--- none.
---
--- A REGISTRY, NOT A VIEW. This used to hold one terminal at a time in a
--- module-local, and `open` closed whatever was there first -- so two Paseo
--- terminals could not be alive in Neovim at once, which is most of what made
--- the old Terminals tab feel like a demo. What is per TERMINAL (a buffer, a
--- libvterm channel, a subscription on the daemon) lives here, keyed by id.
--- What is per WINDOW belongs to whatever is showing it -- see
--- |paseo.ui.termfloat|.

local bridge = require "paseo.bridge"

local api = vim.api

local M = {}

---@class paseo.TerminalView
---@field id string
---@field terminal paseo.Terminal
---@field buf integer
---@field chan integer
---@field rows integer|nil
---@field cols integer|nil

---@type table<string, paseo.TerminalView>
local views = {}

---A buffer that is never deleted, to park a window on.
---
---Deleting a buffer CLOSES every window showing it, and a terminal dying is
---exactly the moment its buffer is on screen -- so detaching the one you were
---looking at took the surface down with it, which looked like the editor
---closing your terminal manager because a process exited. Every window holding
---a dying buffer is moved here first.
---@type integer|nil
local parking

---@return integer
local function park()
  if not (parking and api.nvim_buf_is_valid(parking)) then
    parking = api.nvim_create_buf(false, true)
    vim.bo[parking].bufhidden = "hide"
  end
  return parking
end

---Feed bytes from the daemon into the right terminal channel.
---@param payload table
local function receive(payload)
  local view = payload.id and views[payload.id]
  if not view or not payload.data then
    return
  end
  if not (view.buf and api.nvim_buf_is_valid(view.buf)) then
    return
  end
  local ok, bytes = pcall(vim.base64.decode, payload.data)
  if ok and bytes and #bytes > 0 then
    pcall(api.nvim_chan_send, view.chan, bytes)
  end
end

local listening = false

---Register the output listener exactly once.
---
---`bridge.on` has no `off`, so a listener per attach would stack up one dead
---closure per terminal you opened. It is also why there is a registry rather
---than a listener each: ONE handler indexing `views` by `payload.id` is the
---whole of how several attached terminals are fed at the same time.
local function listen()
  if listening then
    return
  end
  listening = true
  bridge.on("terminal_output", function(payload)
    vim.schedule(function()
      receive(payload)
    end)
  end)
end

---The size a PTY should run at, from the window it is being drawn in.
---@param win integer|nil
---@return integer rows, integer cols
local function size_of(win)
  if not (win and api.nvim_win_is_valid(win)) then
    return 24, 80
  end
  return math.max(1, api.nvim_win_get_height(win)), math.max(1, api.nvim_win_get_width(win))
end

---@return table<string, paseo.TerminalView>
function M.views()
  return views
end

---@param id string
---@return paseo.TerminalView|nil
function M.view(id)
  return views[id]
end

---The buffer and subscription for a terminal, created once.
---
---IDEMPOTENT ON PURPOSE. `terminals.attach` replays the whole scrollback as
---its first act (`restore: full-snapshot`), so attaching twice to a buffer we
---kept would print everything that terminal has ever said a second time.
---@param terminal paseo.Terminal
---@param win? integer  The window it is about to be shown in, so the first
---attach runs at the size it will be drawn at rather than at 24x80.
---@return paseo.TerminalView
function M.ensure(terminal, win)
  local id = terminal.id
  local held = views[id]
  if held and held.buf and api.nvim_buf_is_valid(held.buf) then
    held.terminal = terminal
    return held
  end

  listen()

  local buf = api.nvim_create_buf(false, true)
  -- NOT `bufhidden = "wipe"`: this buffer outlives being shown. Swapping the
  -- window to another terminal would wipe it, taking the channel and leaving
  -- the daemon streaming into nothing.
  vim.bo[buf].bufhidden = "hide"

  -- The channel must exist BEFORE the daemon is asked for output, or the
  -- restore replay -- which is the entire scrollback, and the first thing that
  -- arrives -- has nowhere to go and the terminal opens blank.
  local chan = api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      -- Base64 rather than the raw string: this crosses a JSONL pipe and what
      -- you type is not always text -- <C-c> is 0x03, an arrow key is three
      -- bytes starting with ESC, and a pasted line can be any encoding at all.
      bridge.request(
        "terminals.input",
        { terminalId = id, data = vim.base64.encode(data) },
        function() end
      )
    end,
  })

  local rows, cols = size_of(win)
  ---@type paseo.TerminalView
  local view = { id = id, terminal = terminal, buf = buf, chan = chan, rows = rows, cols = cols }
  views[id] = view

  bridge.request("terminals.attach", { terminalId = id, rows = rows, cols = cols }, function(err)
    if err then
      vim.schedule(function()
        vim.notify("paseo: cannot attach to that terminal — " .. tostring(err), vim.log.levels.ERROR)
        M.detach(id)
      end)
    end
  end)

  return view
end

---Tell the daemon what size we are drawing at. Only when it changed: a resize
---is a signal to whatever is running, and repeating it redraws a TUI for
---nothing.
---@param view paseo.TerminalView
---@param win integer|nil
function M.resize(view, win)
  if not view then
    return
  end
  local rows, cols = size_of(win)
  if rows == view.rows and cols == view.cols then
    return
  end
  view.rows, view.cols = rows, cols
  bridge.request(
    "terminals.resize",
    { terminalId = view.id, rows = rows, cols = cols },
    function() end
  )
end

---Put a terminal in a window.
---@param view paseo.TerminalView
---@param win integer
function M.show(view, win)
  if not (view and win and api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(view.buf)) then
    return
  end
  if api.nvim_win_get_buf(win) ~= view.buf then
    api.nvim_win_set_buf(win, view.buf)
  end
  for option, value in pairs { number = false, relativenumber = false, signcolumn = "no", winbar = "" } do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
  M.resize(view, win)
end

---Stop following a terminal and drop its buffer.
---
---Detaching matters more than the buffer: the daemon goes on streaming a
---terminal nobody is subscribed to otherwise, and the sidecar goes on
---base64-ing every byte of it across the pipe.
---@param id string
function M.detach(id)
  local view = views[id]
  if not view then
    return
  end
  views[id] = nil

  bridge.request("terminals.detach", { terminalId = id }, function() end)
  if view.buf and api.nvim_buf_is_valid(view.buf) then
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(win) == view.buf then
        pcall(api.nvim_win_set_buf, win, park())
      end
    end
    pcall(api.nvim_buf_delete, view.buf, { force = true })
  end
end

function M.detach_all()
  local ids = vim.tbl_keys(views)
  for _, id in ipairs(ids) do
    M.detach(id)
  end
end

return M
