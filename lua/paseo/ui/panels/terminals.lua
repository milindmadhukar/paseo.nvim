--- The terminals in this workspace, live.
---
--- Paseo runs terminals as well as agents, and until now this plugin could see
--- only half of that: the `claude` and `codex` sessions you started in the app
--- were PTYs on the daemon with no route into Neovim at all. A row here opens
--- the real thing -- see |paseo.ui.terminal| -- rather than a rendering of it.
---
--- Fed by push from |paseo.terminals|, the same way the Sessions panel is fed
--- by |paseo.agents|, so the activity column says which terminal is waiting on
--- you without polling any of them.

local layout = require "paseo.ui.layout"
local widgets = require "paseo.ui.widgets"
local terminals = require "paseo.terminals"

local M = {}

M.title = "Terminals"

---Where a terminal draws, inside the dashboard body.
---
---Rows this panel draws before its first terminal: a heading and a blank.
local HEADING = 2

---Where a terminal opened from here is floated: over the body, and over the
---body only, so the chrome and the footer stay readable behind it.
---@return table|nil
local function body_geometry()
  local float = require "paseo.ui.float"
  local g = float.geometry_of()
  if not g then
    return nil
  end
  local rows = layout.rows(g.height)
  return {
    row = layout.screen_row(g, rows.body_first),
    col = g.col + 2,
    width = g.width - 4,
    -- One row short of the body, so the composer's border is never covered.
    height = math.max(5, rows.body_height - 1),
    zindex = g.z_panes,
  }
end

---@param id string
local function open_terminal(id)
  local geometry = body_geometry()
  if not geometry then
    return
  end
  require("paseo.ui.terminal").open_id(id, geometry)
end

---Start a terminal in this workspace.
---@param chat table
---@param command string|nil
function M.create(chat, command)
  local bridge = require "paseo.bridge"
  bridge.request(
    "terminals.create",
    { cwd = chat.root, command = command, name = command },
    function(err, result)
      vim.schedule(function()
        if err then
          vim.notify(
            "paseo: could not start a terminal — " .. tostring(err),
            vim.log.levels.ERROR
          )
          return
        end
        local terminal = result and result.terminal
        -- Straight into it. You did not ask for a row in a list; you asked for
        -- a terminal.
        if terminal and terminal.id then
          open_terminal(terminal.id)
        end
      end)
    end
  )
end

