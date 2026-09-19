--- The plugin's highlight groups.
---
--- Until now there were none: the chat was a `filetype=markdown` buffer and
--- every colour came from the user's treesitter. That is why `local ns =
--- vim.api.nvim_create_namespace "paseo.chat"` sat unused in `ui/chat.lua` --
--- it was a stub for this file.
---
--- Colours are DERIVED, never hardcoded. Volt already solves this: it reads
--- base46's palette when NvChad is installed and falls back to Normal/Comment
--- otherwise, exposing `ExRed`/`ExGreen`/`ExBlue`/`ExYellow`/`CommentFg`. We
--- build on those so the chat matches whatever theme is loaded, the same way
--- `typr/ui/hl.lua` does.
---
--- There are TWO families here and the split matters:
---
---   * foreground-only groups -- the transcript, the timeline, the permission
---     dialog. These draw on top of whatever background the window has.
---   * background groups -- `PaseoNormal`, `PaseoCard`, the chips. These are
---     what gives the dashboard depth, and they are the reason the surface
---     stopped looking like coloured text on a flat float. They are DERIVED
---     from `Normal`'s background by lightness steps, exactly as
---     `volt/highlights.lua` derives its own tiers, and they are SKIPPED
---     ENTIRELY on a transparent theme -- painting an opaque rectangle over
---     someone's wallpaper is worse than having no card at all.

local api = vim.api

local M = {}

---Colour for the transcript. The transcript is REAL buffer lines -- so `y`, `/`
---and soft-wrap keep working -- and these extmarks carry its highlighting.
M.ns = api.nvim_create_namespace "paseo.chat"

---Anchors marking where each rendered block STARTS.
---
---Deliberately a second namespace. Re-rendering a tool card when it finishes
---means clearing that block's highlights first, and
---`nvim_buf_clear_namespace` is per-namespace over a row range -- so sharing
---one namespace would delete the very anchor being used to find the block.
---
---Anchors also survive text inserted above them: `nvim_buf_set_lines` shifts
---extmarks, which is why a card can be replaced by id rather than by a line
---number that went stale three messages ago.
M.ns_anchor = api.nvim_create_namespace "paseo.chat.anchor"

---True when the surface has real card backgrounds to sit on.
---
---Read by the widgets: a card with no background is drawn as a plain rule
---instead of a filled rectangle, because an unfilled box on a transparent
---theme is just noise.
M.opaque = false

---@param value integer|nil
---@return string|nil
local function hex(value)
  return value and ("#%06x"):format(value) or nil
end

---Resolve a group's foreground, following links.
---@param name string
---@return string|nil
local function fg_of(name)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hex(hl.fg) or nil
end

---@param name string
---@return string|nil
local function bg_of(name)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hex(hl.bg) or nil
end

---Volt's palette, or a usable stand-in.
---
---`require "volt.highlights"` is a SIDE-EFFECTING module: requiring it defines
---the Ex* groups. It is pcall'd so this file still loads in a headless test
---where volt is not on the runtimepath -- the fallbacks below are ordinary
---Neovim groups that always exist.
---@return table<string, string|nil>
local function palette()
  pcall(require, "volt.highlights")

  local function pick(volt_group, ...)
    local found = fg_of(volt_group)
    if found then
      return found
    end
    for _, fallback in ipairs { ... } do
      found = fg_of(fallback)
      if found then
        return found
      end
    end
    return nil
  end

  return {
    red = pick("ExRed", "DiagnosticError", "ErrorMsg"),
    green = pick("ExGreen", "DiagnosticOk", "String"),
    blue = pick("ExBlue", "Function", "Identifier"),
    yellow = pick("ExYellow", "DiagnosticWarn", "WarningMsg"),
    grey = pick("CommentFg", "Comment", "NonText"),
    border = pick("ExLightGrey", "LineNr", "Comment"),
    -- `Normal` first, not `NormalFloat`. The dashboard covers most of the
    -- screen and REPLACES its windows' `Normal` with `PaseoNormal`, so the
    -- colour it has to be a step away from is the editor's, not the popup
    -- background some themes make markedly greyer -- `morning` links
    -- `NormalFloat` to `Pmenu` at #b2b2b2 against a #e4e4e4 editor, and
    -- deriving from that put a grey slab over a white screen.
    bg = bg_of "Normal" or bg_of "NormalFloat",
  }
end

---Blend two colours, or give up gracefully.
---
---Wrapped because `volt.color` is only present when volt is, and because
---`mix` returns its first argument unchanged when either input will not parse
---as hex -- which is what a `nil` background looks like.
---@param accent string|nil
---@param onto string|nil
---@param strength integer  0-100, percent of `onto` in the result.
---@return string|nil
local function blend(accent, onto, strength)
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
local function shift(base, amount)
  if not base then
    return nil
  end
  local ok, color = pcall(require, "volt.color")
  if not ok then
    return nil
  end
  return color.change_hex_lightness(base, amount)
end

---Define every `Paseo*` group. Idempotent, and re-run on `ColorScheme`.
function M.setup()
  local c = palette()

  -- A light theme has to DARKEN where a dark theme lightens, or every "raised"
  -- surface comes out washed into the background. One sign, applied to every
  -- lightness step below -- the same trick `volt/highlights.lua` uses.
  local x = vim.o.bg == "dark" and 1 or -1

  -- `default = false`: a colourscheme that ships its own Paseo* groups is rare,
  -- but a user overriding one in their config should win, and they do that
  -- after setup() by simply setting the group again.
  local groups = {
    -- Roles. The two labels that separate who said what.
    PaseoYou = { fg = c.blue, bold = true },
    PaseoAgent = { fg = c.green, bold = true },

    -- Reasoning. Deliberately quiet: it is context, not the answer.
    PaseoThinking = { fg = c.grey, italic = true },

    -- Tool cards.
    PaseoToolName = { fg = c.blue, bold = true },
    PaseoToolRunning = { fg = c.yellow },
    PaseoToolOk = { fg = c.green },
    PaseoToolFail = { fg = c.red },
    PaseoToolArg = { fg = c.grey },

    -- Chrome.
    PaseoBorder = { fg = c.border },
    PaseoDim = { fg = c.grey },
    PaseoHeader = { fg = c.blue, bold = true },
    PaseoKey = { fg = c.yellow, bold = true },
    PaseoPath = { fg = c.blue, underline = false },

    -- The permission dialog. Danger is the one place a background is used, so
    -- "run this shell command" cannot be mistaken for "read this file".
    PaseoDanger = { fg = c.red, bold = true },
    PaseoBadge = { fg = c.yellow, bold = true },
    -- A question shares the dialog but not the alarm: the agent is asking,
    -- not reaching for the filesystem.
    PaseoQuestion = { fg = c.blue, bold = true },

    -- Expanded diffs inside an edit card.
    PaseoAdd = { fg = c.green },
    PaseoDel = { fg = c.red },
  }

  M.opaque = c.bg ~= nil

  if M.opaque then
    -- Two tiers, two steps apart. The surface sits just off `Normal` so the
    -- dashboard reads as a sheet laid on the editor; a card sits a further
    -- step up so it reads as raised off the sheet. More tiers than this and
    -- the steps stop being distinguishable on low-contrast themes.
    local surface = shift(c.bg, 2 * x) or c.bg
    local card = shift(c.bg, 7 * x) or c.bg

    -- On a LIGHT theme the accents themselves are often pale -- `morning`'s
    -- "added" is #90ee90 -- and a pale foreground on a chip tinted with that
    -- same pale colour is unreadable. Push the accent away from the
    -- background before using it as text; on a dark theme it is already
    -- pushed the right way and is left alone.
    local function ink(accent)
      return x < 0 and (shift(accent, -22) or accent) or accent
    end

    groups.PaseoNormal = { bg = surface }
    -- fg == bg is the whole trick: `nvim_open_win`'s border glyphs render as
    -- solid colour, so the border becomes a one-cell padding ring in the
    -- surface's own colour instead of a drawn box.
    groups.PaseoNormalBorder = { fg = surface, bg = surface }

    groups.PaseoCard = { bg = card }
    groups.PaseoCardBorder = { fg = card, bg = card }
    groups.PaseoCardRule = { fg = c.border, bg = card }
    groups.PaseoCardTitle = { fg = ink(c.blue), bg = card, bold = true }
    groups.PaseoCardDim = { fg = c.grey, bg = card }
    groups.PaseoCardText = { bg = card }

    -- Chips. `mix(accent, bg, N)` is mostly background with a hint of the
    -- accent, and the pure accent as the foreground on top -- legible on any
    -- theme, which a raw accent background is not.
    groups.PaseoChipOff = { fg = c.grey, bg = shift(card, 4 * x) or card }
    groups.PaseoChipOn = { fg = ink(c.green), bg = blend(c.green, card, 82), bold = true }
    groups.PaseoChipFocus = { fg = ink(c.blue), bg = blend(c.blue, card, 72), bold = true }
    groups.PaseoChipWarn = { fg = ink(c.yellow), bg = blend(c.yellow, card, 80), bold = true }
    groups.PaseoChipDanger = { fg = ink(c.red), bg = blend(c.red, card, 78), bold = true }

    groups.PaseoKeycap = { fg = ink(c.blue), bg = blend(c.blue, surface, 76), bold = true }
    groups.PaseoKeycapDim = { fg = c.grey, bg = surface }
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

    groups.PaseoChipOff = { fg = c.grey }
    groups.PaseoChipOn = { fg = c.green, bold = true }
    groups.PaseoChipFocus = { fg = c.blue, bold = true, reverse = true }
    groups.PaseoChipWarn = { fg = c.yellow, bold = true }
    groups.PaseoChipDanger = { fg = c.red, bold = true }

    groups.PaseoKeycap = { fg = c.blue, bold = true }
    groups.PaseoKeycapDim = { fg = c.grey }
  end

  for name, spec in pairs(groups) do
    api.nvim_set_hl(0, name, spec)
  end
end

---Re-derive on theme change, so the chat follows the colourscheme rather than
---freezing whatever was loaded at startup.
function M.attach()
  M.setup()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("PaseoHighlights", { clear = true }),
    callback = M.setup,
    desc = "paseo: re-derive highlight groups",
  })
end

return M
