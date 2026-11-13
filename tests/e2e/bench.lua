--- The UI benchmark's driver, run INSIDE the e2e Neovim (tests/e2e/bench.sh).
---
--- Each flow is the function a key calls, timed from the call to two moments:
---
---   paint  the window is up and the loop has gone idle once, which is when
---          Neovim flushes the screen -- what you would see
---   ready  the real content is in it, not a loading line
---
--- Polled from a 1 ms timer on the loop itself, so the resolution is the
--- loop's, not a shell's: a `--remote-expr` per poll from outside costs more
--- than most of what is being measured.
---
--- `_G.paseo_bench.run(out, phase)` starts the sequence and writes JSON to
--- `out` when it finishes; the shell waits for that file.

local api = vim.api
local M = {}
_G.paseo_bench = M

local results = {}

local function now()
  return vim.uv.hrtime() / 1e6
end

local function chat_mod()
  return require "paseo.ui.chat"
end
local function native()
  return require "paseo.ui.native"
end
local function rail()
  return require "paseo.ui.rail"
end

---Run `trigger`, then wait for `painted` and `ready` to hold. Calls `done`.
local function measure(name, trigger, painted, ready, done, timeout)
  timeout = timeout or 30000
  local t0 = now()
  local ok, err = pcall(trigger)
  if not ok then
    results[name] = { error = tostring(err) }
    return vim.schedule(done)
  end
  local paint_at
  local timer = assert(vim.uv.new_timer())
  timer:start(
    1,
    1,
    vim.schedule_wrap(function()
      if timer:is_closing() then
        return
      end
      local t = now()
      local okp, p = pcall(painted)
      if not paint_at and okp and p then
        paint_at = t - t0
      end
      local okr, r = pcall(ready)
      if paint_at and okr and r then
        timer:stop()
        timer:close()
        results[name] = { paint = paint_at, ready = t - t0 }
        return done()
      end
      if t - t0 > timeout then
        timer:stop()
        timer:close()
        results[name] = { paint = paint_at, timeout = true, ready = t - t0 }
        return done()
      end
    end)
  )
end

---Wait `ms`, then `done`.
local function pause(ms, done)
  vim.defer_fn(done, ms)
end

local function chat_loaded(c)
  return c ~= nil and c.agent_id ~= nil and c.initialised and not c.holding and #(c.order or {}) > 0
end

local function rail_loaded()
  if not rail().win() then
    return false
  end
  local _, workspaces = rail().lines(32)
  return next(workspaces) ~= nil
end

local function panel_win()
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.bo[api.nvim_win_get_buf(w)].filetype == "paseo-panel" then
      return w
    end
  end
end

local function panel_loaded()
  local w = panel_win()
  if not w then
    return false
  end
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, 3, false)
  local text = table.concat(lines, "\n")
  return text ~= "" and not text:find("loading", 1, true)
end

local function newtask_loaded()
  local c = chat_mod().current()
  local t = c and require("paseo.ui.newtask").task(c)
  return t ~= nil and t.draft ~= nil and not t.draft.loading and t.presets ~= nil
end

local function newtask_painted()
  local c = chat_mod().current()
  return c ~= nil and c.draft ~= nil and require("paseo.ui.newtask").task(c) ~= nil
end

---Leave whatever new-task screen is up without starting anything.
local function discard_draft()
  local c = chat_mod().current()
  if c and c.draft then
    pcall(chat_mod().discard, c)
  end
end

---A workspace on the rail other than the one on screen, with an agent.
local function other_workspace(not_dir)
  local _, workspaces = rail().lines(32)
  local lines = vim.tbl_keys(workspaces)
  table.sort(lines)
  for _, line in ipairs(lines) do
    local ws = workspaces[line]
    if ws.directory ~= not_dir and #require("paseo.agents").for_workspace(ws, ws.hostId) > 0 then
      return ws
    end
  end
end

---The sequence: a list of `function(next)` steps.
local function sequence(steps, finish)
  local i = 0
  local function step()
    i = i + 1
    local s = steps[i]
    if not s then
      return finish()
    end
    local ok, err = pcall(s, step)
    if not ok then
      results["step" .. i] = { error = tostring(err) }
      step()
    end
  end
  step()
