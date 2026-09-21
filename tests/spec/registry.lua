--- The agent registry.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures

local function test_registry()
  local reg = require "paseo.registry"

  -- An absent registry is not an error: it means `ws` has never run, which is
  -- the normal state for anyone using only the review half of this plugin.
  local saved = vim.env.XDG_STATE_HOME
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  reg.invalidate()
  eq("registry: an absent file yields an empty list, not nil", reg.list(), {})

  local dir = vim.fs.joinpath(vim.env.XDG_STATE_HOME, "ws")
  vim.fn.mkdir(dir, "p")
  local fd = assert(io.open(vim.fs.joinpath(dir, "registry.json"), "w"))
  fd:write(vim.json.encode {
    version = 1,
    workspaces = {
      {
        name = "otp",
        project = "/tmp/proj",
        root = "/tmp/proj/.workspaces/otp",
        branch = "ws/otp",
        repos = {
          { name = "clm", path = "/tmp/proj/.workspaces/otp/clm", state = "active" },
          { name = "hipa", origin = "/tmp/proj/hipa", state = "declared" },
        },
      },
    },
  })
  fd:close()

  reg.invalidate()
  local list = reg.list()
  eq("registry: reads the file", #list, 1)
  -- A declared member has no worktree yet; it must not be offered as one.
  eq("registry: active() skips declared members", #reg.active(list[1]), 1)
  eq(
    "registry: containing() finds a workspace from inside it",
    (reg.containing "/tmp/proj/.workspaces/otp/clm/app.py" or {}).name,
    "otp"
  )
  eq("registry: containing() returns nil outside one", reg.containing "/tmp/elsewhere", nil)

  vim.env.XDG_STATE_HOME = saved
  reg.invalidate()
end

return {
  { "registry", test_registry },
}
