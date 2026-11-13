--- EXPERIMENTAL. The native surface: the chat out of real splits and nothing
--- else -- no floats over your code, no frame drawn around it.
---
--- ONE TAB PAGE, THE PASEO TAB. Your code is on the tab you came from; Paseo
--- is this one, and `:Paseo native` goes back and forth between the two. You
--- never `gt` to it, and nothing here opens a tab of its own:
---
---   ┌ rail ┬ conversation (winbar: agent · status · keys) ┬ panel ┐
---   │      ├ composer (its own bar: model, mode, the spinner) │       │
---
--- EVERY AGENT YOU OPEN IS A BUFFER. Open an agent or a terminal -- from
--- the rail, the picker, anywhere -- and it is a listed buffer on the Paseo
--- tab, so a bufferline shows what you have open the way the app shows its
--- row of agent tabs, and moving between them is moving between buffers. Any
--- workspace's, side by side, in the order you opened them. Nothing is
--- opened for you and nothing is closed for you: `:bdelete` takes one off,
--- `q` closes the tab.
---
--- The middle window holds the one you are looking at; the composer under
--- it, and the tab's directory (`:tcd`), follow whichever is put there.
--- Leaving the Paseo tab unlists them, so they never show up among your
--- code's buffers; coming back lists them again.
---
--- A SUBAGENT IS A PEEK. It is shown in the middle window in place of its
--- parent, unlisted -- it is not one of the agents you opened -- and `q`
--- goes back to the parent.
---
--- The rail is |paseo.ui.rail|'s buffer. The conversation and composer are
--- the chat's own buffers, exactly as the sidebar shows them. The panel is
--- Settings, Changes or Usage (`ui/panels/`), drawn as real lines by
--- |paseo.ui.render|. `<C-p>` toggles it; `1` `2` `3` in it pick which.
---
--- In MARKDOWN mode (`ui.native.markdown`, on by default) the agent's prose
--- is written as raw markdown and soft-wrapped, so treesitter -- and
--- render-markdown.nvim, if it is installed -- draws headings, fences, lists and
--- tables. Tool cards keep their box drawing.

local render = require "paseo.ui.render"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.native"

---The Paseo tab: the windows it is made of, what is in them, and which
---workspace's agents are its buffers.
---@class paseo.NativeSurface
---@field tab integer
---@field conv integer          The middle window.
---@field comp integer|nil      The composer under it; closed while a terminal
---                             is in the middle.
---@field rail integer|nil
---@field panel_win integer|nil
---@field panel_buf integer|nil
---@field panel string|nil
---@field chat table|nil        The chat in the middle, or the last one there
---                             while a terminal is.
---@field set table[]           The chats you opened, in the order you did.
---@field terms table[]         The terminals you opened: `{ id, host_id, title, buf }`.
---@field peek { parent: table, buf?: integer }|nil  A subagent in the middle.
---@field swapping boolean|nil  Set while this module moves buffers itself.
---@field rail_from integer|nil The window the cursor left for the rail.

---@type paseo.NativeSurface|nil
local S

---The tab you last left for the Paseo tab: where `:Paseo native` goes back to.
local origin

---The panels, in the order of their number keys (`1` `2` `3` in the panel),
---and the module that draws each one.
M.PANELS = { "Settings", "Changes", "Usage" }

---The panel `<C-p>` reopens: the one you last looked at, per session.
local last_panel = "Settings"

---The surface's own keys (`ui.native.keys`): each a key, a list, or false.
---@return { rail: any, focus: any, sessions: any, panel: any, new: any }
local function nkeys()
  return require("paseo.config").get().ui.native.keys or {}
end

local function config()
  return require("paseo.config").get().ui.native
end

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

---The Paseo tab, while it is still up.
---@return paseo.NativeSurface|nil
local function surface()
  if not S then
    return nil
  end
  if not api.nvim_tabpage_is_valid(S.tab) or not valid_win(S.conv) then
    return nil
  end
  if api.nvim_win_get_tabpage(S.conv) ~= S.tab then
    return nil
  end
  return S
end

---The Paseo tab, only if it is the tab you are looking at.
---@return paseo.NativeSurface|nil
local function here()
  local s = surface()
  if s and api.nvim_get_current_tabpage() == s.tab then
    return s
  end
  return nil
end

---The chat in the middle of the Paseo tab, if that is the tab you are on.
---@return table|nil
function M.chat()
  local s = here()
  return s and s.chat or nil
end

---Is `chat` the one in the middle of the Paseo tab, on any tab page?
---@param chat table
---@return boolean
function M.has(chat)
  local s = surface()
  return s ~= nil and chat ~= nil and s.chat == chat and valid_win(chat.win_conversation)
end

---Is `chat` in the middle of the Paseo tab, and is that the tab you are on?
---@param chat table
---@return boolean
function M.is_open(chat)
  return M.has(chat) and here() ~= nil
end

---Is the Paseo tab up?
---@return boolean
function M.any()
  return surface() ~= nil
end

---The Paseo tab's page, if it is up.
---@return integer|nil
function M.tab()
  local s = surface()
  return s and s.tab or nil
end

---The chats listed as buffers -- the workspace's agents -- in order.
---@return table[]
function M.listed()
  local s = surface()
  return s and vim.list_slice(s.set) or {}
end

-- ------------------------------------------------------------------ windows

---Every pane of this surface on the BASE tier (|paseo.ui.theme|'s
---`PaseoBase`): the editor's own background under `ui.colors = "auto"`, the
---plugin's under `"fixed"` -- the same one for every pane either way. The
---box you type in is the one exception, a step raised (|paseo.ui.composer|).
M.WINHL = table.concat({
  "Normal:PaseoBase",
  "NormalNC:PaseoBase",
  "EndOfBuffer:PaseoBase",
  "WinSeparator:PaseoBaseSeparator",
  "WinBar:PaseoBase",
  "WinBarNC:PaseoBase",
}, ",")

local CONVERSATION = {
  wrap = true,
  linebreak = true,
  breakindent = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  scrolloff = 0,
  foldcolumn = "0",
  cursorline = false,
  list = false,
  -- render-markdown conceals the markers it replaces; treesitter alone hides
  -- link targets and the backticks round code.
  conceallevel = 2,
  concealcursor = "",
  -- No `~` down an empty conversation.
  fillchars = "eob: ",
  winhl = M.WINHL,
}

local function set_options(win, options)
  for option, value in pairs(options) do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
end

---Put `buf` in `win` without this module's own BufWinEnter reacting to it.
---@param win integer
---@param buf integer
local function put(win, buf)
  if api.nvim_win_get_buf(win) == buf then
    return
  end
  local s = S
  local was = s and s.swapping
  if s then
    s.swapping = true
  end
  pcall(api.nvim_win_set_buf, win, buf)
  if s then
    s.swapping = was
  end
end

-- ------------------------------------------------------------------ buffers

