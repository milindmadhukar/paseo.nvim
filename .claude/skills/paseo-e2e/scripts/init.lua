-- The e2e Neovim: THIS checkout's plugin, against the live daemon, with state
-- of its own, driven over --listen. Started by start.sh; never your config.
vim.opt.runtimepath:prepend(vim.env.PASEO_NVIM_TREE)
-- The probe module (lua/paseo/e2e_probe.lua) lives next to this file.
vim.opt.runtimepath:append(vim.env.E2E_SCRIPTS)
for _, dep in ipairs { "volt", "base46", "telescope.nvim", "plenary.nvim" } do
  local path = vim.fn.expand("~/.local/share/nvim/lazy/" .. dep)
  if vim.uv.fs_stat(path) then
    vim.opt.runtimepath:append(path)
  end
end
-- Remembered UI state (the rail toggle, ...) goes somewhere of its own, so
-- the harness cannot change how your own editor opens.
vim.env.XDG_STATE_HOME = vim.env.E2E_STATE
vim.opt.shada = ""
vim.opt.swapfile = false
vim.o.termguicolors = true
vim.cmd.colorscheme(vim.env.E2E_SCHEME or "habamax")
require("paseo").setup {}
-- Every notification to a file the driver reads: a held request announces
-- itself only this way.
local log = io.open(vim.env.E2E_LOG, "a")
local notify = vim.notify
vim.notify = function(msg, level, opts)
  log:write(("[%s] %s\n"):format(os.date "%H:%M:%S", tostring(msg)))
  log:flush()
  return notify(msg, level, opts)
end
