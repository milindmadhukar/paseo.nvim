--- Answers worth keeping: the last one at once, a fresh one in the background.
---
--- Stale-while-revalidate, for things the daemon knows that change rarely and
--- are asked for on every open: the provider catalogue, a model's features.
--- The new-task screen used to wait for both on every `<C-n>` -- the catalogue
--- a `providers` call that waits for discovery, the features another round
--- trip after it -- to draw cards it had drawn a minute before with the same
--- answers.
---
--- `get` hands back the kept value straight away, and asks again behind it
--- once the value is older than its `ttl`; the next `get` sees the new one.
--- With nothing kept, it asks, and every caller that arrives while the
--- question is out shares the one answer. A value the fetcher marks as not
--- worth keeping (a catalogue still discovering) is handed over and not kept.

local M = {}

---@class paseo.StoreEntry
---@field value any
---@field at integer      vim.uv.now() when kept
---@field pending boolean a fetch is out
---@field waiting fun(value: any, err: string|nil)[]

---@type table<string, paseo.StoreEntry>
local entries = {}

---@alias paseo.StoreFetch fun(done: fun(value: any, err: string|nil, keep?: boolean))

---@param key string
---@return paseo.StoreEntry
local function entry(key)
  local e = entries[key]
  if not e then
    e = { pending = false, waiting = {} }
    entries[key] = e
  end
  return e
end

---Ask again, whatever is kept. `callback`, if given, gets the new answer.
---@param key string
---@param fetch paseo.StoreFetch
---@param callback? fun(value: any, err: string|nil)
function M.refresh(key, fetch, callback)
  local e = entry(key)
  if callback then
    table.insert(e.waiting, callback)
  end
  if e.pending then
    return
  end
  e.pending = true
  local ok, err = pcall(fetch, function(value, fetch_err, keep)
    e.pending = false
    if not fetch_err and value ~= nil and keep ~= false then
      e.value, e.at = value, vim.uv.now()
    end
    local waiting = e.waiting
    e.waiting = {}
    for _, fn in ipairs(waiting) do
      pcall(fn, value, fetch_err)
    end
  end)
  if not ok then
    e.pending = false
    local waiting = e.waiting
    e.waiting = {}
    for _, fn in ipairs(waiting) do
      pcall(fn, nil, tostring(err))
    end
  end
end

---The kept answer for `key` at once, or the first one when there is none.
---@param key string
---@param ttl integer ms a kept value is fresh for
---@param fetch paseo.StoreFetch
---@param callback fun(value: any, err: string|nil, cached: boolean)
function M.get(key, ttl, fetch, callback)
  local e = entries[key]
  if e and e.value ~= nil then
    callback(e.value, nil, true)
    if vim.uv.now() - e.at > ttl then
      M.refresh(key, fetch)
    end
    return
  end
  M.refresh(key, fetch, function(value, err)
    callback(value, err, false)
  end)
end

---What is kept for `key`, if anything.
---@param key string
---@return any
function M.peek(key)
  local e = entries[key]
  return e and e.value
end

---Keep `value` for `key`, as if it had just been fetched.
---@param key string
---@param value any
function M.put(key, value)
  local e = entry(key)
  e.value, e.at = value, vim.uv.now()
end

---Forget every key starting with `prefix` (everything, with none).
---@param prefix? string
function M.invalidate(prefix)
  for key in pairs(entries) do
    if not prefix or vim.startswith(key, prefix) then
      local e = entries[key]
      e.value, e.at = nil, nil
    end
  end
end

return M
