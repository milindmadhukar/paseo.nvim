--- EXPERIMENTAL. The native surface: the chat out of real splits and nothing
--- else -- no floats over your code, no frame drawn around it.
---
--- ONE TAB PAGE PER AGENT. A tab page is Neovim's own answer to "a separate
--- arrangement of windows", so two agents in one workspace are two tabs and
--- `gt`/`gT` move between them. Each tab is:
---
---   ┌ rail ┬ conversation (winbar: agent · status · keys) ┬ panel ┐
---   │      ├ composer (its own bar: model, mode, the spinner) │       │
---
--- The rail is |paseo.ui.rail|'s buffer -- one buffer, shown in a window on
--- every native tab. The conversation and composer are the chat's own buffers,
--- exactly as the sidebar shows them. The panel is Settings, Changes or Usage
--- (`ui/panels/`), drawn as real lines by |paseo.ui.render|. `<C-p>` toggles
--- it; `1` `2` `3` in it pick which.
---
--- WHAT IS CURRENT FOLLOWS THE TAB. `:Paseo mode`, `:Paseo stop` and every
--- other command act on |paseo.ui.chat|'s current chat, so entering a native
--- tab makes its agent the current one.
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

---Per tab page: the chat it shows and the windows it made.
---@class paseo.NativeTab
---@field chat table
---@field rail integer|nil
---@field panel_win integer|nil
---@field panel_buf integer|nil
---@field panel string|nil

---@type table<integer, paseo.NativeTab>
local tabs = {}

---See `M.leave`.
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

---The entry for a tab page, only while its conversation is still up.
---@param tab integer
---@return paseo.NativeTab|nil
local function entry(tab)
  local t = tabs[tab]
  if not t then
    return nil
  end
  if not api.nvim_tabpage_is_valid(tab) or not valid_win(t.chat.win_conversation) then
    return nil
  end
  if api.nvim_win_get_tabpage(t.chat.win_conversation) ~= tab then
    return nil
  end
  return t
end

---The chat on the tab page you are looking at, if it is a native one.
---@return table|nil
function M.chat()
  local t = entry(api.nvim_get_current_tabpage())
  return t and t.chat or nil
end

---Does `chat` have a native tab, on any tab page?
---@param chat table
---@return boolean
function M.has(chat)
  return chat.native_tab ~= nil and entry(chat.native_tab) ~= nil and tabs[chat.native_tab].chat == chat
end

---Is `chat` on the native tab you are looking at?
---@param chat table
---@return boolean
function M.is_open(chat)
  return M.has(chat) and chat.native_tab == api.nvim_get_current_tabpage()
end

---Is any native tab up?
---@return boolean
function M.any()
  for tab in pairs(tabs) do
    if entry(tab) then
      return true
    end
  end
  return false
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

---The last tab that was NOT an agent's that you left: where `:Paseo native`
---goes back to from an agent's tab.
---Out of the agent's tab, back to the code: the tab you came from if it is
---still there, else any tab that is not an agent's, else a fresh one. The
---agent's tab stays, so `:Paseo native` again lands straight back on it.
function M.leave()
  if origin and api.nvim_tabpage_is_valid(origin) and not entry(origin) then
    api.nvim_set_current_tabpage(origin)
    return
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not entry(tab) then
      api.nvim_set_current_tabpage(tab)
      return
    end
  end
  vim.cmd "tabnew"
end

---Focus the box you type in, on this tab.
function M.back()
  local chat = M.chat()
  if chat and valid_win(chat.win_composer) then
    api.nvim_set_current_win(chat.win_composer)
  end
end

---Keys the rail's buffer is built with, when native builds it first.
local function rail_keys()
  local keys = nkeys()
  return {
    back = M.back,
    toggle = keys.rail,
    focus = keys.focus,
    sessions = keys.sessions,
    on_toggle = function()
      M.toggle_rail()
    end,
  }
end

---Point |paseo.ui.rail| at this tab's rail window.
---@param t paseo.NativeTab
local function adopt_rail(t)
  if valid_win(t.rail) then
    require("paseo.ui.rail").adopt(t.rail)
  end
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

