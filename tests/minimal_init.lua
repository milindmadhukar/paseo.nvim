--- The Neovim the suite runs in.
---
--- Started with `-u`, so none of your own configuration is loaded: the suite
--- tests this plugin against the plugins it declares, and nothing else. That
--- is also what makes it runnable on a CI machine that has no configuration at
--- all.
---
--- The plugin has no plugin dependencies, so nothing but this checkout goes on
--- the runtimepath -- never a plugin manager's install directory.

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

-- The plugin has no `plugin/` directory, so `:Paseo` and the ColorScheme hook
-- that keeps the highlight groups alive both come from `setup()` -- exactly as
-- they do for someone with `opts = {}` in their lazy spec.
-- No prewarm: it probes for a daemon, and the one it would find is yours.
require("paseo").setup { paseo = { prewarm = false } }

vim.opt.swapfile = false

-- State the plugin REMEMBERS -- the workspace rail's toggle, the skills it
-- installed -- goes somewhere of the suite's own. Left at the default, a test
-- pressing the toggle hid the rail in your own editor the next time you
-- opened it.
vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.opt.shada = ""

-- THE SUITE NEVER STARTS A REAL SIDECAR. Every suite stubs `bridge.ensure`
-- and puts back what it found -- which, before this, was the real one. A
-- suite that forgot to stub it (anything reaching `agents.watch`) spawned a
-- sidecar that dialled the daemon on 6767: YOUR daemon, with your sessions.
-- Its late answer to one suite's `agent.find` then opened a start menu inside
-- another and hung the whole run on `inputlist`. The real `ensure` is now this,
-- so forgetting fails one request instead of reaching outside the suite.
require("paseo.bridge").ensure = function(callback)
  callback "the test suite never starts a real sidecar"
end
