--- Choosing a setting, in whatever picker you already use.
---
--- Model, thinking level, provider and permission mode are long-ish lists you
--- want to TYPE at: "son" and `<CR>`, not five `l`s along a row of chips. Every
--- Neovim user has already picked the picker that does that, and tuned it --
--- snacks, telescope, fzf-lua, mini.pick -- and all of them answer to
--- `vim.ui.select`. So these choices go there.
---
--- When nothing has replaced `vim.ui.select`, the builtin is `inputlist`: a
--- numbered list at the bottom of the screen that cannot be searched. That is
--- worse than the plugin's own chooser, so this falls back to
--- |paseo.ui.choose| rather than to it.
---
--- Questions -- yes/no, where a fork goes, "change the model or fork?" -- stay
--- on |paseo.ui.choose|. They are not option lists, and a fuzzy finder over
--- two answers is a slower way to say yes.

local M = {}

---Has anything replaced the builtin `vim.ui.select`?
---
---Read every call rather than once: snacks and telescope's ui-select both
---install themselves lazily, often after this plugin has loaded.
---@return boolean
function M.overridden()
  local info = debug.getinfo(vim.ui.select, "S")
  local source = info and info.source or ""
  return not (source:find("vim/ui.lua", 1, true) or source:find("vim\\ui.lua", 1, true))
end

---`vim.ui.select`, or the Paseo chooser when `vim.ui.select` is the builtin.
---@param items any[]
---@param opts? { prompt?: string, format_item?: fun(item: any): string, kind?: string }
---@param on_choice fun(item: any|nil, index: integer|nil)
function M.select(items, opts, on_choice)
  if M.overridden() then
    return vim.ui.select(items, opts or {}, on_choice)
  end
  return require("paseo.ui.choose").select(items, opts, on_choice)
end

---The text one entry of a settings group is listed under.
---
---Plain text, because that is what every picker matches against. The current
---one is marked, and a dangerous mode says so IN THE TEXT: the chip colours
---that tell `bypassPermissions` from `plan` on the card do not survive the
---trip into somebody else's picker.
---@param group table  A group, as |paseo.ui.session|.groups shapes one.
---@param entry table
---@return string
function M.format(group, entry)
  local parts = { entry.id == group.current and "●" or " ", entry.label or entry.id }
  if entry.tone == "danger" then
    parts[#parts + 1] = "⚠"
  end
  if entry.note and entry.note ~= "" then
    parts[#parts + 1] = "· " .. entry.note
  end
  if entry.description and entry.description ~= "" then
    parts[#parts + 1] = "— " .. entry.description
  end
  return table.concat(parts, " ")
end

---Pick one entry of a settings group.
---
---The entry with the current value is listed FIRST: `vim.ui.select` has no
---"start on this one", and a picker opened on what is set lets `<CR>` mean
---"leave it".
---@param group table|nil
---@param on_entry fun(entry: table)  Not called on cancel, nor when nothing changed.
---@return boolean opened
function M.group(group, on_entry)
  if not group then
    return false
  end
  if #(group.entries or {}) == 0 then
    local why = group.placeholder or ("no " .. group.label:lower() .. " to choose from")
    vim.notify("paseo: " .. why, vim.log.levels.WARN)
    return false
  end

  local items = {}
  for _, entry in ipairs(group.entries) do
    if entry.id == group.current then
      table.insert(items, 1, entry)
    else
      items[#items + 1] = entry
    end
  end

  M.select(items, {
    prompt = group.label,
    kind = "paseo." .. group.id,
    format_item = function(entry)
      return M.format(group, entry)
    end,
  }, function(entry)
    if entry and entry.id ~= group.current then
      on_entry(entry)
    end
  end)
  return true
end

return M
