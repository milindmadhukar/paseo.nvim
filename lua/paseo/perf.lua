--- Where the time goes. Off unless asked for, and then cheap.
---
--- Turned on by `PASEO_PERF=1` in the environment, `vim.g.paseo_perf = true`
--- before setup, or `require("paseo.perf").enable()` at any point. Off, every
--- hook in the plugin is one boolean test; nothing is wrapped and nothing is
--- recorded.
---
--- On, it records three things:
---
--- - SPANS: the wall time of named functions (`rail.draw`, `transcript.stream`,
---   ...). Wrapped from outside by `M.instrument`, so the modules being
---   measured carry no timing code of their own.
--- - RPCS: every bridge request, from the write to the reply, per op -- and,
---   from the sidecar, how much of that was spent QUEUED behind other ops
---   versus RUNNING against the daemon. The difference between those two is
---   the whole question of whether a slow call is slow or merely late.
--- - STALLS: how late a 10 ms timer fires on the main loop, which is how long
---   the editor could not answer a key.
---
--- `M.report()` returns the lot as a table; `require("paseo.perf").show()` prints it.

local M = {}

---@class paseo.PerfStat
---@field n integer
---@field total number ms
---@field max number ms
---@field samples number[] ms, the most recent `KEEP`

local KEEP = 2000

---@type table<string, paseo.PerfStat>
local stats = {}
---@type table<string, integer>
local counters = {}

M.enabled = vim.env.PASEO_PERF == "1" or vim.g.paseo_perf == true

local hrtime = vim.uv.hrtime

-- LuaJIT has neither; a wrapped function must hand back every value it got,
-- nils included, or a caller reading the second return sees the wrong one.
local function pack(...)
  return { n = select("#", ...), ... }
end
local unpack = unpack or table.unpack

---Now, in milliseconds, at nanosecond resolution.
---@return number
function M.now()
  return hrtime() / 1e6
end

---Record one sample of `name`.
---@param name string
---@param ms number
function M.add(name, ms)
  if not M.enabled then
    return
  end
  local s = stats[name]
  if not s then
    s = { n = 0, total = 0, max = 0, samples = {} }
    stats[name] = s
  end
  s.n = s.n + 1
  s.total = s.total + ms
  if ms > s.max then
    s.max = ms
  end
  s.samples[(s.n - 1) % KEEP + 1] = ms
end

---Count an occurrence of `name`.
---@param name string
---@param by? integer
function M.count(name, by)
  if not M.enabled then
    return
  end
  counters[name] = (counters[name] or 0) + (by or 1)
end

---Time `fn(...)` as `name` and return what it returned.
---@generic T
---@param name string
---@param fn fun(...): T
---@return T
function M.time(name, fn, ...)
  if not M.enabled then
    return fn(...)
  end
  local t0 = hrtime()
  local result = pack(fn(...))
  M.add(name, (hrtime() - t0) / 1e6)
  return unpack(result, 1, result.n)
end

---What has been wrapped, so a second `instrument` does not wrap twice.
---@type table<string, boolean>
local wrapped = {}

---Wrap `module[field]` for every field named, so each call is a span named
---`<short>.<field>`. Modules call their own functions through `M.x`, which
---is what makes this work without touching them; a `local function` inside a
---module is invisible to it, by design.
---@param targets table<string, string[]>  module name -> function names
function M.instrument(targets)
  for module, fields in pairs(targets) do
    local ok, mod = pcall(require, module)
    if ok and type(mod) == "table" then
      local short = module:gsub("^paseo%.", ""):gsub("^ui%.", "")
      for _, field in ipairs(fields) do
        local key = module .. "." .. field
        local original = mod[field]
        if type(original) == "function" and not wrapped[key] then
          wrapped[key] = true
          local name = short .. "." .. field
          mod[field] = function(...)
            if not M.enabled then
              return original(...)
            end
            local t0 = hrtime()
            local result = pack(original(...))
            M.add(name, (hrtime() - t0) / 1e6)
            return unpack(result, 1, result.n)
          end
        end
      end
    end
  end
end

