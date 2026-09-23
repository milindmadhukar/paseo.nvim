--- The full-screen surface: the conversation, plus everything about the
--- agent session, on dashboard tabs.
---
--- The DEFAULT surface. The sidebar is for asking a question beside your code;
--- this is for the rest of the time -- when you want to see what the agent is
--- doing, what it has cost, what is changed on disk, which agent sessions are running
--- and where, and to change the mode without a `vim.ui.select` prompt covering
--- the thing you are reading.
---
--- Structure, from the bottom up: a dimmed backdrop, a volt-drawn chrome window
--- carrying the tab bar and the active panel, and -- on the conversation tab
--- only -- the real conversation and composer buffers floated on top. The
--- chrome is volt's; the conversation is never volt's, because virtual text
--- cannot be yanked.
---
--- ONE NAVIGATION BAR. There used to be two: the tabs, and a strip of session
--- chips on the row directly under them. Two rows of things to click, stacked,
--- disagreeing about which of them you navigate with -- so the strip is gone
--- and the Sessions tab is where you move between sessions, with a search over
--- them. What the strip alone could say -- WHICH session the Chat tab is
--- showing, which a terminal has nothing else to say it -- is drawn at the
--- right-hand end of the tab bar, as a label rather than as a control.
---
--- The chrome is THREE volt sections rather than one, and that is not tidiness:
--- the footer repaints ten times a second while a turn runs, and a single
--- section would drag the Changes panel -- which shells out to `git status` per
--- repo -- through every one of those frames.

local icons = require "paseo.ui.icons"
local layout = require "paseo.ui.layout"
local render = require "paseo.ui.render"
local style = require "paseo.ui.style"
local widgets = require "paseo.ui.widgets"
local sidebar = require "paseo.ui.sidebar"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.float"

---@type table|nil
local state

M.TABS = { "Chat", "Sessions", "Settings", "Changes", "Usage", "Workspaces" }

--- Tab name -> the module under `paseo.ui.panels` that draws it: the name,
--- lowercased. The list tab was spelled `Agents & terminals` -- for what it
--- holds, at the cost of a per-tab exception table here, a name too long to
--- say in a sentence, and a bar whose second pill was three times the width of
--- the rest. It holds SESSIONS. That agents and terminals are both sessions is
--- the whole point of the list, and the kind glyph on each row says which.
---@param name string
---@return string
local function panel_module(name)
  return name:lower()
end

-- --------------------------------------------------------------- push feeds

---A repaint is already queued.
local settling = false

---The tabs whose BODY says something about the agent directory, and so have to
---be redrawn when it changes.
local BODY_FOLLOWS_AGENTS = { Sessions = true, Workspaces = true }

---One spinner frame, matching |paseo.ui.widgets|.spinner's own 100ms.
local SPINNER_MS = 100

---@type uv.uv_timer_t|nil
local spinner_timer

local function stop_spinner()
  if not spinner_timer then
    return
  end
  spinner_timer:stop()
  if not spinner_timer:is_closing() then
    spinner_timer:close()
  end
  spinner_timer = nil
end

---Is there a turning glyph on screen right now?
---@return boolean
local function spinner_wanted()
  return state ~= nil
    and state.tab == "Workspaces"
    and api.nvim_buf_is_valid(state.buf)
    and require("paseo.agents").busy()
end

---A 10Hz repaint while a workspace row is spinning, and NOT A MOMENT LONGER.
---
---The push feed is not a clock. Agent updates arrive every few hundred
---milliseconds and `directory_changed` coalesces them at 120ms on top of that,
---which is a stutter rather than a spinner -- so the frames need a clock of
---their own. This is it, and it exists only while something is actually
---turning: a timer redrawing a tab nobody is looking at is the leak that
---matters, which is why every caller goes through here rather than starting
---one.
---
---Only the `body` section, and only a glyph swap inside it: volt records each
---section's start row when the layout is measured and never recomputes it, so
---a repaint that changed a row COUNT would draw every section below it at the
---wrong row. See |paseo.ui.animate|'s header.
local function sync_spinner()
  if not spinner_wanted() then
    return stop_spinner()
  end
  if spinner_timer then
    return
  end
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    SPINNER_MS,
    SPINNER_MS,
    vim.schedule_wrap(function()
      if not spinner_wanted() then
        return stop_spinner()
      end
      pcall(require("volt").redraw, state.buf, { "body" })
    end)
  )
end