---Every buffer the workspace is listed as: its agents', then its terminals'.
---@param s paseo.NativeSurface
---@return integer[]
local function buffers(s)
  local out = {}
  for _, chat in ipairs(s.set) do
    if valid_buf(chat.conversation) then
      out[#out + 1] = chat.conversation
    end
  end
  for _, term in ipairs(s.terms) do
    if valid_buf(term.buf) then
      out[#out + 1] = term.buf
    end
  end
  return out
end

---Defined below, with the rest of the row's bookkeeping.
local order

---List or unlist the workspace's buffers.
---
---In order, and only while the Paseo tab is the current one: a per-tab
---bufferline (NvChad's tabufline keeps `t:bufs`) records a buffer on the tab
---it was listed on, so listing them from your code's tab would put the agents
---on THAT tab's row.
---@param s paseo.NativeSurface
---@param on boolean
local function set_listed(s, on)
  for _, buf in ipairs(buffers(s)) do
    if vim.bo[buf].buflisted ~= on then
      pcall(function()
        vim.bo[buf].buflisted = on
      end)
    end
  end
  if on then
    order(s)
    pcall(vim.cmd, "redrawtabline")
  end
end

---One more buffer in the set, listed straight away when you are on the tab.
---@param s paseo.NativeSurface
---@param buf integer
local function list_one(s, buf)
  if valid_buf(buf) and api.nvim_get_current_tabpage() == s.tab and not vim.bo[buf].buflisted then
    pcall(function()
      vim.bo[buf].buflisted = true
    end)
  end
end

---@param s paseo.NativeSurface
---@param chat table
---@return integer|nil
local function index_of(s, chat)
  for i, c in ipairs(s.set) do
    if c == chat then
      return i
    end
  end
  return nil
end

---@param s paseo.NativeSurface
---@param chat table
local function add(s, chat)
  if not index_of(s, chat) then
    s.set[#s.set + 1] = chat
  end
  require("paseo.ui.chat").name_conversation(chat)
  list_one(s, chat.conversation)
end

---A per-tab bufferline's own list (NvChad's `t:bufs`, which records buffers
---as they are listed) kept in the row's order -- the order you opened them
---in -- through the unlisting and relisting of leaving and coming back.
---@param s paseo.NativeSurface
order = function(s)
  if api.nvim_get_current_tabpage() ~= s.tab or type(vim.t.bufs) ~= "table" then
    return
  end
  local ours, mine = buffers(s), {}
  for _, buf in ipairs(ours) do
    mine[buf] = true
  end
  local present = {}
  for _, buf in ipairs(vim.t.bufs) do
    present[buf] = true
  end
  local out, placed = {}, false
  for _, buf in ipairs(vim.t.bufs) do
    if not mine[buf] then
      out[#out + 1] = buf
    elseif not placed then
      placed = true
      for _, b in ipairs(ours) do
        if present[b] then
          out[#out + 1] = b
        end
      end
    end
  end
  vim.t.bufs = out
end

---The terminal entry for a buffer of the set.
---@param s paseo.NativeSurface
---@param buf integer
---@return table|nil
local function term_of(s, buf)
  for _, term in ipairs(s.terms) do
    if term.buf == buf then
      return term
    end
  end
  return nil
end

---A name for a terminal's buffer: `paseo://terminal/<title>`.
---@param term table
local function name_term(term)
  local title = vim.trim(((term.title or "terminal"):gsub("[/\\]", "\u{2215}"):gsub("%s+", " ")))
  local want = "paseo://terminal/" .. (title ~= "" and title or "terminal")
  if vim.b[term.buf].paseo_named == want then
    return
  end
  for n = 1, 50 do
    if pcall(api.nvim_buf_set_name, term.buf, n == 1 and want or ("%s (%d)"):format(want, n)) then
      break
    end
  end
  vim.b[term.buf].paseo_named = want
end

---A terminal of the workspace, as a buffer. The PTY is not attached until
---the buffer is first shown -- a workspace with five terminals is five
---streams nobody asked to watch yet -- so it starts as an empty, named
---buffer that becomes the terminal in place, keeping its spot on the row.
---@param s paseo.NativeSurface
---@param terminal table
---@param host_id string|nil
local function add_term(s, terminal, host_id)
  for _, term in ipairs(s.terms) do
    if term.id == terminal.id then
      return term
    end
  end
  host_id = terminal.hostId or host_id
  local view = require("paseo.ui.terminal").view(terminal.id, host_id)
  local term = {
    id = terminal.id,
    host_id = host_id,
    -- The rail's name for it, not the shell's window title (`user@host:~/…`,
    -- the same for every terminal and too long for a tab).
    title = require("paseo.terminals").label(terminal, host_id),
    terminal = terminal,
  }
  if view and valid_buf(view.buf) then
    term.buf = view.buf
  else
    term.buf = api.nvim_create_buf(false, true)
    vim.bo[term.buf].bufhidden = "hide"
    vim.bo[term.buf].swapfile = false
  end
  vim.b[term.buf].paseo_terminal_id = terminal.id
  name_term(term)
  s.terms[#s.terms + 1] = term
  list_one(s, term.buf)
  return term
end

-- ------------------------------------------------------------------ leaving

---Out of the Paseo tab, back to the code: the tab you came from if it is
---still there, else any other, else a fresh one. The Paseo tab stays, so
---`:Paseo native` again lands straight back on it.
function M.leave()
  local s = surface()
  local paseo = s and s.tab
  if origin and api.nvim_tabpage_is_valid(origin) and origin ~= paseo then
    api.nvim_set_current_tabpage(origin)
    return
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if tab ~= paseo then
      api.nvim_set_current_tabpage(tab)
      return
    end
  end
  -- The Paseo tab is the only one: your code gets a tab back. This is the
  -- one tab this module ever makes besides its own.
  vim.cmd "tabnew"
end

---Open `file` with your code: back on the tab you came from, in a window
---there that holds a file, as an ordinary buffer among your others.
---@param file string
function M.edit(file)
  M.leave()
  local function plain(win)
    local buf = api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == "" and api.nvim_win_get_config(win).relative == ""
  end
  if not plain(api.nvim_get_current_win()) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if plain(win) then
        api.nvim_set_current_win(win)
        break
      end
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(file))
end

---Focus the box you type in.
function M.back()
  local s = here()
  if s and valid_win(s.comp) then
    api.nvim_set_current_win(s.comp)
  elseif s then
    api.nvim_set_current_win(s.conv)
  end
end

-- --------------------------------------------------------------------- rail

---Keys the rail's buffer is built with, when native builds it first.
local function rail_keys()
  local keys = nkeys()
  return {
    back = function()
      M.from_rail()
    end,
    toggle = keys.rail,
    focus = keys.focus,
    sessions = keys.sessions,
    on_toggle = function()
      M.toggle_rail()
    end,
  }
end

---The rail's columns: the width you last dragged it to, else `native.rail`.
---@return integer
local function rail_width()
  local saved = require("paseo.ui.rail").width "rail"
  return math.max(16, saved or (config().rail > 0 and config().rail) or 32)
end

---The panel's columns, the same way: last dragged, else `native.panel`.
---@return integer
local function panel_width()
  return math.max(30, require("paseo.ui.rail").width "panel" or config().panel)
end

---Set between a VimResized and the next tick; see the resize autocmd.
local vim_resizing = false

---Remember `win`'s width as `name`'s, if it is still a window.
---@param name "rail"|"panel"
---@param win integer|nil
local function keep_width(name, win)
  if win and api.nvim_win_is_valid(win) then
    require("paseo.ui.rail").set_width(name, api.nvim_win_get_width(win))
  end
end

---WinResized's windows: any rail or panel among them keeps its new width.
---(Its own function so the suite, which has no UI and so no WinResized, can
---call it.)
---@param windows integer[]
function M._resized(windows)
  for _, win in ipairs(windows) do
    if api.nvim_win_is_valid(win) then
      local ft = vim.bo[api.nvim_win_get_buf(win)].filetype
      if ft == "paseo-rail" then
        keep_width("rail", win)
      elseif ft == "paseo-panel" then
        keep_width("panel", win)
      end
    end
  end
end

---Open the rail down the left of the Paseo tab.
---@param s paseo.NativeSurface
local function open_rail(s)
  if valid_win(s.rail) then
    return
  end
  local rail = require "paseo.ui.rail"
  local from = api.nvim_get_current_win()
  api.nvim_set_current_win(s.conv)
  vim.cmd(("topleft %dvsplit"):format(rail_width()))
  s.rail = api.nvim_get_current_win()
  api.nvim_win_set_buf(s.rail, rail.buf(rail_keys()))
  vim.wo[s.rail].winfixwidth = true
  rail.adopt(s.rail)
  rail.load()
  if valid_win(from) then
    api.nvim_set_current_win(from)
  end
  -- A bufferline that offsets past a sidebar (nvim-tree's way) measures it
  -- when it draws: tell it the sidebar is there.
  pcall(vim.cmd.redrawtabline)
end

---Is the rail showing on the Paseo tab, and is that the tab you are on?
---@return boolean
function M.rail_shown()
  local s = here()
  return s ~= nil and valid_win(s.rail)
end

---`<C-s>`: into the rail, on the session on screen -- opening it first.
function M.focus_rail()
  local s = here()
  if not s then
    return
  end
  local from = api.nvim_get_current_win()
  if from ~= s.rail then
    -- What `<C-b>` in the rail goes back to.
    s.rail_from = from
    pcall(vim.cmd.stopinsert)
  end
  open_rail(s)
  if valid_win(s.rail) then
    local rail = require "paseo.ui.rail"
    rail.reveal()
    rail.draw()
    api.nvim_set_current_win(s.rail)
    rail.seat { session = true }
  end
end

---Where the cursor goes back to when the rail closes: the window it was in
---when the rail took it, if that is still a window on the Paseo tab, else
---the box you type in.
---@param s paseo.NativeSurface
local function return_from_rail(s)
  local back = s.rail_from
  s.rail_from = nil
  if valid_win(back) and back ~= s.rail and api.nvim_win_get_tabpage(back) == s.tab then
    api.nvim_set_current_win(back)
  else
    M.back()
  end
end

---Out of the rail, the rail left open: back to where the cursor came from.
function M.from_rail()
  local s = here()
  if s then
    return_from_rail(s)
  end
end

---`<C-b>`: the rail, on or off -- and the cursor with it.
---
---OPENING IT IS GOING TO IT, as with nvim-tree: the cursor lands in the rail,
---on the session in the middle. CLOSING IT FROM THE RAIL goes back to the
---window you were in when it opened. Closed from anywhere else, the cursor
---stays where it is: you were not in the rail, so there is nothing to
---return from.
function M.toggle_rail()
  local s = here()
  if not s then
    return
  end
  -- REMEMBERED, across restarts (|paseo.ui.rail|'s state file): a rail you
  -- hid stays hidden next session.
  if valid_win(s.rail) then
    local win = s.rail
    local was_in = api.nvim_get_current_win() == win
    keep_width("rail", win)
    s.rail = nil
    pcall(api.nvim_win_close, win, true)
    require("paseo.ui.rail").set_visible(false)
    pcall(vim.cmd.redrawtabline)
    if was_in or not valid_win(api.nvim_get_current_win()) then
      return_from_rail(s)
    else
      s.rail_from = nil
    end
  else
    require("paseo.ui.rail").set_visible(true)
    M.focus_rail()
  end
  -- ONE PAINT. The conversation just changed width; left to the resize
  -- watcher, its cards re-laid themselves out 50ms after the rail moved, and
  -- that second beat was the delay you could see.
  if s.chat and s.chat.win_conversation == s.conv then
    transcript.redraw(s.chat)
  end
end

---Step through the workspace's buffers: `delta` 1 is the next, -1 the
---previous, wrapping. What a terminal's next/prev keys do -- a terminal has
---no bufferline keys of its own in terminal mode.
---@param delta integer
function M.cycle(delta)
  local s = here()
  if not s then
    return
  end
  local list = buffers(s)
  if #list == 0 then
    return
  end
  local at = 1
  local shown = api.nvim_win_get_buf(s.conv)
  for i, buf in ipairs(list) do
    if buf == shown then
      at = i
    end
  end
  local target = list[((at - 1 + delta) % #list) + 1]
  api.nvim_set_current_win(s.conv)
  vim.cmd.stopinsert()
  api.nvim_win_set_buf(s.conv, target)
end

---The keys out of a terminal (`ui.terminal.keys`).
---
---A terminal takes every key, which is what it is for -- so the few it does
---not take are your whole way out, bound in TERMINAL mode as well as normal,
---or each would start with `<C-\><C-n>`. `chrome` leaves terminal mode,
---`terminal` goes back in, `next`/`prev` are the workspace's next and
---previous buffer, `sessions` is the rail. `q` (normal mode only -- in
---terminal mode it is a letter) goes back to the agent that was in the
---middle; the terminal lives on, on the daemon. `false` unbinds any of them.
---@param buf integer
function M.bind_terminal(buf)
  if not (buf and api.nvim_buf_is_valid(buf)) or vim.b[buf].paseo_terminal_keys then
    return
  end
  vim.b[buf].paseo_terminal_keys = true
  local keys = (require("paseo.config").get().ui.terminal or {}).keys or {}
  local function map(modes, lhs, fn, desc)
    for _, key in ipairs(require("paseo.ui.keys").list(lhs)) do
      vim.keymap.set(
        modes,
        key,
        fn,
        { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc }
      )
    end
  end
  map({ "n", "t" }, keys.chrome, function()
    vim.cmd.stopinsert()
  end, "out of the terminal, into normal mode")
  map({ "n", "t" }, keys.terminal, function()
    vim.cmd.startinsert()
  end, "back into the terminal")
  map({ "n", "t" }, keys.next, function()
    M.cycle(1)
  end, "the workspace's next buffer")
  map({ "n", "t" }, keys.prev, function()
    M.cycle(-1)
  end, "the workspace's previous buffer")
  map({ "n", "t" }, keys.sessions, function()
    vim.cmd.stopinsert()
    M.focus_rail()
  end, "the sessions, in the rail")
  map("n", "q", function()
    local s = here()
    if s and s.chat and valid_buf(s.chat.conversation) then
      M.show(s.chat)
    end
  end, "back to the agent (the terminal lives on)")
end

-- ------------------------------------------------------------------- panels

---Write the panel's lines into its buffer.
---@param t paseo.NativeSurface
local function draw_panel(t)
  if
    not (t.panel and valid_win(t.panel_win) and t.panel_buf and api.nvim_buf_is_valid(t.panel_buf))
  then
    return
  end
  local panel = require("paseo.ui.panels." .. t.panel:lower())
  local width = api.nvim_win_get_width(t.panel_win) - 1
  local height = api.nvim_win_get_height(t.panel_win)
  local ok, lines = pcall(panel.lines, t.chat, width, height)
  if not ok then
    lines = { { { "  " .. tostring(lines), "PaseoToolFail" } } }
  end
  local cursor = api.nvim_win_get_cursor(t.panel_win)
  api.nvim_buf_clear_namespace(t.panel_buf, ns, 0, -1)
  render.to_buffer(t.panel_buf, ns, 0, -1, lines or {})
  vim.bo[t.panel_buf].modifiable = false
  pcall(api.nvim_win_set_cursor, t.panel_win, cursor)
end

---Repaint every panel that is up. The panels' own views ask for this when
---what they draw changes, and so does every frame of |paseo.ui.animate|.
function M.redraw_panels()
  local t = surface()
  if t and t.chat then
    draw_panel(t)
  end
end

---Close this tab's panel.
---@param t paseo.NativeSurface
local function close_panel(t)
  if t.panel then
    local panel = require("paseo.ui.panels." .. t.panel:lower())
    if t.panel_buf and type(panel.detach) == "function" then
      pcall(panel.detach, t.chat, t.panel_buf)
    end
  end
  if valid_win(t.panel_win) then
    keep_width("panel", t.panel_win)
    pcall(api.nvim_win_close, t.panel_win, true)
  end
  if t.panel_buf and api.nvim_buf_is_valid(t.panel_buf) then
    pcall(api.nvim_buf_delete, t.panel_buf, { force = true })
  end
  t.panel, t.panel_win, t.panel_buf = nil, nil, nil
end

---Show `name` in this tab's panel split.
---@param t paseo.NativeSurface
---@param name string
local function show_panel(t, name)
  close_panel(t)
  local from = api.nvim_get_current_win()
  api.nvim_set_current_win(t.conv)
  vim.cmd(("botright %dvsplit"):format(panel_width()))
  t.panel_win = api.nvim_get_current_win()
  t.panel_buf = api.nvim_create_buf(false, true)
  t.panel = name
  vim.bo[t.panel_buf].bufhidden = "wipe"
  vim.bo[t.panel_buf].filetype = "paseo-panel"
  pcall(
    api.nvim_buf_set_name,
    t.panel_buf,
    ("paseo://panel/%s/%d"):format(name:lower(), t.panel_buf)
  )
  api.nvim_win_set_buf(t.panel_win, t.panel_buf)
  set_options(t.panel_win, {
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    cursorline = true,
    winfixwidth = true,
    fillchars = "eob: ",
    winhl = M.WINHL .. ",CursorLine:PaseoRowHover",
  })
  -- A TAB STRIP, not a title: every panel is one key away, and the strip
  -- says which. `<C-p>` used to step Settings -> Changes -> Usage -> closed,
  -- so reaching Usage was three presses and going back to Settings was four.
  local strip = { { " ", "PaseoDim" } }
  for i, panel_name in ipairs(M.PANELS) do
    local here = panel_name == name
    strip[#strip + 1] =
      { (" %d %s "):format(i, panel_name), here and "PaseoChipFocus" or "PaseoDim" }
  end
  local key = require "paseo.ui.keys"
  local reload, close = key.label("panel", "r"), key.label("panel", "q")
  strip[#strip + 1] = {
    "  "
      .. (reload and (" " .. reload .. " reload") or "")
      .. (reload and close and " ·" or "")
      .. (close and (" " .. close .. " close") or ""),
    "PaseoDim",
  }
  vim.wo[t.panel_win].winbar = render.to_winbar(strip)
  last_panel = name

  local panel = require("paseo.ui.panels." .. name:lower())
  -- UP FIRST, FILLED IN AFTER. The split paints on the keypress that asked
  -- for it; what goes in it (git, the daemon, a full layout) is drawn on the
  -- next tick, so `<C-p>` never waits on any of that to show you something.
  render.to_buffer(t.panel_buf, ns, 0, -1, { { { "  loading…", "PaseoDim" } } })
  vim.bo[t.panel_buf].modifiable = false
  local shown = t.panel_buf
  vim.schedule(function()
    if t.panel_buf ~= shown or not api.nvim_buf_is_valid(shown) then
      return
    end
    if type(panel.load) == "function" then
      pcall(panel.load, t.chat)
    end
    draw_panel(t)
  end)
  if type(panel.attach) == "function" then
    pcall(panel.attach, t.chat, t.panel_buf)
  end

  local keys = require "paseo.ui.keys"
  local opts = { buffer = t.panel_buf, nowait = true, silent = true }
  -- The surface's keys (configured), then the panel's own (remappable).
  local function surface(lhs, fn, desc)
    for _, key in ipairs(keys.list(lhs)) do
      vim.keymap.set("n", key, fn, vim.tbl_extend("force", opts, { desc = "paseo: " .. desc }))
    end
  end
  local function map(lhs, fn, desc)
    keys.set("panel", "n", lhs, fn, vim.tbl_extend("force", opts, { desc = "paseo: " .. desc }))
  end
  surface(nkeys().panel, M.toggle_panel, "close the panel")
  surface(nkeys().rail, M.toggle_rail, "show or hide the workspace rail")
  for i, panel_name in ipairs(M.PANELS) do
    map(tostring(i), function()
      M.panel(panel_name)
    end, "the " .. panel_name .. " panel")
  end
  map("q", function()
    close_panel(t)
    M.back()
  end, "close the panel")
  -- The panels that take `r` themselves have already bound it, and win;
  -- this is the reload for the ones that do not.
  if vim.fn.maparg(keys.label("panel", "r") or "r", "n", false, true).buffer ~= 1 then
    map("r", function()
      if type(panel.invalidate) == "function" then
        pcall(panel.invalidate)
      end
      if type(panel.load) == "function" then
        pcall(panel.load, t.chat)
      end
      draw_panel(t)
    end, "reload the panel")
  end

  if valid_win(from) then
    api.nvim_set_current_win(from)
  end
end

---`<C-p>`: the panel, on or off.
---
---On: the panel you last looked at (Settings the first time), with the cursor
---in it -- `1` `2` `3` there jump straight to Settings, Changes or Usage.
---Off: closed, and back to the box you type in.
function M.toggle_panel()
  local t = here()
  if not t then
    return
  end
  if valid_win(t.panel_win) then
    close_panel(t)
    return M.back()
  end
  M.panel(last_panel)
end

---Kept for callers of the old name: it toggles now. See |M.toggle_panel|.
M.cycle_panel = M.toggle_panel

---Open a panel by name and put the cursor in it.
---@param name? string  One of `M.PANELS`; nil is the one you last looked at.
function M.panel(name)
  local t = here()
  if not t then
    return
  end
  show_panel(t, name or last_panel)
  if valid_win(t.panel_win) then
    api.nvim_set_current_win(t.panel_win)
  end
end

-- ------------------------------------------------------------------- header

---The keys this surface adds, on the conversation's winbar.
---@type { at: integer, lhs: string|nil }|nil
local out_key

---The winbar's hints, from the keys as they are BOUND: a remapped key shows
---as what you remapped it to, an unbound one is not advertised at all.
---@return { [1]: string, [2]: string }[]
local function hints()
  local keys = require "paseo.ui.keys"
  -- The way back to your code is YOUR key (the plugin maps none): looked up
  -- among your mappings, at most every couple of seconds -- the winbar is
  -- redrawn on every streamed event.
  local now = vim.uv.now()
  if not out_key or now - out_key.at > 2000 then
    out_key = {
      at = now,
      lhs = keys.user_key { "<Plug>(paseo-native)", "<cmd>Paseo native<cr>", ":Paseo native<cr>" },
    }
  end
  local out = {}
  for _, hint in ipairs {
    { out_key.lhs, "code" },
    { keys.label(nil, nkeys().panel), "panel" },
    { keys.label(nil, nkeys().rail), "rail" },
    { keys.label("conversation", "q"), "close" },
  } do
    if hint[1] then
      out[#out + 1] = hint
    end
  end
  return out
end

---Repaint the conversation's winbar: which agent, what it is doing, and the
---surface's keys. The composer's own bar is |paseo.ui.composer|'s.
---@param chat table
function M.refresh(chat)
  local win = chat.win_conversation
  if not valid_win(win) then
    return
  end
  local widgets = require "paseo.ui.widgets"
  local sidebar = require "paseo.ui.sidebar"
  local width = api.nvim_win_get_width(win)

  local agent = chat.agent_id and require("paseo.agents").get(chat.agent_id, chat.host_id)
  local title = chat.title or (agent and agent.title)
  local left = {
    { "  ", "PaseoDim" },
    { title or vim.fn.fnamemodify(chat.local_root or chat.root, ":~"), "PaseoHeader" },
  }
  local status = sidebar.status(chat)
  if #status > 0 then
    left[#left + 1] = { "  ", "PaseoDim" }
    vim.list_extend(left, status)
  elseif chat.permissions and next(chat.permissions) then
    left[#left + 1] =
      { "  " .. require("paseo.ui.icons").status.waiting .. " waiting on you", "PaseoBadge" }
  end

  -- The keys on the right only if you asked (`hints.winbar`); otherwise the
  -- title and status have the whole bar.
  local right = config().hints.winbar and widgets.hints(hints(), nil, math.max(0, width - 30)) or {}
  pcall(function()
    vim.wo[win].winbar = render.to_winbar(
      widgets.row(render.truncate(left, math.max(4, width - render.width(right) - 2)), right, width)
    )
  end)
end

-- ------------------------------------------------------------------ spinner

---@type uv.uv_timer_t|nil
local timer

---One clock for every rail on screen: the rail's buffer is shared, so one
---draw a tick repaints them all.
local function sync_spinner()
  local rail = require "paseo.ui.rail"
  local want = M.any() and rail.spinning()
  if want and not timer then
    timer = vim.uv.new_timer()
    timer:start(
      100,
      100,
      vim.schedule_wrap(function()
        if not (M.any() and rail.spinning()) then
          if timer then
            timer:stop()
            timer:close()
            timer = nil
          end
          return
        end
        rail.draw()
      end)
    )
  elseif not want and timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

M.sync_spinner = sync_spinner

-- ------------------------------------------------------------------- layout

---Tell render-markdown.nvim the conversation changed.
---
---It redraws on `TextChanged`, `WinScrolled` and the like -- events that
---never fire for a buffer written to from a callback while the cursor is in
---the box. So a reply landed in the buffer and stayed raw until something
---happened to scroll. One nudge per burst of writes, to its group alone.
---@param chat table
local function watch_markdown(chat)
  local buf = chat.conversation
  if chat.markdown_watched == buf or not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  chat.markdown_watched = buf
  local pending = false
  api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not chat.markdown then
        chat.markdown_watched = nil
        return true -- detach; reattached when markdown mode comes back
      end
      if pending then
        return
      end
      pending = true
      vim.defer_fn(function()
        pending = false
        if api.nvim_buf_is_valid(buf) then
          pcall(api.nvim_exec_autocmds, "TextChanged", { group = "RenderMarkdown", buffer = buf })
        end
      end, 30)
    end,
    on_detach = function()
      chat.markdown_watched = nil
    end,
  })
end

---The conversation is markdown on this surface; nowhere else is it.
---@param chat table
---@param on boolean
---@return boolean redrew
local function set_markdown(chat, on)
  local want = on and config().markdown or nil
  if chat.markdown == want then
    return false
  end
  chat.markdown = want
  transcript.redraw(chat, { force = true })
  return true
end

---The surface's keys, on the chat's two buffers, while it is on this surface.
---@param chat table
local function bind(chat)
  local keys = nkeys()
  local list = {
    { keys.rail, M.toggle_rail, "show or hide the workspace rail" },
    { keys.focus, M.focus_rail, "into the workspace rail" },
    { keys.sessions, M.focus_rail, "the sessions, in the rail" },
    { keys.panel, M.toggle_panel, "the panel: Settings / Changes / Usage" },
    {
      keys.new,
      function()
        if api.nvim_get_mode().mode ~= "n" then
          pcall(vim.cmd.stopinsert)
        end
        require("paseo.new").open(require("paseo.new").context(chat))
      end,
      "start an agent or a terminal",
    },
  }
  chat.native_keys = {}
  for _, buf in ipairs { chat.conversation, chat.composer } do
    for _, item in ipairs(list) do
      for _, lhs in ipairs(require("paseo.ui.keys").list(item[1])) do
        if buf and api.nvim_buf_is_valid(buf) then
          vim.keymap.set(
            "n",
            lhs,
            item[2],
            { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. item[3] }
          )
          chat.native_keys[#chat.native_keys + 1] = { buf, lhs }
        end
      end
    end
  end
end

---@param chat table
local function unbind(chat)
  for _, pair in ipairs(chat.native_keys or {}) do
    if api.nvim_buf_is_valid(pair[1]) then
      pcall(vim.keymap.del, "n", pair[2], { buffer = pair[1] })
    end
  end
  chat.native_keys = nil
end

-- ---------------------------------------------------------------- the row

---Is this chat's agent a Paseo subagent -- a peek, not one of the row's?
---@param chat table
---@return boolean
local function is_subagent(chat)
  local agent = chat.agent_id and require("paseo.agents").get(chat.agent_id, chat.host_id)
  return agent ~= nil and agent.labels ~= nil and agent.labels[require("paseo.subagents").PARENT_LABEL] ~= nil
end

---Keep the row's names current: an agent's title arrives after it starts,
---and a terminal can be renamed from the rail. Nothing is added or taken
---away here -- the row is what you opened.
function M.sync()
  local s = surface()
  if not s then
    return
  end
  local chats = require "paseo.ui.chat"
  for _, chat in ipairs(s.set) do
    chats.name_conversation(chat)
  end
  for _, term in ipairs(s.terms) do
    if valid_buf(term.buf) then
      term.title = require("paseo.terminals").label(term.terminal or term.id, term.host_id)
      name_term(term)
    end
  end
  order(s)
end

-- ------------------------------------------------------------------ keeping

---Drop the surface's bookkeeping: its tab is gone.
local function forget()
  local s = S
  S = nil
  if not s then
    return
  end
  for _, chat in ipairs(s.set) do
    if valid_buf(chat.conversation) then
      pcall(function()
        vim.bo[chat.conversation].buflisted = false
      end)
    end
  end
  for _, term in ipairs(s.terms) do
    if valid_buf(term.buf) then
      pcall(function()
        vim.bo[term.buf].buflisted = false
      end)
    end
  end
  local chat = s.chat
  if chat then
    if chat.win_conversation == s.conv then
      chat.win_conversation, chat.win_composer = nil, nil
    end
    if chat.surface == "native" then
      chat.surface = nil
    end
    unbind(chat)
  end
end

local augroup

---What is in the middle window now, when it was not this module that put it
---there: `:bnext`, a bufferline click, `:b N`.
---@param buf integer
local function entered(buf)
  local s = surface()
  if not s or s.swapping then
    return
  end
  local chats = require "paseo.ui.chat"
  local chat = chats.by_buffer(buf)
  if chat then
    if chat ~= s.chat or not valid_win(s.comp) then
      if chat.initialised or not chat.agent_id then
        M.open(chat, { focus = false })
      else
        -- Listed but never looked at: `open` subscribes and fetches it.
        chats.open {
          agent_id = chat.agent_id,
          host_id = chat.host_id,
          root = chat.root,
          remote = true,
          surface = "native",
          focus = false,
        }
      end
    end
    return
  end
  local term = term_of(s, buf)
  if term then
    M.show_terminal(term, { insert = false })
  end
end

---The autocmds that keep `current`, the rail and the bookkeeping honest.
local function watch()
  if augroup then
    return
  end
  augroup = api.nvim_create_augroup("paseo.native", { clear = true })

  api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    desc = "paseo: the composer follows the agent put in the middle",
    callback = function(args)
      local s = surface()
      if not s or s.swapping then
        return
      end
      local win = api.nvim_get_current_win()
      if win == s.conv then
        return entered(args.buf)
      end
      -- A buffer key pressed in the box, the rail or the panel: the agent
      -- goes to the middle, and that window gets its own buffer back.
      local buf = args.buf
      local ours = require("paseo.ui.chat").by_buffer(buf) or term_of(s, buf)
      local own = (win == s.comp and s.chat and s.chat.composer)
        or (win == s.rail and require("paseo.ui.rail").buf(rail_keys()))
        or (win == s.panel_win and s.panel_buf)
      if ours and own and own ~= buf then
        vim.schedule(function()
          if valid_win(win) and valid_buf(own) then
            put(win, own)
          end
          if surface() then
            api.nvim_set_current_win(s.conv)
            api.nvim_win_set_buf(s.conv, buf)
          end
        end)
      end
    end,
  })

  api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    desc = "paseo: a deleted agent buffer leaves the row",
    callback = function(args)
      local s = surface()
      if not s or s.swapping then
        return
      end
      for _, chat in ipairs(s.set) do
        if chat.conversation == args.buf and vim.bo[args.buf].buflisted then
          -- After the delete: the buffer is still being taken down here.
          vim.schedule(function()
            M.remove(chat)
            -- `:bdelete` unloads it, and an unloaded `nofile` buffer has
            -- lost the transcript: the chat goes too, and opening the agent
            -- again builds it afresh.
            if not (valid_buf(chat.conversation) and api.nvim_buf_is_loaded(chat.conversation)) then
              require("paseo.ui.chat").dispose(chat)
            end
          end)
          return
        end
      end
    end,
  })

  api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    desc = "paseo: entering the Paseo tab lists its agents",
    callback = function()
      local s = here()
      if not s then
        return
      end
      set_listed(s, true)
      if s.chat then
        require("paseo.ui.chat").set_current(s.chat)
        M.refresh(s.chat)
      end
      if valid_win(s.rail) then
        require("paseo.ui.rail").adopt(s.rail)
      end
      require("paseo.ui.rail").draw()
    end,
  })

  api.nvim_create_autocmd("TabLeave", {
    group = augroup,
    desc = "paseo: leaving the Paseo tab unlists its agents",
    callback = function()
      local s = surface()
      local tab = api.nvim_get_current_tabpage()
      if s and tab == s.tab then
        set_listed(s, false)
      else
        origin = tab
      end
    end,
  })

  api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    desc = "paseo: forget the Paseo tab once it is gone",
    callback = function()
      if S and not api.nvim_tabpage_is_valid(S.tab) then
        local chat = S.chat
        forget()
        if chat then
          set_markdown(chat, false)
        end
      end
      sync_spinner()
    end,
  })

  -- `:q` in the conversation or the box takes the whole Paseo tab: half a
  -- chat is not a layout anything here knows how to draw.
  api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    desc = "paseo: the Paseo tab goes with its conversation",
    callback = function(args)
      local s = surface()
      local closed = tonumber(args.match)
      if s and not s.swapping and (closed == s.conv or (closed == s.comp and s.chat)) then
        vim.schedule(function()
          M.close_surface()
        end)
      end
    end,
  })

  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = augroup,
    desc = "paseo: refit native panels",
    callback = function(ev)
      -- A rail or panel you dragged (`<C-w><`, the mouse) keeps that width.
      -- Not when the EDITOR changed size: a narrow terminal squeezing the
      -- rail is not you asking for a narrower one.
      if ev.event == "VimResized" then
        vim_resizing = true
        vim.schedule(function()
          vim_resizing = false
        end)
      elseif not vim_resizing then
        M._resized((vim.v.event or {}).windows or {})
      end
      vim.schedule(function()
        local s = surface()
        if s and s.chat then
          M.refresh(s.chat)
        end
        M.redraw_panels()
        require("paseo.ui.newtask").redraw()
      end)
    end,
  })

  require("paseo.terminals").on_change(function()
    vim.schedule(function()
      if M.any() then
        M.sync()
      end
    end)
  end)

  require("paseo.agents").on_change(function()
    vim.schedule(function()
      if M.any() then
        M.sync()
        require("paseo.ui.rail").directory_changed()
        sync_spinner()
      end
    end)
  end)
