--- Agent-session controls: mode, thinking level, model, feature toggles.
---
--- The same four things `ui/session.lua` drives, but shown all at once with the
--- current value FILLED IN, instead of four separate prompts you have to open
--- one at a time to find out what is set.
---
--- This file is a VIEW over `ui/session.lua`'s model, and it is deliberately
--- reusable: `M.new` returns a view object that the native surface's panel and
--- the standalone popup both drive. They differ only in how wide they are and
--- what they call to repaint, so sharing the builders is what keeps the two
--- from drifting into different-looking versions of the same four settings.
---
--- A group of kind `"pick"` -- provider, model, permission mode, thinking --
--- is ONE row showing what is set, and its key or `<CR>` opens the list in
--- your own picker (|paseo.ui.pick|, i.e. `vim.ui.select`), where you can
--- type at it. Those lists are what you search; walking a row of chips to
--- reach the fourth one was the slow way to choose. Toggles stay checkboxes.
---
--- WHY A FOCUS MODEL AND NOT THE CURSOR. Focus is ours, held by id and drawn
--- with `PaseoChipFocus`, so it survives a redraw that rebuilds every row, and
--- it picks one chip out of a row of several. It began as a workaround: volt
--- dispatched `<CR>` through a `CursorMoved` autocmd and reset the cursor to
--- `{1,1}` after every click, so a selection on the cursor was thrown away on
--- each interaction.

local pick = require "paseo.ui.pick"
local render = require "paseo.ui.render"
local session = require "paseo.ui.session"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Settings"

---The index of the entry a group has set, else 1.
---@param group table
---@return integer
function M.current(group)
  for i, entry in ipairs(group.entries or {}) do
    if entry.id == group.current then
      return i
    end
  end
  return 1
end

---Focus is stored BY ID, never by index: the lists change under us -- switching
---model replaces every thinking option -- and an index kept across that lands
---on whatever happens to be third now.
---@class paseo.AgentSettingsView
---@field source paseo.SettingsSource
---@field only string|nil   Draw just this group.
---@field section string    Left from volt, which repainted this section on
---                          hover. Nothing dispatches a hover now.
---@field compact boolean   Drop the padding inside every card.
---@field spread boolean    Pick groups show every option, not just what is set.
---@field hints table[]|nil Extra footer hint pairs.
---@field footer nil|fun(width: integer): table[][]  A row under the cards.
---@field focus { group: string|nil, entry: string|nil }
---@field redraw fun()
local View = {}
View.__index = View