---Redraw what a CHANGE IN THE DIRECTORY changes: the tab bar -- whose
---right-hand end names the session you are in -- and the session list if that
---is the tab you are on.
---
---THIS IS WHY ARCHIVING A SESSION DID NOTHING until you moved. Both
---directories are push-fed -- that is the entire point of the sidecar -- and
---both were being kept perfectly up to date in |paseo.agents| and
---|paseo.terminals| with nothing asking the surface to draw them again. The
---row only disappeared when something else caused a redraw, which in practice
---was the next `j`, or a mouse-move over the panel: the data was right and the
---picture was a second-hand copy of it.
---
---Coalesced, because one archive produces three `remove` events (measured
---against a live daemon) and an agent working produces a status update every
---few hundred milliseconds. `gen_data` is deliberately NOT re-run: every
---panel's `lines` is padded to the body height, so the sections keep the row
---counts volt measured.
local function directory_changed()
  if not state or settling then
    return
  end
  settling = true
  vim.defer_fn(function()
    settling = false
    if not (state and api.nvim_buf_is_valid(state.buf)) then
      return
    end
    local sections = { "tabs" }
    -- Only the tabs that DRAW the directory redraw their body. Redrawing any
    -- other would re-run that panel's `lines` -- `git status` per repo, on the
    -- Changes tab -- for a change it does not show. Workspaces earns its place
    -- here because every row carries what its agents are doing; without it the
    -- status column was a snapshot from whenever the tab was last rebuilt.
    if BODY_FOLLOWS_AGENTS[state.tab] then
      sections[#sections + 1] = "body"
    end
    pcall(require("volt").redraw, state.buf, sections)
    -- An agent that just STARTED is the event that makes a spinner necessary,
    -- and one that just finished is the event that makes it stop.
    sync_spinner()
  end, 120)
end

---Follow both directories, once per session.
---
---Subscribing is |paseo.agents|' and |paseo.terminals|' job and they are
---already doing it -- the panels ask for it when they draw. All this adds is
---the listener that turns an update into a repaint.
local watching = false
local function watch_directories()
  if watching then
    return
  end
  watching = true
  require("paseo.agents").on_change(directory_changed)
  require("paseo.terminals").on_change(directory_changed)
end

-- ----------------------------------------------------------------- the mount

---What a NORMAL window has to be turned into before volt may draw in it.
---
---`wrap` is the one that is not taste. Volt writes `h` lines of `w` spaces and
---addresses rows by INDEX -- one wrapped line puts every row below it one off
---its extmark, and the surface comes apart from the bottom up. The gutter
---options are the second half of the same problem: `virt_text_win_col` counts
---from the TEXT AREA and a win-relative pane counts from the window ORIGIN,
---so every column of gutter is a column of disagreement between the chrome
---and the panes floated over it. 'statuscolumn' is in the list because a
---user's global one is how a gutter comes back after you have turned the
---other three off.
---
---DELIBERATELY NOT `ui/sidebar.lua`'s `WINDOW`, which this otherwise nearly
---duplicates: its first entry is `wrap = true`, which is right for a pane of
---real wrapped text and is precisely the value that breaks volt here. One
---shared table would be an invitation to "fix" the disagreement in the wrong
---direction.
local HOST = {
  wrap = false,
  linebreak = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  cursorline = false,
  cursorcolumn = false,
  colorcolumn = "",
  list = false,
  spell = false,
  scrolloff = 0,
  sidescrolloff = 0,
  -- The chrome draws its own rows as volt sections. A winbar would sit above
  -- them and cost the chrome the row it measured itself against.
  winbar = "",
  winblend = 0,
}

---The one `HOST` entry that is not the same on both mounts.
---
---On a tab page of its own the dashboard is the only thing there and `:e
---file` from it is a mistake -- there is no window for the file to go to that
---is not this one. Taking over the window you were standing in is the
---opposite: the file goes exactly where it was always going to go, and the
---dashboard getting out of the way is the point. `bufhidden = "wipe"` and the
---`BufWipeout` handler are what make that safe -- volt's extmarks are on a
---buffer that no longer exists by the time the file is loaded.
local FIXBUF = { tab = true, here = false }

---The filetype the buffer surface carries.
---
---The nvim-tree parallel, and the thing to hang an `ftplugin/` off. Spelled
---the way the plugin's other owned buffers are -- `paseo-create`,
---`paseo-settings`, `paseo-manifest`, `paseo-answer`.
M.FILETYPE = "paseo-dash"

---How many dashboards have wanted the name. See `host_buf`.
local named = 0

---The window options `style_host` overwrites, so a window HANDED BACK is the
---window it was. `winhl` is in the list because the host is repainted into
---the surface's own background and a file buffer left in it would keep that.
---@param win integer
---@return table<string, any>
local function capture_host(win)
  local saved = {}
  local function keep(option)
    local ok, value = pcall(function()
      return vim.wo[win][option]
    end)
    if ok then
      saved[option] = value
    end
  end
  for option in pairs(HOST) do
    keep(option)
  end
  keep "winhl"
  keep "winfixbuf"
  return saved
end

---Put them back. Nothing else may be in `saved`: it is `capture_host`'s.
---@param win integer
---@param saved table<string, any>
local function restore_host(win, saved)
  if not (win and api.nvim_win_is_valid(win) and saved) then
    return
  end
  for option, value in pairs(saved) do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
end

---@param win integer
---@param how "tab"|"here"
local function style_host(win, how)
  for option, value in pairs(HOST) do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
  pcall(function()
    vim.wo[win].winfixbuf = FIXBUF[how]
  end)

  -- `NormalNC` is the entry the float never needed and this mount cannot do
  -- without: the cursor lives in the composer PANE, so the host is a
  -- not-current window nearly all of the time, and a colourscheme that dims
  -- `NormalNC` would tint the whole dashboard whenever you were typing.
  --
  -- The statusline groups are here rather than in `HOST` for the same reason
  -- 'laststatus' is not touched at all: the statusline is outside the height
  -- we measured, so it costs the layout nothing -- but a bright rule under
  -- the surface is still a bright rule under the surface.
  pcall(function()
    vim.wo[win].winhl = table.concat({
      "Normal:PaseoNormal",
      "NormalNC:PaseoNormal",
      "EndOfBuffer:PaseoNormal",
      "SignColumn:PaseoNormal",
      "CursorLine:PaseoNormal",
      "StatusLine:PaseoNormal",
      "StatusLineNC:PaseoNormal",
    }, ",")
  end)
end

---The chrome buffer, for a mount that has to survive being displaced.
---
---`bufhidden = "wipe"` rather than the float's `hide`: this buffer sits in a
---window the user can `:e` out of, and a volt buffer nobody can see is still
---a volt buffer on `volt.events.bufs`, still dispatching clicks. Gone with
---its window is the only state that stays honest -- which is what the
---unconditional volt cleanup in `M.close` is there to survive.
---@return integer
local function host_buf()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  -- A `://` name is not expanded against the cwd the way a bare word would
  -- be, and the default tabline shows its tail -- `dashboard`. `E95` if a
  -- stale one outlived us, which is what the counter is for.
  if not pcall(api.nvim_buf_set_name, buf, "paseo://dashboard") then
    named = named + 1
    pcall(api.nvim_buf_set_name, buf, ("paseo://dashboard-%d"):format(named))
  end
  return buf
end

---A tab page of its own, holding this buffer and nothing else.
---
---`:tab sbuffer` rather than `:tabnew` + `nvim_win_set_buf`, which leaves the
---new tab's own empty buffer behind -- listed, loaded and never collected --
---once per open for the length of the session.
---
---After the current tab rather than at the end: the dashboard for what you
---are looking at belongs next to it.
---@param buf integer
---@return integer win, integer tabpage
local function mount_tab(buf)
  local ok = pcall(vim.cmd, ("tab sbuffer %d"):format(buf))
  if not (ok and api.nvim_get_current_buf() == buf) then
    -- 'switchbuf' is the only thing that can redirect `sbuffer`, and the
    -- fallback costs four lines.
    vim.cmd "tabnew"
    local scratch = api.nvim_get_current_buf()
    api.nvim_win_set_buf(0, buf)
    if
      scratch ~= buf
      and api.nvim_buf_is_valid(scratch)
      and api.nvim_buf_get_name(scratch) == ""
      and not vim.bo[scratch].modified
    then
      pcall(api.nvim_buf_delete, scratch, { force = true })
    end
  end
  return api.nvim_get_current_win(), api.nvim_get_current_tabpage()
end

---@class paseo.Float.Displaced
---@field win integer      The window we took.
---@field buf integer|nil  What it held.
---@field view table|nil   And where it was scrolled to.
---@field options table    `capture_host`'s.
---@field showtabline integer|nil  The editor chrome we turned off, if we did.
---@field laststatus integer|nil

---Whether the editor's own tabline and statusline come down with the surface.
---@return boolean
local function bare()
  local ui = require("paseo.config").get().ui
  return (ui.buffer or {}).chrome ~= true
end

---Take the two global rows off, and remember what they were.
---
---BEFORE the geometry is measured, not after: 'laststatus' is a row out of
---the host window itself, so hiding it after measuring leaves the chrome one
---row short of the box it is drawn in for as long as nothing forces a re-fit.
---@param displaced paseo.Float.Displaced
local function hide_chrome(displaced)
  if not bare() then
    return
  end
  displaced.showtabline, displaced.laststatus = vim.o.showtabline, vim.o.laststatus
  vim.o.showtabline, vim.o.laststatus = 0, 0
end

---@param displaced paseo.Float.Displaced|nil
local function show_chrome(displaced)
  if not displaced then
    return
  end
  if displaced.showtabline ~= nil then
    vim.o.showtabline = displaced.showtabline
  end
  if displaced.laststatus ~= nil then
    vim.o.laststatus = displaced.laststatus
  end
end

---Take over the window you are standing in.
---
---nvdash's arrangement, and the default, because this surface is ONE window
---and a tab page is an arrangement of windows. The tab bought nothing: it put
---a tabline up over a surface that draws a header of its own, and it made
---"back to my code" a `gt` rather than the key that opened it.
---
---What the window held is remembered HERE rather than left to Neovim's
---alternate file. `bufhidden = "wipe"` means our own buffer is gone before
---anyone could ask `#` what it replaced, `#` is per window and any `:b` in
---between rewrites it, and the view -- the line you were on, where the window
---was scrolled to -- is not in the alternate file at all. Coming back to the
---right file on the wrong line is the half of "goes back to where I was" that
---gets noticed.
---
---A FLOAT IS NOT A WINDOW TO TAKE OVER. Opening the dashboard from inside
---somebody else's float -- a picker, its preview, a terminal popup -- would
---mount it on a window that is about to close itself and take the surface
---with it, so the search is for a normal window on this tab page and
---`mount_tab` is the fallback when there is none.
---@param buf integer
---@return integer win, integer|nil tabpage, paseo.Float.Displaced|nil
local function mount_here(buf)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative ~= "" then
    win = nil
    for _, candidate in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_config(candidate).relative == "" then
        win = candidate
        break
      end
    end
  end
  if not win then
    local fallback, tabpage = mount_tab(buf)
    return fallback, tabpage, nil
  end

  local displaced = {
    win = win,
    buf = api.nvim_win_get_buf(win),
    view = api.nvim_win_call(win, vim.fn.winsaveview),
    options = capture_host(win),
  }
  hide_chrome(displaced)
  -- 'winfixbuf' is somebody else's, on a window we did not open -- nvim-tree
  -- and oil both set it -- and `nvim_win_set_buf` fails outright against it.
  pcall(function()
    vim.wo[win].winfixbuf = false
  end)
  api.nvim_win_set_buf(win, buf)
  api.nvim_set_current_win(win)
  return win, nil, displaced
end

---Hand the window back the way it was found.
---
---Three cases, and the middle one is the one worth stating: the window is
---STILL OURS, so put the buffer and the view back; the window is gone --
---`:q`, `:only`, `:tabclose` -- so there is nothing to give back; or the
---window holds something else already, which is `:e file` from the dashboard
---doing exactly what it should, and touching it now would close the file the
---user just opened.
---@param held table  The dead `state`.
---@return boolean  Did this leave the host window standing?
local function restore_here(held)
  local displaced = held.displaced
  show_chrome(displaced)
  if not displaced then
    return false
  end

  local win = displaced.win
  if not (win and api.nvim_win_is_valid(win)) then
    return false
  end

  local ours = api.nvim_win_get_buf(win) == held.buf
  if ours then
    if displaced.buf and api.nvim_buf_is_valid(displaced.buf) then
      pcall(api.nvim_win_set_buf, win, displaced.buf)
    else
      -- The buffer we displaced was deleted while the dashboard was up. An
      -- empty one rather than closing the window: the window is the user's,
      -- we only borrowed it.
      pcall(api.nvim_win_call, win, function()
        vim.cmd "enew"
      end)
    end
  end

  -- THE OPTIONS GO BACK EITHER WAY, and the case where it is not obvious is
  -- the one that matters: `:e file` from the dashboard leaves the window
  -- holding somebody's source with 'wrap' off, no gutter and `Normal` linked
  -- to the surface's own background. The buffer is not ours any more; the
  -- window still is.
  restore_host(win, displaced.options)
  -- The view is, though. It is where the buffer we just put back was scrolled
  -- to, and against anything else it is a line number from another file.
  if ours and displaced.view then
    pcall(api.nvim_win_call, win, function()
      vim.fn.winrestview(displaced.view)
    end)
  end
  return true
end

-- ------------------------------------------------------------------ geometry

---Where the surface sits, how big it is, and how it stacks.
---
---The z-index is the half worth explaining. It used to be 100, which is ABOVE
---the 50 that `nvim_open_win` and plenary's popup hand out by default -- so
---every telescope picker, diff preview and `vim.ui.select` opened from the
---dashboard rendered underneath it and looked like nothing had happened.
---Sitting below the default means the things you open on top of the dashboard
---are on top of it. The one window that must never be covered -- the
---permission dialog -- asks for its own z-index well above both.
---@return table
local function float_geometry()
  local config = require "paseo.config"
  local ui = config.get().ui.float
  local columns, lines = vim.o.columns, vim.o.lines

  -- Floored at a size the layout still works in -- below this the tab bar and
  -- the composer stop fitting -- and capped at the editor, so neither a tiny
  -- terminal nor an over-large setting can put the border off screen.
  local w = math.min(columns, math.max(60, config.cells(ui.width, columns, 94)))
  local h = math.min(lines, math.max(20, config.cells(ui.height, lines, 86)))

  -- Centred when `row`/`col` say nothing. `(total - size) / 2` is exactly the
  -- formula floaterm centres with, so a config that gives both the same size
  -- gets both in the same place and switching between them does not jump.
  --
  -- These two are CELLS rather than percentages: they are window coordinates,
  -- not sizes, and "row 3" is what you mean when you pin a window.
  local row = type(ui.row) == "number" and math.floor(ui.row) or math.floor((lines - h) / 2)
  local col = type(ui.col) == "number" and math.floor(ui.col) or math.floor((columns - w) / 2)

  -- The composer is measured from the bottom, so the conversation gets what is
  -- left. A CEILING it grows to rather than a height it stands at -- see
  -- `M.resize_composer`. Clamped to leave the conversation at least five rows.
  local composer = ui.composer
  if type(composer) == "function" then
    composer = composer(h)
  end
  composer = type(composer) == "number" and math.floor(composer) or 7
  composer = math.max(1, math.min(composer, h - 10))
  local composer_min = type(ui.composer_min) == "number" and math.floor(ui.composer_min) or 3

  local z = ui.zindex or 30
  return {
    -- Which MOUNT this geometry describes. The dashboard is the same surface
    -- either way -- same chrome, same six tabs, same panes -- and the only
    -- thing that differs is what it is anchored to, so the difference lives
    -- in the geometry rather than in a second copy of the module.
    mount = "float",
    relative = "editor",
    width = w,
    height = h,
    -- Whether the chrome window has a frame, which decides where its first
    -- CONTENT row is -- `nvim_open_win` is handed the border's row, not the
    -- content's. |paseo.ui.layout|.screen_row is the one place that matters,
    -- and everything floated over the body is positioned through it.
    border = select(1, style.window_border()) ~= "none",
    row = math.max(0, math.min(row, lines - h)),
    col = math.max(0, math.min(col, columns - w)),
    composer = composer,
    composer_min = math.max(1, math.min(composer_min, composer)),
    backdrop = ui.backdrop ~= false,
    -- The panes are ABOVE the chrome they sit on and below anything opened
    -- over the whole surface.
    z_backdrop = math.max(1, z - 5),
    z_chrome = z,
    z_panes = z + 5,
  }
end

---A dashboard setting, from `ui.buffer` if the buffer mount overrides it and
---from `ui.float` otherwise.
---
---`composer`, `zindex` and `tab_keys` describe the DASHBOARD -- how tall the
---prompt box grows, how the panes stack, whether a bare digit switches tab --
---and not the mount. Restating all three under `ui.buffer` would be three
---more places for the two surfaces to drift apart on a question neither of
---them asks differently. So `ui.buffer` carries what is genuinely its own,
---and inherits the rest.
---@param name string
---@return any
local function dash_option(name)
  local ui = require("paseo.config").get().ui
  local value = (ui.buffer or {})[name]
  if value == nil then
    value = ui.float[name]
  end
  return value
end

---The box when the dashboard IS a window rather than one floated over the
---editor: the host window's own text area, exactly.
---
---`row` and `col` are NOT zero, and that is the whole reason |paseo.ui.layout|
---needs no branch for this mount. A win-relative float at `0,0` sits at the
---host's ORIGIN -- above the winbar, left of the gutter -- while volt draws
---with `virt_text_win_col`, which counts from the TEXT AREA. Feeding the
---winbar row into `row` and 'textoff' into `col` cancels exactly that
---difference, and `layout.screen_row` then answers win-relative coordinates
---with the same arithmetic it has always used for screen ones.
---
---'textoff' is read rather than assumed zero even though `HOST` turns every
---gutter off: a user's global 'statuscolumn', or a `FileType` autocmd that
---puts numbers back, would otherwise shift the chrome text one way and the
---panes the other.
---@param win integer
---@return table
local function host_geometry(win)
  local info = vim.fn.getwininfo(win)[1] or {}
  local textoff = info.textoff or 0
  -- `nvim_win_get_height` INCLUDES the winbar row; `getwininfo().height` is
  -- the text rows, which is what the chrome buffer actually has to fill.
  local h = math.max(1, info.height or api.nvim_win_get_height(win))
  local w = math.max(1, api.nvim_win_get_width(win) - textoff)

  -- A FUNCTION OF THE SURFACE'S ROWS, not just a number. This mount's default
  -- is a share of the host rather than the float's flat seven, which is the
  -- whole reason the option grew a function form: a ceiling written in cells
  -- fits one terminal.
  local composer = dash_option "composer"
  if type(composer) == "function" then
    composer = composer(h)
  end
  composer = type(composer) == "number" and math.floor(composer) or 7
  composer = math.max(1, math.min(composer, h - 10))
  local composer_min = dash_option "composer_min"
  composer_min = type(composer_min) == "number" and math.floor(composer_min) or 3
  composer_min = math.max(1, math.min(composer_min, composer))

  local z = math.floor(dash_option "zindex" or 30)
  return {
    mount = "buffer",
    relative = "win",
    host = win,
    width = w,
    height = h,
    -- There is no frame, so `screen_row` adds nothing for one.
    border = false,
    row = (vim.wo[win].winbar or "") ~= "" and 1 or 0,
    col = textoff,
    composer = composer,
    composer_min = composer_min,
    -- Nothing behind a tab page to dim.
    backdrop = false,
    z_backdrop = 1,
    -- Vestigial on this mount -- the chrome is a normal window, and a normal
    -- window is below every float whatever number you write here. Kept so the
    -- two geometries have one shape.
    z_chrome = z,
    z_panes = z + 5,
  }
end

---@param mount string|nil
---@param host integer|nil
---@return table
local function geometry_for(mount, host)
  if mount == "buffer" and host and api.nvim_win_is_valid(host) then
    return host_geometry(host)
  end
  return float_geometry()
end

---The `relative` half of a window config, from the geometry rather than from
---a literal.
---
---THE one thing that makes the panes mount-aware. The float's are relative to
---the editor; the buffer mount's are relative to its host window -- which is
---also what puts them on the host's TAB PAGE rather than on whichever tab
---happened to be current when a re-fit ran.
---
---Both keys, always. `nvim_win_set_config` given `relative = "win"` with no
---`win` re-anchors to the CURRENT window, which during a re-fit is routinely
---not ours.
---@param g table
---@return table
local function anchor(g)
  if g.relative == "win" and g.host and api.nvim_win_is_valid(g.host) then
    return { relative = "win", win = g.host }
  end
  return { relative = "editor" }
end

---A window config built on whatever the geometry is anchored to.
---@param g table
---@param opts table
---@return table
local function placed(g, opts)
  return vim.tbl_extend("error", anchor(g), opts)
end

-- -------------------------------------------------------------------- chrome

---Jump to a tab, as a click action.
---@param name string
---@return fun()
local function goto_tab(name)
  return function()
    M.select(name)
  end
end

---Which session the Chat tab is showing, as `icon, label`.
---
---WHAT THE STRIP WAS FOR, and all of it that was worth a row of its own. A
---terminal session has no composer bar and no transcript, so without this the
---dashboard could be showing a PTY with nothing on screen saying which one.
---The rest of what the strip did -- moving between sessions -- is the Sessions
---tab's job, and doing it in two places is what made the strip a second
---navigation bar under the first.
---@return string|nil icon, string|nil label
local function session_label()
  local chat = state.chat
  local here = state.session or { kind = "agent", id = chat.agent_id, hostId = chat.host_id }

  if here.kind == "terminal" then
    local terminals = require "paseo.terminals"
    local item = here.id and terminals.get(here.id, here.hostId or chat.host_id)
    if not item then
      return nil
    end
    return icons.panel.Terminals, terminals.label(item)
  end

  -- BY ID, not by filtering the directory on the root: this row repaints ten
  -- times a second while a turn runs, and `for_root` resolves a symlink per
  -- agent to compare paths.
  local agent = here.id and require("paseo.agents").get(here.id, here.hostId or chat.host_id)
  if agent then
    return icons.panel.Sessions, agent.title or agent.id
  end
  -- Before the directory has landed -- a cold open is a repaint or two ahead
  -- of the daemon -- there is still a session on screen, so it is named from
  -- what we have rather than left blank and then appearing.
  if here.id then
    return icons.panel.Sessions, chat.title or here.id:sub(1, 8)
  end
  return nil
end

---The tab bar and the rule under it.
---
---Each tab is numbered in the bar itself. The footer used to advertise "1-5
---jump" and nothing on screen said which number was which, so the hint was
---unusable even where the keys worked.
---
---The right-hand end carries the session label -- see `session_label`. It is
---the LAST thing on the row to get any width: the pills say which key goes
---where, which is the one thing this row cannot do without.
---@return table[][]
local function tab_lines()
  if not state then
    return { {}, {} }
  end
  -- One pill per tab, number and name inside the same background, so a tab is
  -- a shape you can aim at rather than two differently-coloured words that
  -- happen to sit next to each other.
  --
  -- Truncation is not a neutral failure here: the bar is the only place that
  -- says which number is which tab, and the tab that falls off the end is
  -- always the last one, which is the one you had not discovered yet. Six
  -- pills fit an 80-column terminal with two columns to spare; a SEVENTH does
  -- not. So when they do not fit, the pills you are not on keep their number
  -- and lose their name -- which still says which key goes where, and is the
  -- one thing this row exists to say. The row count never changes, because
  -- `g.height - 4` and the composer geometry are both measured against it.
  local inner = state.geometry.width - 2

  ---A pill's text at a given level of detail.
  ---@param i integer
  ---@param name string
  ---@param level "full"|"named"|"icon"|"number"
  ---@return string
  local function pill(i, name, level)
    local icon = icons.panel[name] or ""
    if level == "full" then
      return (" %d %s %s "):format(i, icon, name)
    end
    if level == "named" then
      return (" %d %s "):format(i, name)
    end
    if level == "icon" then
      return (" %d %s "):format(i, icon)
    end
    return (" %d "):format(i)
  end

  ---@param level "full"|"named"|"icon"|"number"
  ---@return integer
  local function measure(level)
    local width = -1 -- the gap before the first pill is never drawn
    for i, name in ipairs(M.TABS) do
      -- At the narrowest level the ACTIVE tab still keeps its name: the row
      -- has to say where you are even when it cannot say where everything
      -- else is.
      local at = (level == "number" and name == state.tab) and "named" or level
      width = width + 1 + vim.fn.strwidth(pill(i, name, at))
    end
    return width
  end

  -- Truncation is not a neutral failure here: the bar is the only place that
  -- says which number is which tab, and the tab that falls off the end is
  -- always the last one, which is the one you had not discovered yet. So the
  -- bar DEGRADES instead, a step at a time, and every level still says which
  -- key goes where -- the one thing this row exists to say.
  --
  --   full    1 󰭻 Chat      number, icon and name
  --   named   1 Chat        the icon goes first: the name is the thing you
  --                         read, the icon is the thing you recognise, and a
  --                         name you cannot read is worth less than one you can
  --   icon    1 󰭻           seven of these fit in 41 columns
  --   number  1             with the active tab alone keeping its name
  --
  -- The row count never changes at any level, because the body height and the
  -- composer geometry are both measured against it.
  ---The bar at one level of detail.
  ---@param level "full"|"named"|"icon"|"number"
  ---@return table[]
  local function bar(level)
    local tabs = {}
    for i, name in ipairs(M.TABS) do
      local active = name == state.tab
      local id = "paseo:tab:" .. name
      local hovered = vim.g.nvmark_hovered == id
      -- Gap BEFORE each pill but the first, never after the last.
      if i > 1 then
        tabs[#tabs + 1] = { " ", nil }
      end
      tabs[#tabs + 1] = {
        pill(i, name, (level == "number" and active) and "named" or level),
        (active or hovered) and "PaseoChipFocus" or "PaseoChipOff",
        -- Hover paints a tab exactly as focus does, so pointing at one and
        -- being on one look like the same state, because they are.
        { click = goto_tab(name), hover = { id = id, redraw = "tabs" } },
      }
    end
    return tabs
  end

  -- THE LABEL TAKES WHAT THE PILLS LEAVE, and never a column more. It is the
  -- only thing on screen naming the session a terminal is showing, which is
  -- why it is on this row at all -- but the pills are the navigation, and a
  -- bar that gave up six tab names to spell out one session title would have
  -- traded the thing you steer with for the thing you are looking at. So it
  -- is cut to fit, down to a glyph and a few letters, and dropped below that.
  local icon, label = session_label()
  local label_cells
  if icon then
    local hl = (state.session and state.session.kind == "terminal") and "PaseoYellow1"
      or "PaseoBlue1"
    label_cells = { { icon .. " ", hl }, { label, "PaseoDim" }, { " " } }
  end
  -- Enough to be worth drawing: the glyph, and enough of a name to recognise.
  local floor = icon and (vim.fn.strwidth(icon) + 5) or 0

  local levels = { "full", "named", "icon", "number" }
  local at = #levels
  for i, candidate in ipairs(levels) do
    if measure(candidate) <= inner then
      at = i
      break
    end
  end
  local level = levels[at]

  local line = render.truncate(bar(level), inner)
  if label_cells then
    local room = inner - render.width(line) - 2
    local width = render.width(label_cells)
    if room >= width then
      line = widgets.row(line, label_cells, inner)
    elseif room >= floor then
      -- Cut the NAME, never the glyph: `󰆍 lazyg…` still says which kind of
      -- session this is and roughly which one.
      line = widgets.row(line, render.truncate(label_cells, room), inner)
    elseif room >= vim.fn.strwidth(icon) + 1 then
      line = widgets.row(line, { { icon .. " ", label_cells[1][2] } }, inner)
    end
  end

  -- NO rule under the tabs, in any style. It used to be drawn for the framed
  -- ones, and that was the "three frame weights in one window" complaint in
  -- miniature: the float's own edge, a full-bleed rule directly under the
  -- pills, and a box around every card below it. The pills are a row of filled
  -- shapes and delimit the bar perfectly well by themselves -- which is why
  -- the unframed styles never wanted it and why the framed ones do not either.
  --
  -- The ROW stays. Dropping it would shift every section below, and volt
  -- records each section's start row when the layout is measured and never
  -- recomputes it on redraw.
  return { line, {} }
end

---The active panel, padded to the space between the tabs and the footer.
---@return table[][]
local function body_lines()
  if not state then
    return { {} }
  end
  local g = state.geometry
  local height = layout.rows(g.height).body_height
  local lines = {}

  if state.tab ~= "Chat" then
    local ok, panel = pcall(require, "paseo.ui.panels." .. panel_module(state.tab))
    -- The height is passed as well as the width. A panel that can tighten
    -- itself -- Agent drops the breathing room inside its cards -- needs to
    -- know how many rows it is being given, and the rest simply ignore it.
    local body = ok and panel.lines(state.chat, g.width - 4, height)
      or {
        { { "  this panel is unavailable", "PaseoToolFail" } },
      }
    for _, line in ipairs(body) do
      local row = { { "  ", nil } }
      vim.list_extend(row, render.truncate(vim.deepcopy(line), g.width - 4))
      lines[#lines + 1] = row
    end
  end
  -- On the Chat tab there is nothing to draw: the conversation is a real
  -- buffer floated over exactly this area.

  -- Pad out: volt draws one extmark per row at a row computed in `gen_data`
  -- and clears nothing first, so a panel that shrank leaves the previous
  -- draw's rows behind with nothing to overwrite them.
  while #lines < height do
    lines[#lines + 1] = {}
  end
  while #lines > height do
    table.remove(lines)
  end
  return lines
end

---@return table[][]
local function footer_lines()
  -- One builder for every hint bar in the plugin. This row had been copied
  -- into five files and they had already drifted -- this one advertised
  -- "1-5 jump" while there were six tabs.
  local widgets = require "paseo.ui.widgets"
  local pairs_ = {
    { "1-" .. #M.TABS, "tabs" },
    { "<Tab>", "cycle" },
  }

  -- IN A TERMINAL THE FIRST TWO ARE A LIE unless you have left terminal mode
  -- first, so the keys that work from inside one come first while one is up.
  -- A hint bar that names keys the buffer you are standing in has not bound is
  -- worse than a short one: it is the only place the surface says what its
  -- keys are, which is why this row exists at all.
  if state and state.session and state.session.kind == "terminal" then
    local keys = require("paseo.config").get().ui.terminal.keys
    local first = {}
    if keys.chrome then
      first[#first + 1] = { keys.chrome, "tab bar" }
    end
    if keys.sessions then
      first[#first + 1] = { keys.sessions, "sessions" }
    end
    if keys.terminal then
      first[#first + 1] = { keys.terminal, "terminal" }
    end
    for i = #first, 1, -1 do
      table.insert(pairs_, 1, first[i])
    end
  end
  -- Not on the buffer mount, where `<C-f>` is deliberately not bound. A hint
  -- bar is the only place the surface says what its keys are, so one that
  -- names a key doing nothing is worse than a shorter bar -- and
  -- `widgets.hints` degrades, so the columns go back to the others.
  --
  -- Appended rather than written as a `nil` in the literal: a hole in a table
  -- constructor makes `#` and `ipairs` undefined, and the three pairs BELOW
  -- it are the ones that would quietly vanish.
  if not state or state.mount ~= "buffer" then
    pairs_[#pairs_ + 1] = { "<C-f>", "sidebar" }
  end

  -- `f` IS BOUND ON THE CONVERSATION AND THE COMPOSER, and nowhere else. On
  -- the Settings tab it is the Features card's key, on the Sessions tab the
  -- chrome has its own alphabet, and in a terminal it is a letter you are
  -- typing -- so advertising it everywhere would name a key that does four
  -- different things depending on where you are standing, which is exactly
  -- what the rule above exists to prevent.
  --
  -- The Chat tab with an AGENT on it is the one place all three are true at
  -- once: the buffers are on screen, `f` is theirs, and there is a
  -- conversation to fork.
  if
    state
    and state.tab == "Chat"
    and not (state.session and state.session.kind == "terminal")
    and state.chat
    and state.chat.agent_id
  then
    pairs_[#pairs_ + 1] = { "f", "fork" }
  end

  vim.list_extend(pairs_, {
    { "<C-c>", "stop" },
    { "<C-t>", "speak" },
    { "q", "close" },
  })

  if not state then
    return { widgets.hints(pairs_) }
  end

  -- The spinner and the elapsed count are on the COMPOSER'S BAR now -- against
  -- the box whose answer you are waiting for. They stay here for the tabs that
  -- have no composer on them, because a turn keeps running while you read the
  -- Changes panel and that is exactly when "is it still going" is hard to
  -- answer: on those tabs there is nothing else on screen that moves.
  local status = {}
  if state.tab ~= "Chat" or (state.session and state.session.kind == "terminal") then
    status = sidebar.status(state.chat)

    -- THE MICROPHONE, for the same reason. The bar over the box draws a live
    -- meter while you dictate, and away from the Chat tab there is no box --
    -- so "am I still recording" would have nothing on screen answering it.
    local chat = state.chat
    if chat and chat.dictating then
      local said = chat.dictating == "starting" and "opening" or "listening"
      table.insert(status, 1, { icons.ui.mic .. " " .. said .. " ", "PaseoToolFail" })
    end
  end

  -- Sized to what is left after it, and DEGRADING rather than truncating: the
  -- hint that falls off the end is the least important one, whereas a row cut
  -- to fit loses whichever end the renderer happens to cut.
  local hints = widgets.hints(pairs_, nil, state.geometry.width - 2 - render.width(status) - 2)

  return {
    widgets.row(hints, status, state.geometry.width - 2, "PaseoNormal"),
  }
end

---Redraw the chrome. The ONE entry point for any content change.
---
---Volt computes each section's row and the buffer height once, in `gen_data`,
---and `redraw` writes extmarks at those precomputed rows without clearing
---anything first. A panel whose content changed height therefore has to go all
---the way back through `gen_data`, or rows from the previous draw survive
---underneath the new ones.
---The chrome buffer, for a panel that has to schedule a redraw of itself.
---
---A panel is handed a width and a height, not a buffer -- but an animated
---readout has to tell volt WHICH buffer to repaint when its timer fires, and
---there is only ever one dashboard.
---@return integer|nil
function M.chrome_buf()
  return state and api.nvim_buf_is_valid(state.buf) and state.buf or nil
end

function M.rebuild()
  if not state or not api.nvim_buf_is_valid(state.buf) then
    return
  end

  local volt = require "volt"
  local g = state.geometry

  api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  volt.gen_data {
    {
      buf = state.buf,
      ns = ns,
      xpad = 1,
      layout = {
        -- Fresh tables every call: volt's `draw` strips the third element
        -- from every cell it is handed, so a cached line list loses its
        -- click targets after the first draw.
        {
          name = "tabs",
          lines = function()
            return render.to_volt(tab_lines())
          end,
        },
        {
          name = "body",
          lines = function()
            return render.to_volt(body_lines())
          end,
        },
        {
          name = "footer",
          lines = function()
            return render.to_volt(footer_lines())
          end,
        },
      },
    },
  }

  vim.bo[state.buf].modifiable = true
  volt.set_empty_lines(state.buf, g.height, g.width)
  vim.bo[state.buf].modifiable = false
  volt.redraw(state.buf, "all")
end

---Repaint only what changes while a turn runs: the tab bar and the footer.
---
---Called from `sidebar.refresh`, which the spinner drives at 10 Hz. Going
---through `rebuild` here would rebuild the Changes panel -- one `git status`
---per repo -- ten times a second for the length of every turn.
---
---The FOOTER is in the list because that is where the spinner and the elapsed
---count live. Leaving it out is how the status would tick once and then sit
---frozen at `0s` for the rest of the turn. The TAB BAR is in it because its
---right-hand end names the session, and a session renamed by the daemon --
---which is what a title arriving from the provider is -- must not sit at
---`a1b2c3d4` until the next tab change.
---@param chat table
function M.refresh_live(chat)
  if not state or state.chat ~= chat or not api.nvim_buf_is_valid(state.buf) then
    return
  end
  local sections = { "tabs", "footer" }
  -- Usage is the other thing a running turn changes, and it is pure Lua -- no
  -- subprocess -- so it can afford to ride along.
  if state.tab == "Usage" then
    sections[#sections + 1] = "body"
  end
  require("volt").redraw(state.buf, sections)
end

-- --------------------------------------------------------------- child panes

---Tab navigation, bound where your cursor actually IS.
---
---This is why "1-5 jump" did nothing. The keys were mapped on the chrome
---buffer, and on the Chat tab -- the tab it opens on -- the chrome buffer never
---holds the cursor: `show_agent_panes` enters the composer. Every one of those
---keystrokes went to a buffer that had no such mapping.
---@param buf integer
---@param cycle boolean  Also take `<Tab>`/`<S-Tab>`.
local function bind_tabs(buf, cycle)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  -- A BARE DIGIT IS ALSO A COUNT, and these are ordinary buffers, so binding
  -- `3` costs you `3p` and `5j` in them for as long as the dashboard is up.
  -- That is the trade the footer is making, and it is the right one by default
  -- -- a seven-line prompt box is not where you type counts -- but it is a
  -- trade, so `ui.float.tab_keys = false` buys the counts back and leaves
  -- `<M-3>` and `<Tab>`, which collide with nothing.
  local digits = dash_option "tab_keys" ~= false
  for i, name in ipairs(M.TABS) do
    local keys = digits and { tostring(i), ("<M-%d>"):format(i) } or { ("<M-%d>"):format(i) }
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, function()
        M.select(name)
      end, { buffer = buf, nowait = true, silent = true, desc = "paseo: tab " .. name })
    end
  end
  if not cycle then
    -- The conversation keeps its own `<Tab>`: expanding a tool card to see
    -- what the command printed is worth more there than a second way to cycle
    -- tabs, and `1`-`6` reach every tab anyway.
    return
  end
  vim.keymap.set("n", "<Tab>", function()
    M.cycle(1)
  end, { buffer = buf, nowait = true, silent = true, desc = "paseo: next tab" })
  vim.keymap.set("n", "<S-Tab>", function()
    M.cycle(-1)
  end, { buffer = buf, nowait = true, silent = true, desc = "paseo: previous tab" })
end

---Give the conversation and composer their keys back.
---
---These are buffers you KEEP -- the sidebar shows the same two -- so mappings
---left behind would still be swallowing digits long after the dashboard was
---closed, and a stale `<Tab>` would try to select a tab on a surface that no
---longer exists.
---@param buf integer
---@param cycle boolean
local function unbind_tabs(buf, cycle)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  for i = 1, #M.TABS do
    pcall(vim.keymap.del, "n", tostring(i), { buffer = buf })
    pcall(vim.keymap.del, "n", ("<M-%d>"):format(i), { buffer = buf })
  end
  if cycle then
    pcall(vim.keymap.del, "n", "<Tab>", { buffer = buf })
    pcall(vim.keymap.del, "n", "<S-Tab>", { buffer = buf })
  end
end

---How many rows the composer wants for what is in it.
---
---An input that stands at its full configured height over an empty buffer is
---the "opaque rectangle" complaint in one line: seven rows of flat card colour
---is the largest and emptiest shape on the screen, and none of it is telling
---you anything. So the box GROWS with the prompt, between the configured
---floor and ceiling, which is what every chat composer does and what makes it
---read as a field rather than as a panel.
---
---THE FLOOR IS NOT 1. It was, and one row is a different mistake with the
---same shape: the box you write a paragraph into looked like `:e `, and it
---looked like that at the start of every session, which is the moment it has
---to say what it is for.
---
---|paseo.ui.layout|.composer_rows does the counting for both surfaces -- the
---sidebar has always called it, the dashboard carried a second copy, and the
---copy was the worse one: it divided a display width by a column count, which
---knows nothing about 'linebreak' or double-width characters. Passing the
---window when there is one gets Neovim's own answer instead; the width is
---what `show_agent_panes` uses to size a pane it has not opened yet.
---@param chat table
---@param g table
---@return integer
local function composer_rows(chat, g)
  return layout.composer_rows {
    buf = chat.composer,
    win = chat.win_composer,
    width = layout.panes(g).width,
    min = g.composer_min,
    max = g.composer,
  }
end

---Re-seat the two panes for the composer's current height.
---
---Only the panes move. The chrome underneath is a fixed stack whose rows volt
---measured once, and the body it draws on the Chat tab is blank anyway -- the
---conversation is a real buffer floated over exactly that area -- so growing
---the composer costs two `nvim_win_set_config` calls and no redraw.
---@param chat table
function M.resize_composer(chat)
  if not state or state.chat ~= chat or state.tab ~= "Chat" then
    return
  end
  local win, conversation = chat.win_composer, chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end

  local g = state.geometry
  local panes = layout.panes(g, composer_rows(chat, g), { framed = M.composer_framed() })
  -- `+ 1` is the bar, which is a winbar and therefore inside the height.
  if api.nvim_win_get_height(win) == panes.composer + 1 then
    return
  end

  pcall(
    api.nvim_win_set_config,
    win,
    placed(g, {
      row = panes.composer_row,
      col = panes.col,
      width = panes.width,
      height = panes.composer + 1,
    })
  )
  require("paseo.ui.composer").reveal(win)
  if conversation and api.nvim_win_is_valid(conversation) then
    pcall(
      api.nvim_win_set_config,
      conversation,
      placed(g, {
        row = panes.top,
        col = panes.col,
        width = panes.width,
        height = panes.conversation,
      })
    )
    -- The conversation follows the agent, and it just got taller. Without this
    -- the extra rows open up BELOW the last line and the transcript stops
    -- looking like it reached the bottom.
    transcript.follow(chat)
  end
end

---Does the composer have a drawn box, or is it a plate?
---
---`ui.style`'s answer, not ours -- see |paseo.ui.style|'s `composer_border`.
---Public because the geometry depends on it in three places and they must
---agree: a box costs two rows the plate does not.
---@return boolean
function M.composer_framed()
  return (require("paseo.ui.style").composer_border()) ~= "none"
end

---Float the real conversation and composer over the Chat tab.
local function show_agent_panes()
  if not state then
    return
  end
  local g = state.geometry
  local chat = state.chat

  -- Where each pane goes is `ui/layout.lua`'s arithmetic, not ours: the same
  -- numbers decide how many rows the body gets and which row the terminals
  -- panel maps a click to, and they were three independent copies.
  local border, border_hl = require("paseo.ui.style").composer_border()
  local panes = layout.panes(g, composer_rows(chat, g), { framed = border ~= "none" })

  chat.win_conversation = api.nvim_open_win(
    chat.conversation,
    false,
    placed(g, {
      row = panes.top,
      col = panes.col,
      width = panes.width,
      height = panes.conversation,
      style = "minimal",
      border = "none",
      zindex = g.z_panes,
    })
  )
  chat.win_composer = api.nvim_open_win(
    chat.composer,
    true,
    placed(g, {
      row = panes.composer_row,
      col = panes.col,
      width = panes.width,
      -- The bar is a winbar, so it comes out of the window's own height.
      height = panes.composer + 1,
      style = "minimal",
      -- WHATEVER `ui.style` SAYS, which under the default `plate` is nothing at
      -- all. A drawn box here was the one thing on the surface that ignored the
      -- style: a hard rounded rule around the composer, inside a window whose
      -- own edge is invisible, with cards below it that have no frame either.
      -- What separates the box from the transcript now is what separates every
      -- other card from it -- one tier of elevation, and a title row.
      border = border,
      zindex = g.z_panes,
    })
  )

  -- The surface reads as ONE sheet: the conversation shares the chrome's
  -- background, and the composer is a raised card -- the same tier the Agent
  -- panel's cards sit on, so "where you type" is visibly a control and not
  -- more transcript.
  pcall(function()
    vim.wo[chat.win_conversation].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal"
  end)
  require("paseo.ui.composer").style(chat, { border = border ~= "none" and border_hl or nil })

  -- Grow and shrink with what is typed. `TextChangedP` is in the list because
  -- a completion popup inserting a multi-line snippet changes the buffer
  -- without either of the other two firing.
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = api.nvim_create_augroup("PaseoComposerGrow", { clear = true }),
    buffer = chat.composer,
    desc = "paseo: grow the composer with its content",
    callback = function()
      M.resize_composer(chat)
    end,
  })

  for _, win in ipairs { chat.win_conversation, chat.win_composer } do
    for option, value in pairs {
      wrap = true,
      linebreak = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      -- Following the agent means the last line sits ON the last row. With a
      -- global `scrolloff` of 8 it cannot: the view stops eight rows early and
      -- the transcript never looks like it reached the bottom.
      scrolloff = 0,
    } do
      pcall(function()
        vim.wo[win][option] = value
      end)
    end
  end
  -- The transcript has no bar of its own: the tab bar above it names the
  -- session, and the composer's bar under it says what that session is set to.
  pcall(function()
    vim.wo[chat.win_conversation].winbar = ""
  end)

  bind_tabs(chat.conversation, false)
  bind_tabs(chat.composer, true)

  M.refresh_live(chat)
  transcript.redraw(chat)
end

---The keys a PTY buffer gets while it is the Chat tab.
---
---A TERMINAL TAKES EVERY KEY, and that is what it is for -- so the handful it
---does not take are the whole of your way out, and they have to be enough to
---reach the tab bar. They are:
---
---  * `keys.chrome` -- OUT OF THE PTY AND ONTO THE TAB BAR, without leaving
---    the Chat tab. The terminal stays on screen; the keystrokes stop going to
---    it, so `1`-`6`, `<Tab>` and everything else the chrome binds work from
---    there. This is the answer to "I can only switch tabs with the mouse":
---    `<M-3>` is one key, but a great many terminal emulators, multiplexers
---    and remote sessions never deliver an Alt chord at all, and when that is
---    true of yours the Alt bindings below are not a way out, they are six
---    keys that do nothing.
---  * `keys.sessions` -- straight to the Sessions tab, which is the list of
---    everything running and the search over it.
---  * `keys.next`/`keys.prev` -- the session either side of this one.
---  * `<M-1>`-`<M-6>` -- the tabs, for the terminals that do deliver them.
---
---DIGITS IN TERMINAL MODE ARE DELIBERATELY NOT AMONG THEM: a bare `2` inside a
---PTY is a `2` the program running in it wanted. In the PTY's NORMAL mode --
---which you are in after `<C-\><C-n>`, and which is a Neovim buffer like any
---other -- they are bound, along with `<Tab>`, because there they cost only a
---count and the surface behaving differently in one buffer is worse. `<Esc>`
---is never bound in either: it belongs to the PTY, so vim running inside one
---can still leave insert mode.
---
---Everything but the digits is bound in TERMINAL mode as well as normal, which
---is the only way any of it is worth having -- a key you must press
---`<C-\><C-n>` to reach first is a key you do not reach, and the whole point
---of this surface is that a terminal is a session like any other rather than a
---place you get stuck in.
---@param buf integer
local function bind_terminal(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local keys = require("paseo.config").get().ui.terminal.keys
  local function map(mode, lhs, fn, desc)
    if not lhs then
      return
    end
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  for i, name in ipairs(M.TABS) do
    map({ "n", "t" }, ("<M-%d>"):format(i), function()
      M.select(name)
    end, "paseo: tab " .. name)
    -- The same tab, from the PTY's normal mode, spelled the way it is spelled
    -- on every other buffer this surface owns.
    if dash_option "tab_keys" ~= false then
      map("n", tostring(i), function()
        M.select(name)
      end, "paseo: tab " .. name)
    end
  end
  map("n", "<Tab>", function()
    M.cycle(1)
  end, "paseo: next tab")
  map("n", "<S-Tab>", function()
    M.cycle(-1)
  end, "paseo: previous tab")

  map({ "n", "t" }, keys.chrome, M.focus_chrome, "paseo: out to the tab bar")
  map({ "n", "t" }, keys.sessions, function()
    M.select "Sessions"
  end, "paseo: the session list")
  map({ "n", "t" }, keys.next, function()
    M.cycle_session(1)
  end, "paseo: next session")
  map({ "n", "t" }, keys.prev, function()
    M.cycle_session(-1)
  end, "paseo: previous session")
  -- Normal mode only. `q` in terminal mode is a letter, and `<C-c>` is SIGINT
  -- and belongs to whatever is running -- which is the difference between a
  -- terminal you work in and a terminal you visit.
  map("n", "q", M.close, "paseo: close the dashboard")
end

---A terminal session: the PTY, filling the whole panel area.
---
---No composer, so no border either -- a bordered window costs two rows the
---body does not have. The chat panes get away with one because the composer's
---bottom border deliberately lands ON the last body row.
local function show_terminal_pane()
  if not state then
    return
  end
  local terminals = require "paseo.terminals"
  local terminal = require "paseo.ui.terminal"
  local item = terminals.get(state.session.id, state.session.hostId or state.chat.host_id)
  if not item then
    -- The terminal died while we were pointed at it -- a directory update that
    -- no longer lists it, never a process exiting under us. Fall back rather
    -- than leaving the tab blank.
    state.session = { kind = "agent", id = state.chat.agent_id, hostId = state.chat.host_id }
    return show_agent_panes()
  end

  local g = state.geometry
  local pane = layout.panes(g).body
  state.term_win = api.nvim_open_win(
    api.nvim_create_buf(false, true),
    true,
    placed(g, {
      row = pane.row,
      col = pane.col,
      width = pane.width,
      height = pane.height,
      style = "minimal",
      border = "none",
      zindex = g.z_panes,
    })
  )
  pcall(function()
    vim.wo[state.term_win].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal"
  end)

  local view = terminal.ensure(item, state.term_win)
  terminal.show(view, state.term_win)
  bind_terminal(view.buf)

  M.refresh_live(state.chat)
  -- Entered, and in insert. Landing on the chrome instead would send every
  -- keystroke to the tab bar.
  api.nvim_set_current_win(state.term_win)
  vim.cmd.startinsert()
end

---Whatever the current session needs on the Chat tab.
local function show_panes()
  if not state then
    return
  end
  if state.session and state.session.kind == "terminal" then
    return show_terminal_pane()
  end
  show_agent_panes()
end

local function hide_panes()
  if not state then
    return
  end
  local chat = state.chat
  -- Out of terminal mode BEFORE the window goes, or the editor is left in a
  -- mode the next surface did not ask for.
  if state.term_win and api.nvim_get_current_win() == state.term_win then
    pcall(vim.cmd.stopinsert)
  end
  -- Built by appending rather than as a literal. `ipairs` stops at the first
  -- nil, and these three are nil independently -- so `{ composer, conversation,
  -- term_win }` with the first two already cleared iterates NOTHING, and the
  -- PTY window survives the dashboard that owned it.
  local doomed = {}
  for _, win in pairs {
    composer = chat and chat.win_composer,
    conversation = chat and chat.win_conversation,
    terminal = state.term_win,
  } do
    doomed[#doomed + 1] = win
  end
  for _, win in ipairs(doomed) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  if chat then
    chat.win_composer, chat.win_conversation = nil, nil
  end
  state.term_win = nil
end

-- ------------------------------------------------------------------- tabs

---The panel module for a tab, if it has one.
---
---Chat has none -- it is the conversation, floated over the body -- and a tab
---whose module fails to load must not take the surface down with it.
---@param name string
---@return table|nil
local function panel_for(name)
  local ok, panel = pcall(require, "paseo.ui.panels." .. panel_module(name))
  return ok and panel or nil
end

---Give a panel the chrome buffer's keys, and take them back again.
---
---The six panels SHARE one buffer, so a panel that binds `<CR>` has to unbind
---it on the way out or the Changes tab inherits it and tries to apply a
---agent setting. `attach`/`detach` are both optional: the panel contract has
---always been pcall-and-optional.
---@param name string
---@param method "attach"|"detach"
local function panel_keys(name, method)
  if not state then
    return
  end
  local panel = panel_for(name)
  if panel and type(panel[method]) == "function" then
    pcall(panel[method], state.chat, state.buf)
  end
end

---@param name string
function M.select(name)
  if not state or not vim.tbl_contains(M.TABS, name) then
    return
  end
  local was_chat = state.tab == "Chat"
  local leaving = state.tab
  if leaving ~= name then
    panel_keys(leaving, "detach")
  end
  state.tab = name

  if name == "Chat" and not was_chat then
    show_panes()
  elseif name ~= "Chat" then
    hide_panes()
    -- Arriving at a panel is the moment to refresh it. A panel that fetched
    -- once and cached the answer is a panel that shows you a workspace list
    -- from an hour ago -- or, if the daemon happened to be down then, an error
    -- for the rest of the session.
    local panel = panel_for(name)
    if panel and type(panel.load) == "function" then
      pcall(panel.load, state.chat)
    end
    panel_keys(name, "attach")
  end

  M.rebuild()
  sync_spinner()
  if state.win and api.nvim_win_is_valid(state.win) and name ~= "Chat" then
    api.nvim_set_current_win(state.win)
  end
end

---@param step integer
function M.cycle(step)
  if not state then
    return
  end
  local at = 1
  for i, name in ipairs(M.TABS) do
    if name == state.tab then
      at = i
    end
  end
  M.select(M.TABS[(at - 1 + step) % #M.TABS + 1])
end

-- ------------------------------------------------------------- open / close

---Move a tab page off a window we are about to close.
---
---Closing a float that is another TAB PAGE'S CURRENT WINDOW leaves that tab
---pointing at a window which no longer exists. Neovim does not recover: the
---next `:tabclose`, or merely switching back, dies with `E315: ml_get: Invalid
---lnum` -- and with the four windows this surface opens, it takes the whole
---process down instead.
---
---The dashboard is always its tab's current window, so this is one keystroke
---away: open the chat, `gt`, close it. `workspaces.open` with the default
---`"tab"` does exactly that shape of thing on every workspace switch, which is
---what turned a latent crash into a routine one.
---
---`nvim_tabpage_set_win` is 0.11. On 0.10 the only way to move another tab
---page's cursor is to stand on it, and `noautocmd` keeps that round trip from
---looking like navigation to a config that chdirs on `TabEnter`.
---@param wins integer[]  Windows about to be closed.
local function reseat(wins)
  local doomed = {}
  for _, win in ipairs(wins) do
    if win and api.nvim_win_is_valid(win) then
      doomed[win] = true
    end
  end

  local here = api.nvim_get_current_tabpage()
  local tabs = {}
  for win in pairs(doomed) do
    local tab = api.nvim_win_get_tabpage(win)
    if tab ~= here then
      tabs[tab] = true
    end
  end

  for tab in pairs(tabs) do
    if api.nvim_tabpage_is_valid(tab) and doomed[api.nvim_tabpage_get_win(tab)] then
      local keep
      for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
        -- A normal window for preference: seating the tab on another float is
        -- the same bug one step along.
        if not doomed[win] and api.nvim_win_get_config(win).relative == "" then
          keep = win
          break
        end
      end
      if keep and api.nvim_tabpage_set_win then
        pcall(api.nvim_tabpage_set_win, tab, keep)
      elseif keep then
        local there = api.nvim_tabpage_get_number(tab)
        vim.cmd("noautocmd tabnext " .. there)
        pcall(api.nvim_set_current_win, keep)
        vim.cmd("noautocmd tabnext " .. api.nvim_tabpage_get_number(here))
      end
    end
  end
end

function M.close()
  if not state then
    return
  end
  -- APPENDED, NOT A LIST LITERAL. Every one of these is optional -- there is
  -- no backdrop on the buffer mount, no PTY window unless a terminal is up --
  -- and a `nil` in the middle of a table constructor is where `ipairs` stops.
  -- Written `{ state.win, state.backdrop_win, … }` this reseated the first
  -- window and silently skipped the other four on every mount that has no
  -- backdrop, which is the mount whose host window is routinely another tab
  -- page's current one.
  local doomed = {}
  local function doom(win)
    if win then
      table.insert(doomed, win)
    end
  end
  -- The `"here"` mount's host is NOT doomed: `restore_here` hands that window
  -- back rather than closing it, and reseating a tab page off a window that is
  -- about to survive moves somebody's cursor for nothing.
  if not state.displaced then
    doom(state.win)
  end
  doom(state.backdrop_win)
  doom(state.chat.win_conversation)
  doom(state.chat.win_composer)
  -- THE PTY WINDOW BELONGS IN HERE. It is a float on this tab page and it is
  -- routinely the tab's current window -- you were typing in it. Left out,
  -- closing the dashboard from another tab leaves this one pointing at a
  -- window that no longer exists, and the next `:tabclose` dies with `E315:
  -- ml_get: Invalid lnum` or takes the process down outright.
  doom(state.term_win)
  reseat(doomed)
  -- Before `state` goes: `panel_keys` reads it, and a panel left attached
  -- would have its mappings outlive the buffer they were bound to. So does
  -- `hide_panes`, which is why the windows go here rather than below.
  panel_keys(state.tab, "detach")
  hide_panes()

  local held = state
  state = nil
  -- Before anything else that can fail: a timer outliving the buffer it
  -- redraws is an error every frame, forever.
  stop_spinner()

  -- A list's search box is a window of OURS floated over the body, and the
  -- ordinary way it closes is losing focus -- which does not happen when the
  -- dashboard is torn down from somewhere else, `:Paseo chat` toggling it
  -- shut while you were typing in it. Left alone it is a box floating over
  -- your code with nothing underneath it.
  require("paseo.ui.filter").close()

  -- Before the buffer goes. A tween's timer redraws a named section every
  -- frame, and one left running against a deleted buffer is an error a frame
  -- forever rather than once.
  require("paseo.ui.animate").stop_all()

  -- The PTY windows are shut, so there is nothing left showing the terminal
  -- buffers and the daemon can stop base64-ing them across the pipe at a
  -- surface nobody is looking at. The cost is that reopening replays the
  -- scrollback, because `terminal.ensure` is only idempotent while the buffer
  -- lives; that is the cheaper half of the trade.
  require("paseo.ui.terminal").detach_all()

  if held.augroup then
    pcall(api.nvim_del_augroup_by_id, held.augroup)
  end

  unbind_tabs(held.chat.conversation, false)
  unbind_tabs(held.chat.composer, true)

  -- BEFORE THE WINDOWS GO, and it is what decides whether one of them goes at
  -- all. The `"here"` mount borrowed a window the user opened; closing it
  -- would answer "put my code back" by taking a split away.
  local kept = restore_here(held)

  for _, win in ipairs { held.win, held.backdrop_win } do
    if win and api.nvim_win_is_valid(win) and not (kept and win == held.win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs { held.buf, held.backdrop } do
    if buf then
      -- BEFORE THE VALIDITY CHECK, NOT INSIDE IT. Volt never clears its own
      -- state table, and the case where nobody else will either is exactly
      -- the case where the buffer is already gone: `:q` on a window we host,
      -- or `bufhidden = "wipe"` doing what it says. Guarded, both tables
      -- leaked for the session every time the buffer went first.
      require("volt.state")[buf] = nil
      -- And its global on_key handler keeps dispatching against a dead buffer
      -- unless the buf is taken off its list.
      local bufs = require("volt.events").bufs
      for i, id in ipairs(bufs) do
        if id == buf then
          table.remove(bufs, i)
          break
        end
      end
      if api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  held.chat.surface = nil
end

---@param chat table
---@param opts? { mount?: "float"|"buffer" }
function M.open(chat, opts)
  local mount = opts and opts.mount or "float"

  -- A TAB PAGE YOU CANNOT SEE IS ONE `gt` AWAY, NOT GONE.
  --
  -- `is_open` is tab-aware, and for a float that is exactly right: an
  -- invisible float is no use to you, so "open it" means open another one
  -- where you are. This mount is a tab page -- the surface you asked for
  -- already exists and has your draft in it, and "open it" means GO THERE.
  -- Without this, `:Paseo buf` from your code opened a second dashboard tab
  -- every time.
  if
    mount == "buffer"
    and state
    and state.mount == "buffer"
    and state.tabpage
    and api.nvim_tabpage_is_valid(state.tabpage)
    and state.tabpage ~= api.nvim_get_current_tabpage()
    and M.showing(chat)
  then
    api.nvim_set_current_tabpage(state.tabpage)
  end

  -- Already up on this chat: go to the Chat tab and focus the composer rather
  -- than tearing the surface down and rebuilding it. "Open the chat" while
  -- sitting on the Usage panel means show me the conversation -- and it has to,
  -- because the caller goes on to put the cursor in `chat.win_composer`, which
  -- on any other tab does not exist.
  --
  -- ON THE SAME MOUNT. A dashboard floating over your code is not the one
  -- `:Paseo buf` asked for, however open it is -- without the second test the
  -- two commands took this branch on each other and neither could swap.
  if M.is_open(chat) and state.mount == mount then
    -- AND ON THE CONVERSATION, not on whatever the Chat tab was last left on.
    -- `state.session` survives a trip through the panels, so: `<C-s>` out of a
    -- terminal to the session list, an agent picked out of that list, and the
    -- Chat tab came back showing the same PTY -- a key that visibly did
    -- nothing. The session pointer is what "open the chat" moves.
    if not (state.session and state.session.kind == "agent") then
      state.session = { kind = "agent", id = chat.agent_id, hostId = chat.host_id }
      hide_panes()
    end
    M.select "Chat"
    -- `select` only opens the panes when it is CHANGING tab, so the case
    -- above -- already on Chat, terminal panes just closed -- needs them
    -- opened here.
    if not (chat.win_composer and api.nvim_win_is_valid(chat.win_composer)) then
      show_panes()
    end
    if chat.win_composer and api.nvim_win_is_valid(chat.win_composer) then
      api.nvim_set_current_win(chat.win_composer)
    end
    return
  end
  M.close()

  -- The background tiers the whole surface is drawn on. Idempotent, and
  -- re-derived on `ColorScheme` -- but a user who opens the dashboard before
  -- anything else has touched the highlights still gets them.
  require("paseo.ui.hl").setup()

  -- An agent archived, started, or finishing a turn repaints the surface from
  -- here on. Registered once per session, and harmless while the dashboard is
  -- closed: `directory_changed` returns on a nil `state`.
  watch_directories()

  local buf, win, g, backdrop, backdrop_win, tabpage, displaced

  if mount == "buffer" then
    -- The window FIRST, the geometry second: this mount's box is the host
    -- window's own text area, so there is nothing to measure until it exists.
    buf = host_buf()
    local how = require("paseo.config").get().ui.buffer.open
    if how == "tab" then
      win, tabpage = mount_tab(buf)
    else
      win, tabpage, displaced = mount_here(buf)
    end
    style_host(win, displaced and "here" or "tab")
    g = host_geometry(win)
  else
    g = float_geometry()

    if g.backdrop then
      backdrop = api.nvim_create_buf(false, true)
      backdrop_win = api.nvim_open_win(backdrop, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = vim.o.columns,
        height = vim.o.lines,
        focusable = false,
        style = "minimal",
        border = "none",
        zindex = g.z_backdrop,
      })
      vim.wo[backdrop_win].winblend = 25
    end

    local edge, edge_hl = style.window_border()

    buf = api.nvim_create_buf(false, true)
    win = api.nvim_open_win(buf, true, {
      relative = "editor",
      row = g.row,
      col = g.col,
      width = g.width,
      height = g.height,
      style = "minimal",
      border = edge,
      zindex = g.z_chrome,
    })

    -- On the default -- `ui.style`'s "invisible" -- `PaseoNormalBorder` is
    -- fg == bg, so `nvim_open_win`'s border glyphs render as solid colour and
    -- the box becomes a one-cell padding ring in the surface's own background.
    -- That is the single change that stops the dashboard looking like a framed
    -- rectangle and starts it looking like a card. The other border settings
    -- paint the same glyphs in `PaseoBorder` and you get a visible edge.
    vim.wo[win].winhl = ("Normal:PaseoNormal,NormalFloat:PaseoNormal,FloatBorder:%s"):format(
      edge_hl
    )
  end

  state = {
    buf = buf,
    win = win,
    backdrop = backdrop,
    backdrop_win = backdrop_win,
    chat = chat,
    geometry = g,
    -- Which mount is up, and -- when it is the buffer one -- the window and
    -- the tab page it lives in. `host` is `win` today, and stays a separate
    -- field because it is what `anchor` and `geometry_for` read: "the window
    -- the panes hang off" is a different question from "the chrome window".
    mount = g.mount,
    host = g.host,
    tabpage = tabpage,
    -- What this mount owes the window it took, and nil on every other one.
    -- See `mount_here`.
    displaced = displaced,
    tab = "Chat",
    -- What the Chat tab is showing. A sibling of `chat` rather than something
    -- folded into it: `state.chat` is identity-compared by `is_open`,
    -- `refresh_live` and every panel, and none of them should have to learn
    -- that a session might be a PTY.
    session = { kind = "agent", id = chat.agent_id },
  }
  chat.surface = mount

  M.rebuild()

  local events = require "volt.events"
  events.add(buf)
  -- THE HALF THAT MAKES A CELL CLICKABLE WITH A MOUSE. `events.add` only
  -- binds `<CR>`; the `LeftMouse` dispatch lives behind `enable`, which
  -- `volt.run` calls and this surface -- which drives `gen_data`/`redraw`
  -- itself, to keep the conversation out of volt's hands -- never did. So
  -- the tab bar and every panel row had actions that no click reached.
  if not vim.g.extmarks_events then
    events.enable()
  end

  local map = function(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  for i, name in ipairs(M.TABS) do
    map(tostring(i), function()
      M.select(name)
    end)
  end
  map("<Tab>", function()
    M.cycle(1)
  end)
  map("<S-Tab>", function()
    M.cycle(-1)
  end)
  -- Swallow the paste keys. The chrome is not modifiable, and the realistic
  -- way to land here holding one is `3p` typed in the composer out of habit:
  -- the `3` switched tab and moved the cursor, and the `p` that followed it
  -- answered with `E21: Cannot make changes, 'modifiable' is off`, which
  -- blames the wrong thing entirely.
  map("p", function() end)
  map("P", function() end)
  map("q", M.close)
  if mount == "float" then
    -- `<Esc>` DISMISSES A FLOAT AND DOES NOT DESTROY A TAB PAGE.
    --
    -- On a float it is the universal "close the thing in front of me", and it
    -- is right. The buffer mount is not in front of anything -- it is a place
    -- you are standing -- and in a normal window `<Esc>` means "cancel what I
    -- was in the middle of": clear the search highlight, drop a pending
    -- count, leave a mode. Rebinding that to tear the tab down means one
    -- stray press after a mistyped `i` takes the surface with it. nvim-tree,
    -- oil, fugitive and neo-tree all bind `q` and none of them binds `<Esc>`.
    --
    -- Left UNBOUND rather than mapped to a no-op, which would swallow the
    -- legitimate uses along with the accident.
    map("<Esc>", M.close)

    -- `<C-f>` is the sidebar swap, and the buffer mount is not in that pair:
    -- the sidebar is with your code, the buffer surface is a place of its
    -- own, the float is floating. |paseo.ui.chat|.fullscreen declines it from
    -- the other side, for the conversation and composer -- which keep their
    -- own `<C-f>` because they are shared with the sidebar.
    map("<C-f>", function()
      M.close()
      chat.surface = "sidebar"
      sidebar.open(chat)
    end)
  end
  local term_keys = require("paseo.config").get().ui.terminal.keys
  if term_keys.sessions then
    map(term_keys.sessions, function()
      M.select "Sessions"
    end)
  end
  -- BACK INTO THE PTY, and the pair of `focus_chrome`. Without it the way out
  -- of a terminal is one-way: you reach the tab bar, pick the Chat tab you are
  -- already on, and nothing takes you back down into the session.
  if term_keys.terminal then
    map(term_keys.terminal, M.focus_terminal)
  end

  -- THE DASHBOARD DID NOT FOLLOW A RESIZE. It registered no autocmds at all,
  -- so making the terminal bigger left a float at its old size with the panes
  -- floating wherever they had been. That was survivable while everything on
  -- it was redrawn text; it is not once a PTY is one of the panes, because a
  -- terminal that is not told its size renders to the wrong one.
  state.augroup = api.nvim_create_augroup("paseo.float", { clear = true })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = state.augroup,
    callback = function()
      vim.schedule(M.relayout)
    end,
    desc = "paseo: re-fit the dashboard",
  })

  -- RE-FIT WHAT YOU HAVE JUST COME BACK TO. `M.relayout` declines to work on
  -- a surface that is not on the current tab page -- see the comment there --
  -- and this is the other half of that: the deferred re-fit happens when you
  -- arrive, before you can see that it was needed.
  api.nvim_create_autocmd("TabEnter", {
    group = state.augroup,
    callback = function()
      if state and state.dirty then
        vim.schedule(M.relayout)
      end
    end,
    desc = "paseo: re-fit the dashboard you have come back to",
  })

  if mount == "buffer" then
    -- THE DOOR THE FLOAT NEVER HAD. A float is only ever closed by us; a
    -- window in the layout is closed by `:q`, `<C-w>c`, `:only`, `:tabclose`
    -- and a session restore, none of which go anywhere near `M.close`.
    --
    -- The case that makes it load-bearing rather than tidy: on a dash tab the
    -- user has SPLIT, closing the host leaves the two panes valid and
    -- floating over the remaining window, anchored to a window id that no
    -- longer exists, with no way to reach them. `hide_panes` reaps them.
    --
    -- Scheduled because `WinClosed` fires DURING the close and `M.close` goes
    -- on to close three more windows and delete a buffer. Re-entrancy is not
    -- a worry: `M.close` nils `state` and deletes this augroup before it
    -- touches a window, so a second caller finds nothing to do.
    --
    -- No `TabClosed` handler to go with it. The order is `WinClosed`(pane) ->
    -- `WinClosed`(host) -> `BufWipeout` -> `TabClosed`, so the host is always
    -- first and a second handler is only a second chance to double-fire.
    api.nvim_create_autocmd("WinClosed", {
      group = state.augroup,
      pattern = tostring(win),
      callback = function()
        vim.schedule(M.close)
      end,
      desc = "paseo: the dashboard's window went away",
    })

    -- And the buffer going without the window -- `:bd`, `:bw`, a plugin that
    -- swaps buffers under you. `winfixbuf` makes it rare rather than
    -- impossible. Also scheduled: deleting a buffer from inside its own
    -- `BufWipeout` is not allowed.
    api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
      group = state.augroup,
      buffer = buf,
      callback = function()
        vim.schedule(M.close)
      end,
      desc = "paseo: the dashboard's buffer went away",
    })

    -- THE FILE YOU OPEN GOES IN THE WINDOW, NOT IN THE BOX YOU TYPE IN.
    --
    -- "It goes away when I open a file" is half of what this surface is, and
    -- the half that does not happen by itself. The chrome buffer is displaced
    -- and wiped by an `:e` typed at it, which the handler above catches -- but
    -- the cursor on this surface is almost never on the chrome. It is in the
    -- composer, which is a FLOAT, and a picker that opens a file in "the
    -- window you came from" opens it there: a source file in a three-row box
    -- over a dashboard that is still up.
    --
    -- So a real file landing in either pane is taken as "leave", and it is
    -- reseated in the window this surface borrowed -- which is where it was
    -- always going.
    --
    -- Only `"here"`, and only a real file. On a tab page of its own there is
    -- no borrowed window to hand it to, and `buftype` keeps the panes' own
    -- traffic -- a PTY, a help page, a quickfix list -- out of it.
    if displaced then
      api.nvim_create_autocmd("BufWinEnter", {
        group = state.augroup,
        callback = function(args)
          if not (state and state.displaced) then
            return
          end
          local into = api.nvim_get_current_win()
          if into ~= chat.win_composer and into ~= chat.win_conversation then
            return
          end
          local landed = args.buf
          if landed == chat.composer or landed == chat.conversation or landed == state.buf then
            return
          end
          if vim.bo[landed].buftype ~= "" then
            return
          end
          local host = state.displaced.win
          -- Scheduled for the same reason the `WinClosed` handler is: `M.close`
          -- closes three windows and deletes a buffer, and we are inside the
          -- event that put a buffer in one of them.
          vim.schedule(function()
            M.close()
            if host and api.nvim_win_is_valid(host) and api.nvim_buf_is_valid(landed) then
              pcall(api.nvim_win_set_buf, host, landed)
              pcall(api.nvim_set_current_win, host)
            end
          end)
        end,
        desc = "paseo: a file opened on the dashboard belongs in the window under it",
      })
    end

    -- LAST, once the surface is finished. This is the name a user hangs an
    -- `ftplugin/paseo-dash.lua` off, and it should not fire at a half-built
    -- window with no keys on it.
    vim.bo[buf].filetype = M.FILETYPE
  end

  show_panes()
end

---The size a PTY should run at here, for a terminal that does not exist yet.
---
---A terminal created before the surface is up gets the daemon's default and is
---resized the moment it is shown, which is a visible reflow; asking first
---costs nothing.
---@return { rows: integer, cols: integer }|nil
function M.body_size()
  if not state then
    return nil
  end
  local pane = layout.panes(state.geometry).body
  return { rows = pane.height, cols = pane.width }
end

---Where the panel body IS, in editor cells, for a window floated over it.
---
---The same rectangle `body_size` measures, with its corner: a search box
---belongs over the list it narrows, not centred on an editor whose middle is
---somewhere else entirely.
---@return { row: integer, col: integer, width: integer, height: integer }|nil
function M.body_area()
  if not state then
    return nil
  end
  local pane = layout.panes(state.geometry).body
  return { row = pane.row, col = pane.col, width = pane.width, height = pane.height }
end

---The session the Chat tab is showing.
---@return { kind: "agent"|"terminal", id: string|nil, hostId: string|nil }|nil
function M.session()
  return state and state.session
end

---Put the keyboard on the CHROME, leaving what is on screen where it is.
---
---The way out of a PTY that changes nothing you can see. A terminal session
---takes every keystroke -- that is what a terminal is -- so with the panes up
---the tab bar is a row you can only reach with the mouse. This hands the
---cursor back to the chrome window underneath, where `1`-`6`, `<Tab>` and `q`
---are bound; the terminal stays drawn over the body, because a way out that
---also closed what you were looking at is a way out you would think twice
---about taking.
---
---`ui.terminal.keys.terminal` is the other direction, on the chrome.
function M.focus_chrome()
  if not state or not (state.win and api.nvim_win_is_valid(state.win)) then
    return
  end
  -- Out of terminal mode FIRST. Switching window from terminal mode leaves it
  -- anyway, but not before Neovim has decided what to do with a pending
  -- keystroke -- and `stopinsert` is also what takes the cursor out of the
  -- composer when the Chat tab is showing an agent.
  if api.nvim_get_mode().mode ~= "n" then
    pcall(vim.cmd.stopinsert)
  end
  pcall(api.nvim_set_current_win, state.win)
end

---Back into the PTY from the chrome -- the other half of `focus_chrome`.
---
---Only when the session on the Chat tab IS a terminal. Bound on the chrome to
---`ui.terminal.keys.terminal`, which the config has documented as exactly this
---for as long as it has existed without anything binding it.
function M.focus_terminal()
  if not state or not (state.session and state.session.kind == "terminal") then
    return
  end
  if state.tab ~= "Chat" then
    -- `select` opens the panes and lands in the terminal itself.
    return M.select "Chat"
  end
  if state.term_win and api.nvim_win_is_valid(state.term_win) then
    api.nvim_set_current_win(state.term_win)
    vim.cmd.startinsert()
  end
end

---Show a session on the Chat tab.
---
---An agent that is not the one this surface is on is not ours to show: it is a
---different `paseo.Chat`, and |paseo.ui.chat|.open is the thing that knows how
---to subscribe to it, fetch its timeline and reseat this window. Anything else
----- the agent we already have, or any terminal -- is a repaint.
---@param session { kind: "agent"|"terminal", id: string|nil, hostId?: string }
function M.show_session(session)
  if not state then
    return
  end
  local host_id = session.hostId or state.chat.host_id
  if
    session.kind == "agent"
    and session.id
    and (session.id ~= state.chat.agent_id or host_id ~= state.chat.host_id)
  then
    local agent = require("paseo.agents").get(session.id, host_id)
    return require("paseo.ui.chat").open {
      root = (agent and agent.cwd) or state.chat.root,
      host_id = host_id,
      remote = true,
      agent_id = session.id,
      title = agent and agent.title,
    }
  end

  hide_panes()
  state.session = { kind = session.kind, id = session.id, hostId = host_id }
  if state.tab ~= "Chat" then
    -- `select` shows the panes itself, and detaches whatever panel we are
    -- leaving on the way.
    return M.select "Chat"
  end
  show_panes()
  M.rebuild()
end

---Step to the next or previous session in this workspace.
---
---Agents first, then terminals, which is the order the Sessions list draws
---them in -- two orderings of one list is how they start disagreeing.
---@param step integer
function M.cycle_session(step)
  if not state then
    return
  end
  local chat = state.chat
  local order = {}
  for _, agent in ipairs(require("paseo.agents").for_root(chat.root, chat.host_id)) do
    order[#order + 1] = { kind = "agent", id = agent.id, hostId = chat.host_id }
  end
  for _, item in ipairs(require("paseo.terminals").for_root(chat.root, chat.host_id)) do
    order[#order + 1] = { kind = "terminal", id = item.id, hostId = chat.host_id }
  end
  if #order == 0 then
    return
  end

  local here = state.session or {}
  local at = 1
  for i, item in ipairs(order) do
    if
      item.kind == here.kind
      and item.id == here.id
      and item.hostId == (here.hostId or chat.host_id)
    then
      at = i
    end
  end
  M.show_session(order[(at - 1 + step) % #order + 1])
end

---Re-fit everything to the editor's new size.
---
---A full `rebuild` rather than a `redraw`: the width changed, and volt records
---each section's rows and widths once, in `gen_data`.
function M.relayout()
  if not state or not api.nvim_win_is_valid(state.win) then
    return
  end

  -- NOT WHILE YOU ARE STANDING SOMEWHERE ELSE. Re-fitting recreates the
  -- panes, and `show_agent_panes` opens the composer with `enter = true` --
  -- which, for a window on another tab page, SWITCHES to it. So a terminal
  -- resize while you worked in your code would haul you onto the dashboard
  -- and leave you there, firing every `TabEnter` hook on the way.
  --
  -- It waits at the door instead: the `TabEnter` autocmd in `M.open` runs it
  -- when you arrive. This is a fix for the float as much as for the buffer
  -- mount -- with `relative = "editor"` panes it could also strand them on
  -- whichever tab was current when the resize landed.
  if api.nvim_win_get_tabpage(state.win) ~= api.nvim_get_current_tabpage() then
    state.dirty = true
    return
  end
  state.dirty = false

  local g = geometry_for(state.mount, state.host)

  -- NOTHING MOVED, NOTHING TO RE-FIT. `WinResized` fires for any window on
  -- the tab page, not just for the editor changing size -- and one of those
  -- windows is a modal of ours: the new-agent screen opens and then sizes
  -- itself to its content the moment the model's features land. Re-fitting
  -- for that tore the panes down and reopened them, and `show_agent_panes`
  -- enters the composer as it does on a cold open, so the cursor was pulled
  -- out of the modal you were looking at and the only way back in was a
  -- click.
  local old = state.geometry
  if
    old
    and old.host == g.host
    and old.row == g.row
    and old.col == g.col
    and old.width == g.width
    and old.height == g.height
  then
    return
  end
  state.geometry = g

  -- ONLY THE FLOAT OWNS ITS OWN BOX. The buffer mount's box IS the host
  -- window, and the host window is however big Neovim has just made it --
  -- moving it here would be arguing with the thing that told us.
  if state.mount ~= "buffer" then
    pcall(api.nvim_win_set_config, state.win, {
      relative = "editor",
      row = g.row,
      col = g.col,
      width = g.width,
      height = g.height,
    })
    if state.backdrop_win and api.nvim_win_is_valid(state.backdrop_win) then
      pcall(api.nvim_win_set_config, state.backdrop_win, {
        relative = "editor",
        row = 0,
        col = 0,
        width = vim.o.columns,
        height = vim.o.lines,
      })
    end
  end

  -- The panes are laid out from the geometry, so they are cheapest to close
  -- and reopen -- and on any tab but Chat there are none.
  if state.tab == "Chat" then
    -- WHATEVER HAD THE CURSOR KEEPS IT. The panes are recreated here, so
    -- their window ids change: the composer and the terminal are followed to
    -- their new windows, and anything else that was focused -- the chrome, or
    -- a modal floating over all of it -- is simply put back.
    local chat = state.chat
    local was = api.nvim_get_current_win()
    local composer = chat and was == chat.win_composer
    local conversation = chat and was == chat.win_conversation
    local terminal = was == state.term_win

    hide_panes()
    show_panes()

    local back = (composer and chat.win_composer)
      or (conversation and chat.win_conversation)
      or (terminal and state.term_win)
      or (api.nvim_win_is_valid(was) and was)
      or nil
    if back and api.nvim_win_is_valid(back) then
      -- `show_terminal_pane` lands in insert mode, which belongs to the PTY
      -- and to nothing else: leaving it set would send the next keystroke
      -- into a window that is not a terminal.
      if back ~= state.term_win and api.nvim_get_mode().mode ~= "n" then
        pcall(vim.cmd.stopinsert)
      end
      pcall(api.nvim_set_current_win, back)
    end
  end

  M.rebuild()
end

---@param chat table
---@return boolean
function M.is_open(chat)
  if not state then
    return false
  end
  -- Self-healing, because the chrome window can go away WITHOUT us: `:only`, a
  -- session restore, or another plugin's autocmd -- nvchad's dashboard closes
  -- every other window when the last real buffer is wiped. Left alone, the
  -- state outlives the window, `is_open` lies, and `open` then takes its
  -- "already up, just focus it" branch and puts nothing on screen.
  if not (state.win and api.nvim_win_is_valid(state.win)) then
    M.close()
    return false
  end
  -- AND STILL SHOWING OUR BUFFER. The `"here"` mount borrowed a window the
  -- user already had, so the window outliving the surface is the ORDINARY
  -- case: `:e file` from the dashboard displaces the chrome buffer and leaves
  -- a perfectly valid window holding somebody's source. The `BufWipeout`
  -- handler closes us a tick later; until it runs, this is what stops
  -- `is_open` claiming a dashboard that is not on screen.
  if api.nvim_win_get_buf(state.win) ~= state.buf then
    M.close()
    return false
  end
  -- AND ON THE TAB PAGE YOU ARE LOOKING AT. A float belongs to the tab it was
  -- opened on, so after `workspaces.open`'s default `tabnew` the previous
  -- dashboard is still a perfectly valid window -- just an invisible one. Left
  -- unasked, `chat.toggle` saw "already open", took its close branch, and the
  -- first press of the chat key in a new workspace did nothing you could see.
  -- The second one opened it, which reads as a key that needs pressing twice.
  if api.nvim_win_get_tabpage(state.win) ~= api.nvim_get_current_tabpage() then
    return false
  end
  return state.chat == chat
end

---Is this chat's dashboard up AT ALL -- on any tab page?
---
---The other question, and not the one `is_open` answers. `is_open` means "is
---it usable from where you are standing", because its callers go on to focus
---a window or to decide that a toggle should close. This one means "is there
---a chat on screen somewhere", which is what |paseo.ui.chat|.follow needs:
---the whole point of following is to move a surface that is on the tab you
---just LEFT onto the one you are on now, and a tab-aware test would answer
---"nothing open" at exactly that moment and leave it behind.
---@param chat table
---@return boolean
function M.showing(chat)
  if not state then
    return false
  end
  if not (state.win and api.nvim_win_is_valid(state.win)) then
    M.close()
    return false
  end
  return state.chat == chat
end

---The chat this surface is showing, if it is up.
---@return table|nil
function M.chat()
  return state and state.chat or nil
end

---The tab it is on, if it is up.
---@return string|nil
function M.tab()
  return state and state.tab or nil
end

---Which mount the dashboard is on, if it is up.
---
---Read by |paseo.ui.chat|.fullscreen, which has to decline `<C-f>` on the
---buffer mount from the conversation and composer -- two buffers the sidebar
---shares, so the key cannot simply be left unbound there the way it is on the
---chrome.
---@return "float"|"buffer"|nil
function M.mount()
  return state and state.mount or nil
end

return M
