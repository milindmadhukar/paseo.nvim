--- Buffer-local mappings that give back what they displaced.
---
--- A panel's buffer is not the panel's alone: whatever it is shown in binds
--- keys on it too -- the native surface's `q`, `1` `2` `3`, `<C-p>` and `r`,
--- the popup's own `q`. So a panel that binds a key and then deletes it on
--- the way out can take somebody else's with it, and the panel does not know
--- that; it only knows it bound a key. (The old dashboard's panels shared one
--- buffer whose `<CR>` volt owned, which is where this bit first: one panel's
--- release killed `<CR>` on all the others.)
---
--- Hence: save what is displaced, restore it on release. Only a BUFFER-LOCAL
--- mapping is ours to displace -- a global one is not overwritten, it is
--- shadowed, and comes back by itself.

local api = vim.api

local M = {}

---Bind `mappings` on `buf`, remembering whatever they displace.
---@param buf integer
---@param mappings table[]  `{ { lhs, rhs, desc? }, … }`
---@param desc? string  Default description.
---@return table[]|nil saved  Hand this back to `M.release`.
function M.take(buf, mappings, desc)
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end

  local saved = {}
  for _, mapping in ipairs(mappings) do
    -- `maparg` reads the CURRENT buffer, not `buf`, and nothing promises the
    -- two are the same at attach time. The old dashboard attached a panel
    -- while the cursor was still in the composer, whose `<CR>` sends the
    -- prompt -- and a lookup from there restored *send the prompt* onto the
    -- panel's buffer.
    local existing
    api.nvim_buf_call(buf, function()
      existing = vim.fn.maparg(mapping[1], "n", false, true)
    end)
    saved[#saved + 1] = {
      lhs = mapping[1],
      prev = (type(existing) == "table" and existing.buffer == 1) and existing or nil,
    }
    vim.keymap.set("n", mapping[1], mapping[2], {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = mapping[3] or desc or "paseo",
    })
  end
  return saved
end

---Give the buffer its keys back.
---@param buf integer
---@param saved table[]|nil
function M.release(buf, saved)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  for _, mapping in ipairs(saved or {}) do
    pcall(vim.keymap.del, "n", mapping.lhs, { buffer = buf })
    if mapping.prev then
      -- `mapset` restores a buffer-local mapping to the CURRENT buffer, so it
      -- has to run with the right one current -- otherwise the displaced key
      -- comes back attached to whatever you happened to be looking at.
      pcall(api.nvim_buf_call, buf, function()
        vim.fn.mapset("n", false, mapping.prev)
      end)
    end
  end
end

-- ------------------------------------------------------------ configured

---Every lhs a key option names: a string is one, a list is several, `false`
---(or nil) is none -- the "leave it unbound" every key option accepts.
---@param spec string|string[]|false|nil
---@return string[]
function M.list(spec)
  if type(spec) == "string" then
    return spec ~= "" and { spec } or {}
  end
  if type(spec) == "table" then
    local out = {}
    for _, lhs in ipairs(spec) do
      if type(lhs) == "string" and lhs ~= "" then
        out[#out + 1] = lhs
      end
    end
    return out
  end
  return {}
end

---What a built-in key is bound as in `scope`, after your `keys.<scope>`
---remaps (|paseo-config.keys|): keyed by the DEFAULT key, so `["d"] = false`
---unbinds it, `["d"] = "x"` moves it, `["d"] = { "d", "x" }` adds one.
---@param scope string  "conversation"|"composer"|"rail"|"panel"|…
---@param lhs string|string[]|false|nil  The default, or a list of them.
---@return string[]
function M.resolve(scope, lhs)
  local remaps = (require("paseo.config").get().keys or {})[scope] or {}
  local out, seen = {}, {}
  for _, default in ipairs(M.list(lhs)) do
    local remap = remaps[default]
    local lhss = remap == nil and { default } or M.list(remap)
    for _, key in ipairs(lhss) do
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = key
      end
    end
  end
  return out
end

---`vim.keymap.set` for a built-in key, through `resolve`: nothing if it was
---unbound, every lhs if it was remapped to several.
---@param scope string
---@param mode string|string[]
---@param lhs string|string[]|false|nil
---@param rhs string|function
---@param opts? table
---@return string[] bound
function M.set(scope, mode, lhs, rhs, opts)
  local bound = M.resolve(scope, lhs)
  for _, key in ipairs(bound) do
    vim.keymap.set(mode, key, rhs, opts)
  end
  return bound
end

---The key to SHOW for a built-in one in a hint: the first it is bound as, or
---nil when it is unbound -- in which case the hint should go, not lie.
---@param scope string|nil  nil: `lhs` is already a configured key option.
---@param lhs string|string[]|false|nil
---@return string|nil
function M.label(scope, lhs)
  local keys = scope and M.resolve(scope, lhs) or M.list(lhs)
  return keys[1]
end

---A key YOU mapped, globally, to `rhs` (a `<Plug>` name or a command line
---such as `<cmd>Paseo native<cr>`): what a hint can show for an action the
---plugin deliberately leaves unmapped. Case and `<cr>` spelling ignored.
---@param rhs string|string[]
---@param mode? string
---@return string|nil
function M.user_key(rhs, mode)
  local wants = {}
  for _, want in ipairs(type(rhs) == "table" and rhs or { rhs }) do
    wants[#wants + 1] = want:lower():gsub("%s+", " ")
  end
  for _, map in ipairs(api.nvim_get_keymap(mode or "n")) do
    local got = (map.rhs or ""):lower():gsub("%s+", " ")
    for _, want in ipairs(wants) do
      if got == want or got == want .. "<cr>" or got:gsub("<cr>$", "") == want:gsub("<cr>$", "") then
        return (map.lhs:gsub("^ ", "<Space>"))
      end
    end
  end
  return nil
end

return M