---Open the rail on the tab you are on.
---@param t paseo.NativeTab
local function open_rail(t)
  if valid_win(t.rail) then
    return
  end
  local rail = require "paseo.ui.rail"
  local width = rail_width()
  local from = api.nvim_get_current_win()
  api.nvim_set_current_win(t.chat.win_conversation)
  vim.cmd(("topleft %dvsplit"):format(width))
  t.rail = api.nvim_get_current_win()
  api.nvim_win_set_buf(t.rail, rail.buf(rail_keys()))
  vim.wo[t.rail].winfixwidth = true
  rail.adopt(t.rail)
  rail.load()
  if valid_win(from) then
    api.nvim_set_current_win(from)
  end
end

---Defined with the autocmds below; declared here for `rail_beside`.
local watch

---Rails on tab pages that are not agent tabs -- a provider subagent's
---read-only view, opened from a native tab. Keyed by tab page.
---@type table<integer, integer>
local side_rails = {}

---The keys out of a terminal's tab (`ui.terminal.keys`).
---
---A terminal takes every key, which is what it is for -- so the few it does
---not take are your whole way out, bound in TERMINAL mode as well as normal,
---or each would start with `<C-\><C-n>`. They are Neovim's own moves:
---`chrome` leaves terminal mode, `terminal` goes back in, `next`/`prev` are
---the next and previous tab page, `sessions` is the rail. `q` (normal mode
---only -- in terminal mode it is a letter) closes the tab; the terminal lives
---on, on the daemon. `false` unbinds any of them.
---@param buf integer
function M.bind_terminal(buf)
  if not (buf and api.nvim_buf_is_valid(buf)) or vim.b[buf].paseo_terminal_keys then
    return
  end
  vim.b[buf].paseo_terminal_keys = true
  local keys = (require("paseo.config").get().ui.terminal or {}).keys or {}
  local function map(modes, lhs, fn, desc)
    for _, key in ipairs(require("paseo.ui.keys").list(lhs)) do
      vim.keymap.set(modes, key, fn, { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc })
    end
  end
  map({ "n", "t" }, keys.chrome, function()
    vim.cmd.stopinsert()
  end, "out of the terminal, into normal mode")
  map({ "n", "t" }, keys.terminal, function()
    vim.cmd.startinsert()
  end, "back into the terminal")
  map({ "n", "t" }, keys.next, function()
    vim.cmd.tabnext()
  end, "the next tab")
  map({ "n", "t" }, keys.prev, function()
    vim.cmd.tabprevious()
  end, "the previous tab")
  map({ "n", "t" }, keys.sessions, function()
    local win = side_rails[api.nvim_get_current_tabpage()]
    if valid_win(win) then
      vim.cmd.stopinsert()
      api.nvim_set_current_win(win)
    end
  end, "the sessions, in the rail")
  map("n", "q", function()
    pcall(vim.cmd.tabclose)
  end, "close this tab (the terminal lives on)")
end

---Is the rail showing on the native tab you are looking at?
---@return boolean
function M.rail_shown()
  local t = entry(api.nvim_get_current_tabpage())
  return t ~= nil and valid_win(t.rail)
end

---Put the workspace rail down the left of THIS tab page, which is not an
---agent tab -- the read-only subagent view.
---
---Opening a subagent used to put you on a bare tab page: the rail you had
---been navigating by was simply gone until you went back. The rail is one
---buffer, so the same one goes here, and TabEnter points it at this window
---whenever you come back to this tab.
function M.rail_beside()
  local tab = api.nvim_get_current_tabpage()
  if valid_win(side_rails[tab]) then
    return side_rails[tab]
  end
  local rail = require "paseo.ui.rail"
  local width = rail_width()
  local from = api.nvim_get_current_win()
  vim.cmd(("topleft %dvsplit"):format(width))
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, rail.buf(rail_keys()))
  vim.wo[win].winfixwidth = true
  side_rails[tab] = win
  rail.adopt(win)
  rail.load()
  watch()
  if valid_win(from) then
    api.nvim_set_current_win(from)
  end
  return win
end

