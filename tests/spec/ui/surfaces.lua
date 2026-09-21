--- The float: opening it, closing it, and its chrome.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local transcript = require "paseo.ui.transcript"

local function test_surfaces()
  -- --------------------------------------------------------------- surfaces

  -- Opening and closing the float must leave nothing behind. The regression:
  -- `close()` set its state to nil before the helper that closes the
  -- conversation and composer floats read it, so two windows survived every
  -- close and stacked up across the session.
  local float = require "paseo.ui.float"
  local surface_chat = {
    root = vim.uv.cwd(),
    agent_id = "test-agent",
    provider = "test",
    streaming = false,
    pending = {},
    conversation = vim.api.nvim_create_buf(false, true),
    composer = vim.api.nvim_create_buf(false, true),
  }
  transcript.reset(surface_chat)
  transcript.upsert(surface_chat, { kind = "user", text = "hello" })

  local wins_before = #vim.api.nvim_list_wins()
  local bufs_before = #vim.api.nvim_list_bufs()
  for _ = 1, 3 do
    float.open(surface_chat)
    float.select "Usage"
    float.select "Chat"
    float.close()
  end
  eq("ui: the float leaves no windows behind", #vim.api.nvim_list_wins(), wins_before)
  eq("ui: the float leaves no buffers behind", #vim.api.nvim_list_bufs(), bufs_before)

  -- THE "1-5 JUMP DOES NOT WORK" BUG. The tab keys were mapped on the chrome
  -- buffer alone, and on the Chat tab -- the tab it opens on -- the chrome
  -- never holds the cursor, because `show_chat_panes` enters the composer. So
  -- every one of those keystrokes went to a buffer with no such mapping, while
  -- the footer advertised them.
  ---@param buf integer
  ---@param key string
  local function mapping(buf, key)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == key then
        return m.desc or "(no desc)"
      end
    end
    return nil
  end

  float.open(surface_chat)
  eq("ui: the cursor lands in the composer", vim.api.nvim_get_current_buf(), surface_chat.composer)
  truthy(
    "ui: so the tab keys are bound THERE, not only on the chrome",
    mapping(surface_chat.composer, "1") ~= nil and mapping(surface_chat.composer, "5") ~= nil
  )
  truthy(
    "ui: and on the conversation, which is the other pane you read from",
    mapping(surface_chat.conversation, "5") ~= nil
  )
  -- Pressed where the cursor actually is.
  vim.api.nvim_feedkeys("5", "x", false)
  eq("ui: pressing 5 in the composer jumps to the fifth tab", float.tab(), float.TABS[5])
  vim.api.nvim_feedkeys("1", "x", false)
  eq("ui: and 1 comes back to the conversation", float.tab(), "Chat")

  -- The conversation keeps its own `<Tab>`, which expands a tool card to show
  -- what the command printed. That is worth more there than a second way to
  -- cycle tabs, and `1`-`6` reach every tab from the conversation anyway.
  truthy(
    "ui: the float does not take <Tab> from the conversation",
    mapping(surface_chat.conversation, "<Tab>") ~= "paseo: next tab",
    mapping(surface_chat.conversation, "<Tab>")
  )
  eq(
    "ui: but the composer, which had no <Tab>, cycles with it",
    mapping(surface_chat.composer, "<Tab>"),
    "paseo: next tab"
  )

  -- These are buffers you KEEP -- the sidebar shows the same two -- so a
  -- mapping left behind would go on swallowing digits with no dashboard open.
  float.close()
  truthy(
    "ui: closing the float gives the composer its digits back",
    mapping(surface_chat.composer, "1") == nil and mapping(surface_chat.composer, "<Tab>") == nil
  )
  truthy("ui: and the conversation's", mapping(surface_chat.conversation, "1") == nil)

  -- Z-INDEX. The surface used to sit at 100, above the 50 that `nvim_open_win`
  -- and plenary's popup hand out by default -- so every telescope picker and
  -- `vim.ui.select` opened FROM the dashboard rendered underneath it, and
  -- looked like nothing had happened.
  float.open(surface_chat)
  local highest = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local win_config = vim.api.nvim_win_get_config(win)
    if win_config.relative ~= "" then
      highest = math.max(highest, win_config.zindex or 0)
    end
  end
  truthy(
    "ui: the dashboard stacks below a default float, so pickers open on top",
    highest < 50,
    highest
  )
  float.close()

  -- GEOMETRY IS CONFIGURABLE, and the box is the whole reason: a margin in
  -- cells that looks right on a 200-column monitor is most of a laptop screen,
  -- and someone whose terminal float is already a known size wants this one to
  -- match it rather than to be near it.
  local config = require "paseo.config"
  ---@return table
  local function box()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local win_config = vim.api.nvim_win_get_config(win)
      if win_config.relative ~= "" and win_config.zindex == config.get().ui.float.zindex then
        return win_config
      end
    end
    return {}
  end

  -- THE UNIT IS A PERCENTAGE, 1-100. Fractions were the first attempt: `0.92`
  -- and `92` are each obvious once you know which convention you are in, and
  -- nothing on the page tells you which. floaterm's `size` is percentages, so
  -- percentages are what a number copied between the two configs means.
  config.setup { ui = { float = { width = 50, height = 50 } } }
  float.open(surface_chat)
  local half = box()
  eq("ui: a number is a percentage of the editor", {
    half.width,
    half.height,
  }, {
    math.max(60, math.floor(vim.o.columns * 50 / 100)),
    math.max(20, math.floor(vim.o.lines * 50 / 100)),
  })
  eq("ui: and with no row/col it centres", {
    half.row,
    half.col,
  }, {
    math.floor((vim.o.lines - half.height) / 2),
    math.floor((vim.o.columns - half.width) / 2),
  })
  float.close()

  -- The same arithmetic, in the same order, as floaterm's -- so the two agree
  -- to the cell rather than to within a rounding error, and a config that
  -- gives them one size gets them one place.
  local floaterm_h = math.floor(vim.o.lines * (90 / 100))
  local floaterm_w = math.floor(vim.o.columns * (92 / 100))
  config.setup { ui = { float = { width = 92, height = 90 } } }
  float.open(surface_chat)
  local matched = box()
  eq("ui: a percentage matches floaterm's, box and position", {
    matched.width,
    matched.height,
    matched.row,
    matched.col,
  }, {
    floaterm_w,
    floaterm_h,
    math.floor(vim.o.lines / 2 - floaterm_h / 2),
    math.floor(vim.o.columns / 2 - floaterm_w / 2),
  })
  float.close()

  -- `row`/`col` are CELLS: they are window coordinates, not sizes. A function
  -- is the escape hatch for a size no percentage can express, and returns
  -- cells too. Neither may put the border off screen.
  config.setup {
    ui = {
      float = {
        width = function(columns)
          return columns
        end,
        height = 100,
        row = -5,
        col = 9999,
      },
    },
  }
  float.open(surface_chat)
  local pinned = box()
  eq("ui: a function returns cells, row/col are cells, and both are clamped", {
    pinned.width,
    pinned.height,
    pinned.row,
    pinned.col,
  }, { vim.o.columns, vim.o.lines, 0, 0 })
  float.close()

  -- The composer is measured from the bottom, and the conversation gets what
  -- is left -- so a composer taller than the box would hand the conversation a
  -- negative height rather than merely looking wrong.
  config.setup { ui = { float = { composer = 999 } } }
  float.open(surface_chat)
  local squeezed = vim.api.nvim_win_get_config(surface_chat.win_conversation)
  truthy(
    "ui: an absurd composer height still leaves the conversation a window",
    squeezed.height >= 5,
    squeezed.height
  )
  float.close()
  config.setup {}

  -- THE COMPOSER GROWS WITH THE PROMPT. Standing at its full configured height
  -- over an empty buffer made it the largest and emptiest shape on the screen
  -- -- seven rows of flat card colour, none of it saying anything.
  do
    float.open(surface_chat)
    local composer = function()
      return vim.api.nvim_win_get_height(surface_chat.win_composer)
    end
    local conversation = function()
      return vim.api.nvim_win_get_height(surface_chat.win_conversation)
    end

    ---@param lines string[]
    local function typed(lines)
      vim.api.nvim_buf_set_lines(surface_chat.composer, 0, -1, false, lines)
      float.resize_composer(surface_chat)
    end

    typed { "" }
    local empty, roomy = composer(), conversation()
    eq("ui: an empty composer is one row", empty, 1)

    typed { "a", "b", "c" }
    eq("ui: three lines make it three", composer(), 3)
    eq("ui: and the conversation gives up exactly those rows", conversation(), roomy - 2)

    -- `wrap` is on, so asking the buffer for its line count says one and the
    -- box would stay a single row with the cursor off the bottom of it.
    typed { string.rep("x", vim.o.columns * 2) }
    truthy("ui: a wrapped line counts the rows it OCCUPIES", composer() > 1, composer())

    -- The configured height is the ceiling, not the resting state.
    typed { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" }
    eq("ui: and it never grows past ui.float.composer", composer(), 7)

    typed { "" }
    eq("ui: sending shrinks it back", composer(), empty)
    eq("ui: and the conversation gets its rows back", conversation(), roomy)
    float.close()
  end

  float.open(surface_chat)

  -- FEATURE PARITY. The header used to be the conversation window's winbar,
  -- and the conversation window only exists on the Chat tab -- so every other
  -- tab had no header at all and the dashboard could not tell you which model
  -- it was on. It is a volt section in the chrome now.
  -- The Sessions tab maps CURSOR ROWS to sessions, and the only thing between
  -- a panel's own line numbering and the buffer's is `body_row_offset`. It is
  -- a constant, so it is checked against a real open dashboard rather than
  -- against itself -- the panel this replaced hardcoded the same sum and was
  -- wrong about it.
  do
    local agents = require "paseo.agents"
    local old_for_root, old_watch = agents.for_root, agents.watch
    agents.watch = function() end
    agents.for_root = function()
      return { { id = "row-probe", title = "row-probe", status = "idle" } }
    end
    float.select "Sessions"
    local probe
    for line, row in pairs(require("paseo.ui.panels.sessions")._rows) do
      if row.id == "row-probe" then
        probe = line
      end
    end
    local chrome
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if require("volt.state")[buf] then
        chrome = buf
      end
    end
    local on_that_row = ""
    if chrome and probe then
      local marks = vim.api.nvim_buf_get_extmarks(
        chrome,
        -1,
        { probe - 1, 0 },
        { probe - 1, -1 },
        { details = true }
      )
      local parts = {}
      for _, mark in ipairs(marks) do
        for _, cell in ipairs(mark[4].virt_text or {}) do
          parts[#parts + 1] = cell[1]
        end
      end
      on_that_row = table.concat(parts)
    end
    truthy(
      "ui: a Sessions row is on the buffer line its map claims",
      on_that_row:find("row-probe", 1, true) ~= nil,
      ("row %s holds %q"):format(tostring(probe), on_that_row)
    )
    agents.for_root, agents.watch = old_for_root, old_watch
  end

  float.select "Usage"
  eq("ui: the panels do not keep a conversation window", surface_chat.win_conversation, nil)
  local chrome_buf
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    -- volt is a HARD dependency now -- there is no plain-text fallback behind
    -- the chrome any more -- so this is a lookup, not a probe.
    if require("volt.state")[buf] then
      chrome_buf = buf
    end
  end
  truthy("ui: the dashboard chrome is a volt buffer", chrome_buf ~= nil)
  if chrome_buf then
    local marks = vim.api.nvim_buf_get_extmarks(
      chrome_buf,
      -1,
      { 0, 0 },
      { 1, -1 },
      { details = true }
    )
    local drawn = {}
    for _, mark in ipairs(marks) do
      for _, cell in ipairs(mark[4].virt_text or {}) do
        drawn[#drawn + 1] = cell[1]
      end
    end
    drawn = table.concat(drawn)
    truthy(
      "ui: the header is drawn in the chrome, so it survives leaving the Chat tab",
      drawn:find("test", 1, true) ~= nil,
      drawn
    )
    -- Every tab's NUMBER, at every width. The bar degrades from name+icon to
    -- name, to icon, to bare number as the terminal narrows, and the number is
    -- the one thing it must never drop -- it is the only place that says which
    -- key goes where, and the tab that would fall off the end is always the
    -- last one, which is the one you had not discovered yet.
    local unnumbered = {}
    for i = 1, #require("paseo.ui.float").TABS do
      if not drawn:find(" " .. i .. " ", 1, true) then
        unnumbered[#unnumbered + 1] = i
      end
    end
    eq("ui: every tab keeps its number however narrow the bar gets", unnumbered, {}, drawn)

    -- Clicking a tab is the other half of "1-5 jump": volt dispatches a click
    -- through the cell's third element, and `volt.events.enable` -- which this
    -- surface never called, because it drives gen_data/redraw itself rather
    -- than going through `volt.run` -- is what routes LeftMouse to it.
    local targets = 0
    for _, row in pairs(require("volt.state")[chrome_buf].clickables) do
      targets = targets + #row
    end
    truthy("ui: the tab bar and header carry click targets", targets >= #float.TABS, targets)
    truthy("ui: and volt's mouse dispatch is switched on", vim.g.extmarks_events == true)

    -- The six panels SHARE the chrome buffer, so a panel that binds keys has
    -- to give them back. `<CR>` is the one that matters: volt binds it at open
    -- and that is how every other panel's rows are reached from the keyboard,
    -- so a Session panel that simply DELETED its own `<CR>` on the way out
    -- would leave the key dead on all five of the others.
    local function buf_map(lhs)
      local found = vim.fn.maparg(lhs, "n", false, true)
      return type(found) == "table" and found.buffer == 1 and found or nil
    end
    vim.api.nvim_set_current_buf(chrome_buf)

    local volt_cr = buf_map "<CR>"
    truthy("ui: volt binds <CR> on the chrome buffer", volt_cr ~= nil)
    eq("ui: and the Session keys are not bound on another tab", buf_map "h", nil)

    float.select "Session"
    truthy("ui: the Session panel takes the movement keys", buf_map "h" ~= nil)
    truthy("ui: and its group mnemonics", buf_map "s" ~= nil)
    truthy("ui: and displaces volt's <CR>", buf_map("<CR>").callback ~= volt_cr.callback)

    float.select "Usage"
    eq("ui: leaving gives the movement keys back", buf_map "h", nil)
    eq("ui: and the mnemonics", buf_map "s", nil)
    eq(
      "ui: and RESTORES volt's <CR> rather than deleting it",
      buf_map("<CR>").callback,
      volt_cr.callback
    )
  end
  float.close()

  -- Volt keys its state by buffer and never clears it; ours must.
  local entries = 0
  for _ in pairs(require "volt.state") do
    entries = entries + 1
  end
  eq("ui: the float clears its volt state", entries, 0)
  eq("ui: and takes its buffer off volt's key handler", #require("volt.events").bufs, 0)

  -- The session panel replaces four separate `vim.ui.select` prompts, so its
  -- rows have to be actionable -- a read-only list of settings you still have
  -- to leave the panel to change would be worse than the prompts.
end

return {
  { "ui.surfaces", test_surfaces },
}
