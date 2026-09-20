--- Design tokens: the colours every surface is built from.
---
--- Split out of `ui/hl.lua`, which now only APPLIES what this file derives.
--- The reason for the split is that the tokens are read directly by the
--- widgets -- a chart needs the four stops of an accent ramp as a LIST, not as
--- four highlight groups it has to guess the names of -- while applying groups
--- is a one-shot side effect that happens on `ColorScheme`.
---
--- Nothing here is hardcoded. Volt already solves palette sourcing: it reads
--- base46's compiled palette when NvChad is installed and synthesises the same
--- roles from `Normal`/`Comment`/`added`/`removed`/`Function` otherwise. We
--- build on that, so paseo follows whatever theme is loaded without depending
--- on any particular one.
---
--- Two structures come out of it:
---
---   * the ELEVATION ladder -- five backgrounds stepped off `Normal`, which is
---     what gives the dashboard depth. Surfaces are separated by elevation and
---     padding rather than by drawn boxes, which is the whole point of the
---     redesign: a frame around every card reads as noise, a sheet raised off
---     its background reads as design.
---   * the ACCENT ramps -- four stops per accent, blended towards the
---     background. Four stops rather than an on/off pair is what makes faint
---     dividers, tinted tiles, heat scales and fades possible at all.
---
--- Both flip direction on a light theme, and both collapse to nothing on a
--- transparent one, where painting an opaque rectangle over someone's
--- wallpaper is worse than having no card.

local api = vim.api

local M = {}

---@class paseo.Theme.Palette
---@field red string|nil
---@field green string|nil
---@field blue string|nil
---@field yellow string|nil
---@field grey string|nil
---@field border string|nil
---@field text string|nil
---@field bg string|nil

---@param value integer|nil
---@return string|nil
local function hex(value)
  return value and ("#%06x"):format(value) or nil
end

---Resolve a group's foreground, following links.
---@param name string
---@return string|nil
local function fg_of(name)
  local ok, group = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hex(group.fg) or nil
end

---@param name string
---@return string|nil
local function bg_of(name)
  local ok, group = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hex(group.bg) or nil
end

---Blend two colours, or give up gracefully.
---
---Wrapped because `volt.color` is only present when volt is, and because `mix`
---returns its first argument unchanged when either input will not parse as hex
----- which is what a `nil` background looks like.
---@param accent string|nil
---@param onto string|nil
---@param strength integer  0-100, percent of `onto` in the result.
---@return string|nil
function M.blend(accent, onto, strength)
  if not (accent and onto) then
    return nil
  end
  local ok, color = pcall(require, "volt.color")
  if not ok then
    return nil
  end
  return color.mix(accent, onto, strength)
end

---Move a colour towards white (positive) or black (negative).
---@param base string|nil
---@param amount number  Absolute lightness points, 0-100.
---@return string|nil
function M.shift(base, amount)
  if not base then
    return nil
  end
  local ok, color = pcall(require, "volt.color")
  if not ok then
    return nil
  end
  return color.change_hex_lightness(base, amount)
end

---The contrast ratio an accent must clear against the surface it is drawn on.
---
---Below WCAG's 4.5 for body text, deliberately. These are short, bold labels
---on a tinted plate rather than paragraphs, and holding out for 4.5 on a
---low-contrast theme means walking the accent so far it stops being the
---accent -- which loses more information than the contrast gains.
M.MIN_CONTRAST = 3.2

---Relative luminance, per WCAG 2.
---@param hex_colour string
---@return number
local function luminance(hex_colour)
  local channels = {}
  for i = 0, 2 do
    local byte = tonumber(hex_colour:sub(2 + i * 2, 3 + i * 2), 16) or 0
    local channel = byte / 255
    channels[i + 1] = channel <= 0.03928 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * channels[1] + 0.7152 * channels[2] + 0.0722 * channels[3]
end

---Contrast ratio between two colours, 1 (identical) to 21 (black on white).
---@param a string|nil
---@param b string|nil
---@return number
function M.contrast(a, b)
  if not (a and b) then
    return 21
  end
  local la, lb = luminance(a), luminance(b)
  local lighter, darker = math.max(la, lb), math.min(la, lb)
  return (lighter + 0.05) / (darker + 0.05)
end

