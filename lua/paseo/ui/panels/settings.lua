--- Agent-session controls: mode, thinking level, model, feature toggles.
---
--- The same four things `ui/session.lua` drives, but shown all at once with the
--- current value FILLED IN, instead of four separate prompts you have to open
--- one at a time to find out what is set.
---
--- This file is a VIEW over `ui/session.lua`'s model, and it is deliberately
--- reusable: `M.new` returns a view object that the dashboard panel and the
--- standalone popup both drive. They differ only in how wide they are and what
--- they call to repaint, so sharing the builders is what keeps the two from
--- drifting into different-looking versions of the same four settings.
---
--- WHY A FOCUS MODEL AND NOT THE CURSOR. volt dispatches `<CR>` through a
--- `CursorMoved` autocmd and then resets the cursor to `{1,1}` after every
--- click (`volt/events.lua:44-48`), so a selection that lived on the cursor
--- would be thrown away by the framework on each interaction. Focus is ours,
--- drawn with `PaseoChipFocus`, and hover paints the same group -- so the
--- mouse and the keyboard are visibly the same interaction, not two.

local render = require "paseo.ui.render"
local session = require "paseo.ui.session"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Settings"

---Focus is stored BY ID, never by index: the lists change under us -- switching
---model replaces every thinking option -- and an index kept across that lands
---on whatever happens to be third now.
---@class paseo.AgentSettingsView
---@field source paseo.SettingsSource
---@field only string|nil   Draw just this group.
---@field section string    The volt section a hover repaints.
---@field compact boolean   Drop the padding inside every card.
---@field hints table[]|nil Extra footer hint pairs.
---@field footer nil|fun(width: integer): table[][]  A row under the cards.
---@field focus { group: string|nil, entry: string|nil }
---@field redraw fun()
local View = {}
View.__index = View

---@param source paseo.SettingsSource  |paseo.ui.session|.source or |paseo.ui.draft|.source
---@param opts? { only?: string, section?: string, hints?: table[], redraw?: fun() }
---@return paseo.AgentSettingsView
function M.new(source, opts)
  opts = opts or {}
  return setmetatable({
    source = source,
    only = opts.only,
    -- Which volt section a hover has to repaint. The dashboard calls its
    -- panel area "body"; the popup draws one section of its own.
    section = opts.section or "body",
    -- Drop the padding inside every card. Set by whichever surface is drawing
    -- when the rows it has are fewer than the rows the layout wants.
    compact = false,
    -- Extra hint pairs for the footer. The popup has a `q` the dashboard tab
    -- does not, and a hint bar that lies about how to get out is worse than
    -- no hint bar.
    hints = opts.hints,
    focus = { group = opts.only, entry = nil },
    redraw = opts.redraw or function() end,
  }, View)
end

-- ------------------------------------------------------------------- focus

---The groups this view draws, after `only` has been applied.
---@return table[]|nil
function View:groups()
  local groups = self.source:groups()
  if not groups then
    return nil
  end
  if not self.only then
    return groups
  end
  local group = session.group(groups, self.only)
  return group and { group } or groups
end

---Where focus actually is, resolved against the CURRENT lists.
---
---Falls back to the selected entry rather than the first one, so opening the
---panel puts you on what is set instead of making you walk to it.
---@return table|nil group, table|nil entry, integer gi, integer ei
function View:resolve()
  local groups = self:groups()
  if not groups or #groups == 0 then
    return nil, nil, 0, 0
  end

  local gi = 1
  for i, group in ipairs(groups) do
    if group.id == self.focus.group then
      gi = i
    end
  end
  -- A group with nothing in it cannot hold focus; step to one that can.
  if #groups[gi].entries == 0 then
    for i, group in ipairs(groups) do
      if #group.entries > 0 then
        gi = i
        break
      end
    end
  end

  local group = groups[gi]
  local ei = 0
  for i, entry in ipairs(group.entries) do
    if entry.id == self.focus.entry then
      ei = i
    end
  end
  if ei == 0 then
    for i, entry in ipairs(group.entries) do
      if entry.id == group.current then
        ei = i
      end
    end
  end
  ei = ei == 0 and 1 or ei

  return group, group.entries[ei], gi, ei
end

---@param group table|nil
---@param entry table|nil
function View:set_focus(group, entry)
  self.focus.group = group and group.id or nil
  self.focus.entry = entry and entry.id or nil
