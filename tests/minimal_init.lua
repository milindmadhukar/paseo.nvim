--- The Neovim the suite runs in.
---
--- Started with `-u`, so none of your own configuration is loaded: the suite
--- tests this plugin against the plugins it declares, and nothing else. That
--- is also what makes it runnable on a CI machine that has no configuration at
--- all.
---
--- Dependencies come from `$PASEO_TEST_DEPS` (see `tests/deps.sh`), never from
--- a plugin manager's install directory.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fs.dirname(here)

-- Test the tree you are STANDING IN. Running from a worktree used to load
-- spec.lua from the worktree and every module under test from the main
-- checkout -- a suite that passes while testing none of your changes.
vim.opt.runtimepath:prepend(root)

-- `require "tests.spec"` resolves through package.path, which Neovim seeds
-- with `./?.lua` alone -- so without this the suite only runs from the repo
-- root, and silently tests nothing from anywhere else.
package.path = ("%s/?.lua;%s"):format(root, package.path)

local deps = assert(vim.env.PASEO_TEST_DEPS, "PASEO_TEST_DEPS is not set; run tests/run.sh")
for name, kind in vim.fs.dir(deps) do
  if kind == "directory" then
    vim.opt.runtimepath:append(vim.fs.joinpath(deps, name))
  end
end

-- gitsigns does nothing until it is set up, and the hunk suites need it
-- attached to real fixture repos. Everything else here is required on demand.
require("gitsigns").setup {}

-- The plugin has no `plugin/` directory, so `:Paseo` and the ColorScheme hook
-- that keeps the highlight groups alive both come from `setup()` -- exactly as
-- they do for someone with `opts = {}` in their lazy spec.
require("paseo").setup {}

vim.opt.swapfile = false
vim.opt.shada = ""
