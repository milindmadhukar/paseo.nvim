--- The terminal surface: a rail of Paseo's terminals, and the one you are in.
---
--- Paseo runs terminals as well as agents -- the `claude` and `codex` sessions
--- started from the app are PTYs on the daemon -- and this is where they are
--- driven from. It replaces a dashboard tab that could show exactly one at a
--- time and closed it again the moment you switched tabs.
---
--- The shape is floaterm's, because floaterm already worked out what a
--- terminal manager in a float looks like: a narrow list down the left, a bar
--- naming what you are in, and the terminal filling the rest. Two of its
--- lessons are load-bearing here.
---
--- EVERY WINDOW IS `relative = "editor"`, WITH PRE-FLOORED COORDINATES. Hanging
--- the bar and the terminal off the rail with `relative = "win"` makes their
--- screen position the sum of two independently rounded numbers, and the rig
--- lines up at some terminal sizes and not others.
---
--- THE RAIL IS A FIXED NUMBER OF ROWS. Volt records each section's starting row
--- once, in `gen_data`, and `redraw` writes extmarks at those rows without
--- clearing anything -- so a list that changed height on a terminal appearing
--- would draw past the end of the buffer, and `handle_hover` raises "Invalid
--- 'line': out of range" from inside `vim.on_key` the next time the mouse
--- moves. Padding the list to a constant means every change is one
--- `volt.redraw`, with no `gen_data` and no resize.
---
--- What floaterm does that this must NOT is own the process. Paseo does. A
--- terminal dying arrives as a directory snapshot that no longer lists it,
--- never as an `on_exit`, so none of floaterm's reaping machinery applies.

local config = require "paseo.config"
local render = require "paseo.ui.render"
local terminal = require "paseo.ui.terminal"
local terminals = require "paseo.terminals"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---Rows the rail's help footer takes: a rule and two hint lines.
local FOOTER_ROWS = 3

---@type table|nil
local state

-- ---------------------------------------------------------------- geometry

---The three boxes, in absolute editor cells.
---
---Both boxes' bottom edges land on the same row, so the rig reads as one
---rectangle rather than as two windows that happen to be adjacent.
---@return table
local function geometry()
  local ui = config.get().ui.terminal
  local columns, lines = vim.o.columns, vim.o.lines

  local w = math.min(columns, math.max(50, config.cells(ui.width, columns, 84)))
  local h = math.min(lines, math.max(12, config.cells(ui.height, lines, 78)))

  -- Both whole numbers: the centring arithmetic yields a fractional row
  -- whenever `lines` and `h` differ in parity, and a fractional coordinate is
  -- rounded per window -- which is enough to knock the rig out of line.
  local row = type(ui.row) == "number" and math.floor(ui.row) or math.floor((lines - h) / 2)
  local col = type(ui.col) == "number" and math.floor(ui.col) or math.floor((columns - w) / 2)
  row = math.max(0, math.min(row, lines - h))
  col = math.max(0, math.min(col, columns - w))

  -- Cells, not a percentage -- the rail holds names.
  local list = math.max(16, math.min(36, math.floor(tonumber(ui.list) or 22)))
  -- ...but never more than half the box, or a narrow editor gets a rail and
  -- no terminal.
  list = math.min(list, math.floor(w / 2))

  local z = ui.zindex or 45
  -- Two columns for the rail's own border.
  local right_col = col + list + 2
  local right_w = math.max(20, w - list - 2)

  return {
    width = w,
    height = h,
    row = row,
    col = col,
    list = list,
    zindex = z,
    backdrop = ui.backdrop ~= false,
    bar = { row = row, col = right_col, width = right_w, height = 1 },
    term = { row = row + 3, col = right_col, width = right_w, height = math.max(3, h - 3) },
  }
end

-- ----------------------------------------------------------------- content

---@return paseo.Terminal[]
local function order()
  if not state then
    return {}
  end
  return terminals.for_root(state.root)
end

---@param id string|nil
---@return integer
local function index_of(id)
  for i, item in ipairs(order()) do
    if item.id == id then
      return i
    end
  end
  return 0
end

