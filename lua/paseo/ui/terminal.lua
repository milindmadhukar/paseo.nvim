--- A Paseo terminal, rendered as a real terminal.
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

local bridge = require "paseo.bridge"
local terminals = require "paseo.terminals"

local api = vim.api

local M = {}

---The open terminal, if any. One at a time, like the permission dialog: this
---floats over the dashboard body, and two of them would cover each other.
---@type table|nil
local open_view

---@param data string  raw bytes
---@return string
local function encode(data)
  return vim.base64.encode(data)
end

---Feed bytes from the daemon into the terminal channel.
---@param payload table
local function receive(payload)
  local view = open_view
  if not view or view.id ~= payload.id or not payload.data then
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

---Register the output listener exactly once. `bridge.on` has no `off`, so a
---listener per attach would stack up one dead closure per terminal you opened.
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

---The size the PTY should run at, from the window we are rendering it in.
---@param win integer
---@return integer rows, integer cols
local function size_of(win)
  if not (win and api.nvim_win_is_valid(win)) then
    return 24, 80
  end
  return math.max(1, api.nvim_win_get_height(win)), math.max(1, api.nvim_win_get_width(win))
end

---Tell the daemon what size we are drawing at.
---@param view table
local function resize(view)
  local rows, cols = size_of(view.win)
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

---Close the open terminal, detaching from the daemon.
---
---Detaching matters more than closing the window: the daemon goes on streaming
---a terminal nobody is subscribed to otherwise, and the sidecar goes on
---base64-ing every byte of it across the pipe.
function M.close()
  local view = open_view
  if not view then
    return
  end
  open_view = nil

  if view.augroup then
    pcall(api.nvim_del_augroup_by_id, view.augroup)
  end
  bridge.request("terminals.detach", { terminalId = view.id }, function() end)

  if view.win and api.nvim_win_is_valid(view.win) then
    pcall(api.nvim_win_close, view.win, true)
  end
  if view.buf and api.nvim_buf_is_valid(view.buf) then
    pcall(api.nvim_buf_delete, view.buf, { force = true })
  end
end

---@return table|nil
function M.current()
  return open_view
end

---Open a terminal over `geometry`, attaching to its live output.
---@param terminal paseo.Terminal
---@param geometry { row: integer, col: integer, width: integer, height: integer, zindex: integer }
function M.open(terminal, geometry)
  M.close()
  listen()

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  -- The channel must exist BEFORE the daemon is asked for output, or the
  -- restore replay -- which is the entire scrollback, and the first thing that
  -- arrives -- has nowhere to go and the terminal opens blank.
  local id = terminal.id
  local chan = api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      -- Base64 rather than the raw string: this crosses a JSONL pipe and what
      -- you type is not always text -- <C-c> is 0x03, an arrow key is three
      -- bytes starting with ESC, and a pasted line can be any encoding at all.
      bridge.request("terminals.input", { terminalId = id, data = encode(data) }, function() end)
    end,
  })

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = geometry.row,
    col = geometry.col,
    width = geometry.width,
    height = geometry.height,
    style = "minimal",
    border = "none",
    zindex = geometry.zindex,
  })
  for option, value in pairs { number = false, relativenumber = false, signcolumn = "no", winbar = "" } do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end

  local view = {
    id = id,
    terminal = terminal,
    buf = buf,
    win = win,
    chan = chan,
    rows = nil,
    cols = nil,
  }
  open_view = view

  -- `q` closes, but only from NORMAL mode. In terminal mode every key belongs
  -- to the PTY -- including `q`, and including `<Esc>`, which is why the
  -- dashboard's own `<Esc>` map is never set on this buffer: vim running
  -- inside this terminal has to be able to leave insert mode. `<C-\><C-n>` is
  -- Neovim's own way out and is left exactly where people expect it.
  vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, silent = true, desc = "paseo: back to the terminal list" })
  vim.keymap.set("n", "<C-c>", M.close, { buffer = buf, nowait = true, silent = true, desc = "paseo: back to the terminal list" })

  local rows, cols = size_of(win)
  view.rows, view.cols = rows, cols

  bridge.request(
    "terminals.attach",
    { terminalId = id, rows = rows, cols = cols },
    function(err)
      if err then
        vim.schedule(function()
          vim.notify("paseo: cannot attach to that terminal — " .. tostring(err), vim.log.levels.ERROR)
          M.close()
        end)
      end
    end
  )

  view.augroup = api.nvim_create_augroup("PaseoTerminal" .. id, { clear = true })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = view.augroup,
    callback = function()
      if open_view == view then
        resize(view)
      end
    end,
  })
  -- Closed by anything other than `M.close` -- `:q`, a window manager, the
  -- dashboard going away underneath it. Without this the daemon keeps
  -- streaming into a buffer that no longer exists.
  api.nvim_create_autocmd("WinClosed", {
    group = view.augroup,
    pattern = tostring(win),
    callback = function()
      if open_view == view then
        M.close()
      end
    end,
  })

  -- Straight into terminal mode: you opened a terminal to type in it.
  vim.cmd.startinsert()
  return view
end

---Open the terminal that `id` names, if the directory still has it.
---@param id string
---@param geometry table
function M.open_id(id, geometry)
  local terminal = terminals.get(id)
  if not terminal then
    vim.notify("paseo: that terminal is gone", vim.log.levels.WARN)
    return
  end
  return M.open(terminal, geometry)
end

return M
