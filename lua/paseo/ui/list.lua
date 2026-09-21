--- A list you drive from the keyboard, for the dashboard's list tabs.
---
--- The sibling of |paseo.ui.panels.settings|. That file is a view over a grid
--- of CONTROLS; this one is a view over SECTIONS OF ROWS. They share a shape
--- -- focus held by id, keys taken and given back, measure before you draw --
--- and share almost no drawing, which is why they are two files and not one
--- base class with two subclasses to save thirty lines.
---
--- WHY A FOCUS MODEL AND NOT THE CURSOR. The same reason the settings view has
--- one, and it bit harder here. volt dispatches `<CR>` through a `CursorMoved`
--- autocmd and then resets the cursor to `{1,1}` after every click, so a
--- selection that lived on the cursor is thrown away by the framework on each
--- interaction. The panels this replaces kept a `buffer line -> item` map and
--- read `nvim_win_get_cursor`, which meant three things at once:
---
---   * nothing on screen said which row you were on, because the cursor is a
---     terminal cursor sitting in a volt-drawn line;
---   * the cursor was never PUT on a row when you arrived at the tab, so the
---     first `<CR>` you pressed did nothing;
---   * and one click sent it back to line 1 regardless.
---
--- Which is why the Sessions tab had working keymaps and read as broken.
---
--- Focus is ours, held as `{ section = id, row = id }`, resolved against the
--- current data on every draw, and painted with the same highlight as hover --
--- pointing at a row and moving to it are the same state.
---
--- A ROW THAT DISAPPEARS does not take focus with it. These lists are push-fed
--- by the daemon: agents come and go, a terminal you just killed is gone by
--- the next frame, `git status` re-runs. So `resolve` falls back in steps --
--- the same id somewhere else, then whatever took its place, then the active
--- row, then the first one -- and the last of those is what seeds focus on the
--- very first draw, so a list that arrives AFTER you switched tabs still lands
--- focus somewhere without anyone having to remember to do it.

local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local M = {}

---Re-fetch. `r` everywhere, including the settings grid, so the one key that
---means "ask again" means it on every tab.
local RELOAD = "r"

---@class paseo.ListRow
---@field id string              Stable across redraws. Focus IS this.
---@field cells table[]|nil      A line, as |paseo.ui.render| means one.
---@field right table[]|nil      Right-aligned cells; justified into `cells`.
---@field active boolean|nil     "This is the current one" -- NOT focus.
---@field activate fun()|nil     `<CR>`, and a click.
---@field keys table<string, fun()>|nil  Per-row verbs, by the source's alphabet.
---@field skip boolean|nil       Drawn, but `j`/`k` step over it.

---@class paseo.ListSection
---@field id string
---@field title string|nil
---@field icon string|nil
---@field hl string|nil          Highlight for the icon. Default `PaseoBlue1`.
---@field swatch string|nil      Name to hash a colour block off, instead of an icon.
---@field summary table[]|nil    Cells drawn after the title.
---@field empty string|nil       What to say when it has no rows.
---@field rows paseo.ListRow[]

---@class paseo.ListSource
---@field sections fun(self): paseo.ListSection[]|nil  nil == not loaded yet
---@field load fun(self, done: fun())
---@field keys table<string, string>|nil  The per-row key ALPHABET.
---@field verbs table<string, fun()>|nil  Keys that act on the LIST, not on a
---                             row -- "new terminal", "new agent". A row's own
---                             `keys` entry wins over one of these.
---@field hints table[]|nil      Extra `{ lhs, label }` pairs for the footer.
---@field loading string|nil     What to say while the first fetch is out.

---@class paseo.ListView
---@field source paseo.ListSource
---@field section string         The volt section a hover repaints.
---@field focus { section: string|nil, row: string|nil }
---@field at { si: integer, ri: integer }  Where focus last RESOLVED to.
---@field offset integer         First visible row, for lists taller than the body.
---@field redraw fun()
local View = {}
View.__index = View

---@param source paseo.ListSource
---@param opts? { section?: string, redraw?: fun() }
---@return paseo.ListView
function M.new(source, opts)
  opts = opts or {}
  return setmetatable({
    source = source,
    section = opts.section or "body",
    focus = { section = nil, row = nil },
    -- Where focus last landed, as indices. Only ever read when the id it was
    -- standing on has gone -- see `resolve`.
    at = { si = 1, ri = 1 },
    offset = 0,
    loading = false,
    redraw = opts.redraw or function() end,
  }, View)
end

-- --------------------------------------------------------------------- data

---@return paseo.ListSection[]|nil
function View:sections()
  return self.source:sections()
end

