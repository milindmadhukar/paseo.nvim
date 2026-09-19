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
    bg = bg_of "Normal",
  }
end

---Define every `Paseo*` group. Idempotent, and re-run on `ColorScheme`.
function M.setup()
  local c = palette()

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