---The rail.
---
---`state.rows` is rebuilt HERE, every call, mapping a buffer line to a
---terminal id. That is deliberately not arithmetic on the cursor row: the
---panel this replaces computed `row - 5` from the number of heading rows, and
---any change to the heading silently retargeted `d`.
---@return table[][]
local function list_lines()
  local g = state.geometry
  local inner = g.list - 2
  local list = order()
  state.rows = {}

  -- The section is exactly as tall as the window, every time. That is what
  -- makes a terminal appearing one `volt.redraw` -- see the note at the top --
  -- and it is also what puts the help on the bottom row rather than leaving it
  -- floating wherever the list happened to end. The height only changes on a
  -- resize, and a resize already goes all the way back through `gen_data`.
  local rows = math.max(6, g.height)

  local lines = {
    { { " Terminals", "PaseoHeader" } },
    { { string.rep("─", inner), "PaseoBorder" } },
  }

  if #list == 0 then
    lines[#lines + 1] = {
      { terminals.ready(state.root) and " none yet" or " loading…", "PaseoDim" },
    }
  end

  for i, item in ipairs(list) do
    local glyph = terminals.glyph(item)
    local current = item.id == state.current
    local click = function()
      M.focus(item.id)
    end
    local line = widgets.row({
      {
        current and require("paseo.ui.icons").marker.mine or " ",
        current and "PaseoAgent" or nil,
        click,
      },
      { glyph[1] .. " ", glyph[2], click },
      { terminals.label(item), current and "PaseoAgent" or "PaseoCardText", click },
    }, { i <= 9 and { tostring(i) .. " ", "PaseoKeycapDim", click } or { "", nil, click } }, inner)
    lines[#lines + 1] = render.truncate(line, inner)
    state.rows[#lines] = item.id
  end

  -- More terminals than rows is not a thing to hide. Cut to fit and say by how
  -- much: the last row becomes a count rather than the last terminal silently
  -- not being there.
  local body = rows - FOOTER_ROWS
  if #lines > body then
    local shown = body - 1 - 2 -- less the count row, less header and rule
    for line = shown + 3, #lines do
      state.rows[line] = nil
    end
    for _ = #lines, body, -1 do
      table.remove(lines)
    end
    lines[#lines + 1] = { { (" +%d more"):format(#list - shown), "PaseoDim" } }
  end
  while #lines < body do
    lines[#lines + 1] = {}
  end

  lines[#lines + 1] = { { string.rep("─", inner), "PaseoBorder" } }
  lines[#lines + 1] = widgets.hints { { "c", "new" }, { "d", "kill" } }
  lines[#lines + 1] = widgets.hints { { "r", "name" }, { "q", "close" } }
  return lines
end

---The bar over the terminal: what you are in, and where.
---
---Three segments, and they give way in priority order as the bar narrows --
---the NAME is what you are reading, so it goes last. Composing the row and
---then truncating it would be the opposite: `render.truncate` cuts from the
---end, so the first thing to disappear would be the directory and the second
---would be nothing, because the live title would have run into where it was.
---@return table[][]
local function bar_lines()
  local g = state.geometry
  local inner = g.bar.width - 2
  local item = state.current and terminals.get(state.current)

  local left = { { " ", "PaseoDim" } }
  if item then
    left[#left + 1] = { terminals.label(item), "PaseoHeader" }
  else
    left[#left + 1] = { "no terminal", "PaseoDim" }
  end

  ---Columns not yet spoken for, less the gap a justified row needs.
  local function spare()
    return inner - render.width(left) - 2
  end

  -- The directory, in full if it fits and as its last component if it does
  -- not. A path elided to `…/w/2/ws-ter…` tells you nothing; a basename does.
  local right = {}
  local full = vim.fn.fnamemodify(state.root, ":~")
  local tail = vim.fn.fnamemodify(state.root, ":t")
  if spare() >= #full + 1 then
    right = { { full .. " ", "PaseoDim" } }
  elseif spare() >= #tail + 1 then
    right = { { tail .. " ", "PaseoDim" } }
  end

  -- The live PTY title -- `user@host:~/dir` for a shell, the running program
  -- for anything else. It belongs here and not in the rail, where every
  -- terminal in a directory reports the same one and twenty columns of
  -- identical text is not a list. Last in, first out.
  local subtitle = item and terminals.subtitle(item)
  local room = spare() - render.width(right)
  if subtitle and room > 12 then
    table.insert(left, { "  " .. subtitle, "PaseoDim" })
    left = render.truncate(left, inner - render.width(right) - 2)
  end

  return { widgets.row(left, right, inner, "PaseoNormal") }
end

---What fills the terminal pane when there is nothing to show in it.
---
---Rather than closing the surface, which is what floaterm does when its last
---terminal dies: pressing `d` on the last row and having the window vanish is
---jarring, and it is also the whole of the ordering problem between a window
---closing and a terminal ending.
local function empty_buf()
  if not (state.empty and api.nvim_buf_is_valid(state.empty)) then
    state.empty = api.nvim_create_buf(false, true)
    vim.bo[state.empty].bufhidden = "hide"
    api.nvim_buf_set_lines(state.empty, 0, -1, false, { "", "   c  a new terminal" })
    vim.bo[state.empty].modifiable = false
  end
  return state.empty
end

local function show_empty()
  if not (state and state.term_win and api.nvim_win_is_valid(state.term_win)) then
    return
  end
  -- Out of terminal mode first: the pane you are leaving is a PTY you may be
  -- typing in, and the placeholder is not one.
  if api.nvim_get_current_win() == state.term_win then
    pcall(vim.cmd.stopinsert)
  end
  api.nvim_win_set_buf(state.term_win, empty_buf())
end

-- ------------------------------------------------------------------ volt

---Repaint the rail and the bar. Never `gen_data`: both sections are a fixed
---number of rows, which is the point of padding them.
local function redraw()
  if not state then
    return
  end
  local volt = require "volt"
  if state.listbuf and api.nvim_buf_is_valid(state.listbuf) then
    pcall(volt.redraw, state.listbuf, "list")
  end
  if state.barbuf and api.nvim_buf_is_valid(state.barbuf) then
    pcall(volt.redraw, state.barbuf, "bar")
  end
end

local function measure()
  local volt = require "volt"
  volt.gen_data {
    {
      buf = state.listbuf,
      ns = state.ns,
      xpad = 1,
      layout = {
        -- Fresh tables every call: volt's `draw` strips the third element from
        -- every cell it is handed, so a cached line list loses its click
        -- targets after the first draw.
        {
          name = "list",
          lines = function()
            return render.to_volt(list_lines())
          end,
        },
      },
    },
    {
      buf = state.barbuf,
      ns = state.ns,
      xpad = 1,
      layout = {
        {
          name = "bar",
          lines = function()
            return render.to_volt(bar_lines())
          end,
        },
      },
    },
  }
end

-- ------------------------------------------------------------------- verbs

---@return string|nil
function M.current()
  return state and state.current or nil
end

---Show a terminal, attaching to it if this is the first look.
---@param id string
---@param enter? boolean  Put the cursor in it. Default true.
function M.focus(id, enter)
  if not state then
    return
  end
  local item = terminals.get(id)
  if not item then
    return
  end
  state.current = id
  local view = terminal.ensure(item, state.term_win)
  terminal.show(view, state.term_win)
  redraw()
  if enter ~= false and state.term_win and api.nvim_win_is_valid(state.term_win) then
    api.nvim_set_current_win(state.term_win)
    vim.cmd.startinsert()
  end
end

---@param step integer
---@param enter? boolean
function M.cycle(step, enter)
  local list = order()
  if #list == 0 then
    return
  end
  local at = index_of(state and state.current)
  -- One expression for both directions, floaterm's: `at` is 1-based, so
  -- `at - 1` is the 0-based index and a step of -1 needs `- 2`.
  local next_at = (math.max(1, at) + (step < 0 and -2 or 0)) % #list
  M.focus(list[next_at + 1].id, enter)
end

---@param n integer
---@param enter? boolean
function M.jump(n, enter)
  local item = order()[n]
  if item then
    M.focus(item.id, enter)
  end
end

---Everything `c` can start.
---
---A shell, then one entry per provider the daemon actually has -- read live,
---so enabling one in Paseo makes it appear here without a config change --
---then whatever is configured, then a free-text escape hatch.
---@param cwd string
---@param callback fun(presets: table[])
function M.presets(cwd, callback)
  local out = { { label = "Shell" } }

  for _, preset in ipairs(config.get().ui.terminal.presets or {}) do
    if type(preset) == "string" then
      out[#out + 1] = { label = preset, command = preset }
    elseif type(preset) == "table" and preset.command then
      out[#out + 1] = {
        label = preset.label or preset.command,
        command = preset.command,
        args = preset.args,
      }
    end
  end
  out[#out + 1] = { label = "Command…", prompt = true }

  require("paseo.ui.create").catalogue(cwd, function(entries)
    local providers = {}
    for _, entry in ipairs(entries or {}) do
      -- `enabled ~= false` rather than `status == "ready"`: a provider can be
      -- installed and configured while its models are still being fetched,
      -- and a terminal running its CLI does not need a model at all.
      if entry.enabled ~= false and entry.provider then
        providers[#providers + 1] = {
          label = entry.label or entry.provider,
          command = entry.provider,
        }
      end
    end
    -- Providers go after the shell and before everything else, which is the
    -- order you reach for them in.
    for i, preset in ipairs(providers) do
      table.insert(out, i + 1, preset)
    end
    callback(out)
  end)
end

---Start a terminal here and go straight into it.
---@param preset? table  `{ command?, args?, label? }`
function M.create(preset)
  if not state then
    return
  end
  preset = preset or {}
  require("paseo.bridge").request("terminals.create", {
    cwd = state.root,
    command = preset.command,
    args = preset.args,
    name = preset.label ~= "Shell" and (preset.label or preset.command) or nil,
    rows = state.geometry.term.height,
    cols = state.geometry.term.width,
  }, function(err, result)
    vim.schedule(function()
      if err then
        return vim.notify(
          "paseo: could not start a terminal — " .. tostring(err),
          vim.log.levels.ERROR
        )
      end
      local item = result and result.terminal
      -- Straight into it. You did not ask for a row in a list; you asked for
      -- a terminal.
      if item and item.id then
        -- The directory is told by push and may not have caught up, so seed
        -- it rather than waiting for the snapshot.
        terminals.adopt(item, state.root)
        if preset.label and preset.label ~= "Shell" then
          terminals.set_label(item.id, preset.label)
        end
        M.focus(item.id)
      end
    end)
  end)
end

---Ask what to run, then run it.
function M.new()
  if not state then
    return
  end
  local root = state.root
  M.presets(root, function(presets)
    vim.schedule(function()
      vim.ui.select(presets, {
        prompt = "New terminal",
        format_item = function(preset)
          return preset.label
        end,
      }, function(preset)
        if not preset then
          return
        end
        if preset.prompt then
          return vim.ui.input({ prompt = "Command: " }, function(command)
            if command and vim.trim(command) ~= "" then
              M.create { command = command, label = command }
            end
          end)
        end
        M.create(preset)
      end)
    end)
  end)
end

---@param id string
function M.rename(id)
  local item = terminals.get(id)
  vim.ui.input(
    { prompt = "Name: ", default = item and terminals.label(item) or "" },
    function(title)
      if title == nil then
        return
      end
      -- Ours first, because it is the one that survives. The daemon is told as
      -- well -- a later one may keep a title the PTY does not overwrite, and
      -- the name then shows up in the Paseo app too -- but nothing here waits
      -- on that answer.
      terminals.set_label(id, title)
      redraw()
      require("paseo.bridge").request(
        "terminals.rename",
        { terminalId = id, title = title },
        function() end
      )
    end
  )
end

---@param id string
function M.kill(id)
  local item = terminals.get(id)
  local name = item and terminals.label(item) or id
  -- Killing a terminal kills whatever is running in it, and "whatever" is
  -- routinely an agent mid-turn. Asked rather than assumed.
  vim.ui.select({ "no", "yes" }, { prompt = ("Kill %s?"):format(name) }, function(choice)
    if choice ~= "yes" then
      return
    end
    require("paseo.bridge").request("terminals.kill", { terminalId = id }, function(err)
      if err then
        vim.schedule(function()
          vim.notify("paseo: could not kill it — " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end)
  end)
end

-- -------------------------------------------------------- the world changes

---A terminal appeared, was renamed, or died.
---
---Death arrives HERE and nowhere else: Paseo owns the process, so there is no
---`on_exit` to hang it off, and a window closing means something else
---entirely. No race either -- the bridge already dispatches on the main loop,
---the payload is a full list for the directory rather than a delta, and
---nothing below resizes a window.
local function directory_changed()
  if not state then
    return
  end
  local alive = {}
  for _, item in ipairs(order()) do
    alive[item.id] = true
  end

  -- The SURVIVOR GOES UP FIRST, before anything is detached. Detaching deletes
  -- the PTY buffer, and the one that just died is the one on screen -- so
  -- closing that window is what the editor would otherwise do, and the
  -- surface's own `WinClosed` would read it as "the user closed me".
  if state.current and not alive[state.current] then
    state.current = nil
    local first = order()[1]
    if first then
      M.focus(first.id)
    else
      show_empty()
    end
  end

  for id in pairs(terminal.views()) do
    if not alive[id] then
      terminal.detach(id)
    end
  end
  redraw()
end

local watching = false

-- --------------------------------------------------------------- open/close

---@param buf integer
---@param mode string|string[]
---@param lhs string|false
---@param rhs function
---@param desc string
local function map(buf, mode, lhs, rhs, desc)
  if not lhs or not api.nvim_buf_is_valid(buf) then
    return
  end
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
end

---The keys every PTY buffer gets.
---
---`1`-`9` are NOT among them, on purpose: a bare digit in a terminal buffer
---costs you `50k` to scroll back, and the rail is one keystroke away. The
---`<M->` forms reach the same terminals and collide with nothing.
---@param buf integer
local function bind_terminal(buf)
  local keys = config.get().ui.terminal.keys
  map(buf, "n", "q", M.close, "paseo: close the terminal surface")
  map(buf, "n", "<C-c>", M.close, "paseo: close the terminal surface")
  -- Bound in TERMINAL mode as well as normal: cycling that first needs
  -- `<C-\><C-n>` is cycling nobody uses.
  map(buf, { "n", "t" }, keys.next, function()
    M.cycle(1)
  end, "paseo: next terminal")
  map(buf, { "n", "t" }, keys.prev, function()
    M.cycle(-1)
  end, "paseo: previous terminal")
  map(buf, { "n", "t" }, keys.list, function()
    if state and state.listwin and api.nvim_win_is_valid(state.listwin) then
      vim.cmd.stopinsert()
      api.nvim_set_current_win(state.listwin)
    end
  end, "paseo: to the terminal list")
  for i = 1, 9 do
    map(buf, { "n", "t" }, "<M-" .. i .. ">", function()
      M.jump(i)
    end, "paseo: terminal " .. i)
  end
end

---@param buf integer
local function bind_list(buf)
  local keys = config.get().ui.terminal.keys
  local function under_cursor()
    local win = api.nvim_get_current_win()
    return state and state.rows and state.rows[api.nvim_win_get_cursor(win)[1]] or nil
  end

  map(buf, "n", "<CR>", function()
    local id = under_cursor()
    if id then
      M.focus(id)
    end
  end, "paseo: open this terminal")
  map(buf, "n", "c", M.new, "paseo: new terminal")
  map(buf, "n", "r", function()
    local id = under_cursor()
    if id then
      M.rename(id)
    end
  end, "paseo: rename this terminal")
  map(buf, "n", "d", function()
    local id = under_cursor()
    if id then
      M.kill(id)
    end
  end, "paseo: kill this terminal")
  map(buf, "n", keys.terminal, function()
    if state and state.term_win and api.nvim_win_is_valid(state.term_win) then
      api.nvim_set_current_win(state.term_win)
    end
  end, "paseo: back to the terminal")
  -- Cycling from the RAIL leaves you on the rail: jumping into the terminal
  -- on every step would make a second `<C-j>` impossible without coming back.
  map(buf, "n", keys.next, function()
    M.cycle(1, false)
  end, "paseo: next terminal")
  map(buf, "n", keys.prev, function()
    M.cycle(-1, false)
  end, "paseo: previous terminal")
  -- Here the digits are free, and they are the fastest way to the fifth
  -- terminal.
  for i = 1, 9 do
    map(buf, "n", tostring(i), function()
      M.jump(i)
    end, "paseo: terminal " .. i)
  end
end

---@return boolean
function M.is_open()
  return state ~= nil and state.listwin ~= nil and api.nvim_win_is_valid(state.listwin)
end

function M.close()
  if not state or state.closing then
    return
  end
  state.closing = true
  local held = state
  state = nil

  -- The attachments first: a daemon streaming into a buffer that is about to
  -- be deleted is bytes across the pipe for nothing.
  terminal.detach_all()

  for _, win in ipairs { held.term_win, held.barwin, held.listwin, held.backdrop_win } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end

  -- volt's own teardown: it deletes these buffers, clears `volt.state` and
  -- takes them off the global key handler's list. THE PTY BUFFERS ARE NOT IN
  -- THIS LIST and must not be -- `volt.utils.close` force-deletes whatever it
  -- is handed, which would take the channels with it.
  pcall(function()
    require("volt.utils").close { bufs = { held.listbuf, held.barbuf, held.backdrop } }
  end)

  if held.empty and api.nvim_buf_is_valid(held.empty) then
    pcall(api.nvim_buf_delete, held.empty, { force = true })
  end
  if held.augroup then
    pcall(api.nvim_del_augroup_by_id, held.augroup)
  end
  if held.prev_win and api.nvim_win_is_valid(held.prev_win) then
    pcall(api.nvim_set_current_win, held.prev_win)
  end
end

---Reposition the whole rig, and tell the daemon the new size.
local function relayout()
  if not state then
    return
  end
  local volt = require "volt"
  local g = geometry()
  state.geometry = g

  local boxes = {
    { state.listwin, { row = g.row, col = g.col, width = g.list, height = g.height } },
    { state.barwin, g.bar },
    { state.term_win, g.term },
  }
  for _, box in ipairs(boxes) do
    if box[1] and api.nvim_win_is_valid(box[1]) then
      pcall(
        api.nvim_win_set_config,
        box[1],
        vim.tbl_extend("force", { relative = "editor" }, box[2])
      )
    end
  end
  if state.backdrop_win and api.nvim_win_is_valid(state.backdrop_win) then
    pcall(api.nvim_win_set_config, state.backdrop_win, {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines,
    })
  end

  -- The rail's row COUNT is constant; its width is not, so the layout has to
  -- be measured again and the empty lines rewritten at the new width.
  vim.bo[state.listbuf].modifiable = true
  vim.bo[state.barbuf].modifiable = true
  api.nvim_buf_clear_namespace(state.listbuf, state.ns, 0, -1)
  api.nvim_buf_clear_namespace(state.barbuf, state.ns, 0, -1)
  measure()
  volt.set_empty_lines(state.listbuf, g.height, g.list)
  volt.set_empty_lines(state.barbuf, 1, g.bar.width)
  vim.bo[state.listbuf].modifiable = false
  vim.bo[state.barbuf].modifiable = false
  volt.redraw(state.listbuf, "all")
  volt.redraw(state.barbuf, "all")

  local view = state.current and terminal.view(state.current)
  if view then
    terminal.resize(view, state.term_win)
  end
end

---@param opts? { root?: string, id?: string }
function M.open(opts)
  opts = opts or {}
  if state then
    if opts.id then
      M.focus(opts.id)
    end
    return
  end

  local volt = require "volt"
  require("paseo.ui.hl").setup()

  local root = opts.root
  if not root then
    local chat = require("paseo.ui.chat").current()
    root = chat and chat.root or assert(vim.uv.cwd())
  end

  local g = geometry()
  state = {
    root = root,
    geometry = g,
    ns = api.nvim_create_namespace "paseo.termfloat",
    listbuf = api.nvim_create_buf(false, true),
    barbuf = api.nvim_create_buf(false, true),
    prev_win = api.nvim_get_current_win(),
    rows = {},
  }

  if g.backdrop then
    state.backdrop = api.nvim_create_buf(false, true)
    state.backdrop_win = api.nvim_open_win(state.backdrop, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines,
      focusable = false,
      style = "minimal",
      border = "none",
      zindex = math.max(1, g.zindex - 5),
    })
    vim.wo[state.backdrop_win].winblend = 20
  end

  -- Measured before the windows exist, the way volt wants it: `gen_data` runs
  -- every section's `lines()` and records where each one starts.
  measure()

  state.listwin = api.nvim_open_win(state.listbuf, true, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.list,
    height = g.height,
    style = "minimal",
    border = "rounded",
    zindex = g.zindex,
  })
  state.barwin = api.nvim_open_win(state.barbuf, false, {
    relative = "editor",
    row = g.bar.row,
    col = g.bar.col,
    width = g.bar.width,
    height = g.bar.height,
    style = "minimal",
    border = "rounded",
    zindex = g.zindex,
  })

  -- Opened on the placeholder, not on a throwaway scratch buffer: deleting
  -- the only buffer a window holds closes the window with it.
  state.term_win = api.nvim_open_win(empty_buf(), false, {
    relative = "editor",
    row = g.term.row,
    col = g.term.col,
    width = g.term.width,
    height = g.term.height,
    style = "minimal",
    border = "rounded",
    zindex = g.zindex,
  })

  for _, win in ipairs { state.listwin, state.barwin, state.term_win } do
    api.nvim_win_set_hl_ns(win, state.ns)
  end
  api.nvim_set_hl(state.ns, "Normal", { link = "PaseoNormal" })
  api.nvim_set_hl(state.ns, "NormalFloat", { link = "PaseoNormal" })
  api.nvim_set_hl(state.ns, "FloatBorder", { link = "PaseoNormalBorder" })

  volt.run(state.listbuf, { h = g.height, w = g.list })
  volt.run(state.barbuf, { h = 1, w = g.bar.width })
  vim.bo[state.listbuf].filetype = "paseo-terminals"

  -- The PTY buffers are deliberately absent: `volt.utils.close` force-deletes
  -- every buffer it is given.
  volt.mappings {
    bufs = { state.listbuf, state.barbuf },
    winclosed_event = true,
    after_close = M.close,
  }
  require("volt.events").add(state.listbuf)
  bind_list(state.listbuf)

  state.augroup = api.nvim_create_augroup("PaseoTermFloat", { clear = true })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = state.augroup,
    callback = function()
      if state then
        vim.schedule(relayout)
      end
    end,
  })
  -- A PTY buffer entering the terminal window is the one moment its keys can
  -- be bound: the buffers are created by `terminal.ensure`, which knows
  -- nothing about this surface.
  api.nvim_create_autocmd("BufWinEnter", {
    group = state.augroup,
    callback = function(ev)
      if state and state.term_win and api.nvim_win_is_valid(state.term_win) then
        if api.nvim_win_get_buf(state.term_win) == ev.buf then
          bind_terminal(ev.buf)
        end
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    pattern = tostring(state.term_win),
    callback = function()
      M.close()
    end,
  })

  if not watching then
    watching = true
    -- Registered once for the process: `terminals.on_change` has no removal
    -- either, and the handler is a no-op while the surface is closed.
    terminals.on_change(function()
      vim.schedule(directory_changed)
    end)
  end
  terminals.watch(root, function()
    vim.schedule(function()
      if not state then
        return
      end
      local first = opts.id and terminals.get(opts.id) or order()[1]
      if first then
        M.focus(first.id)
      else
        show_empty()
      end
      redraw()
    end)
  end)

  if opts.id then
    M.focus(opts.id)
  end
  return state
end

function M.toggle(opts)
  if M.is_open() then
    return M.close()
  end
  return M.open(opts)
end

return M