---The functions worth watching. Anything here runs on the main loop and is
---on the path from a key to a painted window.
M.HOT = {
  ["paseo.ui.rail"] = { "build", "draw", "load", "spinning", "directory_changed", "reveal", "seat" },
  ["paseo.ui.transcript"] = { "stream", "flush", "upsert", "redraw", "rerender" },
  ["paseo.ui.sidebar"] = { "header", "refresh", "parts" },
  ["paseo.ui.composer"] = { "refresh" },
  ["paseo.ui.native"] = { "open", "show", "sync", "toggle_rail", "toggle_panel", "redraw_panels", "refresh" },
  ["paseo.ui.newtask"] = { "open", "draw", "load" },
  ["paseo.ui.chat"] = { "open", "refresh", "load_settings", "draft" },
  ["paseo.ui.panels.settings"] = { "load", "draw" },
  ["paseo.ui.permission"] = { "relay" },
  ["paseo.workspaces"] = { "strategy", "here", "list", "scope" },
  ["paseo.workspace"] = { "discover" },
  ["paseo.repos"] = { "list", "resolve" },
  ["paseo.daemon"] = { "resolve", "probe" },
  ["paseo.agents"] = { "all", "for_root", "for_workspace", "workspace_bucket" },
  ["paseo.subagents"] = { "list", "counts", "counts_under", "track" },
  ["paseo.new"] = { "open", "isolation" },
  ["paseo.pr"] = { "watch", "rollup" },
}

---@type uv.uv_timer_t|nil
local stall_timer

---Watch the main loop: a 10 ms timer, and how late each tick lands. A tick
---that lands 80 ms late is 80 ms in which a key went unanswered.
local function watch_stalls()
  if stall_timer then
    return
  end
  local last = hrtime()
  stall_timer = vim.uv.new_timer()
  stall_timer:start(10, 10, function()
    -- On the loop thread itself: a timer callback IS the main loop, so its
    -- lateness is exactly the loop's.
    local now = hrtime()
    local late = (now - last) / 1e6 - 10
    last = now
    if late > 4 then
      M.add("loop.stall", late)
    end
  end)
end

---Turn recording on, wrap the hot functions, and start the stall watch.
function M.enable()
  M.enabled = true
  M.instrument(M.HOT)
  watch_stalls()
end

---Forget everything recorded so far.
function M.reset()
  stats = {}
  counters = {}
end

---@param samples number[]
---@param q number 0..1
---@return number
local function quantile(samples, q)
  if #samples == 0 then
    return 0
  end
  local sorted = vim.deepcopy(samples)
  table.sort(sorted)
  local i = math.max(1, math.min(#sorted, math.ceil(q * #sorted)))
  return sorted[i]
end

---Everything recorded, summarised: per name its count, total, mean, median,
---p90 and max, in ms.
---@return { spans: table<string, table>, counters: table<string, integer> }
function M.report()
  local spans = {}
  for name, s in pairs(stats) do
    spans[name] = {
      n = s.n,
      total = s.total,
      mean = s.total / s.n,
      p50 = quantile(s.samples, 0.5),
      p90 = quantile(s.samples, 0.9),
      max = s.max,
    }
  end
  return { spans = spans, counters = vim.deepcopy(counters) }
end

---The report as lines, slowest total first.
---@return string[]
function M.lines()
  local r = M.report()
  local names = vim.tbl_keys(r.spans)
  table.sort(names, function(a, b)
    return r.spans[a].total > r.spans[b].total
  end)
  local out = { ("%-38s %7s %9s %8s %8s %8s"):format("span", "n", "total", "p50", "p90", "max") }
  for _, name in ipairs(names) do
    local s = r.spans[name]
    out[#out + 1] = ("%-38s %7d %9.1f %8.2f %8.2f %8.2f"):format(name, s.n, s.total, s.p50, s.p90, s.max)
  end
  local counted = vim.tbl_keys(r.counters)
  table.sort(counted)
  if #counted > 0 then
    out[#out + 1] = ""
    for _, name in ipairs(counted) do
      out[#out + 1] = ("%-38s %7d"):format(name, r.counters[name])
    end
  end
  return out
end

---`:lua require("paseo.perf").show()`: turn recording on the first time;
---after that, print what it has measured.
function M.show()
  if not M.enabled then
    M.enable()
    return vim.notify(
      "paseo: perf recording is on now; do the slow thing, then show() again",
      vim.log.levels.INFO
    )
  end
  vim.notify(table.concat(M.lines(), "\n"), vim.log.levels.INFO, { title = "paseo: perf" })
end

return M
