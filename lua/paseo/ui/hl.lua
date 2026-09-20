--- Applying the plugin's highlight groups, and the transcript's namespaces.
---
--- The colours themselves live in `ui/theme.lua`; this file is the side
--- effecting half -- it takes the derived table, lays the user's overrides on
--- top, and writes the result into namespace 0 on every `ColorScheme`.
---
--- The split is not tidiness. The widgets read tokens (the four stops of an
--- accent ramp, the five elevation tiers) as DATA, and a chart cannot do that
--- against a set of highlight groups without guessing at their names. Deriving
--- and applying are also different lifetimes: tokens are read on every redraw,
--- groups are written once per theme change.

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

---The live token set. Refreshed by `setup()`, read by the widgets.
---@type paseo.Theme|nil
M.theme = nil

---Define every `Paseo*` group. Idempotent, and re-run on `ColorScheme`.
function M.setup()
  local theme = require "paseo.ui.theme"

  M.theme = theme.derive()
  M.opaque = M.theme.opaque

  local groups = theme.groups(M.theme)

  -- The user's overrides go on LAST, and they are a config key rather than
  -- "set the group again after setup()" -- which is what the docs used to say
  -- and which quietly stopped working the moment anyone changed colourscheme,
  -- because this function re-runs on `ColorScheme` and overwrote them.
  local overrides = require("paseo.config").get().ui.theme
  if type(overrides) == "table" then
    for name, spec in pairs(overrides) do
      if type(spec) == "table" then
        groups[name] = vim.tbl_extend("force", groups[name] or {}, spec)
      end
    end
  end

  for name, spec in pairs(groups) do
    api.nvim_set_hl(0, name, spec)
  end
end

---The live token set, deriving it first if nothing has yet.
---@return paseo.Theme
function M.tokens()
  if not M.theme then
    M.setup()
  end
  return M.theme
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