---Every row of every section, in order, with where it came from.
---@param sections paseo.ListSection[]
---@return { row: paseo.ListRow, section: paseo.ListSection, si: integer, ri: integer }[]
local function flatten(sections)
  local flat = {}
  for si, section in ipairs(sections) do
    for ri, row in ipairs(section.rows or {}) do
      flat[#flat + 1] = { row = row, section = section, si = si, ri = ri }
    end
  end
  return flat
end

-- -------------------------------------------------------------------- focus

---Where focus actually is, resolved against the CURRENT sections.
---
---Four fallbacks, in order, and each one exists for a case that happens:
---
---  1. the focused id, in the section it was in -- the ordinary path;
---  2. the focused id in ANY section, so a terminal that moved out of the
---     agents block keeps focus rather than losing it to a heading;
---  3. whatever now occupies the position focus last resolved to, so `d` on a
---     row leaves you standing on the row that took its place rather than back
---     at the top of the list;
---  4. the active row, else the first one -- which is also the FIRST DRAW,
---     where there is no focus yet and something has to be under `<CR>`.
---@return paseo.ListRow|nil row, paseo.ListSection|nil section, integer si, integer ri
function View:resolve()
  local sections = self:sections()
  if not sections then
    return nil, nil, 0, 0
  end
  local flat = flatten(sections)
  if #flat == 0 then
    return nil, nil, 0, 0
  end

  -- 1 and 2. Compared BY ID, never by table identity: `sections()` builds
  -- fresh tables on every call -- it has to, because volt strips the third
  -- element out of every cell it is handed -- so `==` would silently never
  -- match and the focus ring would never appear.
  if self.focus.row then
    local elsewhere
    for _, item in ipairs(flat) do
      if item.row.id == self.focus.row then
        if item.section.id == self.focus.section then
          return item.row, item.section, item.si, item.ri
        end
        elsewhere = elsewhere or item
      end
    end
    if elsewhere then
      return elsewhere.row, elsewhere.section, elsewhere.si, elsewhere.ri
    end
  end

  -- 3. The position it last resolved to, clamped into the shape we have now.
  local si = math.max(1, math.min(self.at.si, #sections))
  local rows = sections[si].rows or {}
  if #rows > 0 then
    local ri = math.max(1, math.min(self.at.ri, #rows))
    return rows[ri], sections[si], si, ri
  end

  -- 4. The active row, else the first.
  for _, item in ipairs(flat) do
    if item.row.active then
      return item.row, item.section, item.si, item.ri
    end
  end
  return flat[1].row, flat[1].section, flat[1].si, flat[1].ri
end

---@param row paseo.ListRow|nil
---@param section paseo.ListSection|nil
---@param si? integer
---@param ri? integer
function View:set_focus(row, section, si, ri)
  self.focus.row = row and row.id or nil
  self.focus.section = section and section.id or nil
  if si and ri then
    self.at = { si = si, ri = ri }
  end
end

---Step through every row of every section, in order.
---
---Running off the end of a section lands in the next one, so `j` means "the
---next row" everywhere rather than "the next row in this block". `skip` rows
---are drawn but stepped over: the Workspaces panel lists the repos of this
---unit of work underneath, and those are a readout, not somewhere to stand.
---@param step integer
function View:move(step)
  local sections = self:sections()
  if not sections then
    return
  end
  local flat = {}
  for _, item in ipairs(flatten(sections)) do
    if not item.row.skip then
      flat[#flat + 1] = item
    end
  end
  if #flat == 0 then
    return
  end

  local _, _, si, ri = self:resolve()
  local at = 1
  for i, item in ipairs(flat) do
    if item.si == si and item.ri == ri then
      at = i
    end
  end

  local next_item = flat[(at - 1 + step) % #flat + 1]
  self:set_focus(next_item.row, next_item.section, next_item.si, next_item.ri)
  self.redraw()
end

---First or last row. `first` when `step` is negative.
---@param step integer
function View:edge(step)
  local sections = self:sections()
  if not sections then
    return
  end
  local flat = {}
  for _, item in ipairs(flatten(sections)) do
    if not item.row.skip then
      flat[#flat + 1] = item
    end
  end
  if #flat == 0 then
    return
  end
  local item = step < 0 and flat[1] or flat[#flat]
  self:set_focus(item.row, item.section, item.si, item.ri)
  self.redraw()
end

---Move to the first row of the previous or next section.
---@param step integer
function View:section_step(step)
  local sections = self:sections()
  if not sections then
    return
  end
  local _, _, si = self:resolve()
  if si == 0 then
    return
  end
  -- Sections with nothing to stand on are skipped rather than landed on and
  -- silently bounced off.
  for i = 1, #sections do
    local at = ((si - 1 + step * i) % #sections) + 1
    for ri, row in ipairs(sections[at].rows or {}) do
      if not row.skip then
        self:set_focus(row, sections[at], at, ri)
        return self.redraw()
      end
    end
  end
end

---`<CR>`.
function View:activate()
  local row = self:resolve()
  if row and row.activate then
    row.activate()
  end
end

---Run the verb bound to this key.
---
---The focused row's own first, then the source's. A row that has nothing under
---the key falls through to the list-wide verb rather than doing nothing, which
---is what makes `c` mean "new terminal" from anywhere in the Sessions list
---while `d` means "kill THIS one".
---@param key string
function View:verb(key)
  local row = self:resolve()
  local fn = (row and row.keys and row.keys[key]) or (self.source.verbs or {})[key]
  if fn then
    fn()
  end
end

function View:reload()
  self.source:load(function()
    self.redraw()
  end)
end

-- ------------------------------------------------------------------- drawing

---@param section paseo.ListSection
---@return table[]
local function heading(section)
  local line = { { "  " } }
  -- A swatch instead of an icon where the sections are all the same KIND of
  -- thing and what distinguishes them is which one: four repos get four
  -- headings that were otherwise four identical blue lines, and the only way
  -- to tell them apart was to read them.
  if section.swatch then
    line[#line + 1] = widgets.swatch(section.swatch)
    line[#line + 1] = { " " }
  elseif section.icon then
    line[#line + 1] = { section.icon .. "  ", section.hl or "PaseoBlue1" }
  end
  line[#line + 1] = { section.title or "", "PaseoHeader" }
  for _, cell in ipairs(section.summary or {}) do
    line[#line + 1] = cell
  end
  return line
end

---One row, painted whole when it is focused, hovered or current.
---
---`fill_row` drops per-cell colour, so the band is one unbroken sweep across
---the full width rather than stopping where the text does -- and the gaps
---carry the action too, which is what makes a row something you aim at rather
---than something you must hit.
---@param self paseo.ListView
---@param row paseo.ListRow
---@param width integer
---@param focused boolean
---@return table[]
function View:paint(row, width, focused)
  local id = self.section .. "." .. row.id
  local cells = vim.deepcopy(row.cells or {})
  if row.right and #row.right > 0 then
    cells = widgets.row(cells, vim.deepcopy(row.right), width)
  end

  local action = row.activate and widgets.hover(id, self.section, row.activate) or nil
  local hl = widgets.row_hl(id, { focused = focused, active = row.active })
  if hl then
    return widgets.fill_row(cells, width, hl, action)
  end
  for _, cell in ipairs(cells) do
    cell[3] = action
  end
  return cells
end

---@param width integer
---@param height? integer
---@return table[][]
function View:lines(width, height)
  local sections = self:sections()
  if not sections then
    -- Drawing is not a good place to start a round trip, but it is the only
    -- place that knows there is nothing to draw. Guarded, because volt calls
    -- `lines()` again on every hover -- unguarded, a mouse moved across a
    -- panel that had not loaded yet fires one request per mouse-move event.
    if not self.loading then
      self.loading = true
      self.source:load(function()
        self.loading = false
        self.redraw()
      end)
    end
    return { { { "  " .. (self.source.loading or "loading…"), "PaseoDim" } } }
  end

  -- Resolved once and carried as an ID, because every `sections()` call above
  -- built new tables and the one we drew from is not the one `resolve` will
  -- build next time.
  local focused = self:resolve()
  local focus_id = focused and focused.id

  ---@param w integer  Content width. One narrower once a scrollbar is due.
  ---@return table[][] body, integer focus_line  The line focus landed on, 0
  ---if it did not land anywhere.
  local function body(w)
    local out, focus_line = {}, 0
    for _, section in ipairs(sections) do
      if section.title then
        out[#out + 1] = heading(section)
        out[#out + 1] = {}
      end
      if #(section.rows or {}) == 0 and section.empty then
        out[#out + 1] = { { "    " .. section.empty, "PaseoDim" } }
      end
      for _, row in ipairs(section.rows or {}) do
        local lit = row.id == focus_id
        out[#out + 1] = self:paint(row, w, lit)
        if lit then
          focus_line = #out
        end
      end
      out[#out + 1] = {}
    end
    return out, focus_line
  end

  local drawn, focus_line = body(width)
  local hints = self:hints()

  if not height then
    drawn[#drawn + 1] = hints
    return drawn
  end

  -- The hint bar is always the last row and never scrolls: a list that scrolls
  -- its own instructions off the bottom stops saying what its keys are at
  -- exactly the point it has grown enough to need them.
  local room = math.max(1, height - 1)
  if #drawn <= room then
    self.offset = 0
    drawn[#drawn + 1] = hints
    return drawn
  end

  -- It overflows, so a scrollbar is due and the gutter it needs is a column
  -- the rows cannot also have. Measure first and redraw narrower, rather than
  -- truncating what was drawn: the focused row is padded to the full width by
  -- `fill_row`, so trimming it afterwards put an ellipsis on the one row that
  -- had nothing to elide.
  local gutter = math.max(1, width - 1)
  drawn, focus_line = body(gutter)

  -- MINIMAL SCROLL: move only when focus has left the window, so the list does
  -- not lurch under a `j` that did not need it. The offset lives on the view
  -- and is clamped every draw -- it is never the cursor's, which volt resets.
  local top = self.offset
  if focus_line > 0 then
    if focus_line <= top then
      top = focus_line - 1
    elseif focus_line > top + room then
      top = focus_line - room
    end
  end
  self.offset = math.max(0, math.min(top, #drawn - room))

  -- `scrollbar` answers one cell per visible row, and blanks when everything
  -- fits -- which cannot happen here, because that is the branch above. Every
  -- line is squared to the gutter first: only the FOCUSED row is padded out to
  -- the width it was drawn at, so appending the bar to each line as it stood
  -- put it in a different column on every row.
  local bar = widgets.scrollbar(self.offset, #drawn, room)
  local window = {}
  for i = 1, room do
    local line = drawn[self.offset + i] or {}
    render.pad(line, gutter)
    if bar[i] then
      line[#line + 1] = bar[i]
    end
    window[i] = line
  end

  window[#window + 1] = hints
  return window
end

---@return table[]
function View:hints()
  local pairs_ = { { "j k", "move" }, { "<CR>", "open" } }
  local taken = {}
  for _, hint in ipairs(self.source.hints or {}) do
    pairs_[#pairs_ + 1] = hint
    taken[hint[1]] = true
  end
  -- Only when the source did not claim the key for something of its own. A
  -- hint bar that advertises one key for two things is worse than one that
  -- leaves the second unadvertised: it is wrong about the first.
  if not taken[RELOAD] then
    pairs_[#pairs_ + 1] = { RELOAD, "reload" }
  end
  return widgets.hints(pairs_)
end

-- --------------------------------------------------------------------- keys

---@return table[]
function View:mappings()
  local out = {}

  ---Later wins, and the source's keys are added last.
  ---
  ---`keys.take` binds in order and does not notice a repeat, so a source that
  ---spells one of its verbs `r` used to bind BOTH that and the built-in
  ---reload, leave whichever came last on the key, and advertise the two of
  ---them side by side in the hint bar. Deduped here so the clash is resolved
  ---once, in favour of the panel -- which is the half that knows what its own
  ---list is for -- rather than by accident of ordering.
  local at = {}
  local function bind(lhs, fn, desc)
    if at[lhs] then
      out[at[lhs]] = { lhs, fn, desc }
      return
    end
    out[#out + 1] = { lhs, fn, desc }
    at[lhs] = #out
  end

  local moves = { j = 1, ["<Down>"] = 1, k = -1, ["<Up>"] = -1 }
  for lhs, step in pairs(moves) do
    bind(lhs, function()
      self:move(step)
    end, "paseo: move through the list")
  end

  -- `h`/`l` step by SECTION, so the four directions mean on a list what they
  -- mean on the settings grid: the small step and the big one.
  for lhs, step in pairs { l = 1, ["<Right>"] = 1, h = -1, ["<Left>"] = -1 } do
    bind(lhs, function()
      self:section_step(step)
    end, "paseo: next section")
  end

  bind("g", function()
    self:edge(-1)
  end, "paseo: first row")
  bind("G", function()
    self:edge(1)
  end, "paseo: last row")
  bind("<CR>", function()
    self:activate()
  end, "paseo: open what is focused")
  bind(RELOAD, function()
    self:reload()
  end, "paseo: reload")

  -- Bound from the source's ALPHABET, never from the rows it happens to have
  -- right now. Keys are taken the moment you arrive at the tab, which on a
  -- cold open is before the daemon has answered -- a key derived from data
  -- that has not landed yet would simply never be bound.
  local alphabet = {}
  for _, key in pairs(self.source.keys or {}) do
    alphabet[key] = true
  end
  for key in pairs(self.source.verbs or {}) do
    alphabet[key] = true
  end
  for key in pairs(alphabet) do
    bind(key, function()
      self:verb(key)
    end, "paseo: " .. key .. " on the focused row")
  end

  return out
end

---@param buf integer
function View:bind(buf)
  -- Binding twice would capture our own mappings as the "previous" ones and
  -- leave nothing to restore.
  if self.bound then
    self:unbind(buf)
  end
  self.bound = require("paseo.ui.keys").take(buf, self:mappings(), "paseo: list")
end

---Give the buffer its keys back.
---
---Required, not tidiness: the dashboard's panels share one chrome buffer and
---volt owns `<CR>` on it, so a panel that merely deleted its own `<CR>` would
---leave the key dead on every other one for the rest of the session.
---@param buf integer
function View:unbind(buf)
  local saved = self.bound
  self.bound = nil
  require("paseo.ui.keys").release(buf, saved)
end

return M