end

-- --------------------------------------------------------------------- open

---Is the Paseo tab the one you are on? What a toggle key asks: there, it
---goes back to your code, whatever is in the middle.
---@return boolean
function M.on_tab()
  return here() ~= nil
end

---Back onto the Paseo tab, AS YOU LEFT IT -- the agent, terminal or peek in
---the middle, the window you were in. What the toggle key does coming in.
---@return boolean entered  False when there is no Paseo tab to go to.
function M.enter()
  local s = surface()
  if not s then
    return false
  end
  if api.nvim_get_current_tabpage() ~= s.tab then
    api.nvim_set_current_tabpage(s.tab)
  end
  return true
end

---Make the Paseo tab, once.
---@param chat table  What goes in the middle first.
---@return paseo.NativeSurface
local function create(chat)
  vim.cmd "tabnew"
  local tab = api.nvim_get_current_tabpage()
  local scratch = api.nvim_get_current_buf()
  local conv = api.nvim_get_current_win()
  api.nvim_win_set_buf(conv, chat.conversation)
  -- `tabnew`'s empty buffer, which nothing else is showing now.
  if
    api.nvim_buf_is_valid(scratch)
    and api.nvim_buf_get_name(scratch) == ""
    and not vim.bo[scratch].modified
    and #vim.fn.win_findbuf(scratch) == 0
  then
    pcall(api.nvim_buf_delete, scratch, {})
  end
  S = { tab = tab, conv = conv, set = {}, terms = {} }
  return S
