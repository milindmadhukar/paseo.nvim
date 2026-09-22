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

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local style = require "paseo.ui.style"
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
---@field text string|nil        What a search matches against. Absent means
---                              the row's own cells, glyphs and all -- fine
---                              for a list whose rows read as words, and not
---                              for one whose right-hand column is a chip.

---@class paseo.ListSection
---@field id string
---@field title string|nil
---@field icon string|nil
---@field hl string|nil          Highlight for the icon. Default `PaseoBlue1`.
---@field swatch string|nil      Name to hash a colour block off, instead of an icon.
---@field summary table[]|nil    Cells drawn after the title.
---@field empty string|nil       What to say when it has no rows.
---@field rule boolean|nil       Draw a hairline under the heading, separating
---                              this section from the one above it.
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
---@field search string|nil      Turn `/` on, with this as the box's title --
---                              "sessions", "workspaces". Absent means the
---                              list has no search and `/` is left alone.
---@field anchor fun(): { row: integer, col: integer, width: integer, height: integer }|nil
---                              The AREA the search box floats over -- it sits
---                              at the bottom of it. Absent centres the box,
---                              which is right for a list that is not on the
---                              dashboard and wrong for one that is.

---@class paseo.ListView
---@field source paseo.ListSource
---@field section string         The volt section a hover repaints.
---@field focus { section: string|nil, row: string|nil }
---@field at { si: integer, ri: integer }  Where focus last RESOLVED to.
---@field offset integer         First visible row, for lists taller than the body.
---@field query string           The live search. `""` means no filter at all.
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
    query = "",
    loading = false,
    redraw = opts.redraw or function() end,
  }, View)
end

-- --------------------------------------------------------------------- data

