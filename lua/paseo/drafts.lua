--- The new-session drafts you have not sent, kept across restarts.
---
--- A draft is the new-session screen (|paseo.ui.newtask|) with what you typed
--- in its box and what you picked above it. Quit Neovim with three of them on
--- the go and the next Paseo tab opens with the three back: the text, the
--- provider, the mode, where it goes.
---
--- One file, `stdpath("state")/paseo/drafts.json`, the drafts filed by id:
--- >
---   { "version": 1, "drafts": { "<id>": {
---       "scope": "session", "kind": "chat", "where": "here",
---       "ctx": { "root": ..., "host_id": ..., "workspace_id": ... },
---       "choice": { "provider": "claude/opus", "modeId": "plan", ... },
---       "prompt": ["first line", "second"], "updated": 1763100000 } } }
--- <
--- Written a moment after a change rather than on every key, and at once on
--- the way out. A draft leaves the file when it is SENT or thrown away (`q`,
--- `:bdelete`) -- and quitting Neovim is neither: what is open when you quit
--- is what comes back. Images and attachments are not kept; only text.

local M = {}

local VERSION = 1

---How long after the last change the file is written.
M.DELAY = 500

---@class paseo.SavedDraft
---@field id string
---@field scope "session"|"agent"
---@field kind "chat"|"terminal"
---@field where "here"|"worktree"
---@field base string|nil
---@field preset string|nil
---@field ctx table
---@field choice table   |paseo.NewChoice|: provider, modeId, thinkingOptionId, featureValues.
---@field prompt string[]
---@field created integer  When it was first kept: the order they come back in.
---@field updated integer

---@type table<string, paseo.SavedDraft>|nil  Loaded on first use.
local store
local timer
local exiting = false
local watching = false

---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath "state", "paseo", "drafts.json")
end

---@return table<string, paseo.SavedDraft>
local function load()
  if store then
    return store
  end
  store = {}
  local fd = io.open(M.path(), "r")
  if fd then
    local text = fd:read "*a"
    fd:close()
    local ok, parsed = pcall(vim.json.decode, text)
    if ok and type(parsed) == "table" and type(parsed.drafts) == "table" then
      for id, entry in pairs(parsed.drafts) do
        if type(entry) == "table" and type(entry.ctx) == "table" then
          entry.id = id
          store[id] = entry
        end
      end
    end
  end
  return store
end

local function write()
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if fd then
    -- `vim.empty_dict`: an empty Lua table encodes as `[]`, which reads back
    -- as a list.
    local drafts = next(load()) and load() or vim.empty_dict()
    fd:write(vim.json.encode { version = VERSION, drafts = drafts })
    fd:close()
  end
end

---Write now whatever is waiting.
function M.flush()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
    pcall(write)
  end
end

local function later()
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
  end
  timer:start(
    M.DELAY,
    0,
    vim.schedule_wrap(function()
      M.flush()
    end)
  )
end

---Quitting keeps every draft, and writes what is pending first.
local function watch()
  if watching then
    return
  end
  watching = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("paseo.drafts", { clear = true }),
    desc = "paseo: keep the drafts you quit with",
    callback = function()
      M.flush()
      -- Whatever tears the chats down after this is Neovim going, not you
      -- throwing a draft away.
      exiting = true
    end,
  })
end

---Keep `entry` (a later write).
---@param entry paseo.SavedDraft
function M.save(entry)
  if exiting or not entry.id then
    return
  end
  watch()
  local was = load()[entry.id]
  entry.created = entry.created or (was and was.created) or os.time()
  entry.updated = os.time()
  load()[entry.id] = entry
  later()
end

---The draft is sent, or thrown away: out of the file.
---@param id string|nil
function M.remove(id)
  if exiting or not id or not load()[id] then
    return
  end
  load()[id] = nil
  later()
end

---Every kept draft, oldest first: the order they come back in.
---@return paseo.SavedDraft[]
function M.all()
  local out = vim.tbl_values(load())
  table.sort(out, function(a, b)
    if (a.created or 0) ~= (b.created or 0) then
      return (a.created or 0) < (b.created or 0)
    end
    return a.id < b.id
  end)
  return out
end

---For the tests: forget what was read, and the way out.
function M.reset()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  store = nil
  exiting = false
end

return M