---`<C-s>`: into the rail, on the session on screen -- opening it first.
function M.focus_rail()
  local t = entry(api.nvim_get_current_tabpage())
  if not t then
    return
  end
  open_rail(t)
  if valid_win(t.rail) then
    local rail = require "paseo.ui.rail"
    rail.reveal()
    rail.draw()
    api.nvim_set_current_win(t.rail)
    rail.seat { session = true }
  end
end

---`<C-b>`: the rail on this tab, on or off.
function M.toggle_rail()
  local t = entry(api.nvim_get_current_tabpage())
  if not t then
    return
  end
  -- REMEMBERED, across tabs and restarts (|paseo.ui.rail|'s state file): a
  -- rail you hid stays hidden on the next agent's tab and the next session.
  if valid_win(t.rail) then
    local win = t.rail
    keep_width("rail", win)
    t.rail = nil
    pcall(api.nvim_win_close, win, true)
    require("paseo.ui.rail").set_visible(false)
    M.back()
    return
  end
  require("paseo.ui.rail").set_visible(true)
  open_rail(t)
end

-- ------------------------------------------------------------------- panels

---Write the panel's lines into its buffer.
---@param t paseo.NativeTab
local function draw_panel(t)
  if not (t.panel and valid_win(t.panel_win) and t.panel_buf and api.nvim_buf_is_valid(t.panel_buf)) then
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
  for tab in pairs(tabs) do
    local t = entry(tab)
    if t then
      draw_panel(t)
    end
  end
end

---Close this tab's panel.
---@param t paseo.NativeTab
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
---@param t paseo.NativeTab
---@param name string
local function show_panel(t, name)
  close_panel(t)
  local from = api.nvim_get_current_win()
  api.nvim_set_current_win(t.chat.win_conversation)
  vim.cmd(("botright %dvsplit"):format(panel_width()))
  t.panel_win = api.nvim_get_current_win()
  t.panel_buf = api.nvim_create_buf(false, true)
  t.panel = name
  vim.bo[t.panel_buf].bufhidden = "wipe"
  vim.bo[t.panel_buf].filetype = "paseo-panel"
  pcall(api.nvim_buf_set_name, t.panel_buf, ("paseo://panel/%s/%d"):format(name:lower(), t.panel_buf))
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
    strip[#strip + 1] = { (" %d %s "):format(i, panel_name), here and "PaseoChipFocus" or "PaseoDim" }
  end
  local key = require "paseo.ui.keys"
  local reload, close = key.label("panel", "r"), key.label("panel", "q")
  strip[#strip + 1] = {
    "  " .. (reload and (" " .. reload .. " reload") or "") .. (reload and close and " ·" or "") .. (close and (" " .. close .. " close") or ""),
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
  local t = entry(api.nvim_get_current_tabpage())
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
---@param name string
function M.panel(name)
  local t = entry(api.nvim_get_current_tabpage())
  if not t then
    return
  end
  show_panel(t, name)
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
    { "gt", "next agent" },
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
    left[#left + 1] = { "  " .. require("paseo.ui.icons").status.waiting .. " waiting on you", "PaseoBadge" }
  end

  local right = widgets.hints(hints(), nil, math.max(0, width - 30))
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
          vim.keymap.set("n", lhs, item[2], { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. item[3] })
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

---Drop a tab's bookkeeping.
---@param tab integer
local function forget(tab)
  local t = tabs[tab]
  tabs[tab] = nil
  if t and t.chat.native_tab == tab then
    t.chat.native_tab = nil
  end
end

local augroup

---The autocmds that keep `current`, the rail and the bookkeeping honest.
watch = function()
  if augroup then
    return
  end
  augroup = api.nvim_create_augroup("paseo.native", { clear = true })

  api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    desc = "paseo: the agent on this native tab is the current one",
    callback = function()
      local tab = api.nvim_get_current_tabpage()
      local t = entry(tab)
      if not t then
        -- A tab with a rail of its own that is not an agent's (the
        -- read-only subagent view): the rail follows you there too.
        if valid_win(side_rails[tab]) then
          require("paseo.ui.rail").adopt(side_rails[tab])
          require("paseo.ui.rail").draw()
        end
        return
      end
      require("paseo.ui.chat").set_current(t.chat)
      adopt_rail(t)
      require("paseo.ui.rail").draw()
      M.refresh(t.chat)
    end,
  })

  api.nvim_create_autocmd("TabLeave", {
    group = augroup,
    desc = "paseo: remember the editor tab you left for an agent's",
    callback = function()
      local tab = api.nvim_get_current_tabpage()
      if not entry(tab) then
        origin = tab
      end
    end,
  })

  api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    desc = "paseo: forget native tabs that are gone",
    callback = function()
      for tab, t in pairs(tabs) do
        if not api.nvim_tabpage_is_valid(tab) then
          forget(tab)
          t.chat.win_conversation, t.chat.win_composer = nil, nil
          if t.chat.surface == "native" then
            t.chat.surface = nil
          end
          unbind(t.chat)
          set_markdown(t.chat, false)
        end
      end
      sync_spinner()
    end,
  })

  -- `:q` in the conversation or the box takes the whole tab: half a chat is
  -- not a layout anything here knows how to draw.
  api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    desc = "paseo: a native tab goes with its conversation",
    callback = function(args)
      local closed = tonumber(args.match)
      for _, t in pairs(tabs) do
        local chat = t.chat
        if closed == chat.win_conversation or closed == chat.win_composer then
          vim.schedule(function()
            M.close(chat)
          end)
          return
        end
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
        for tab in pairs(tabs) do
          local t = entry(tab)
          if t then
            M.refresh(t.chat)
          end
        end
        M.redraw_panels()
        require("paseo.ui.newtask").redraw()
      end)
    end,
  })

  require("paseo.agents").on_change(function()
    vim.schedule(function()
      if M.any() then
        require("paseo.ui.rail").directory_changed()
        sync_spinner()
      end
    end)
  end)
