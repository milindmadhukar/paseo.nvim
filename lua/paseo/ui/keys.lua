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

return M