---Walk `fg` away from `bg` until it is legible on it.
---
---BOTH directions are tried and the better result wins, rather than picking
---one from whichever of the two is lighter. That heuristic looks obvious and
---is wrong: `morning`'s "added" is #90ee90, marginally lighter than the plate
---it sits on, so "keep going lighter" walks it into the white ceiling at a
---contrast ratio of 1.4 -- less legible than where it started. Darkening the
---same colour clears the target in four steps.
---
---A colour that already clears the target is returned untouched, so a theme
---that had its accents right keeps them exactly.
---@param fg string|nil
---@param bg string|nil
---@param target number
---@return string|nil
function M.readable(fg, bg, target)
  if not (fg and bg) then
    return fg
  end
  if M.contrast(fg, bg) >= target then
    return fg
  end

  local best, best_ratio = fg, M.contrast(fg, bg)

  for _, direction in ipairs { -1, 1 } do
    local candidate = fg
    -- Bounded: 25 steps of 4 points covers the full lightness range, so a
    -- pathological theme costs a fixed number of conversions rather than
    -- looping.
    for _ = 1, 25 do
      local stepped = M.shift(candidate, 4 * direction)
      if not stepped or stepped == candidate then
        break
      end
      candidate = stepped

      local ratio = M.contrast(candidate, bg)
      if ratio > best_ratio then
        best, best_ratio = candidate, ratio
      end
      if ratio >= target then
        break
      end
    end
    -- One direction already cleared it; the other cannot do better by enough
    -- to be worth moving the hue further than necessary.
    if best_ratio >= target then
      break
    end
  end

  return best
end

---Volt's palette, or a usable stand-in.
---
---`require "volt.highlights"` is a SIDE-EFFECTING module: requiring it defines
---the Ex* groups. It is pcall'd so this file still loads in a headless test
---where volt is not on the runtimepath -- the fallbacks below are ordinary
---Neovim groups that always exist.
---@return paseo.Theme.Palette
function M.palette()
  pcall(require, "volt.highlights")

  -- `Normal` first, not `NormalFloat`. The dashboard covers most of the screen
  -- and REPLACES its windows' `Normal` with `PaseoNormal`, so the colour it has
  -- to be a step away from is the editor's, not the popup background some
  -- themes make markedly greyer -- `morning` links `NormalFloat` to `Pmenu` at
  -- #b2b2b2 against a #e4e4e4 editor, and deriving from that put a grey slab
  -- over a white screen.
  local bg = bg_of "Normal" or bg_of "NormalFloat"
  local text = fg_of "Normal"

  -- volt's `Ex*` groups are only trustworthy when base46 is: its OTHER path
  -- writes `ExBlue = { fg = get_hl "Function" }`, and `volt.utils.get_hl`
  -- returns a TABLE -- `{ fg = "#87afaf" }` -- not a colour, so every accent on
  -- that path resolves to #000000. Black is not obviously wrong on a dark
  -- theme, which is why it went unnoticed; it is simply invisible.
  --
  -- So the fallback is ours rather than volt's, and it reads the same
  -- SEMANTIC groups volt meant to read. That is the whole difference between
  -- the two chains: with base46 we take a palette someone chose, and without
  -- it we take the groups every colourscheme has to define anyway.
  local themed = vim.g.base46_cache ~= nil

  local function pick(volt_group, ...)
    if themed then
      local found = fg_of(volt_group)
      if found then
        return found
      end
    end
    for _, fallback in ipairs { ... } do
      local found = fg_of(fallback)
      if found then
        return found
      end
    end
    return nil
  end

  -- `Added`/`Removed`/`Changed` before `String`/`ErrorMsg`/`WarningMsg`: the
  -- diff groups mean what we mean, and the syntax groups only happen to. On
  -- `morning`, `String` is MAGENTA -- so a tool that succeeded was drawn in the
  -- same colour a string literal is, which is not a shade of "it worked".
  local grey = pick("CommentFg", "Comment", "NonText")

  return {
    red = pick("ExRed", "DiagnosticError", "Removed", "diffRemoved", "ErrorMsg"),
    green = pick("ExGreen", "DiagnosticOk", "Added", "diffAdded", "String"),
    blue = pick("ExBlue", "Function", "Identifier", "Directory"),
    yellow = pick("ExYellow", "DiagnosticWarn", "Changed", "diffChanged", "WarningMsg"),
    -- Dim has to be DIMMER than body text, and on some themes it is not.
    -- Two different ways of being too loud, so two corrections: a saturated
    -- `Comment` is replaced with a neutral derived from the body text, and
    -- whatever survives that is then pulled towards the background until it
    -- actually recedes.
    grey = M.dimmer(
      M.saturation(grey) > M.MAX_CHROME_SATURATION and (M.blend(text, bg, 45) or grey) or grey,
      text,
      bg
    ),
    border = pick("ExLightGrey", "LineNr", "Comment"),
    text = text,
    bg = bg,
  }