end

---Put `chat` on a native tab: its own if it has one, a new one if not.
---@param chat table
function M.open(chat)
  watch()

  if M.has(chat) then
    api.nvim_set_current_tabpage(chat.native_tab)
    if valid_win(chat.win_composer) then
      api.nvim_set_current_win(chat.win_composer)
    end
    set_markdown(chat, true)
    M.refresh(chat)
    return
  end

  -- Windows left over from another surface's layout are not ours to reuse.
  chat.win_conversation, chat.win_composer = nil, nil

  vim.cmd "tabnew"
  local tab = api.nvim_get_current_tabpage()
  -- The tab is the agent's, so its directory is too: `:e`, telescope and
  -- `:Paseo explain` from here start where the agent works.
  local dir = chat.local_root or chat.root
  if dir and vim.fn.isdirectory(dir) == 1 then
    pcall(vim.cmd.tcd, vim.fn.fnameescape(dir))
  end
  local scratch = api.nvim_get_current_buf()
  local conversation = api.nvim_get_current_win()
  api.nvim_win_set_buf(conversation, chat.conversation)
  -- `tabnew`'s empty buffer, which nothing else is showing now.
  if
    api.nvim_buf_is_valid(scratch)
    and api.nvim_buf_get_name(scratch) == ""
    and not vim.bo[scratch].modified
    and #vim.fn.win_findbuf(scratch) == 0
  then
    pcall(api.nvim_buf_delete, scratch, {})
  end
  chat.win_conversation = conversation
  set_options(conversation, CONVERSATION)

  vim.cmd "belowright 1split"
  chat.win_composer = api.nvim_get_current_win()
  api.nvim_win_set_buf(chat.win_composer, chat.composer)
  require("paseo.ui.sidebar").style(chat.win_composer)
  vim.wo[chat.win_composer].fillchars = "eob: "
  require("paseo.ui.composer").style(chat)
  vim.wo[chat.win_composer].winfixheight = true

  chat.native_tab = tab
  chat.surface = "native"
  bind(chat)
  require("paseo.ui.surface").remember "native"
  local t = { chat = chat }
  tabs[tab] = t

  if config().rail > 0 and require("paseo.ui.rail").visible() then
    open_rail(t)
  end

  -- render-markdown.nvim attaches on `FileType`, which this buffer had long
  -- before the plugin was loaded (it is lazy on `ft = markdown`, and the
  -- event that loads it is the one it misses). Fire it again for that plugin
  -- alone -- its group, nobody else's handlers -- now there is a window.
  if config().markdown then
    pcall(api.nvim_exec_autocmds, "FileType", { group = "RenderMarkdown", buffer = chat.conversation })
    watch_markdown(chat)
  end

  -- Prose is width-free in markdown mode, but the tool cards are not: draw
  -- everything at this window's width.
  if not set_markdown(chat, true) then
    transcript.redraw(chat, { force = true })
  end
  require("paseo.ui.sidebar").fit_composer(chat)
  require("paseo.ui.chat").set_current(chat)
  M.refresh(chat)
  require("paseo.ui.composer").refresh(chat)
  sync_spinner()
  api.nvim_set_current_win(chat.win_composer)
