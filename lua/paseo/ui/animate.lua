--- Motion, under `ui.animate`.
---
--- THE CONSTRAINT, first, because it shapes everything here: volt records each
--- section's start row once, when the layout is measured in `gen_data`, and
--- never recomputes it on redraw. A section that grows or shrinks mid-flight
--- therefore draws every section BELOW it at the wrong row, and the failure
--- mode is an `Invalid 'line': out of range` thrown from inside `vim.on_key`.
--- `panels/session.lua` already reserves a description row for exactly this
--- reason.
---
--- So nothing in this file changes a height. A tween moves a number inside a
--- bar of fixed width; a flash swaps a highlight; a reveal draws fewer rows
--- into a block that was already the right size and fills the rest with
--- blanks. Every effect is a repaint of one named section, which is what makes
--- them cheap -- volt's extmarks are keyed `id = row`, so redrawing a section
--- overwrites its own rows in place with no clear and no flicker.
---
--- All of it is off when `ui.animate = false`, which normalises to every
--- effect false in `config.setup`. The spinner is NOT here and is never
--- disabled: a turn that is running has to look different from a turn that is
--- wedged, and that is information rather than decoration.

local M = {}

---Live effects, keyed by an arbitrary string the caller owns.
---@type table<string, { value: number, target: number, timer: uv.uv_timer_t?, until_: integer?, from: integer? }>
local live = {}

---@return table
local function settings()
  return require("paseo.config").get().ui.animate or {}
end

---@param effect string
---@return boolean
function M.enabled(effect)
  local on = settings()[effect]
  -- A surface that has not called `config.setup` yet still has to draw, and
  -- drawing it instantly is the safe default.
  return on == true
end

---@return integer
local function interval()
  return math.floor(1000 / math.max(1, settings().fps or 30))
end

---Stop and forget one effect.
---@param key string
function M.stop(key)
  local state = live[key]
  if not state then
    return
  end
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
  end
  live[key] = nil
end