end

---How saturated a colour is, 0 (grey) to 1.
---@param hex_colour string|nil
---@return number
function M.saturation(hex_colour)
  if not hex_colour then
    return 0
  end
  local ok, color = pcall(require, "volt.color")
  if not ok then
    return 0
  end
  local _, saturation = color.hex2hsl(hex_colour)
  return saturation or 0
end

---Above this, a colour is a SYNTAX choice rather than a chrome colour.
---
---`morning` sets `Comment` to pure blue and `desert` to cyan. Both are quiet
---enough by luminance -- they pass a contrast test against the background
---perfectly well -- and both are far louder than the body text they are
---supposed to sit behind, because saturation pulls the eye in a way lightness
---does not. Chrome that shouts is chrome you read first.
M.MAX_CHROME_SATURATION = 0.45

---Pull `colour` towards the background until it is no louder than `text`.
---
---"Dim" is a relationship, not a colour: whatever the theme says, the label
---has to recede behind the thing it labels. A colour that already does is
---returned untouched.
---@param colour string|nil
---@param text string|nil
---@param bg string|nil
---@return string|nil
function M.dimmer(colour, text, bg)
  if not (colour and text and bg) then
    return colour
  end

  local ceiling = M.contrast(text, bg) * 0.75
  local candidate = colour

  for _ = 1, 20 do
    if M.contrast(candidate, bg) <= ceiling then
      return candidate
    end
    -- Towards the background, whichever way that is.
    local stepped = M.blend(candidate, bg, 12)
    if not stepped or stepped == candidate then
      break
    end
    candidate = stepped
  end

  return candidate
end

---The accents that get a full ramp. Order is fixed so a chart asking for "the
---nth series" gets the same colour across redraws.
M.ACCENTS = { "red", "green", "blue", "yellow" }

---How far each ramp stop is blended towards the background, in percent.
---
---Deliberately NOT an even 20/40/60/80. An even ramp reads as four steps of
---nothing much; loading the gap at the faint end is what makes stop 0 look
---like the accent and stop 3 look like a hint of it. These are the stops typr
---uses, and they were arrived at the same way -- by looking at them.
M.RAMP = { 10, 40, 60, 80 }

---How far each elevation tier is stepped off `Normal`'s background, in
---absolute lightness points.
---
---Five tiers: the editor itself, the sheet the surface is, the card raised off
---that sheet, a chip raised off the card, and the selected state. The steps
---widen as they go up because the eye reads the difference between two dark
---greys less readily than between two light ones.
M.ELEVATION = { bg0 = 0, bg1 = 2, bg2 = 5, bg3 = 8, bg4 = 11 }

---@class paseo.Theme
---@field palette paseo.Theme.Palette
---@field opaque boolean   The theme has a background to build tiers on.
---@field sign integer     +1 on a dark theme, -1 on a light one.
---@field bg table<string, string|nil>          Elevation ladder, bg0..bg4.
---@field ramp table<string, string[]>          Accent name -> four stops.
---@field ink fun(accent: string|nil): string|nil

---Derive the whole token set from the current colourscheme.
---@return paseo.Theme
function M.derive()
  local c = M.palette()

  -- A light theme has to DARKEN where a dark theme lightens, or every "raised"
  -- surface comes out washed into the background. One sign, applied to every
  -- lightness step -- the same trick `volt/highlights.lua` uses.
  local sign = vim.o.bg == "dark" and 1 or -1
  local opaque = c.bg ~= nil

  local bg = {}
  for name, step in pairs(M.ELEVATION) do
    bg[name] = opaque and (M.shift(c.bg, step * sign) or c.bg) or nil
  end

  -- An accent used as TEXT has to be legible on the plate it sits on, and
  -- whether it already is depends entirely on the theme. `morning`'s "added"
  -- is #90ee90 -- unreadable on a plate tinted with that same pale green --
  -- while `default`'s is #166336, which is already dark enough that pushing it
  -- further lands on black and throws the hue away.
  --
  -- So this measures rather than assumes: push the accent away from the
  -- surface it will be drawn on, a step at a time, and stop as soon as it is
  -- readable. A theme whose accent is already fine is left alone.
  local function ink(accent, onto)
    if not accent then
      return nil
    end
    return M.readable(accent, onto or bg.bg2 or c.bg, M.MIN_CONTRAST)
  end

  -- The ramp blends towards the EDITOR's background rather than towards the
  -- card's. A ramp that tracked whichever tier it happened to be drawn on
  -- would shift under a chart the moment the chart moved from the surface to
  -- a card, and "the same value is the same colour" is the only reason a heat
  -- scale means anything.
  local ramp = {}
  for _, name in ipairs(M.ACCENTS) do
    local stops = {}
    for i, strength in ipairs(M.RAMP) do
      -- Without a background to blend towards there is nothing to ramp: every
      -- stop collapses to the accent itself, which is the correct degradation
      -- -- a transparent theme gets flat accents rather than mud.
      stops[i] = M.blend(c[name], c.bg, strength) or c[name]
    end
    ramp[name] = stops
  end

  return { palette = c, opaque = opaque, sign = sign, bg = bg, ramp = ramp, ink = ink }