---What a row matches on.
---@param row paseo.ListRow
---@return string
local function row_text(row)
  if row.text then
    return row.text
  end
  local parts = {}
  for _, cell in ipairs(row.cells or {}) do
    parts[#parts + 1] = cell[1]
  end
  for _, cell in ipairs(row.right or {}) do
    parts[#parts + 1] = cell[1]
  end
  return table.concat(parts, " ")
end

---The rows of one section that match `query`, best first.
---
---`matchfuzzy` is Vim's own, which is the point: it is the same ranking the
---quickfix filter and `vim.ui.select`'s fuzzy pickers use, so `wsb` finding
---`ws/bugs` behaves here the way it behaves everywhere else you have typed a
---few letters at a list. The substring fallback is not paranoia about the
---function existing -- it is there for the case that it throws on an input we
---did not expect, which would otherwise take the whole panel's draw down.
---@param rows paseo.ListRow[]
---@param query string
---@return paseo.ListRow[]
local function matching(rows, query)
  local items = {}
  for i, row in ipairs(rows) do
    items[#items + 1] = { text = row_text(row), i = i }
  end

  local ok, hits = pcall(vim.fn.matchfuzzy, items, query, { key = "text" })
  local out = {}
  if ok and type(hits) == "table" then
    for _, hit in ipairs(hits) do
      out[#out + 1] = rows[hit.i]
    end
    return out
  end

  local needle = query:lower()
  for _, item in ipairs(items) do
    if item.text:lower():find(needle, 1, true) then
      out[#out + 1] = rows[item.i]
    end
  end
  return out
end

---The sections as drawn -- the source's, narrowed by the search if there is
---one.
---
---FILTERED HERE AND NOWHERE ELSE, because everything else in this file reads
---the list through this one function: focus resolves against it, `j` steps
---through it, `<CR>` activates out of it. A filter applied only at draw time
---is a filter the keyboard cannot see, which is a list where `j` moves the
---focus ring onto a row that is not on screen.
---
---A section with no matches is DROPPED rather than drawn empty. Its heading
---says nothing about what you searched for, and three headings with nothing
---under them push the matches you wanted off the top of the panel.
---@return paseo.ListSection[]|nil
function View:sections()
  local sections = self.source:sections()
  if not sections or self.query == "" then
    return sections
  end

  local out = {}
  for _, section in ipairs(sections) do
    local rows = matching(section.rows or {}, self.query)
    if #rows > 0 then
      local copy = vim.tbl_extend("force", {}, section)
      copy.rows = rows
      -- The summary counts what the section HAS, not what is left of it after
      -- a search -- "3 running" over one row is the panel contradicting
      -- itself on the same line.
      copy.summary = nil
      copy.empty = nil
      out[#out + 1] = copy
    end
  end
  return out
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

---Narrow the list. `""` widens it again.
---
---REBINDS when the search goes from off to on or back, because `<Esc>` is only
---ours while there is something to clear. On the float mount `<Esc>` closes the
---dashboard, and a panel that held on to it would turn the surface's dismiss
---key into a no-op for as long as you were on this tab.
---@param query string
function View:set_query(query)
  query = query or ""
  local was = self.query ~= ""
  self.query = query
  -- The window the list scrolled to was a window into a longer list.
  self.offset = 0
  if was ~= (query ~= "") and self.buf then
    self:bind(self.buf)
  end
  self.redraw()
end

---`/`: the search box, floated over the list it filters.
function View:search()
  if not self.source.search then
    return
  end
  local anchor = self.source.anchor and self.source.anchor() or nil
  local before = self.query
  require("paseo.ui.filter").open({
    title = self.source.search,
    anchor = anchor,
    initial = self.query,
  }, {
    on_change = function(text)
      self:set_query(text)
    end,
    -- `nil` is `<Esc>`, and it puts the list back the way it WAS -- which is
    -- not the same as unfiltered: `/` opens on the query already in force, so
    -- cancelling an edit of it must not throw the search away as well.
    done = function(text)
      self:set_query(text or before)
    end,
  })
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

---A hairline under a heading, for lists where the sections are separate THINGS
---rather than groups of one thing.
---
---INSET by two, not by one, and the reason is the same one `widgets.card`
---gives: at one cell the rule starts exactly where the content starts and ends
---exactly where it ends, which reads as a table border. Pulling it in past the
---text on both sides is what makes the same glyph read as a divider.
---
---Opt-in per section. A blank line alone is enough separation when the
---sections are two halves of one list -- agents and terminals -- and is not
---when they are twenty workspaces belonging to six different projects.
---@param w integer
---@return table[]
local function rule(w)
  return {
    { "  " .. string.rep(style.BOX.square.h, math.max(0, w - 4)) .. "  ", "PaseoCardRule" },
  }
end

---Columns every row gives up to the gutter. Four, which is exactly the indent
---the panels used to write themselves -- so this costs no width at all.
local GUTTER = 4

---The four columns that say WHERE YOU ARE and WHICH ONE IS LIVE.
---
---Two questions, two marks, and they have to be separable because they are
---frequently both true of the same row. A caret for the keyboard; the same
---left half block the panels used for "this is the session you are in".
---
---Outside the band on purpose. `fill_row` repaints every cell it is handed in
---one flat colour -- that is what makes the focus band an unbroken sweep --
---so a marker inside it is a marker that disappears exactly when you point at
---it, which is how "the active session and the highlighted session look the
---same" happened. The gutter is painted separately, in a variant of its group
---per band, so it keeps its colour on a lit row without punching a hole in
---the fill.
---@param row paseo.ListRow
---@param band string|nil  The row's background group, if it has one.
---@param focused boolean
---@return table[]
local function gutter(row, band, focused)
  local suffix = (band == "PaseoRowHover" and "Hover")
    or (band == "PaseoRowActive" and "Active")
    or ""
  return {
    { focused and (" " .. widgets.icons.focus) or "  ", focused and "PaseoRowCaret" or band },
    {
      row.active and (widgets.icons.mine .. " ") or "  ",
      row.active and ("PaseoRowBar" .. suffix) or band,
    },
  }
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
  local body = math.max(1, width - GUTTER)
  local cells = vim.deepcopy(row.cells or {})
  if row.right and #row.right > 0 then
    cells = widgets.row(cells, vim.deepcopy(row.right), body)
  end

  local action = row.activate and widgets.hover(id, self.section, row.activate) or nil
  local lit = focused or widgets.hovered(id)
  local hl = widgets.row_hl(id, { focused = focused, active = row.active })

  local line = gutter(row, hl, lit)
  for _, cell in ipairs(line) do
    cell[3] = action
  end

  if hl then
    vim.list_extend(line, widgets.fill_row(cells, body, hl, action))
    return line
  end
  for _, cell in ipairs(cells) do
    cell[3] = action
  end
  vim.list_extend(line, cells)
  return line
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
    -- WHAT YOU SEARCHED FOR, over what it left. A filtered list that does not
    -- say it is filtered is a list that has silently lost rows -- and the
    -- count is the half that tells you whether to type another letter or to
    -- delete the last one.
    --
    -- NOT WHILE THE BOX IS OPEN, because the box is floated over the top of
    -- these rows and says the same thing: two rows spent repeating what is
    -- covering them are two rows of matches pushed underneath it.
    if self.query ~= "" and not require("paseo.ui.filter").active() then
      local found = 0
      for _, section in ipairs(sections) do
        found = found + #(section.rows or {})
      end
      out[#out + 1] = {
        { "  " .. icons.ui.search .. " ", "PaseoBlue1" },
        { self.query, "PaseoHeader" },
        { ("   %d match%s"):format(found, found == 1 and "" or "es"), "PaseoDim" },
      }
      out[#out + 1] = {}
    end
    for _, section in ipairs(sections) do
      if section.title then
        out[#out + 1] = heading(section)
        if section.rule then
          out[#out + 1] = rule(w)
        end
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
    -- Every section dropped: the search matched nothing at all. Said once,
    -- here, rather than as an `empty` line under each heading -- the headings
    -- are gone, which is the point.
    if #sections == 0 and self.query ~= "" then
      out[#out + 1] = { { "    nothing here matches", "PaseoDim" } }
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
  if self.source.search then
    -- `<Esc>` only while there is something to clear, because that is the only
    -- time it is bound -- see `set_query`.
    pairs_[#pairs_ + 1] = self.query ~= "" and { "<Esc>", "clear" } or { "/", "search" }
  end
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

  if self.source.search then
    bind("/", function()
      self:search()
    end, "paseo: search this list")
    -- Taken ONLY while a search is in force. `View:set_query` rebinds on the
    -- transition, so the chrome's own `<Esc>` -- which dismisses the dashboard
    -- -- is displaced for exactly as long as there is a filter to drop.
    if self.query ~= "" then
      bind("<Esc>", function()
        self:set_query ""
      end, "paseo: clear the search")
    end
  end

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
  -- Held so a search can rebind itself: `<Esc>` is only taken while there is a
  -- filter to clear, which is a change of mappings rather than of state.
  self.buf = buf
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

---Drop the search when the panel goes away.
---
---A query that outlived a visit to the tab is a list that opens ALREADY
---narrowed, by a word you typed once and have no reason to remember -- which
---reads as sessions having disappeared.
function View:reset()
  self.query = ""
  self.offset = 0
end

return M