end

---The composer's window, under the conversation; made again after a
---terminal had the middle to itself.
---@param s paseo.NativeSurface
---@param chat table
local function ensure_composer(s, chat)
  if valid_win(s.comp) then
    put(s.comp, chat.composer)
  else
    local from = api.nvim_get_current_win()
    api.nvim_set_current_win(s.conv)
    s.swapping = true
    vim.cmd "belowright 1split"
    s.comp = api.nvim_get_current_win()
    pcall(api.nvim_win_set_buf, s.comp, chat.composer)
    s.swapping = false
    if valid_win(from) then
      api.nvim_set_current_win(from)
    end
  end
  require("paseo.ui.sidebar").style(s.comp)
  vim.wo[s.comp].fillchars = "eob: "
  vim.wo[s.comp].winfixheight = true
end

---Put `chat` in the middle of the Paseo tab, its composer under it.
---@param chat table
---@param opts? { focus?: boolean }
function M.show(chat, opts)
  opts = opts or {}
  local s = surface()
  if not s then
    return M.open(chat, opts)
  end
  local old = s.chat
  local panel = s.panel
  if old ~= chat then
    if s.panel then
      close_panel(s)
    end
    if old then
      unbind(old)
      if old.win_conversation == s.conv then
        old.win_conversation, old.win_composer = nil, nil
      end
    end
  end

  -- Asked before the swap: a chat already in the middle is where you are
  -- looking, and has nothing to put back.
  local arriving = api.nvim_win_get_buf(s.conv) ~= chat.conversation or s.chat ~= chat
  put(s.conv, chat.conversation)
  set_options(s.conv, CONVERSATION)
  ensure_composer(s, chat)

  s.chat = chat
  chat.win_conversation, chat.win_composer = s.conv, s.comp
  chat.surface = "native"
  -- The tab stands where the agent in the middle works: `:e`, telescope and
  -- `:Paseo explain` from here start in its workspace.
  local dir = chat.local_root or chat.root
  if dir and dir ~= vim.fn.getcwd(-1, api.nvim_tabpage_get_number(s.tab)) and vim.fn.isdirectory(dir) == 1 then
    -- `silent`: a `:tcd` run from a keypress echoes the new directory.
    api.nvim_win_call(s.conv, function()
      pcall(vim.cmd, "silent tcd " .. vim.fn.fnameescape(dir))
    end)
  end
  require("paseo.ui.composer").style(chat)
  bind(chat)
  require("paseo.ui.surface").remember "native"

  -- render-markdown.nvim attaches on `FileType`, which this buffer had long
  -- before the plugin was loaded (it is lazy on `ft = markdown`, and the
  -- event that loads it is the one it misses). Fire it again for that plugin
  -- alone -- its group, nobody else's handlers -- now there is a window.
  if config().markdown then
    pcall(
      api.nvim_exec_autocmds,
      "FileType",
      { group = "RenderMarkdown", buffer = chat.conversation }
    )
    watch_markdown(chat)
  end
  -- Prose is width-free in markdown mode, but the tool cards are not: draw
  -- them at this window's width (a no-op when they already are).
  if not set_markdown(chat, true) then
    transcript.redraw(chat)
  end
  require("paseo.ui.sidebar").fit_composer(chat)
  -- After the re-lay, which would undo it. `:bnext`, a bufferline click and
  -- the rail all come in here, and none of them goes through `chat.layout`:
  -- back where you left it, or at the end if you were following.
  if arriving then
    transcript.restore(chat)
  end
  require("paseo.ui.chat").set_current(chat)
  M.refresh(chat)
  require("paseo.ui.composer").refresh(chat)
  if panel and not s.panel then
    show_panel(s, panel)
  end
  local rail = require "paseo.ui.rail"
  rail.draw()
  sync_spinner()
  if opts.focus ~= false then
    api.nvim_set_current_win(s.comp)
  end
