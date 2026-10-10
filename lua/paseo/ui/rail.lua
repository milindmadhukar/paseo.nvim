--- The workspace rail: the project's workspaces, down the left of the
--- dashboard, each with what its agents are doing.
---
--- The desktop app's sidebar, and for the same reason it has one. The
--- Workspaces tab answers "what is there" at length; this answers "which of
--- them wants me" without leaving the conversation you are in -- a spinner
--- where an agent is working, a yellow `!` where one is waiting on you, red
--- where a turn failed, green where it finished.
---
--- A REAL BUFFER IN A WINDOW OF ITS OWN, not rows spliced into the chrome.
--- The chrome is volt's, and volt resets the cursor after every click and
--- owns `<CR>` -- see |paseo.ui.list|'s header for what that cost the list
--- tabs. Here the cursor IS the selection: `j`/`k` move it, 'cursorline'
--- paints it, `<CR>` opens what it is on, and none of that needs a focus
--- model on top.
---
--- The window belongs to |paseo.ui.float|, which knows where the body is.
--- This module owns the buffer, the data and the drawing, and outlives any one
--- dashboard so the list is not refetched on every open.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.rail"

M.FILETYPE = "paseo-rail"

---@type integer|nil
local buf

---What was drawn, by buffer line: the workspace on it, or nil for a line that
---is not one (the heading, the gap under it, a message).
---@type table<integer, table>
local at_line = {}

---The last fetch. `root` is the project it was scoped to, so a fetch that
---lands after you have moved project is not drawn as this one's.
local cache = { root = nil, list = nil, err = nil, loading = false }

---Something wants to know when the list changes size -- the float, which
---redraws nothing for it but does want the spinner clock re-checked.
---@type fun()|nil
M.on_change = nil

-- -------------------------------------------------------------- visibility

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath "state", "paseo", "ui.json")
end

---@return table
local function read_state()
  local fd = io.open(state_path(), "r")
  if not fd then
    return {}
  end
  local text = fd:read "*a"
  fd:close()
  local ok, parsed = pcall(vim.json.decode, text)
  return (ok and type(parsed) == "table") and parsed or {}
end

---@param state table
local function write_state(state)
  local path = state_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if not fd then
    return
  end
  fd:write(vim.json.encode(state))
  fd:close()
end

---The rail's options: `ui.buffer.rail` on that mount if it says anything,
---`ui.float.rail` otherwise -- the same inheritance every other dashboard
---option has.
---@param mount? "float"|"buffer"
---@return { enabled: boolean, width: integer, keys: table<string, string|false> }
function M.options(mount)
  local ui = require("paseo.config").get().ui
  local opts = ui.float.rail or {}
  if mount == "buffer" and ui.buffer and ui.buffer.rail then
    opts = vim.tbl_deep_extend("force", opts, ui.buffer.rail)
  end
  return opts
end

---Read once per session and then held: the file is the memory across
---restarts, not the source of truth while one is running.
---@type boolean|nil
local shown

---Is the rail wanted? Your last toggle, or `enabled` if you have never
---pressed it.
---@return boolean
function M.visible()
  if shown == nil then
    local saved = read_state().rail
    if type(saved) == "boolean" then
      shown = saved
    else
      shown = M.options().enabled ~= false
    end
  end
  return shown
end

---@param value boolean
function M.set_visible(value)
  shown = value
  local state = read_state()
  state.rail = value
  pcall(write_state, state)
end

---For the tests: forget what was read, so the next `visible` reads again.
function M.reset()
  shown = nil
  cache = { root = nil, list = nil, err = nil, loading = false }
end

-- ------------------------------------------------------------------- data

---The project the rail lists: where you are standing, not what the chat is
---pointed at -- see |paseo.ui.panels.workspaces| for why those differ.
---@return string
local function project_root()
  return require("paseo.workspaces").here()
end

---Fetch the project's workspaces, and draw them when they land.
---
---Not pushed: the daemon has no workspace subscription the sidecar follows,
---so the rail asks when it is shown and the float asks again every so often
---while it stays up. What is pushed -- what the agents are doing -- comes from
---|paseo.agents| and needs no fetch.
---@param done? fun()
function M.load(done)
  -- NEVER THE ONE TO START THE BRIDGE. A dashboard is only ever open over a
  -- chat that has already asked for it, so a bridge that is not up yet is one
  -- that is on its way -- and the first agent snapshot it delivers asks again
  -- (`M.directory_changed`). Starting it from here would mean a list in a
  -- column was enough to spawn a sidecar and dial a daemon.
  if not require("paseo.bridge").running() then
    return
  end
  local root = project_root()
  if cache.loading and cache.root == root then
    return
  end
  if cache.root ~= root then
    cache.list = nil
  end
  cache.root, cache.loading = root, true
  local ws = require "paseo.workspaces"
  -- And the agents, which the rail draws from as much as from the list. The
  -- float's own panels ask for this when they draw; a dashboard that never
  -- left the Chat tab would otherwise have no statuses to show.
  pcall(require("paseo.agents").watch)
  ws.list(function(list, err)
    vim.schedule(function()
      if cache.root ~= root then
        return
      end
      cache.loading = false
      cache.err = err
      if list then
        cache.list = ws.scope(list, root)
      end
      M.draw()
      if done then
        done()
      end
      if M.on_change then
        M.on_change()
      end
    end)
  end)
