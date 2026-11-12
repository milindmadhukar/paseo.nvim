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
---   1. what the caller asked for -- `:Paseo buf`, `:Paseo sidebar`, `<C-f>`;
---   2. what is ON SCREEN right now -- a session picked from the dashboard
---      stays on the dashboard you picked it from;
---   3. what you last put a chat on -- across a close, a tab switch, a
---      workspace switch;
---   4. `ui.surface`, when nothing has been on screen yet this session.
---
--- Writes come from the surfaces themselves (|paseo.ui.float|.open and
--- |paseo.ui.sidebar|.open), so whatever put a chat on screen -- a command, a
--- key, a test -- is recorded the same way, and nothing has to remember to.

local M = {}

---@alias paseo.SurfaceName "float"|"sidebar"|"buffer"

---@type paseo.SurfaceName|nil
local last

---The last DASHBOARD mount, kept apart from `last`: from the sidebar, `<C-f>`
---goes back to the dashboard you came from, and `last` says "sidebar" there.
---@type "float"|"buffer"|nil
local last_dashboard

---Record that a chat was just put on `name`.
---@param name paseo.SurfaceName
function M.remember(name)
  if name == "float" or name == "sidebar" or name == "buffer" then
    last = name
  end
  if name == "float" or name == "buffer" then
    last_dashboard = name
  end
end

---What you last put a chat on, if anything this session.
---@return paseo.SurfaceName|nil
function M.last()
  return last
end

---The surface showing a chat right now, on any tab page.
---@return paseo.SurfaceName|nil
function M.on_screen()
  local mount = require("paseo.ui.float").mount()
  if mount then
    return mount
  end
  -- No dashboard is up, so a live conversation window is the sidebar's: the
  -- dashboard's panes use the same field and are gone with it. Only the
  -- current chat can hold one -- every open goes through `current`.
  local chat = require("paseo.ui.chat").current()
  if chat and require("paseo.ui.sidebar").is_open(chat) then
    return "sidebar"
  end
  return nil
end

---Where a chat goes. See the header for the order.
---@param explicit? paseo.SurfaceName
---@return paseo.SurfaceName
function M.resolve(explicit)
  return explicit or M.on_screen() or last or require("paseo.config").get().ui.surface
end

---The DASHBOARD you would get, for the callers that need the dashboard in
---particular -- the Sessions list exists nowhere else, and `<C-f>` from the
---sidebar goes to one. The mount on screen, else the last one you used, else
---the configured one if it is a dashboard, else the float.
---@return "float"|"buffer"
function M.dashboard()
  local mount = require("paseo.ui.float").mount()
  if mount then
    return mount
  end
  if last_dashboard then
    return last_dashboard
  end
  return require("paseo.config").get().ui.surface == "buffer" and "buffer" or "float"
end

---For the tests.
function M.reset()
  last, last_dashboard = nil, nil
end

return M