end

---Take `chat`'s tab down. The chat lives on, as it does when any surface
---closes; reopening is `:Paseo native` again.
---@param chat table
function M.close(chat)
  local tab = chat.native_tab
  local t = tab and tabs[tab]
  if t then
    close_panel(t)
  end
  if tab then
    forget(tab)
  end
  chat.win_conversation, chat.win_composer = nil, nil
  if chat.surface == "native" then
    chat.surface = nil
  end
  unbind(chat)
  set_markdown(chat, false)

  if tab and api.nvim_tabpage_is_valid(tab) then
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

---A session from the rail. An agent is a chat, so it gets a tab of its own; a
---terminal gets one too, holding the PTY.
---@param session { kind: string, id: string, hostId?: string }
function M.show_session(session)
  local here = M.chat()
  local host_id = session.hostId or (here and here.host_id)
  if session.kind == "agent" then
    local agent = require("paseo.agents").get(session.id, host_id)
    return require("paseo.ui.chat").open {
      root = (agent and agent.cwd) or (here and here.root),
      host_id = host_id,
      remote = true,
      agent_id = session.id,
      title = agent and agent.title,
      surface = "native",
    }
  end
  if session.kind == "terminal" then
    local terminal = require("paseo.terminals").get(session.id, host_id)
      or { id = session.id, hostId = host_id }
    local ui = require "paseo.ui.terminal"
    local keep_rail = M.rail_shown()
    vim.cmd "tabnew"
    local win = api.nvim_get_current_win()
    local scratch = api.nvim_get_current_buf()
    local view = ui.ensure(terminal, win)
    ui.show(view, win)
    -- The rail comes too, as it does for a subagent's view: a tab of its own
    -- is not a reason to lose the way back.
    if keep_rail then
      M.rail_beside()
      api.nvim_set_current_win(win)
    end
    M.bind_terminal(view.buf)
    if api.nvim_buf_is_valid(scratch) and #vim.fn.win_findbuf(scratch) == 0 then
      pcall(api.nvim_buf_delete, scratch, {})
    end
    vim.cmd "startinsert"
  end
end

---A workspace from the rail: its agent, on a native tab. The workspace's
---sessions are under it on the rail for picking one in particular.
---@param ws table
function M.open_workspace(ws)
  local here = M.chat()
  local host_id = ws.hostId or (here and here.host_id)
  -- BY WORKSPACE ID. Several workspaces can share one directory -- every
  -- `paseo run` in a repository makes its own -- so opening by directory
  -- reused whichever chat was already on screen for it.
  local newest
  for _, agent in ipairs(require("paseo.agents").all(host_id)) do
    if ws.id and agent.workspaceId == ws.id and (not newest or (agent.createdAt or "") > (newest.createdAt or "")) then
      newest = agent
    end
  end
  if newest then
    return M.show_session { kind = "agent", id = newest.id, hostId = host_id }
  end
  require("paseo.ui.chat").open {
    root = ws.directory,
    local_root = ws.local_directory,
    host_id = ws.hostId or (here and here.host_id),
    remote = true,
    surface = "native",
  }
end

---Forget everything. For the test suite.
function M.reset()
  tabs = {}
  last_panel = "Settings"
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

return M
