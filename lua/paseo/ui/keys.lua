--- Buffer-local mappings that give back what they displaced.
---
--- The dashboard's panels SHARE one chrome buffer, and volt binds `<CR>` on it
--- at open -- that is how every panel's rows are activated from the keyboard.
--- So a panel that binds `<CR>` and then deletes it on the way out takes
--- volt's with it, and `<CR>` is dead on all five of the others for the rest of
--- the session. The panel does not know that; it only knows it bound a key.
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
    -- `maparg` reads the CURRENT buffer, not `buf`, and at attach time the
    -- current buffer is usually not the chrome -- `float.select` focuses the
    -- chrome window only after the panel is attached, so the cursor is still
    -- in the composer, whose `<CR>` sends the prompt. Looking it up from the
    -- wrong buffer would restore *send the prompt* onto the chrome buffer.
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
      -- has to run with the right one current -- otherwise volt's `<CR>` comes
      -- back attached to whatever you happened to be looking at.
      pcall(api.nvim_buf_call, buf, function()
        vim.fn.mapset("n", false, mapping.prev)
      end)
    end
  end
end

return M