---@param source paseo.SettingsSource  |paseo.ui.session|.source or |paseo.ui.draft|.source
---@param opts? { only?: string, section?: string, hints?: table[], redraw?: fun(), spread?: boolean }
---@return paseo.AgentSettingsView
function M.new(source, opts)
  opts = opts or {}
  return setmetatable({
    source = source,
    only = opts.only,
    -- Left from volt: the section a hover repainted. Nothing dispatches a
    -- hover now.
    section = opts.section or "body",
    -- Drop the padding inside every card. Set by whichever surface is drawing
    -- when the rows it has are fewer than the rows the layout wants.
    compact = false,
    -- Every option of a pick group on its card, what is set lit and the rest
    -- dim (the new-task screen). Off, a pick group is one row: the panel is
    -- narrow, and twelve models there would push everything off screen.
    spread = opts.spread or false,
    -- Extra hint pairs for the footer, for keys the surface around the view
    -- binds itself -- the popup's `q`. A hint bar that lies about how to get
    -- out is worse than no hint bar.
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
    if group.kind == "pick" then
      -- One stop: the row is the group, and the choosing happens in the
      -- picker. Walking through entries you cannot see would be walking blind.
      if #group.entries > 0 then
        local at = M.current(group)
        flat[#flat + 1] = { group = group, entry = group.entries[at], g = g, e = at }
      end
    else
      for e, entry in ipairs(group.entries) do
        flat[#flat + 1] = { group = group, entry = entry, g = g, e = e }
      end
    end
  end
  if #flat == 0 then
    return
  end

  local at = 1
  for i, item in ipairs(flat) do
    if item.g == gi and (item.e == ei or groups[gi].kind == "pick") then
      at = i
    end
  end

  local next_item = flat[(at - 1 + step) % #flat + 1]
  self:set_focus(next_item.group, next_item.entry)
  self.redraw()
end

---Jump focus to a group by its mnemonic key.
---
---On a pick group the key also OPENS the picker: `s` and type a model name is
---the whole point of the key, and "jump there, then press `<CR>`" is a second
---keypress that only ever means one thing.
---@param key string
function View:jump(key)
  for _, group in ipairs(self:groups() or {}) do
    if group.key == key then
      self:set_focus(group, nil)
      self.redraw()
      if group.kind == "pick" then
        self:activate()
      end
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
  if group.kind == "pick" then
    pick.group(group, function(picked)
      self:set_focus(group, picked)
      self.source:apply(group, picked, function()
        self.redraw()
      end)
    end)
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

---Hover and focus are the same paint. Plain buffers have no pointer hover,
---so this is the keyboard's focus alone; kept as one call site.
---@param id string
---@return boolean
local function hovered(id)
  return require("paseo.ui.widgets").hovered(id)
end

---Is this the focused entry?
---
---COMPARED BY ID, never by identity. `session.groups` builds fresh tables on
---every call (it had to, under volt, which destroyed the ones it was handed),
---so the entry `resolve` picked and the entry `lines` is drawing are two
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
---ITS HEIGHT IS RESERVED, not computed from the focused entry. It stops the
---cards below jumping a row as you move along a chip row. (Under volt it was
---also a crash: volt recorded each section's starting row once, so a section
---that changed height on a hover wrote extmarks past the end of the buffer.)
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
    -- The checkbox volt had: one segment, glyph plus label, state in the
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

---A pick group with EVERY option on the card, for a view with `spread` set:
---the new-task screen, which has the width and is where you read all four
---settings at once before you send.
---
---What is set is lit (green, or its tone); everything else is dim, so the
---card says what you are about to start AND what else there was. Choosing
---still happens in your picker -- the group's letter, or `<CR>` -- so the
---row is one stop in `h j k l`, as the one-row card is. A click on an
---option picks that option directly: you are pointing at it.
---@param self paseo.AgentSettingsView
---@param group table
---@param focus table  `{ group = id, entry = id }`
---@param w integer
---@return table[][]
local function spread_body(self, group, focus, w)
  local lit = focus.group == group.id or hovered("paseo:" .. group.id)
  local current = group.entries[M.current(group)]
  local chips = {}
  for _, entry in ipairs(group.entries) do
    local state
    if entry.id == group.current then
      state = lit and "focus" or (entry.tone or "on")
    else
      -- Toned options keep their tone unselected, as in `chips_body`:
      -- bypass reads as danger while you are choosing, not after.
      state = entry.tone and (entry.tone .. "_off") or "off"
    end
    local label = entry.note and (entry.label .. " · " .. entry.note) or entry.label
    local action = {
      click = function()
        self:set_focus(group, entry)
        self.source:apply(group, entry, function()
          self.redraw()
        end)
      end,
      hover = { id = "paseo:" .. group.id, redraw = self.section },
    }
    chips[#chips + 1] = widgets.chip(label, state, action)
  end
  local lines = widgets.chiprow(chips, w)
  vim.list_extend(lines, description_block(group, current, w))
  return lines
end

---The body of a pick group: what is set, and how to change it.
---
---ONE row, whatever the list's length, so twelve models cost the card no more
---than two do. The chip keeps its tone -- bypass still reads as danger on the
---card, which is the one place left that can colour it. The description is the
---CURRENT entry's, under a height reserved for the longest, so picking a mode
---with a longer description does not move every card below.
---@param self paseo.AgentSettingsView
---@param group table
---@param focus table  `{ group = id, entry = id }`
---@param w integer
---@return table[][]
local function pick_body(self, group, focus, w)
  if #group.entries == 0 then
    return { { { group.placeholder or "(none reported by this provider)", "PaseoCardDim" } } }
  end
  if self.spread then
    return spread_body(self, group, focus, w)
  end
  local entry = group.entries[M.current(group)]
  local set = entry.id == group.current
  local focused = focus.group == group.id or hovered("paseo:" .. group.id)
  local state = focused and "focus" or (set and (entry.tone or "on")) or "off"
  local action = click(self, group, entry)
  -- The hover id is the GROUP's: the row stands for the whole list.
  action.hover.id = "paseo:" .. group.id

  local left = { { " ", "PaseoCardText" }, widgets.chip(entry.label, state, action) }
  if entry.note then
    left[#left + 1] = { "  " .. entry.note, "PaseoCardDim", action }
  end
  local count = #group.entries
  local right = {
    { ("%d option%s  "):format(count, count == 1 and "" or "s"), "PaseoCardDim", action },
    { " " .. (group.key or "<CR>") .. " ", "PaseoChipOff", action },
    { " pick ", "PaseoCardDim", action },
  }
  local line = widgets.row(left, right, w)
  for _, cell in ipairs(line) do
    cell[3] = cell[3] or action
  end

  local lines = { line }
  vim.list_extend(lines, description_block(group, entry, w))
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

  if group.kind == "pick" then
    body = pick_body(self, group, focus, inner)
  elseif group.kind == "chips" then
    body = chips_body(self, group, focus, inner)
  elseif group.kind == "toggles" then
    body = toggles_body(self, group, focus, inner)
  else
    body = radio_body(self, group, focus, inner)
  end

  -- A FLOOR on the body, for a group whose contents come and go. The features
  -- card empties while the daemon is asked what the new mode supports, and a
  -- card that shrinks and grows again moves every card below it, a flicker on
  -- every round trip. (Under volt it was a crash.) Holding the height across
  -- the round trip is what keeps the layout still.
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
    -- place that knows there is nothing to draw. Guarded, because every
    -- repaint draws and `View:lines` draws twice to measure -- unguarded, a
    -- panel that had not loaded yet would fire two `agent.config` requests a
    -- repaint. (Under volt, two per mouse-move event.)
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
  -- A pick group's key opens its picker; any other group's key only moves
  -- there. Two different verbs, so two different hints.
  local picks, jumps = {}, {}
  for _, group in ipairs(groups) do
    if group.key then
      local into = group.kind == "pick" and picks or jumps
      into[#into + 1] = group.key
    end
  end

  local hints = {
    { "h j k l", "move" },
    { "<CR>", #picks > 0 and "pick / apply" or "apply" },
  }
  if #picks > 0 then
    hints[#hints + 1] = { table.concat(picks, " "), "pick" }
  end
  if #jumps > 0 then
    hints[#hints + 1] = { table.concat(jumps, " "), "group" }
  end
  hints[#hints + 1] = { "r", "reload" }
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
  -- Through |paseo.ui.keys|, which saves what it displaces -- the buffer
  -- carries keys the surface or popup bound on it too.
  self.bound = require("paseo.ui.keys").take(buf, self:mappings(), "paseo: agent settings")
end

---Give the buffer its keys back.
---
---Required, not tidiness: the buffer carries keys the surface or popup bound
---on it too, and a plain delete would take any this displaced with it. See
---|paseo.ui.keys|.
---@param buf integer
function View:unbind(buf)
  local saved = self.bound
  self.bound = nil
  require("paseo.ui.keys").release(buf, saved)
end

-- ---------------------------------------------------- the native panel API

---The native panel's view. One surface, one view; rebuilt when the chat
---changes.
---@type paseo.AgentSettingsView|nil
local panel_view

---@param chat table
---@return paseo.AgentSettingsView
local function view_for(chat)
  if not panel_view or panel_view.source.chat ~= chat then
    panel_view = M.new(session.source(chat), {
      redraw = function()
        require("paseo.ui.native").redraw_panels()
      end,
    })
  end
  return panel_view
end

---Ask the daemon, then redraw.
---@param chat table
function M.load(chat)
  local view = view_for(chat)
  -- Marked as out, so the draw that follows this (and sees nothing yet)
  -- does not send a second `agent.config` of its own.
  if view.loading then
    return
  end
  view.loading = true
  view.source:load(function()
    view.loading = false
    view.redraw()
  end)
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