end

-- ---------------------------------------------------------------- drawing

---The glyph and highlight for a workspace's bucket. Public so the tests can
---hold the mapping to what the desktop app draws.
---@param bucket string  |paseo.agents|.workspace_bucket's answer.
---@return string glyph, string hl
function M.status(bucket)
  if bucket == "running" then
    return widgets.spinner(), "PaseoBlue0"
  end
  if bucket == "needs_input" then
    return icons.status.waiting, "PaseoBadge"
  end
  if bucket == "failed" then
    return icons.status.idle, "PaseoToolFail"
  end
  if bucket == "attention" then
    -- Finished while you were somewhere else: news, not a problem.
    return icons.status.idle, "PaseoBlue0"
  end
  if bucket == "done" then
    return icons.status.idle, "PaseoToolOk"
  end
  -- Never opened an agent here.
  return icons.status.pending, "PaseoDim"
end

---@param ws table
---@return boolean
local function is_here(ws)
  local here = vim.fn.resolve(vim.fn.fnamemodify(vim.fn.getcwd(), ":p")):gsub("/+$", "")
  local dir = vim.fn.resolve(ws.local_directory or ws.directory or ""):gsub("/+$", "")
  return dir ~= "" and (here == dir or vim.startswith(here, dir .. "/"))
end