end

---@param out string  where the JSON goes
function M.run(out)
  local perf = require "paseo.perf"
  local first_root = vim.uv.cwd()
  local first_chat, other
  local steps = {
    -- A moment after startup, as a person would take before reaching for an
    -- agent. With nothing done at startup (the baseline) this changes
    -- nothing; with |paseo.prewarm| it is the time the prewarm has.
    function(next)
      pause(tonumber(vim.env.BENCH_SETTLE) or 1500, next)
    end,
    -- COLD: from nothing to a conversation on screen. Includes the sidecar's
    -- boot and the connection, unless something already paid for them.
    function(next)
      measure("chat.open.cold", function()
        vim.cmd "Paseo"
      end, function()
        local c = chat_mod().current()
        return c ~= nil and native().is_open(c)
      end, function()
        return chat_loaded(chat_mod().current())
      end, next)
    end,
    function(next)
      first_chat = chat_mod().current()
      -- The rail opens beside the chat by default; wait for its list.
      measure("rail.first_load", function() end, function()
        return rail().win() ~= nil
      end, rail_loaded, next)
    end,
    function(next)
      pause(300, next)
    end,
  }

  -- Each repeated flow, five times: the first is what a session's first use
  -- costs, the rest what every later one does.
  for i = 1, 5 do
    vim.list_extend(steps, {
      function(next)
        if rail().win() then
          native().toggle_rail()
        end
        pause(150, next)
      end,
      function(next)
        measure(("rail.toggle.%d"):format(i), function()
          native().toggle_rail()
        end, function()
          return rail().win() ~= nil
        end, rail_loaded, next)
      end,
      function(next)
        pause(150, next)
      end,
      function(next)
        measure(("settings.open.%d"):format(i), function()
          native().panel "Settings"
        end, function()
          return panel_win() ~= nil
        end, panel_loaded, next)
      end,
      function(next)
        pause(150, function()
          pcall(native().toggle_panel)
          pcall(native().back)
          pause(150, next)
        end)
      end,
      function(next)
        measure(("newtask.open.%d"):format(i), function()
          require("paseo.new").open()
        end, newtask_painted, newtask_loaded, next)
      end,
      function(next)
        pause(150, function()
          discard_draft()
          pause(200, next)
        end)
      end,
      function(next)
        other = other or other_workspace(first_root)
        if not other then
          results["chat.switch." .. i] = { error = "no other workspace with an agent on the rail" }
          return next()
        end
        local before = chat_mod().current()
        measure(("chat.switch.%d"):format(i), function()
          native().open_workspace(other)
        end, function()
          local c = chat_mod().current()
          return c ~= nil and c ~= before and native().is_open(c)
        end, function()
          local c = chat_mod().current()
          return c ~= before and chat_loaded(c)
        end, next)
      end,
      function(next)
        pause(150, next)
      end,
      function(next)
        local before = chat_mod().current()
        measure(("chat.back.%d"):format(i), function()
          native().show_session { kind = "agent", id = first_chat.agent_id, hostId = first_chat.host_id }
        end, function()
          local c = chat_mod().current()
          return c ~= nil and c ~= before and native().is_open(c)
        end, function()
          return chat_loaded(chat_mod().current())
        end, next)
      end,
      function(next)
        pause(200, next)
      end,
    })
  end

  sequence(steps, function()
    local report = perf.enabled and perf.report() or nil
    local f = assert(io.open(out, "w"))
    f:write(vim.json.encode { flows = results, perf = report })
    f:close()
  end)
end

---The load test: `agents` agents streaming for `seconds`, the rail open. How
---often it repainted, how long the main loop spent on it, and how late the
---loop ran -- which is how long a key would have waited.
---@param out string
---@param seconds integer
function M.load(out, seconds)
  local perf = require "paseo.perf"
  perf.reset()
  local t0 = now()
  vim.defer_fn(function()
    local report = perf.report()
    local f = assert(io.open(out, "w"))
    f:write(vim.json.encode { seconds = (now() - t0) / 1000, perf = report })
    f:close()
  end, seconds * 1000)
end

return M
