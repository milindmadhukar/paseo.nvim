--- Starting a terminal: a screen, not a prompt.
---
--- THE SCREEN IS THE PICKER. This was a `vim.ui.select` of labels, opened over
--- a surface that was itself an overlay -- so starting a terminal meant a list
--- with no highlighting and no notion of what each entry would actually run,
--- on top of a window on top of the editor. Every other choice in this plugin
--- -- the permission mode, the model, a whole new agent -- is a card you drive
--- with `h j k l` and `<CR>`, and this is the same renderer at a smaller size.
---
--- ONE GROUP, drawn as a RADIO rather than as chips. With a shell, three or
--- four live providers, whatever is in `ui.terminal.presets` and a free-text
--- escape hatch, there are too many to read as a chip row -- and a radio gives
--- each entry its own line and a note saying what it runs, which is the thing
--- that tells `claude` from `codex` from `lazygit`.

local icons = require "paseo.ui.icons"
local panel = require "paseo.ui.panels.settings"
local popup = require "paseo.ui.popup"
local render = require "paseo.ui.render"
local terminals = require "paseo.terminals"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---@type paseo.Popup|nil
local state

local XPAD = 2

function M.close()
  local held = state
  state = nil
  if held then
    held.close()
  end
end

---@return integer
local function width()
  return math.max(44, math.min(72, vim.o.columns - 8))
end

---Ask what to run, then run it.
---
---`callback` receives the new terminal's id. Nothing is started until you
---press `<CR>`: there is no Create card, because a card that is not a choice
---reads as one.
---@param opts { root: string, size?: { rows: integer, cols: integer } }
---@param callback? fun(id: string|nil, err: string|nil)
function M.open(opts, callback)
  callback = callback or function() end
  M.close()

  ---@type table[]|nil
  local presets

  local function start(preset)
    M.close()
    terminals.create(opts.root, preset, opts.size, function(id, err)
      if err then
        vim.notify("paseo: could not start a terminal — " .. err, vim.log.levels.ERROR)
      end
      callback(id, err)
    end)
  end

  local source = {
    keys = { command = "c" },
    groups = function()
      if not presets then
        return nil
      end
      local entries = {}
      for _, preset in ipairs(presets) do
        entries[#entries + 1] = {
          id = preset.label,
          label = preset.label,
          note = preset.note or preset.command,
          preset = preset,
        }
      end
      return {
        {
          id = "command",
          key = "c",
          icon = icons.panel.Terminals,
          label = "New terminal",
          kind = "radio",
          entries = entries,
          -- Nothing is "current": this is a choice about a thing that does not
          -- exist yet. `resolve` falls through to the first entry, which is
          -- the shell -- the one you want most of the time.
          current = nil,
          placeholder = "no providers reported, and no presets configured",
        },
      }
    end,
    apply = function(_, _, entry, done)
      local preset = entry.preset or {}
      if preset.prompt then
        -- The one thing a card grid genuinely cannot be is a free-text field.
        M.close()
        return vim.ui.input({ prompt = "Command: " }, function(command)
          if not command or vim.trim(command) == "" then
            return callback(nil, "cancelled")
          end
          start { command = command, label = command }
        end)
      end
      start(preset)
      done()
    end,
    load = function(_, done)
      terminals.presets(opts.root, function(found)
        presets = found
        vim.schedule(done)
      end)
    end,
  }

  local view = panel.new(source, {
    section = "session",
    hints = { { "q", "cancel" } },
    redraw = function()
      if state then
        state.rebuild()
      end
    end,
  })

  state = popup.open {
    view = view,
    width = width,
    -- Above the dashboard's 30, which is the whole reason the dashboard sits
    -- below the z-index a float gets by default.
    zindex = 60,
    title = function(handle)
      local inner = handle.w - (2 * XPAD)
      return {
        render.truncate(
          widgets.row(
            { { icons.panel.Terminals .. "  New terminal", "PaseoHeader" } },
            { { vim.fn.fnamemodify(opts.root, ":~"), "PaseoDim" } },
            inner,
            "PaseoNormal"
          ),
          inner
        ),
        { { string.rep("─", inner), "PaseoBorder" } },
        {},
      }
    end,
    on_close = function()
      state = nil
    end,
  }

  view:reload()
end

---@return boolean
function M.is_open()
  return state ~= nil and state.win ~= nil and api.nvim_win_is_valid(state.win)
end

return M