end

---Put `chat` on the Paseo tab, making the tab if there is none.
---
---WHAT YOU OPEN IS WHAT IS THERE. The chat joins the row -- whatever
---workspace it is in, beside whatever else you have open -- and nothing else
---is added or taken away. A subagent is the exception: a peek in place of
---its parent, off the row.
---@param chat table
---@param opts? { focus?: boolean }
function M.open(chat, opts)
  opts = opts or {}
  watch()
  local s = surface()
  if not s then
    -- Windows left over from another surface's layout are not ours to reuse.
    chat.win_conversation, chat.win_composer = nil, nil
    s = create(chat)
  elseif api.nvim_get_current_tabpage() ~= s.tab then
    api.nvim_set_current_tabpage(s.tab)
  end

  if is_subagent(chat) and s.chat and s.chat ~= chat and not index_of(s, chat) then
    -- Back goes to the agent the peek started from, however many subagents
    -- deep it went.
    s.peek = { parent = s.peek and s.peek.parent or s.chat }
  else
    s.peek = nil
    add(s, chat)
  end

  if not valid_win(s.rail) and config().rail > 0 and require("paseo.ui.rail").visible() then
    open_rail(s)
  end
  M.show(chat, opts)
end

---Show a terminal of the set in the middle, the composer put away -- a
---terminal takes its own input.
---@param term table  An entry of the set's terminals.
---@param opts? { insert?: boolean }
function M.show_terminal(term, opts)
  local s = surface()
  if not s then
    return
  end
  local ui = require "paseo.ui.terminal"
  local terminal = require("paseo.terminals").get(term.id, term.host_id)
    or term.terminal
    or { id = term.id, hostId = term.host_id }
  if s.chat then
    unbind(s.chat)
    if s.chat.win_conversation == s.conv then
      s.chat.win_conversation, s.chat.win_composer = nil, nil
    end
  end
  if s.panel then
    close_panel(s)
  end
  s.swapping = true
  if valid_win(s.comp) then
    pcall(api.nvim_win_close, s.comp, true)
  end
  s.comp = nil
  local view = ui.ensure(terminal, s.conv, { buf = term.buf })
  term.buf = view.buf
  ui.show(view, s.conv)
  s.swapping = false
  M.bind_terminal(view.buf)
  list_one(s, view.buf)
  api.nvim_set_current_win(s.conv)
  require("paseo.ui.rail").draw()
  if not opts or opts.insert ~= false then
    vim.cmd "startinsert"
  end
