--- Frame language: how a card is drawn, and what the outer float's edge is.
---
--- This exists because "borders" turned out to be the whole complaint about
--- how the dashboard looked, and because the right answer is not one style --
--- it is a small set of them with a sane default.
---
--- The default is `"plate"`, which draws NO frame at all. A card is a title
--- row and a body painted one elevation tier above the surface it sits on,
--- with a row of padding above and below. That is the typr/nvzone look, and it
--- is the opposite of what was here before: a full box per card, in a visible
--- rule colour, nested inside the float's own border, with a horizontal rule
--- under the tab bar on top of that. Three frame weights competing inside one
--- window is what "clunky" was.
---
--- The other three presets exist because that is a taste, not a law. `"rule"`
--- keeps a hairline under each title, `"rounded"` and `"square"` keep real
--- boxes for people who want them -- fixed, this time, to one corner style
--- with consistent padding rather than two card renderers that had drifted
--- apart.
---
--- Box characters live here rather than in `ui/icons.lua` because they are a
--- property of the STYLE, not of the vocabulary: nothing outside this file
--- should ever name a corner glyph.

local M = {}

---@param cp integer
---@return string
local function g(cp)
  return vim.fn.nr2char(cp)
end

---Box-drawing sets, by codepoint for the same reason `ui/icons.lua` is.
---
---Light weight only. Heavy (`┃ ━`) and double (`║ ═`) are deliberately absent
---as FRAME characters -- heavy glyphs are used as bar FILLS, where their
---weight is the point, and a frame that competes with its contents for
---attention is the thing this module is here to stop.
M.BOX = {
  rounded = {
    tl = g(0x256d), -- ╭
    tr = g(0x256e), -- ╮
    bl = g(0x2570), -- ╰
    br = g(0x256f), -- ╯
    h = g(0x2500), -- ─
    v = g(0x2502), -- │
  },
  square = {
    tl = g(0x250c), -- ┌
    tr = g(0x2510), -- ┐
    bl = g(0x2514), -- └
    br = g(0x2518), -- ┘
    h = g(0x2500), -- ─
    v = g(0x2502), -- │
  },
}

---Junction glyphs, for the one thing that genuinely needs a ruled grid: a
---table. Same set volt's own `ui/table.lua` uses.
M.JOIN = {
  mid = { top = g(0x252c), bot = g(0x2534), none = g(0x253c) }, -- ┬ ┴ ┼
  left = { top = g(0x250c), bot = g(0x2514), none = g(0x251c) }, -- ┌ └ ├
  right = { top = g(0x2510), bot = g(0x2518), none = g(0x2524) }, -- ┐ ┘ ┤
}

---Bar fills. Heavy vertical for the chunky track, light for dense tables.
---
---The filled and empty glyph are the SAME character; only the highlight
---differs. That is why a volt/typr bar reads as a two-tone track and why the
---`┃`-then-spaces bar that `panels/usage.lua` hand-rolled read as an ASCII
---meter.
M.SCROLL = {
  thumb = g(0x2588), -- █  FULL BLOCK
  track = g(0x2595), -- ▕  RIGHT ONE EIGHTH BLOCK -- present, but barely
}

M.BAR = {
  thick = g(0x2503), -- ┃
  thin = g(0x2502), -- │
  block = g(0x2588), -- █  -- chart columns
  dot_on = g(0xf0130), -- md-checkbox_blank_circle_outline -- chart markers
  dot_off = g(0x00b7), -- MIDDLE DOT -- the chart's background grid
}

---@class paseo.Style
---@field card "plate"|"rule"|"rounded"|"square"
---@field border "invisible"|"rounded"|"single"|"none"

M.CARDS = { "plate", "rule", "rounded", "square" }
M.BORDERS = { "invisible", "rounded", "single", "none" }

---@type table<string, paseo.Style>
M.presets = {
  -- No frame. Elevation and padding do the separating.
  plate = { card = "plate", border = "invisible" },
  -- A hairline under each title, inset from both edges the way a menu
  -- separator is -- full-bleed reads as a table rule, not as a divider.
  rule = { card = "rule", border = "invisible" },
  -- Real boxes, for people who want them.
  rounded = { card = "rounded", border = "rounded" },
  square = { card = "square", border = "single" },
}

---Normalise whatever the user put in `ui.style`.
---
---Accepts a preset name, or a table of the same fields -- so
---`ui.style = "plate"` and `ui.style = { card = "plate", border = "none" }`
---are both valid, and the table form only has to name what it changes.
---@param value string|table|nil
---@return paseo.Style
function M.resolve(value)
  local base = M.presets.plate

  if type(value) == "string" then
    return vim.tbl_extend("force", base, M.presets[value] or {})
  end

  if type(value) == "table" then
    -- A table naming a preset in `preset` layers on top of it; otherwise the
    -- default is the base. Either way unknown keys are ignored rather than
    -- carried, so a typo cannot reach the renderer.
    local from = type(value.preset) == "string" and M.presets[value.preset] or base
    return {
      card = vim.tbl_contains(M.CARDS, value.card) and value.card or from.card,
      border = vim.tbl_contains(M.BORDERS, value.border) and value.border or from.border,
    }
  end

  return vim.deepcopy(base)
end

---True when a valid `ui.style`. Used by `config.setup`'s validation, so a bad
---value is reported against the key that caused it rather than surfacing as a
---card that quietly drew nothing.
---@param value any
---@return boolean
function M.valid(value)
  if value == nil then
    return true
  end
  if type(value) == "string" then
    return M.presets[value] ~= nil
  end
  if type(value) ~= "table" then
    return false
  end
  if value.preset ~= nil and M.presets[value.preset] == nil then
    return false
  end
  if value.card ~= nil and not vim.tbl_contains(M.CARDS, value.card) then
    return false
  end
  if value.border ~= nil and not vim.tbl_contains(M.BORDERS, value.border) then
    return false
  end
  return true
end

---The live style, resolved from config.
---@return paseo.Style
function M.get()
  return M.resolve(require("paseo.config").get().ui.style)
end

---What to hand `nvim_open_win` for the outer edge, and what to paint it with.
---
---`"invisible"` is not `border = "none"`: it keeps a real rounded border and
---paints the glyphs `fg == bg`, which turns the frame into a one-cell ring of
---padding in the surface's own colour. Dropping the border instead would take
---the padding with it and put content hard against the window edge.
---
---A DRAWN edge gets `PaseoSurfaceBorder` rather than `PaseoBorder`, and the
---difference is the background. `PaseoBorder` has none, so the glyphs rendered
---on the editor's background and the framed styles lost the one cell of
---padding the unframed ones get -- the frame read as a hairline pasted onto
---the editor rather than as the edge of a raised sheet.
---@param style? paseo.Style
---@return string border, string group
function M.window_border(style)
  style = style or M.get()

  if style.border == "invisible" then
    return "rounded", "PaseoNormalBorder"
  end
  if style.border == "none" then
    return "none", "PaseoNormalBorder"
  end
  return style.border, "PaseoSurfaceBorder"
end

return M
