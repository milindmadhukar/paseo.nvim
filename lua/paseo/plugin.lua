--- Where this plugin's own files are.
---
--- Derived from THIS file's own path, not from the runtimepath. lazy.nvim
--- resolves a plugin's Lua modules through its own loader, so `require` works
--- long before the plugin directory is added to `rtp` -- and until it is,
--- `nvim_get_runtime_file(...)` returns nothing. The sidecar then "could not
--- start" on a plugin that was installed and working, which is the bug this
--- exists to have fixed once.
---
--- The runtimepath fallback is second for a second reason: it matches on a
--- FILENAME, so a stale copy of the plugin left on `rtp` answers for the one
--- you are running. `tests/run.sh` documents the same hazard -- "a suite that
--- passes while testing none of your changes".

local M = {}

---@return string|nil
function M.root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    -- @<root>/lua/paseo/plugin.lua -> <root>
    local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source:sub(2))))
    if root and vim.uv.fs_stat(root) then
      return root
    end
  end
  local found = vim.api.nvim_get_runtime_file("lua/paseo/plugin.lua", false)[1]
  return found and vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(found))) or nil
end

---A path inside the plugin, if it is actually there.
---@param ... string
---@return string|nil
function M.file(...)
  local root = M.root()
  if not root then
    return nil
  end
  local path = vim.fs.joinpath(root, ...)
  return vim.uv.fs_stat(path) and path or nil
end

return M