end

---Take the Paseo tab down. The chats live on, as they do when any surface
---closes; `:Paseo native` brings it back.
function M.close_surface()
  local s = S
  if not s then
    return
  end
  if s.panel then
    close_panel(s)
  end
  local tab = s.tab
  local chat = s.chat
  forget()
  if chat then
    set_markdown(chat, false)
  end
  if api.nvim_tabpage_is_valid(tab) then
    if #api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd.tabclose, api.nvim_tabpage_get_number(tab))
    else
      -- The last tab cannot close: leave it holding one empty window.
      local wins = api.nvim_tabpage_list_wins(tab)
      local keep = wins[1]
      api.nvim_set_current_win(keep)
      vim.cmd "enew"
      for _, win in ipairs(wins) do
        if win ~= keep then
          pcall(api.nvim_win_close, win, true)
        end
      end
    end
  end
  sync_spinner()
end

---`q`: the Paseo tab goes, as a whole. On a subagent's peek it is back to
---the parent instead. The chats live on; `:Paseo native` brings it back.
---@param chat table
function M.close(chat)
  local s = surface()
  if not s then
    return
  end
  if s.peek and s.chat == chat then
    local parent = s.peek.parent
    s.peek = nil
    if parent and valid_buf(parent.conversation) then
      return M.show(parent)
    end
  end
  M.close_surface()
