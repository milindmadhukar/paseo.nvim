--- The full-screen surface, as functions you can call: |paseo-native-api|.
---
--- Every key the Paseo tab binds is one of these, and so is every
--- `<Plug>(paseo-…)` name (|paseo-plug|). The plugin maps none of them globally -- bind the
--- ones you want, to whatever you like:
---
---   vim.keymap.set("n", "<leader>ap", function() require("paseo.native").panel "Changes" end)
---
--- SAFE FROM ANYWHERE. Called away from the Paseo tab, an action that needs
--- the tab goes there first, opening it if there is none, and then does what
--- it says. A toggle that is called from away from the tab SHOWS: `toggle_rail()`
--- from your code is "take me to the rail", not "hide a rail I cannot see".
---
--- A thin layer over |paseo.ui.native|, whose functions are the surface's
--- internals and move as it does; these names are the ones kept.

local M = {}

local function ui()
  return require "paseo.ui.native"
end

local function chat()
  return require "paseo.ui.chat"
end

---Run `fn` on the Paseo tab, going there (or opening it) first. `fn` is told
---whether it was already there.
---@param fn fun(was_here: boolean)
local function on_tab(fn)
  local native = ui()
  if native.on_tab() then
    return fn(true)
  end
  if native.enter() then
    return fn(false)
  end
  -- No Paseo tab yet. With a chat to put in it, that is immediate; without
  -- one it is a daemon round trip, and `fn` runs once the tab is up.
  if chat().current() then
    chat().surface "native"
    if native.on_tab() then
      fn(false)
    end
    return
  end
  chat().open({ surface = "native" }, function(opened)
    if opened then
      vim.schedule(function()
        if native.on_tab() then
          fn(false)
        end
      end)
    end
  end)
end

-- --------------------------------------------------------------- the tab

---In and out of the Paseo tab: from your code, onto it as you left it (or
---opened, the first time); from it, back to your code. `<Plug>(paseo-native)`.
function M.toggle()
  chat().surface("native", { toggle = true })
end

---Onto the Paseo tab, opening it if there is none. Never leaves it.
function M.open()
  on_tab(function() end)
end

---Back to your code -- the tab you came from -- leaving the Paseo tab as it is.
---Nothing if you are not on it.
function M.code()
  if ui().on_tab() then
    ui().leave()
  end
end

---Take the Paseo tab down. The agents, terminals and drafts live on, and
---`open()` brings it back. (`q` in the conversation.)
function M.close()
  ui().close_surface()
end

-- -------------------------------------------------------------- the rail

---The workspace rail, on or off -- and the cursor with it (`<C-b>`). Away from
---the Paseo tab: go there, rail shown, cursor in it.
function M.toggle_rail()
  on_tab(function(was_here)
    -- The toggle itself whenever it would SHOW: that is what remembers the
    -- rail as shown, across restarts.
    if was_here or not ui().rail_shown() then
      ui().toggle_rail()
    else
      ui().focus_rail()
    end
  end)
end

---Into the rail, on the session on screen, showing it first if it is hidden;
---from the rail, back to the window you came from (`<C-h>`, `<C-s>`).
function M.focus_rail()
  on_tab(function(was_here)
    local rail = require "paseo.ui.rail"
    if was_here and rail.win() and vim.api.nvim_get_current_win() == rail.win() then
      ui().from_rail()
    else
      ui().focus_rail()
    end
  end)
end

-- ------------------------------------------------------------- the panel

---The names `panel()` takes, in the order of their number keys.
M.PANELS = { "Settings", "Changes", "Usage" }

---The panel name as the surface spells it, from any case; nil for no name,
---false for a name that is not one.
---@param name? string
---@return string|false|nil
local function panel_name(name)
  if name == nil or name == "" then
    return nil
  end
  for _, known in ipairs(M.PANELS) do
    if known:lower() == tostring(name):lower() then
      return known
    end
  end
  return false
end

---Show a panel on the right, cursor in it: `"Settings"`, `"Changes"` or
---`"Usage"` (any case), or the one you last looked at when `name` is nil.
---@param name? string
function M.panel(name)
  local known = panel_name(name)
  if known == false then
    vim.notify(
      ("paseo: no panel `%s` (%s)"):format(name, table.concat(M.PANELS, ", ")),
      vim.log.levels.ERROR
    )
    return
  end
  on_tab(function()
    ui().panel(known or nil)
  end)
end

---The panel, on or off (`<C-p>`). Away from the Paseo tab: go there, panel shown.
function M.toggle_panel()
  on_tab(function(was_here)
    if was_here then
      ui().toggle_panel()
    else
      ui().panel()
    end
  end)
end

-- --------------------------------------------------------- the agents

---A new session: the new-task screen (`<C-n>`, |paseo-new|), Local or a new
---worktree. On the Paseo tab it starts from the agent on screen -- its
---project, its provider.
function M.new()
  local new = require "paseo.new"
  local current = chat().current()
  if ui().on_tab() and current then
    pcall(vim.cmd.stopinsert)
    return new.open(new.context(current), { scope = "session" })
  end
  new.open(nil, { scope = "session" })
end

---A new agent IN the session of the chat you are in -- on the Paseo tab or
---in the sidebar: the `+` on the app's row of tabs. With no agent's chat to
---go by this is a new session, and says so (|paseo.new|.open).
function M.new_agent()
  local new = require "paseo.new"
  local current = chat().current()
  pcall(vim.cmd.stopinsert)
  if current and current.agent_id then
    return new.open(new.context(current), { scope = "agent" })
  end
  new.open(nil, { scope = "agent" })
end

---A new session, in a new worktree.
function M.worktree()
  require("paseo.new").open(nil, { scope = "session", where = "worktree" })
end

---The next buffer on the Paseo tab's row of agents and terminals, wrapping.
function M.next()
  on_tab(function()
    ui().cycle(1)
  end)
end

---The previous one.
function M.prev()
  on_tab(function()
    ui().cycle(-1)
  end)
end

---Interrupt the turn the agent on screen is running (`<C-c>`).
function M.stop()
  chat().stop()
end

-- ------------------------------------------------------------ the names

---What the `<Plug>(paseo-…)` names are made from. `arg` is the word after the action, if any.
---@type table<string, { run: fun(arg?: string), desc: string, args?: string[] }>
M.ACTIONS = {
  toggle = { run = M.toggle, desc = "in and out of the Paseo tab" },
  open = { run = M.open, desc = "onto the Paseo tab" },
  code = { run = M.code, desc = "back to your code" },
  close = { run = M.close, desc = "take the Paseo tab down" },
  rail = { run = M.toggle_rail, desc = "the workspace rail, on or off" },
  focus = { run = M.focus_rail, desc = "into the rail and back out" },
  panel = {
    run = function(arg)
      if arg and arg ~= "" then
        M.panel(arg)
      else
        M.toggle_panel()
      end
    end,
    desc = "the panel, on or off; or straight to one",
    args = vim.tbl_map(string.lower, M.PANELS),
  },
  new = { run = M.new, desc = "a new session" },
  ["new-agent"] = { run = M.new_agent, desc = "a new agent in the session on screen" },
  worktree = { run = M.worktree, desc = "a new session in a new worktree" },
  next = { run = M.next, desc = "the next agent or terminal" },
  prev = { run = M.prev, desc = "the previous agent or terminal" },
  stop = { run = M.stop, desc = "stop the turn" },
}

return M
