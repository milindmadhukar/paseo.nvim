--- Talking to the Paseo daemon.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures

local function test_daemon()
  local daemon = require "paseo.daemon"
  local config = require "paseo.config"

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")

  -- Closed, not just written: an unclosed handle leaves the JSON in Lua's
  -- buffer, the reader sees an empty file, and the test passes or fails for
  -- reasons that have nothing to do with the code.
  local function write_config(listen)
    local fd = assert(io.open(tmp .. "/config.json", "w"))
    fd:write(vim.json.encode { daemon = { listen = listen } })
    fd:close()
  end

  write_config "127.0.0.1:7777"
  config.setup { paseo = { home = tmp } }
  local sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  truthy("daemon: reads daemon.listen from config.json", vim.tbl_contains(sources, "daemon.listen"))
  local listened = daemon.candidates()[1]
  eq("daemon: uses the port config.json names, not 6767", listened and listened.port, 7777)
  -- NOT "the default is always last": it is only there when nothing else
  -- named a port. Asserting otherwise was asserting the bug.
  eq("daemon: a named port is the last word", sources[#sources], "daemon.listen")

  write_config "unix:/run/paseo.sock"
  config.setup { paseo = { home = tmp } }
  sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  truthy(
    "daemon: a unix-socket listen is skipped, not turned into a bad URL",
    not vim.tbl_contains(sources, "daemon.listen")
  )

  config.setup { paseo = { url = "ws://127.0.0.1:1234/ws" } }
  local first = daemon.candidates()[1]
  eq("daemon: an explicit url wins outright", first and first.source, "config")

  -- The hardcoded default is a LAST RESORT. Falling through to 6767 when the
  -- daemon's own config named a different port meant silently connecting to a
  -- DIFFERENT daemon -- and it made autostart unreachable, because there was
  -- always something answering.
  write_config "127.0.0.1:6799"
  config.setup { paseo = { home = tmp } }
  local sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  truthy(
    "daemon: a configured port suppresses the 6767 fallback",
    not vim.tbl_contains(sources, "default"),
    vim.inspect(sources)
  )

  -- ...but with no config.json at all, the default is the only thing there is.
  os.remove(tmp .. "/config.json")
  config.setup { paseo = { home = tmp } }
  sources = vim.tbl_map(function(e)
    return e.source
  end, daemon.candidates())
  eq("daemon: with no config.json the default is used", sources, { "default" })

  -- `paseo` must be resolved, not trusted: the desktop binary opens a window.
  local cli = daemon.cli()
  if cli then
    truthy(
      "daemon: cli() only accepts the headless wrapper",
      vim.fn.resolve(cli):match "resources/bin/paseo$" ~= nil,
      vim.fn.resolve(cli)
    )
  end

  config.setup {}
end

return {
  { "daemon", test_daemon },
}