end

---One chat off the row, like `:bdelete`: a new task you backed out of, a
---buffer you deleted. The agent lives on -- it is still on the rail -- and
---the neighbour on the row takes the middle. The last one going takes the
---Paseo tab with it.
---@param chat table
function M.remove(chat)
  local s = surface()
  if not s then
    return
  end
  local at = index_of(s, chat)
  if at then
    table.remove(s.set, at)
  end
  if valid_buf(chat.conversation) then
    pcall(function()
      vim.bo[chat.conversation].buflisted = false
    end)
  end
  if s.chat ~= chat then
    return
  end
  local next_chat = s.set[at or 1] or s.set[(at or 1) - 1] or s.set[#s.set]
  if not M.has(chat) then
    -- Not in the middle any more -- a terminal is, say, started from the new
    -- task being removed. Whatever has the middle keeps it; the neighbour is
    -- only what `q` there goes back to.
    s.chat = next_chat
    return
  end
  unbind(chat)
  if chat.win_conversation == s.conv then
    chat.win_conversation, chat.win_composer = nil, nil
  end
  if chat.surface == "native" then
    chat.surface = nil
  end
  s.chat = nil
  if next_chat and valid_buf(next_chat.conversation) then
    if next_chat.initialised or not next_chat.agent_id then
      return M.open(next_chat)
    end
    return require("paseo.ui.chat").open {
      agent_id = next_chat.agent_id,
      host_id = next_chat.host_id,
      root = next_chat.root,
      remote = true,
      surface = "native",
    }
  end
  M.close_surface()
end

---A chat leaving this surface for another (the sidebar): its markdown
---rendering and keys go, and it is no longer one of the set's buffers.
---@param chat table
function M.release(chat)
  local s = surface()
  if s then
    local at = index_of(s, chat)
    if at then
      table.remove(s.set, at)
    end
    if s.chat == chat then
      s.chat = nil
    end
  end
  if valid_buf(chat.conversation) then
    pcall(function()
      vim.bo[chat.conversation].buflisted = false
    end)
  end
  unbind(chat)
  set_markdown(chat, false)
end

---A session from the rail. An agent is a chat, shown in the middle; a
---terminal takes the middle with its PTY.
---@param session { kind: string, id: string, hostId?: string }
function M.show_session(session)
  local s = surface()
  local here_chat = s and s.chat
  local host_id = session.hostId or (here_chat and here_chat.host_id)
  if session.kind == "agent" then
    local agent = require("paseo.agents").get(session.id, host_id)
    return require("paseo.ui.chat").open {
      root = (agent and agent.cwd) or (here_chat and here_chat.root),
      host_id = host_id,
      remote = true,
      agent_id = session.id,
      title = agent and agent.title,
      surface = "native",
    }
  end
  if session.kind == "terminal" then
    if not s then
      -- Nothing to put it in yet: the Paseo tab, on the current chat.
      local chat = require("paseo.ui.chat").current()
      if not chat then
        return
      end
      M.open(chat)
      s = surface()
      if not s then
        return
      end
    elseif api.nvim_get_current_tabpage() ~= s.tab then
      api.nvim_set_current_tabpage(s.tab)
    end
    local terminal = require("paseo.terminals").get(session.id, host_id)
      or { id = session.id, hostId = host_id }
    local term = add_term(s, terminal, host_id)
    M.show_terminal(term)
  end
end

---A workspace from the rail: its newest agent, opened -- one buffer more on
---the row, the rest of the workspace a pick away on the rail. One with no
---agent yet gets the new-task screen.
---@param ws table
function M.open_workspace(ws)
  local s = surface()
  local host_id = ws.hostId or (s and s.chat and s.chat.host_id)
  -- BY WORKSPACE ID. Several workspaces can share one directory -- every
  -- `paseo run` in a repository makes its own -- so opening by directory
  -- reused whichever chat was already on screen for it.
  local newest
  for _, agent in ipairs(require("paseo.agents").all(host_id)) do
    if
      ws.id
      and agent.workspaceId == ws.id
      and (not newest or (agent.createdAt or "") > (newest.createdAt or ""))
    then
      local parent = agent.labels and agent.labels[require("paseo.subagents").PARENT_LABEL]
      if not parent then
        newest = agent
      end
    end
  end
  if newest then
    return M.show_session { kind = "agent", id = newest.id, hostId = host_id }
  end
  require("paseo.ui.chat").open {
    root = ws.directory,
    local_root = ws.local_directory,
    host_id = host_id,
    remote = true,
    surface = "native",
  }
end

---A read-only buffer -- a provider subagent's transcript -- shown in the
---middle in place of the agent, as a peek: unlisted, and `q` (|M.unpeek|)
---goes back.
---@param buf integer
---@return integer|nil win  The middle window, if the Paseo tab is up here.
function M.peek(buf)
  local s = here()
  if not s then
    return nil
  end
  s.peek = { parent = s.peek and s.peek.parent or s.chat, buf = buf }
  put(s.conv, buf)
  set_options(s.conv, CONVERSATION)
  api.nvim_set_current_win(s.conv)
  return s.conv
end

---Back from a peek to the agent it started from.
function M.unpeek()
  local s = here()
  if not s then
    return
  end
  local parent = s.peek and s.peek.parent or s.chat
  s.peek = nil
  if parent and valid_buf(parent.conversation) then
    M.show(parent)
  end
end

---Forget everything. For the test suite.
function M.reset()
  S = nil
  origin = nil
  last_panel = "Settings"
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

return M