end

---Every `Paseo*` group, as a plain table. Applying it is `ui/hl.lua`'s job.
---@param t? paseo.Theme  Derived fresh when omitted.
---@return table<string, vim.api.keyset.highlight>
function M.groups(t)
  t = t or M.derive()
  local c, ink, bg, ramp = t.palette, t.ink, t.bg, t.ramp

  -- An accent drawn as plain text sits on the SURFACE, not on a card, and it
  -- has to be legible there. `morning`'s DiagnosticOk is #90ee90 -- a pale
  -- green that all but disappears on a light editor -- so the hue comes from
  -- the theme and the lightness is corrected here. A theme whose accents are
  -- already legible keeps them exactly.
  local function on_surface(accent)
    return ink(accent, bg.bg1 or c.bg)
  end

  local groups = {
    -- Roles. The two labels that separate who said what.
    PaseoYou = { fg = on_surface(c.blue), bold = true },
    PaseoAgent = { fg = on_surface(c.green), bold = true },

    -- Reasoning. Deliberately quiet: it is context, not the answer.
    PaseoThinking = { fg = c.grey, italic = true },

    -- Tool cards.
    PaseoToolName = { fg = on_surface(c.blue), bold = true },
    PaseoToolRunning = { fg = on_surface(c.yellow) },
    PaseoToolOk = { fg = on_surface(c.green) },
    PaseoToolFail = { fg = on_surface(c.red) },
    PaseoToolArg = { fg = c.grey },

    -- Chrome.
    PaseoBorder = { fg = c.border },
    PaseoDim = { fg = c.grey },
    PaseoHeader = { fg = on_surface(c.blue), bold = true },
    PaseoKey = { fg = on_surface(c.yellow), bold = true },
    PaseoPath = { fg = on_surface(c.blue), underline = false },

    -- The permission dialog. Danger is the one place a background is used, so
    -- "run this shell command" cannot be mistaken for "read this file".
    PaseoDanger = { fg = on_surface(c.red), bold = true },
    PaseoBadge = { fg = on_surface(c.yellow), bold = true },
    -- A question shares the dialog but not the alarm: the agent is asking,
    -- not reaching for the filesystem.
    PaseoQuestion = { fg = on_surface(c.blue), bold = true },

    -- Expanded diffs inside an edit card.
    PaseoAdd = { fg = on_surface(c.green) },
    PaseoDel = { fg = on_surface(c.red) },

    -- The text ramp. Three weights, and the faint one is what every divider
    -- and disabled row is drawn in -- a rule at content weight is the single
    -- commonest way a terminal UI ends up looking busy.
    PaseoText = { fg = c.text },
    PaseoTextDim = { fg = c.grey },
    PaseoTextFaint = { fg = M.blend(c.grey, c.bg, 50) or c.border },

    -- The empty half of a bar. Derived from the BACKGROUND rather than from
    -- the comment colour, because a track is the absence of fill and has to
    -- read as such -- on `morning`, a comment-derived track came out pale blue
    -- and the bar looked full at 42%.
    PaseoTrack = { fg = bg.bg4 or M.blend(c.grey, c.bg, 70) or c.border },
  }

  -- The accent ramps, as groups, so a `lines()` closure can name a stop
  -- without reaching for the token table: PaseoGreen0 is nearly the accent,
  -- PaseoGreen3 is nearly the background.
  for _, name in ipairs(M.ACCENTS) do
    local capitalised = name:sub(1, 1):upper() .. name:sub(2)
    for i = 1, #M.RAMP do
      groups["Paseo" .. capitalised .. (i - 1)] = { fg = ramp[name][i] }
    end
  end

  if t.opaque then
    groups.PaseoNormal = { bg = bg.bg1 }
    -- fg == bg is the whole trick: `nvim_open_win`'s border glyphs render as
    -- solid colour, so the border becomes a one-cell padding ring in the
    -- surface's own colour instead of a drawn box.
    groups.PaseoNormalBorder = { fg = bg.bg1, bg = bg.bg1 }

    groups.PaseoCard = { bg = bg.bg2 }
    groups.PaseoCardBorder = { fg = bg.bg2, bg = bg.bg2 }
    groups.PaseoCardRule = { fg = M.blend(c.border, bg.bg2, 45) or c.border, bg = bg.bg2 }
    groups.PaseoCardTitle = { fg = ink(c.blue, bg.bg2), bg = bg.bg2, bold = true }
    groups.PaseoCardDim = { fg = c.grey, bg = bg.bg2 }
    groups.PaseoCardText = { bg = bg.bg2 }

    -- The hovered/selected row. One tier above the card, no accent: an accent
    -- here would compete with whatever the row itself is saying.
    groups.PaseoRowHover = { bg = bg.bg3 }
    groups.PaseoRowActive = { bg = bg.bg4 }

    -- Chips and plates. `mix(accent, bg, N)` is mostly background with a hint
    -- of the accent; the accent itself goes on top as the foreground, pushed
    -- until it is legible against THAT plate rather than against the card --
    -- a tinted plate is a different colour from the card it sits on, and
    -- measuring contrast against the wrong one is how a chip ends up readable
    -- in theory and invisible in practice.
    local function plate(accent, onto, strength, extra)
      local fill = M.blend(accent, onto, strength)
      return vim.tbl_extend(
        "force",
        { fg = ink(accent, fill or onto), bg = fill, bold = true },
        extra or {}
      )
    end

    groups.PaseoChipOff = { fg = c.grey, bg = bg.bg3 }
    groups.PaseoChipOn = plate(c.green, bg.bg2, 82)
    groups.PaseoChipFocus = plate(c.blue, bg.bg2, 72)
    groups.PaseoChipWarn = plate(c.yellow, bg.bg2, 80)
    groups.PaseoChipDanger = plate(c.red, bg.bg2, 78)

    groups.PaseoKeycap = plate(c.blue, bg.bg1, 76)
    groups.PaseoKeycapDim = { fg = c.grey, bg = bg.bg1 }

    -- Accent tiles: the same shape at card elevation. This is the badge/KPI
    -- look, and it is the one thing that reads as a solid object rather than
    -- as coloured text.
    for _, name in ipairs(M.ACCENTS) do
      local capitalised = name:sub(1, 1):upper() .. name:sub(2)
      groups["Paseo" .. capitalised .. "Tile"] = plate(c[name], bg.bg2, 82)
    end
  else
    -- Transparent theme. Every group above still has to EXIST -- the widgets
    -- name them unconditionally -- so they become foreground-only, and the
    -- card degrades to a drawn rule. Selection is then signalled by removing
    -- dimming rather than by adding a background, which is exactly what typr
    -- does on the same constraint.
    groups.PaseoNormal = {}
    groups.PaseoNormalBorder = { fg = c.border }
    groups.PaseoCard = {}
    groups.PaseoCardBorder = { fg = c.border }
    groups.PaseoCardRule = { fg = c.border }
    groups.PaseoCardTitle = { fg = c.blue, bold = true }
    groups.PaseoCardDim = { fg = c.grey }
    groups.PaseoCardText = {}

    groups.PaseoRowHover = { bold = true }
    groups.PaseoRowActive = { reverse = true }

    groups.PaseoChipOff = { fg = c.grey }
    groups.PaseoChipOn = { fg = c.green, bold = true }
    groups.PaseoChipFocus = { fg = c.blue, bold = true, reverse = true }
    groups.PaseoChipWarn = { fg = c.yellow, bold = true }
    groups.PaseoChipDanger = { fg = c.red, bold = true }

    groups.PaseoKeycap = { fg = c.blue, bold = true }
    groups.PaseoKeycapDim = { fg = c.grey }

    for _, name in ipairs(M.ACCENTS) do
      local capitalised = name:sub(1, 1):upper() .. name:sub(2)
      groups["Paseo" .. capitalised .. "Tile"] = { fg = c[name], bold = true }
    end
  end

  return groups
end

return M