end

---Move one step through every entry of every group, in order.
---
---Running off the end of a group lands on the next group rather than wrapping
---inside it, so `j` and `l` mean "the next thing" everywhere and there is one
---traversal rather than one per card.
---@param step integer
function View:move(step)
  local groups = self:groups()
  if not groups then
    return
  end
  local _, _, gi, ei = self:resolve()
  if gi == 0 then
    return
  end

  local flat = {}
  for g, group in ipairs(groups) do
    for e, entry in ipairs(group.entries) do
      flat[#flat + 1] = { group = group, entry = entry, g = g, e = e }
    end
  end
  if #flat == 0 then
    return
  end

  local at = 1
  for i, item in ipairs(flat) do
    if item.g == gi and item.e == ei then
      at = i
    end
  end

  local next_item = flat[(at - 1 + step) % #flat + 1]
  self:set_focus(next_item.group, next_item.entry)
  self.redraw()
end

---Jump focus to a group by its mnemonic key.
---@param key string
function View:jump(key)
  for _, group in ipairs(self:groups() or {}) do
    if group.key == key then
      self:set_focus(group, nil)
      self.redraw()
      return
    end
  end
end

---Apply whatever is focused.
function View:activate()
  local group, entry = self:resolve()
  if not (group and entry) then
    return
  end
  self.source:apply(group, entry, function()
    self.redraw()
  end)
end

---Re-fetch from the daemon.
function View:reload()
  self.source:load(function()
    self.redraw()
  end)
end

-- ----------------------------------------------------------------- drawing

---Hover and focus are the same paint, so the two input devices look like one.
---@param id string
---@return boolean
local function hovered(id)
  return vim.g.nvmark_hovered == id
end

---Is this the focused entry?
---
---COMPARED BY ID, never by identity. `session.groups` builds fresh tables on
---every call -- it has to, because volt destroys the ones it is handed -- so
---the entry `resolve` picked and the entry `lines` is drawing are two
---different Lua tables describing the same setting. Comparing them with `==`
---silently never matched, and the focus ring never appeared.
---@param focus table  `{ group = id, entry = id }`
---@param group table
---@param entry table
---@return boolean
local function is_focused(focus, group, entry)
  return focus.group == group.id and focus.entry == entry.id
end

---@param self paseo.AgentSettingsView
---@param group table
---@param entry table
---@return function
local function click(self, group, entry)
  return {
    click = function()
      self:set_focus(group, entry)
      self:activate()
    end,
    hover = { id = "paseo:" .. group.id .. ":" .. entry.id, redraw = self.section },
  }
end

---The focused entry's description, under the options it belongs to.
---
---The description belongs to whatever is focused IN THIS GROUP -- handing
---the one focused entry to every card printed the permission mode's
---description under the thinking levels. Four descriptions stacked under
---four options is four lines you read once; one line that changes as you
---move is one you actually use.
---
---ITS HEIGHT IS RESERVED, not computed from the focused entry. Two reasons,
---and the second is a crash. It stops the cards below jumping a row as you
---move along a chip row. And volt records each section's starting row once,
---in `gen_data`, then draws at those offsets without clearing or re-padding
---- so a section that changed height because you MOVED THE MOUSE writes
---extmarks past the end of the buffer, and `handle_hover` raises
---"Invalid 'line': out of range" from inside `vim.on_key`.
---
---`description` only, never `note`. A note is one word -- "default", or a
---base branch -- and reserving two rows of a card to say it about one entry
---costs the footer its place on a short editor. Notes belong beside the
---entry, which is where `widgets.radio` and the toggles put them.
---@param group table
---@param focused table|nil
---@param w integer
---@return table[][]
local function description_block(group, focused, w)
  local reserved = 0
  for _, entry in ipairs(group.entries) do
    if entry.description then
      reserved = math.max(reserved, #render.wrap(entry.description, w, "PaseoCardDim"))
    end
  end
  if reserved == 0 then
    return {}
  end

  local lines = { {} }
  local wrapped = focused
      and focused.description
      and render.wrap(focused.description, w, "PaseoCardDim")
    or {}
  for i = 1, reserved do
    lines[#lines + 1] = wrapped[i] or {}
  end
  return lines
end

---The body of a chips group: the pills, then the focused one's description.
---@param self paseo.AgentSettingsView
---@param group table
---@param focus table  `{ group = id, entry = id }`
---@param w integer
---@return table[][]
local function chips_body(self, group, focus, w)
  if #group.entries == 0 then
    return { { { group.placeholder or "(none reported by this provider)", "PaseoCardDim" } } }
  end

  local chips = {}
  local focused
  for _, entry in ipairs(group.entries) do
    local id = "paseo:" .. group.id .. ":" .. entry.id
    local state
    if is_focused(focus, group, entry) or hovered(id) then
      focused = entry
      state = "focus"
    elseif entry.id == group.current then
      state = entry.tone or "on"
    else
      -- A toned option keeps its tone even UNSELECTED. The point of colouring
      -- these at all is that you can tell "nothing asks, everything runs" from
      -- "research and write a plan" while you are CHOOSING between them, and
      -- a tone that only appears once you have already picked it is a warning
      -- delivered after the fact.
      state = entry.tone and (entry.tone .. "_off") or "off"
    end
    chips[#chips + 1] = widgets.chip(entry.label, state, click(self, group, entry))
  end

  local lines = widgets.chiprow(chips, w)
  vim.list_extend(lines, description_block(group, focused, w))
  return lines
end

---@param self paseo.AgentSettingsView
---@param group table
---@param focus table  `{ group = id, entry = id }`
---@param w integer
---@return table[][]
local function radio_body(self, group, focus, w)
  if #group.entries == 0 then
    return { { { group.placeholder or "(none reported by this provider)", "PaseoCardDim" } } }
  end
  local lines = {}
  for _, entry in ipairs(group.entries) do
    local id = "paseo:" .. group.id .. ":" .. entry.id
    lines[#lines + 1] = widgets.radio {
      label = entry.label,
      right = entry.note,
      active = entry.id == group.current,
      focused = is_focused(focus, group, entry) or hovered(id),
      w = w,
      click = click(self, group, entry),
    }
  end
  return lines
end

---@param self paseo.AgentSettingsView
---@param group table
---@param focus table  `{ group = id, entry = id }`
---@param w integer
---@return table[][]
local function toggles_body(self, group, focus, w)
  if #group.entries == 0 then
    return { { { group.placeholder or "(none on this provider)", "PaseoCardDim" } } }
  end
  local lines = {}
  local focused
  for _, entry in ipairs(group.entries) do
    local id = "paseo:" .. group.id .. ":" .. entry.id
    local lit = is_focused(focus, group, entry) or hovered(id)
    if lit then
      focused = entry
    end
    local action = click(self, group, entry)
    -- volt's own checkbox: one segment, glyph plus label, state in the
    -- highlight. Ours only supplies the icons and the two colours.
    local cell = widgets.checkbox {
      txt = entry.label,
      active = entry.value,
      check = widgets.icons.check_on,
      uncheck = widgets.icons.check_off,
      hlon = lit and "PaseoChipFocus" or "PaseoChipOn",
      hloff = lit and "PaseoChipFocus" or "PaseoCardDim",
      actions = action,
    }
    -- A note sits to the right of the row it belongs to, the way
    -- `widgets.radio` puts it there: the manifest screen writes each repo's
    -- base branch into one, and the thing discovery most often gets wrong
    -- should be readable without focusing every repo in turn.
    local right = entry.note and { { entry.note .. " ", "PaseoCardDim", action } } or {}
    local line = widgets.row({ { " ", "PaseoCardText" }, cell }, right, w)
    -- The gap between the label and the note carries the action too, so the
    -- target is the row rather than the words on it.
    for _, cell_ in ipairs(line) do
      cell_[3] = cell_[3] or action
    end
    lines[#lines + 1] = line
  end
  vim.list_extend(lines, description_block(group, focused, w))
  return lines
end

---One group, as a card.
---@param self paseo.AgentSettingsView
---@param group table
---@param focus table  `{ group = id, entry = id }`
---@param w integer
---@return table[][]
local function card(self, group, focus, w)
  -- What a card's body actually gets, asked of the style rather than assumed:
  -- a framed card spends two columns on its sides that a plate does not, and
  -- hardcoding either number truncates under the other.
  local inner = math.max(8, widgets.card_inner(w))
  local body

  if group.kind == "chips" then
    body = chips_body(self, group, focus, inner)
  elseif group.kind == "toggles" then
    body = toggles_body(self, group, focus, inner)
  else
    body = radio_body(self, group, focus, inner)
  end

  -- A FLOOR on the body, for a group whose contents come and go. The features
  -- card empties while the daemon is asked what the new mode supports, and a
  -- card that shrinks and grows again moves every card below it -- which volt
  -- turns from a flicker into a crash, because `gen_data` recorded the old
  -- rows and `handle_hover` redraws at them. Holding the height across the
  -- round trip is what keeps the layout still.
  for _ = #body + 1, group.rows or 0 do
    body[#body + 1] = { { "", "PaseoCardText" } }
  end

  -- A blank row above and below the body is what makes a card look like a
  -- card rather than a box with text jammed against its edges. It is also the
  -- first thing to go when there is not enough vertical room: eight rows of
  -- padding or the model list, and the model list wins.
  local lines = {}
  if not self.compact then
    lines[#lines + 1] = { { "", "PaseoCardText" } }
  end
  vim.list_extend(lines, body)
  if not self.compact then
    lines[#lines + 1] = { { "", "PaseoCardText" } }
  end

  return widgets.card {
    -- The mnemonic lives in the title, drawn as a key cap, so the key that
    -- reaches this card is written ON the card rather than only in the footer.
    title = {
      { group.label, "PaseoCardTitle" },
      { "  ", "PaseoCardRule" },
      { " " .. group.key .. " ", "PaseoChipOff" },
    },
    icon = group.icon,
    lines = lines,
    w = w,
  }
end

---@param self paseo.AgentSettingsView
---@param width integer
---@param height? integer  Rows available. Tightens the layout if it will not fit.
---@return table[][]
function View:lines(width, height)
  if height then
    -- Measure at full size, and only then decide. Deciding from the width
    -- alone would compact a tall narrow surface that had plenty of room.
    self.compact = false
    if #self:draw(width) > height then
      self.compact = true
    end
  end
  return self:draw(width)
end

---@param self paseo.AgentSettingsView
---@param width integer
---@return table[][]
function View:draw(width)
  local groups = self:groups()
  if not groups then
    -- Drawing is not a good place to start a round trip, but it is the only
    -- place that knows there is nothing to draw. Guarded, because volt calls
    -- `lines()` again on every hover and `View:lines` calls it twice to
    -- measure -- unguarded, a mouse moved across a panel that had not loaded
    -- yet fired two `agent.config` requests per mouse-move event.
    if not self.loading then
      self.loading = true
      self.source:load(function()
        self.loading = false
        self.redraw()
      end)
    end
    return { { { "  loading agent settings…", "PaseoDim" } } }
  end

  -- Resolved once and carried as IDS, because every `groups()` call builds
  -- new tables.
  local fgroup, fentry = self:resolve()
  local focus = { group = fgroup and fgroup.id, entry = fentry and fentry.id }
  local lines = {}

  local function add(block)
    vim.list_extend(lines, block)
    lines[#lines + 1] = {}
  end

  -- Short cards go side by side: Thinking and Features together cost five rows
  -- instead of ten, which on an 80x24 terminal is exactly the difference
  -- between the model list fitting on screen and not. Which cards pair is the
  -- SOURCE's business -- the new-agent screen has a Provider card the
  -- running-agent one does not, and one more full-width card is one more
  -- than a short editor has room for. Only when there is room for two
  -- readable columns: a card narrower than ~32 truncates its own title, and
  -- two truncated cards are worse than two full-width ones.
  local partner, skip = {}, {}
  if not self.only and width >= 64 then
    for _, pair in ipairs(self.source.pairs or { { "thinking", "features" } }) do
      local a = session.group(groups, pair[1])
      local b = session.group(groups, pair[2])
      -- Both or neither: one card sized to half the width with nothing beside
      -- it looks like a layout bug, not a choice.
      if a and b then
        partner[a], skip[b] = b, true
      end
    end
  end

  for _, group in ipairs(groups) do
    local other = partner[group]
    if other then
      local left = math.floor((width - 2) / 2)
      local right = width - 2 - left
      local a = card(self, group, focus, left)
      local b = card(self, other, focus, right)
      -- Squared off before they are handed to `grid_col`, which pads a short
      -- column with unhighlighted space rather than with the card's own.
      local tall = math.max(#a, #b)
      widgets.card_to_height(a, tall, left)
      widgets.card_to_height(b, tall, right)
      add(widgets.grid_col {
        { lines = a, w = left, pad = 2 },
        { lines = b, w = right },
      })
    elseif not skip[group] then
      add(card(self, group, focus, width))
    end
  end

  -- A surface may put a row of its own under the cards: the new-agent screen
  -- has a "create" action, which is not a setting and must not be drawn as a
  -- card that looks like one.
  if self.footer then
    vim.list_extend(lines, self.footer(width))
  end

  -- The mnemonics come from the groups being DRAWN, not from a literal: this
  -- view is also the one the new-agent screen uses, and that one has a
  -- Provider card the running-agent one does not.
  local keys = {}
  for _, group in ipairs(groups) do
    if group.key then
      keys[#keys + 1] = group.key
    end
  end

  local hints = {
    { "h j k l", "move" },
    { "<CR>", "apply" },
    { table.concat(keys, " "), "group" },
    { "r", "reload" },
  }
  vim.list_extend(hints, self.hints or {})
  lines[#lines + 1] = widgets.hints(hints)

  return lines
end

-- ------------------------------------------------------------------- keys

---Every key this view answers to, as `{ lhs, handler }`.
---@return table[]
function View:mappings()
  local moves = {
    ["l"] = 1,
    ["j"] = 1,
    ["<Right>"] = 1,
    ["<Down>"] = 1,
    ["h"] = -1,
    ["k"] = -1,
    ["<Left>"] = -1,
    ["<Up>"] = -1,
  }

  local out = {}
  for key, step in pairs(moves) do
    out[#out + 1] = {
      key,
      function()
        self:move(step)
      end,
    }
  end

  -- From the CONSTANT, not from the fetched groups: keys are bound the moment
  -- you arrive at the tab, and on a cold open that is before the daemon has
  -- answered. A mnemonic derived from a config that has not landed is a
  -- mnemonic that is never bound at all.
  for _, key in pairs(self.source.keys or session.KEYS) do
    out[#out + 1] = {
      key,
      function()
        self:jump(key)
      end,
    }
  end

  out[#out + 1] = {
    "<CR>",
    function()
      self:activate()
    end,
  }
  out[#out + 1] = {
    "r",
    function()
      self:reload()
    end,
  }

  return out
end

---@param buf integer
function View:bind(buf)
  -- Binding twice would capture our own mappings as the "previous" ones and
  -- there would be nothing left to restore.
  if self.bound then
    self:unbind(buf)
  end
  -- Through |paseo.ui.keys|, which saves what it displaces -- the panels share
  -- one chrome buffer and volt owns `<CR>` on it.
  self.bound = require("paseo.ui.keys").take(buf, self:mappings(), "paseo: agent settings")
end

---Give the buffer its keys back.
---
---Required, not tidiness: the dashboard's chrome buffer is shared by six
---panels, and `<CR>` left bound here would keep trying to apply an agent
---setting from the Changes tab.
---@param buf integer
function View:unbind(buf)
  local saved = self.bound
  self.bound = nil
  require("paseo.ui.keys").release(buf, saved)
end

-- ------------------------------------------------- the dashboard panel API

---The dashboard's view. One surface, one view; rebuilt when the chat changes.
---@type paseo.AgentSettingsView|nil
local panel_view

---@param chat table
---@return paseo.AgentSettingsView
local function view_for(chat)
  if not panel_view or panel_view.source.chat ~= chat then
    panel_view = M.new(session.source(chat), {
      redraw = function()
        require("paseo.ui.float").rebuild()
      end,
    })
  end
  return panel_view
end

---Ask the daemon, then redraw.
---@param chat table
function M.load(chat)
  local view = view_for(chat)
  view.source:load(view.redraw)
end

---@param chat table
---@param width integer
---@param height? integer
---@return table[][]
function M.lines(chat, width, height)
  return view_for(chat):lines(width, height)
end

---@param chat table
---@param buf integer
function M.attach(chat, buf)
  view_for(chat):bind(buf)
end

---@param chat table
---@param buf integer
function M.detach(chat, buf)
  if panel_view then
    panel_view:unbind(buf)
  end
end

return M
