--- Which surface a chat goes on when nobody named one.
---
--- THE SURFACE BELONGS TO YOU, NOT TO A CONVERSATION. It used to be written
--- onto each chat table (`chat.surface`) and cleared again whenever the
--- dashboard closed -- so the answer to "where does this go" depended on which
--- chat object a code path happened to be holding, and the honest answer was
--- usually "nil, so the configured default". Every path that swaps one chat
--- for another -- following you to a workspace you had visited before, a
--- session row, `offer`, adopting an agent `agent.find` already knew -- closes
--- one surface and opens another, and every one of them landed you on a float
--- however long you had been in the buffer dashboard or the sidebar.
---
--- So there is one answer, held here, and it is asked in one order:
---
---   1. what the caller asked for -- `:Paseo native`, `:Paseo sidebar`,
---      `<C-f>`;
---   2. what is ON SCREEN right now -- a session picked from the rail stays
---      on the native surface you picked it from;
---   3. what you last put a chat on -- across a close, a tab switch, a
---      workspace switch;
---   4. `ui.surface`, when nothing has been on screen yet this session.
---
--- There are two surfaces: the native one (a tab page per agent) and the
--- sidebar. `"float"` and `"buffer"` named the old volt dashboard's two mounts;
--- both resolve to the native surface now.
---
--- Writes come from the surfaces themselves (|paseo.ui.native|.open and
--- |paseo.ui.sidebar|.open), so whatever put a chat on screen -- a command, a
--- key, a test -- is recorded the same way, and nothing has to remember to.

local M = {}

---@alias paseo.SurfaceName "native"|"sidebar"

---@type paseo.SurfaceName|nil
local last

---What a name means now: the old dashboard's two mounts are the native surface.
---@param name string|nil
---@return paseo.SurfaceName|nil
local function normalise(name)
  if name == "float" or name == "buffer" then
    return "native"
  end
  return name
end

---Record that a chat was just put on `name`.
---@param name paseo.SurfaceName
function M.remember(name)
  name = normalise(name)
  if name == "sidebar" or name == "native" then
    last = name
  end
end

---What you last put a chat on, if anything this session.
---@return paseo.SurfaceName|nil
function M.last()
  return last
end

---The surface showing a chat right now, on the tab page you are on.
---@return paseo.SurfaceName|nil
function M.on_screen()
  -- A native tab is on screen when it is the tab you are on.
  local native = package.loaded["paseo.ui.native"]
  if native and native.chat() then
    return "native"
  end
  -- A live conversation window off a native tab is the sidebar's. Only the
  -- current chat can hold one -- every open goes through `current`.
  local chat = require("paseo.ui.chat").current()
  if chat and require("paseo.ui.sidebar").is_open(chat) then
    return "sidebar"
  end
  return nil
end

---Where a chat goes. See the header for the order.
---@param explicit? string
---@return paseo.SurfaceName
function M.resolve(explicit)
  return normalise(explicit) or M.on_screen() or last or normalise(require("paseo.config").get().ui.surface)
end

---For the tests.
function M.reset()
  last = nil
end

return M
