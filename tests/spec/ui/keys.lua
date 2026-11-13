--- Keys as configuration: lists, `false`, remaps keyed by the default, the
--- old option names, and hints that show what is actually bound.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

local function test_helpers()
  local config = require "paseo.config"
  local keys = require "paseo.ui.keys"
  local saved = vim.deepcopy(config.get())

  eq("keys: a string is one key", keys.list "<C-b>", { "<C-b>" })
  eq("keys: a list is several", keys.list { "<C-b>", "<leader>e" }, { "<C-b>", "<leader>e" })
  eq("keys: false is none", keys.list(false), {})

  config.setup { keys = { rail = { d = false, m = "M", y = { "y", "Y" } } } }
  eq("keys: an unmapped default is itself", keys.resolve("rail", "a"), { "a" })
  eq("keys: false unbinds it", keys.resolve("rail", "d"), {})
  eq("keys: a string moves it", keys.resolve("rail", "m"), { "M" })
  eq("keys: a list adds one", keys.resolve("rail", "y"), { "y", "Y" })
  eq("keys: the hint shows the moved key", keys.label("rail", "m"), "M")
  eq("keys: and no hint for an unbound one", keys.label("rail", "d"), nil)

  local buf = api.nvim_create_buf(false, true)
  local bound = keys.set("rail", "n", "y", function() end, { buffer = buf })
  eq("keys: set binds every key it resolves to", #bound, 2)
  truthy("keys: Y is bound", api.nvim_buf_call(buf, function()
    return vim.fn.maparg("Y", "n", false, true).buffer == 1
  end))
  eq("keys: set binds nothing for an unbound key", #keys.set("rail", "n", "d", function() end, { buffer = buf }), 0)
  api.nvim_buf_delete(buf, { force = true })

  -- A key YOU mapped to an action the plugin leaves unmapped.
  vim.keymap.set("n", "<leader>zq", "<cmd>Paseo<cr>")
  truthy("keys: finds your own mapping by its rhs", keys.user_key "<cmd>Paseo<cr>" ~= nil)
  pcall(vim.keymap.del, "n", "<leader>zq")

  config.setup(saved)
end

local function test_config()
  local config = require "paseo.config"
  local saved = vim.deepcopy(config.get())

  config.setup {}
  eq("config: the rail toggle defaults to <C-b>", config.get().ui.native.keys.rail, "<C-b>")
  eq("config: the quit guard is off unless asked for", config.get().quit.guard, false)

  config.setup { ui = { native = { keys = { rail = { "<C-b>", "<leader>e" } } } } }
  eq("config: a list of keys is accepted", config.get().ui.native.keys.rail, { "<C-b>", "<leader>e" })

  -- The OLD names still land on the new ones.
  config.setup { ui = { float = { rail = { keys = { toggle = "<C-y>" } }, keys = { new = false } } } }
  eq("config: ui.float.rail.keys.toggle still sets the rail key", config.get().ui.native.keys.rail, "<C-y>")
  eq("config: ui.float.keys.new still sets the new key", config.get().ui.native.keys.new, false)
  config.setup {
    ui = { float = { rail = { keys = { toggle = "<C-y>" } } }, native = { keys = { rail = "<C-x>" } } },
  }
  eq("config: but the new name wins when both are set", config.get().ui.native.keys.rail, "<C-x>")

  truthy(
    "config: a key that is not a key is refused",
    not pcall(config.setup, { keys = { rail = { d = 3 } } })
  )
  config.setup(saved)
end

return {
  { "ui.keys.helpers", test_helpers },
  { "ui.keys.config", test_config },
}