---Stop everything. Called when a surface closes, so a timer cannot outlive
---the buffer it redraws -- which would be a redraw against an invalid buffer
---every frame, forever.
---@param prefix? string  Only keys starting with this.
function M.stop_all(prefix)
  -- Keys collected first, not iterated live: `stop` mutates `live`, and
  -- deep-copying it is not an option either -- every entry holds a `uv` timer,
  -- which is userdata and cannot be copied.
  local keys = {}
  for key in pairs(live) do
    if not prefix or key:sub(1, #prefix) == prefix then
      keys[#keys + 1] = key
    end
  end
  for _, key in ipairs(keys) do
    M.stop(key)
  end
end

---Ease a number towards a target, and return what to draw right now.
---
---Exponential rather than linear: a bar that covers most of the distance
---immediately and then settles reads as responsive, where a constant-rate one
---reads as slow at the start and abrupt at the end.
---@param o { key: string, buf: integer, section: string|string[], target: number, effect?: string }
---@return number
function M.tween(o)
  local target = o.target or 0

  if not M.enabled(o.effect or "bars") then
    M.stop(o.key)
    return target
  end

  local state = live[o.key]
  if not state then
    -- First sight of a value is not a transition. Animating from zero on the
    -- first draw makes every panel open by sweeping its bars up, which is a
    -- lot of motion to say nothing.
    live[o.key] = { value = target, target = target }
    return target
  end

  state.target = target

  -- Close enough. Half a percent is below the resolution of any bar we draw,
  -- so continuing would repaint without changing a cell.
  if math.abs(state.value - target) < 0.5 then
    state.value = target
    if state.timer then
      state.timer:stop()
    end
    return target
  end

  if not state.timer then
    state.timer = vim.uv.new_timer()
  end

  state.timer:stop()
  state.timer:start(
    interval(),
    interval(),
    vim.schedule_wrap(function()
      local current = live[o.key]
      if not current or not vim.api.nvim_buf_is_valid(o.buf) then
        M.stop(o.key)
        return
      end

      current.value = current.value + (current.target - current.value) * 0.28
      if math.abs(current.value - current.target) < 0.5 then
        current.value = current.target
        if current.timer then
          current.timer:stop()
        end
      end

      require("volt").redraw(o.buf, o.section)
    end)
  )

  return state.value
end

---How long a flash lasts, in milliseconds.
M.FLASH_MS = 420

---Start a flash: a tool card settling to ok or failed lights up, then fades.
---
---The fade is what the accent ramp bought us. Before there were four stops per
---accent there was nothing to fade THROUGH -- a flash could only be on or off,
---which is a blink rather than a settle.
---Start a repaint clock for `key`, running for `FLASH_MS`.
---
---Shared by `flash` and `reveal`, which are the same machine -- a start time
---and something that repaints while it runs -- differing only in what they
---read back out of it. Ungated: each caller checks its OWN setting, because
---`reveal` delegating to a gated `flash` meant turning flash off silently
---turned reveal off too.
---
---`on_frame` is how this works on a REAL buffer as well as a volt one. The
---transcript is ordinary buffer lines with extmarks over them, so there is no
---named section to repaint -- it redraws one block by id instead, and says so
---at the call site rather than having this file know about either.
---@param o { key: string, buf: integer, section?: string|string[], on_frame?: fun() }
---@return table
local function clock(o)
  M.stop(o.key)

  local state = { value = 0, target = 0, from = vim.uv.now(), timer = vim.uv.new_timer() }
  live[o.key] = state

  local function frame()
    if o.on_frame then
      return o.on_frame()
    end
    require("volt").redraw(o.buf, o.section)
  end

  state.timer:start(
    interval(),
    interval(),
    vim.schedule_wrap(function()
      if not live[o.key] or not vim.api.nvim_buf_is_valid(o.buf) then
        M.stop(o.key)
        return
      end
      -- Stopped BEFORE the last frame, so the final repaint is the settled
      -- one. Stopping after would leave the effect's last colour on screen
      -- until something else happened to redraw.
      if vim.uv.now() - state.from >= M.FLASH_MS then
        M.stop(o.key)
      end
      pcall(frame)
    end)
  )

  return state
end

---Flash: a tool card settling to ok or failed lights up, then goes.
---@param o { key: string, buf: integer, section?: string|string[], on_frame?: fun() }
function M.flash(o)
  if not M.enabled "flash" then
    return
  end
  clock(o)
end

---Which ramp stop a flashing thing should be drawn at, or nil when it is not
---flashing.
---
---0 is the accent at nearly full strength and 3 is nearly the background, so
---the flash starts bright and decays -- returning `nil` at the end puts the
---caller back on whatever it draws normally.
---@param key string
---@return integer|nil
function M.flash_stop(key)
  local state = live[key]
  if not (state and state.from) then
    return nil
  end

  local elapsed = vim.uv.now() - state.from
  if elapsed >= M.FLASH_MS then
    return nil
  end

  return math.min(3, math.floor((elapsed / M.FLASH_MS) * 4))
end

---How long a full reveal takes.
M.REVEAL_MS = 260

---Begin revealing a block of rows.
---@param o { key: string, buf: integer, section: string|string[] }
function M.reveal(o)
  if not M.enabled "reveal" then
    M.stop(o.key)
    return
  end
  clock(o).until_ = vim.uv.now() + M.REVEAL_MS
end

---How many of `total` rows should be drawn this frame.
---
---The caller pads the remainder with BLANK rows rather than dropping them: the
---block keeps its height throughout, which is the constraint at the top of
---this file.
---@param key string
---@param total integer
---@return integer
function M.revealed(key, total)
  local state = live[key]
  if not (state and state.until_) then
    return total
  end

  local remaining = state.until_ - vim.uv.now()
  if remaining <= 0 then
    return total
  end

  local done = 1 - (remaining / M.REVEAL_MS)
  return math.max(1, math.min(total, math.ceil(done * total)))
end

return M