---The lines, as |paseo.ui.render| means a line, and what is on each.
---@param width integer
---@return table[][] lines, table<integer, table> rows
function M.lines(width)
  local agents = require "paseo.agents"
  local out, rows = {}, {}
  local name = cache.root and vim.fs.basename(cache.root) or "workspaces"
  local count = cache.list and ("  " .. #cache.list) or ""
  local title = render.truncate({ { name, "PaseoHeader" } }, math.max(1, width - #count - 1))
  title[#title + 1] = { count, "PaseoDim" }
  out[1] = title
  out[2] = {}

  if not cache.list then
    out[3] = { { cache.err and "unavailable" or "loading…", cache.err and "PaseoToolFail" or "PaseoDim" } }
    return out, rows
  end
  if #cache.list == 0 then
    out[3] = { { "no workspaces", "PaseoDim" } }
    return out, rows
  end

  for _, ws in ipairs(cache.list) do
    local here = is_here(ws)
    local glyph, hl = M.status(agents.workspace_bucket(ws.directory or "", ws.hostId))
    local line = {
      -- The bar that says "you are in this one", in the same glyph the list
      -- tabs use, so the two read as one vocabulary.
      { here and icons.marker.mine or " ", "PaseoAgent" },
      { glyph .. " ", hl },
    }
    vim.list_extend(
      line,
      render.truncate({ { ws.name or "", here and "PaseoAgent" or "PaseoText" } }, math.max(1, width - 3))
    )
    out[#out + 1] = line
    rows[#out] = ws
  end
  return out, rows
end

---The agent directory moved. Repaint, and fetch the list if there is none
---yet: the first snapshot is also the first sign the bridge is up.
function M.directory_changed()
  if not M.win() then
    return
  end
  if not cache.list and not cache.loading then
    return M.load()
  end
  M.draw()
end

---Does anything on the rail turn? The float's spinner clock asks.
---@return boolean
function M.spinning()
  if not (M.win() and cache.list) then
    return false
  end
  local agents = require "paseo.agents"
  for _, ws in ipairs(cache.list) do
    if agents.workspace_bucket(ws.directory or "", ws.hostId) == "running" then
      return true
    end
  end
  return false
end

---@type integer|nil
local win

---The rail's window, if it is up.
---@return integer|nil
function M.win()
  return win and api.nvim_win_is_valid(win) and win or nil
end

---Paint the buffer from the cache. Cheap -- a dozen short lines -- so the
---spinner clock calls it ten times a second without a second thought.
function M.draw()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local width = M.win() and api.nvim_win_get_width(win) or 28
  local lines, rows = M.lines(width)
  local text = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, cell in ipairs(line) do
      parts[#parts + 1] = cell[1]
    end
    text[i] = table.concat(parts)
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local col = 0
    for _, cell in ipairs(line) do
      local len = #cell[1]
      if cell[2] and len > 0 then
        api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = col + len, hl_group = cell[2] })
      end
      col = col + len
    end
  end
  at_line = rows

  -- KEEP THE CURSOR ON A WORKSPACE. Rewriting the lines leaves it where it
  -- was by number, which is right while the list is the same list -- and on
  -- the heading the first time, which is not.
  if M.win() then
    local line = api.nvim_win_get_cursor(win)[1]
    if not at_line[line] then
      M.seat()
    end
  end
end

---Put the cursor on the workspace you are in, or the first one.
function M.seat()
  if not M.win() then
    return
  end
  local first, mine
  for line = 1, api.nvim_buf_line_count(buf) do
    local ws = at_line[line]
    if ws then
      first = first or line
      if not mine and is_here(ws) then
        mine = line
      end
    end
  end
  local line = mine or first
  if line then
    pcall(api.nvim_win_set_cursor, win, { line, 0 })
  end
end

---The workspace under the cursor.
---@return table|nil
function M.current()
  if not M.win() then
    return nil
  end
  return at_line[api.nvim_win_get_cursor(win)[1]]
end

---Step to the next workspace row, skipping the heading.
---@param step integer
local function move(step)
  if not M.win() then
    return
  end
  local line = api.nvim_win_get_cursor(win)[1]
  local last = api.nvim_buf_line_count(buf)
  local at = line + step
  while at >= 1 and at <= last do
    if at_line[at] then
      return pcall(api.nvim_win_set_cursor, win, { at, 0 })
    end
    at = at + step
  end
end

---Open the workspace under the cursor: the full switch, tab and `tcd` and
---all, exactly as the picker does it. The chat follows you there by itself.
function M.open_current()
  local ws = M.current()
  if not ws then
    return
  end
  require("paseo.workspaces").open(ws)
end

-- ----------------------------------------------------------------- buffer

---The rail's buffer, made once and kept: it outlives the dashboard so the
---list is there the moment the next one opens.
---@param keys { back: fun(), toggle?: string|false, focus?: string|false, on_toggle: fun() }
---@return integer
function M.buf(keys)
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  pcall(api.nvim_buf_set_name, buf, "paseo://workspaces")

  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc })
    end
  end
  map("j", function()
    move(1)
  end, "next workspace")
  map("k", function()
    move(-1)
  end, "previous workspace")
  map("<Down>", function()
    move(1)
  end, "next workspace")
  map("<Up>", function()
    move(-1)
  end, "previous workspace")
  map("<CR>", M.open_current, "open this workspace")
  map("o", M.open_current, "open this workspace")
  map("<2-LeftMouse>", M.open_current, "open this workspace")
  map("r", function()
    M.load()
  end, "refetch the workspaces")
  -- Back to where you were typing. `<Esc>` too: in a list, it is "I am done
  -- here", and the dashboard's own `<Esc>` -- close everything -- would be a
  -- large answer to a small question.
  map("<Esc>", keys.back, "back to the conversation")
  map("q", keys.back, "back to the conversation")
  map(keys.focus, keys.back, "back to the conversation")
  map(keys.toggle, keys.on_toggle, "hide the workspace rail")
  api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = api.nvim_create_augroup("paseo.rail", { clear = true }),
    buffer = buf,
    desc = "paseo: the rail's cursor band only while it has focus",
    callback = function(args)
      if M.win() then
        vim.wo[win].cursorline = args.event == "WinEnter"
      end
    end,
  })
  M.draw()
  return buf
end

---Open the window over `rect`, or move the one that is up.
---@param config table  A window config: `relative`, `row`, `col`, `width`,
---                     `height`, `zindex` -- |paseo.ui.float| builds it.
---@param keys table  See `M.buf`.
function M.show(config, keys)
  local b = M.buf(keys)
  if M.win() then
    pcall(api.nvim_win_set_config, win, config)
  else
    win = api.nvim_open_win(
      b,
      false,
      vim.tbl_extend("force", { style = "minimal", border = "none", focusable = true }, config)
    )
    for option, value in pairs {
      -- `EndOfBuffer` too: under a light theme like `morning` it carries a
      -- background of its own, and every row below the list came out grey.
      winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal,EndOfBuffer:PaseoNormal,CursorLine:PaseoRowHover",
      -- Off until you are IN it. The row you are standing in already has
      -- the bar and the green; a band on it as well, while the cursor is in
      -- the composer, says the rail has focus when it does not.
      cursorline = api.nvim_get_current_win() == win,
      wrap = false,
      scrolloff = 2,
      sidescrolloff = 0,
    } do
      pcall(function()
        vim.wo[win][option] = value
      end)
    end
  end
  M.draw()
  M.seat()
  -- A list from before you moved project is the wrong list, and one that
  -- never landed is no list: fetch. Otherwise draw what is cached at once and
  -- refetch underneath it, so the rail is never blank while it asks.
  M.load()
end

function M.hide()
  if M.win() then
    pcall(api.nvim_win_close, win, true)
  end
  win = nil
end

return M