---@param chat table
---@param id string
local function kill(chat, id)
  local terminal = terminals.get(id)
  local name = terminal and (terminal.title or terminal.name) or id
  -- Killing a terminal kills whatever is running in it, and "whatever" is
  -- routinely an agent mid-turn. Asked rather than assumed.
  vim.ui.select({ "no", "yes" }, { prompt = ("Kill %s?"):format(name) }, function(choice)
    if choice ~= "yes" then
      return
    end
    local view = require("paseo.ui.terminal").current()
    if view and view.id == id then
      require("paseo.ui.terminal").close()
    end
    require("paseo.bridge").request("terminals.kill", { terminalId = id }, function(err)
      if err then
        vim.schedule(function()
          vim.notify("paseo: could not kill it — " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end)
  end)
end

---@param id string
local function rename(id)
  local terminal = terminals.get(id)
  vim.ui.input(
    { prompt = "Name: ", default = terminal and (terminal.title or terminal.name) or "" },
    function(title)
      if not title or vim.trim(title) == "" then
        return
      end
      require("paseo.bridge").request(
        "terminals.rename",
        { terminalId = id, title = title },
        function() end
      )
    end
  )
end

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  -- Same reason as the Sessions panel: the list is push-fed, and without a
  -- subscription an empty table reads as "no terminals" on a workspace with
  -- three running.
  terminals.watch(chat.root)
  local list = terminals.for_root(chat.root)

  local lines = {
    { { "  Terminals in ", "PaseoHeader" }, { vim.fn.fnamemodify(chat.root, ":~"), "PaseoDim" } },
    {},
  }

  if #list == 0 then
    lines[#lines + 1] = {
      { "  ", "PaseoDim" },
      { terminals.ready(chat.root) and "no terminals here yet" or "loading…", "PaseoDim" },
    }
  end

  for _, terminal in ipairs(list) do
    local glyph = terminals.glyph(terminal)
    local click = function()
      open_terminal(terminal.id)
    end
    local reason = terminal.activity and terminal.activity.attentionReason
    local id = "terminals." .. terminal.id
    local action = widgets.hover(id, "body", click)
    local row = {
      { "    " },
      { glyph[1] .. " ", glyph[2] },
      { terminal.title or terminal.name or terminal.id, nil },
      { reason == "needs_input" and "   needs input" or "", "PaseoDanger" },
      { reason == "finished" and "   finished" or "", "PaseoDim" },
    }

    local row_hl = widgets.row_hl(id)
    if row_hl then
      lines[#lines + 1] = widgets.fill_row(row, width, row_hl, action)
    else
      for _, cell in ipairs(row) do
        cell[3] = action
      end
      lines[#lines + 1] = row
    end
  end

  lines[#lines + 1] = {}
  -- Through the one hint builder, so these keys are drawn as caps like every
  -- other key in the plugin -- and spelled the way a keyboard spells them.
  local hints = { { "  " } }
  vim.list_extend(
    hints,
    widgets.hints {
      { "<CR>", "open" },
      { "c", "new" },
      { "r", "rename" },
      { "d", "kill" },
    }
  )
  lines[#lines + 1] = hints
  return lines
end

---The row the cursor is on, as a terminal id.
---
---The list starts at body row 3, which is buffer line 6: header, tab bar,
---rule, then this panel's own heading and its blank line.
---@param chat table
---@return string|nil
local function under_cursor(chat)
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local list = terminals.for_root(chat.root)
  -- HEADING rows before the first item, named rather than folded into a
  -- constant: this used to be a bare `row - 5`, and the 5 was the chrome's
  -- three rows plus this panel's two, with nothing saying so.
  local at = layout.item_at(row, HEADING)
  local terminal = at and list[at]
  return terminal and terminal.id or nil
end

---The keys this panel binds, in the order `detach` takes them back.
local KEYS = { "<CR>", "c", "r", "d" }

---Arriving on this tab. Part of the panel contract in |paseo.ui.float|.
---
---The mouse already works -- every cell carries a click action, which is
---volt's own convention -- but reaching for the mouse to open a terminal in a
---text editor is not the deal. These are the keyboard half.
---@param chat table
---@param buf integer
function M.attach(chat, buf)
  local map = function(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", function()
    local id = under_cursor(chat)
    if id then
      open_terminal(id)
    end
  end, "paseo: open this terminal")
  map("c", function()
    vim.ui.input({ prompt = "Command (blank for a shell): " }, function(command)
      M.create(chat, command and vim.trim(command) ~= "" and command or nil)
    end)
  end, "paseo: new terminal")
  map("r", function()
    local id = under_cursor(chat)
    if id then
      rename(id)
    end
  end, "paseo: rename this terminal")
  map("d", function()
    local id = under_cursor(chat)
    if id then
      kill(chat, id)
    end
  end, "paseo: kill this terminal")
end

---Leaving it again: the keys go back, and so does the PTY.
---
---The panels share one chrome buffer, so `d` left bound here would kill
---terminals from the Changes tab. And a terminal window left floating would
---hover over whatever you switched to.
---@param _chat table
---@param buf integer
function M.detach(_chat, buf)
  require("paseo.ui.terminal").close()
  for _, key in ipairs(KEYS) do
    pcall(vim.keymap.del, "n", key, { buffer = buf })
  end
end

---@param chat table
function M.load(chat)
  terminals.watch(chat.root, function()
    vim.schedule(function()
      require("paseo.ui.float").rebuild()
    end)
  end)
end

return M
