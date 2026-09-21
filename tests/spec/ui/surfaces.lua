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
  -- never holds the cursor, because `show_agent_panes` enters the composer. So
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
  local chat_file = assert(io.open(vim.fs.joinpath(t.repo_root, "lua", "paseo", "ui", "chat.lua")))
  local chat_source = chat_file:read "*a"
  chat_file:close()
  local _, fork_maps = chat_source:gsub('desc = "paseo: fork into a new workspace"', "")
  eq("ui: f is mapped in both main chat buffers", fork_maps, 2)
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
    -- TEXT rows, which is the window's height less its BAR. The bar is a
    -- winbar -- inside the window, not around it -- carrying the session's
    -- model, mode and directory, and the microphone meter while you dictate;
    -- see |paseo.ui.composer|.
    local composer = function()
      return vim.api.nvim_win_get_height(surface_chat.win_composer) - 1
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

  -- A RE-FIT DOES NOT MOVE THE CURSOR. `WinResized` fires for any window on
  -- the tab page, and one of those windows is a modal of ours: the new-agent
  -- screen opens and then sizes itself to its content the moment the model's
  -- features arrive. The re-fit closed and reopened the panes, and
  -- `show_agent_panes` enters the composer -- so the screen that had just
  -- asked you a question lost the cursor, and the only way to answer it was
  -- to click it first.
  do
    float.open(surface_chat)
    local modal = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
      style = "minimal",
      zindex = 80,
    })

    float.relayout()
    eq("ui: nothing moved, so nothing is re-fitted", vim.api.nvim_get_current_win(), modal)
    truthy("ui: and the panes are the same windows", vim.api.nvim_win_is_valid(modal))

    -- The box really did change shape this time, so the panes ARE closed and
    -- reopened -- and the cursor still belongs to whoever had it. Cells rather
    -- than percentages, because both of these have to clear the floor
    -- `geometry` clamps to and a percentage of a 24-row test editor does not.
    local full = function(columns)
      return columns
    end
    local narrower = function(columns)
      return columns - 6
    end
    config.setup { ui = { float = { width = full } } }
    float.relayout()
    eq("ui: a real re-fit leaves the cursor where it was", vim.api.nvim_get_current_win(), modal)
    vim.api.nvim_win_close(modal, true)

    -- And when the composer was the one with the cursor, it is FOLLOWED to
    -- the window the re-fit gave it, rather than left behind on a closed one.
    vim.api.nvim_set_current_win(surface_chat.win_composer)
    local before = surface_chat.win_composer
    config.setup { ui = { float = { width = narrower } } }
    float.relayout()
    truthy("ui: a re-fit gives the composer a new window", surface_chat.win_composer ~= before)
    eq(
      "ui: which is where the cursor goes",
      vim.api.nvim_get_current_win(),
      surface_chat.win_composer
    )
    config.setup {}
    float.close()
  end

  float.open(surface_chat)

  -- FEATURE PARITY. The header used to be the conversation window's winbar,
  -- and the conversation window only exists on the Chat tab -- so every other
  -- tab had no header at all and the dashboard could not tell you which model
  -- it was on. It is a volt section in the chrome now.
  -- The agent-session list used to map CURSOR ROWS to sessions, and the only thing
  -- between a panel's own line numbering and the buffer's was a constant it
  -- had to agree with. It holds focus by ID now, so the thing worth checking
  -- against a REAL open dashboard is different: that the row reaches the
  -- chrome buffer at all, and that exactly one of them is lit.
  do
    local agents = require "paseo.agents"
    local old_for_root, old_watch = agents.for_root, agents.watch
    agents.watch = function() end
    agents.for_root = function()
      return {
        { id = "row-probe", title = "row-probe", status = "idle" },
        { id = "row-other", title = "row-other", status = "idle" },
      }
    end
    float.select "Agents & terminals"

    local chrome
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if require("volt.state")[buf] then
        chrome = buf
      end
    end

    local drawn, lit = {}, 0
    if chrome then
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chrome, -1, 0, -1, { details = true })) do
        local row, banded = {}, false
        for _, cell in ipairs(mark[4].virt_text or {}) do
          row[#row + 1] = cell[1]
          if cell[2] == "PaseoRowHover" then
            banded = true
          end
        end
        drawn[#drawn + 1] = table.concat(row)
        if banded then
          lit = lit + 1
        end
      end
    end
    local joined = table.concat(drawn, "\n")
    truthy(
      "ui: an agent-session row reaches the chrome buffer",
      joined:find("row-probe", 1, true) ~= nil,
      joined
    )

    -- THE BUG THIS TAB HAD. The keys were bound and the rows were reachable,
    -- and nothing on screen said which one you were on -- so it read as a tab
    -- you could only click. Arriving at it now lands focus on a row and paints
    -- it, without anyone having to move first.
    truthy("ui: and arriving on the tab lights exactly one of them", lit == 1, lit)
    local function bound(lhs)
      local found
      vim.api.nvim_buf_call(chrome, function()
        found = vim.fn.maparg(lhs, "n", false, true)
      end)
      return type(found) == "table" and found.buffer == 1
    end
    truthy("ui: the list takes the movement keys", chrome and bound "j")
    truthy("ui: and its per-row verbs", chrome and bound "d")

    -- THE ROW YOU ARCHIVED IS GONE BEFORE YOU MOVE. Both directories are
    -- push-fed, and the surface used to redraw for none of it: archiving a
    -- session left its row on screen until something else caused a repaint,
    -- which in practice was the next `j`. The data was right and the picture
    -- was a second-hand copy of it.
    ---@return string
    local function drawn_chrome()
      local out = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chrome, -1, 0, -1, { details = true })) do
        for _, cell in ipairs(mark[4].virt_text or {}) do
          out[#out + 1] = cell[1]
        end
      end
      return table.concat(out)
    end

    agents.for_root = function()
      return { { id = "row-other", title = "row-other", status = "idle" } }
    end
    -- What the daemon sends when an agent is archived -- verified against a
    -- live one, which emits `remove` three times for the same archive, which
    -- is why the repaint is coalesced rather than immediate.
    agents._apply { kind = "remove", id = "row-probe" }
    vim.wait(600, function()
      return drawn_chrome():find("row-probe", 1, true) == nil
    end, 20)
    truthy(
      "ui: an archived session leaves the list without anyone moving",
      drawn_chrome():find("row-probe", 1, true) == nil,
      drawn_chrome()
    )
    truthy(
      "ui: and the sessions that are still there stay",
      drawn_chrome():find("row-other", 1, true) ~= nil
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
    -- so an Agent panel that simply DELETED its own `<CR>` on the way out
    -- would leave the key dead on all five of the others.
    local function buf_map(lhs)
      local found = vim.fn.maparg(lhs, "n", false, true)
      return type(found) == "table" and found.buffer == 1 and found or nil
    end
    vim.api.nvim_set_current_buf(chrome_buf)

    local volt_cr = buf_map "<CR>"
    truthy("ui: volt binds <CR> on the chrome buffer", volt_cr ~= nil)
    eq("ui: and the Settings keys are not bound on another tab", buf_map "h", nil)

    float.select "Settings"
    truthy("ui: the Settings panel takes the movement keys", buf_map "h" ~= nil)
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

--- A terminal is a SESSION, shown on the Chat tab.
---
--- It used to be a surface of its own -- a rail, a title bar, a pane and a
--- backdrop, four windows over the top of whatever you were looking at, with
--- its own keymaps and its own geometry. The PTY half was always window-
--- agnostic; only the surface is gone.
local function test_terminal_session()
  local float = require "paseo.ui.float"
  local terminal = require "paseo.ui.terminal"
  local terminals = require "paseo.terminals"
  local agents = require "paseo.agents"
  local bridge = require "paseo.bridge"

  local saved = {
    ensure = bridge.ensure,
    request = bridge.request,
    on = bridge.on,
    watch = terminals.watch,
    ready = terminals.ready,
    for_root = terminals.for_root,
    get = terminals.get,
    summary = terminals.summary,
    awatch = agents.watch,
    afor_root = agents.for_root,
  }

  bridge.ensure = function(done)
    done(nil)
  end
  bridge.request = function(_, _, done)
    done(nil, {})
  end
  bridge.on = function() end
  terminals.watch = function() end
  terminals.ready = function()
    return true
  end
  terminals.for_root = function()
    return { { id = "t1", name = "lazygit" } }
  end
  terminals.get = function(id)
    return id == "t1" and { id = "t1", name = "lazygit" } or nil
  end
  terminals.summary = function()
    return "1 here"
  end
  agents.watch = function() end
  agents.for_root = function()
    return { { id = "a1", title = "main", status = "idle" } }
  end

  local chat = {
    root = vim.uv.cwd(),
    agent_id = "a1",
    provider = "test",
    pending = {},
    conversation = vim.api.nvim_create_buf(false, true),
    composer = vim.api.nvim_create_buf(false, true),
  }
  transcript.reset(chat)

  local wins_before = #vim.api.nvim_list_wins()
  local ok, err = pcall(function()
    float.open(chat)
    eq("terminal: a fresh dashboard is on its agent", float.session().kind, "agent")
    truthy("terminal: which has a composer", chat.win_composer ~= nil)

    float.show_session { kind = "terminal", id = "t1" }
    eq("terminal: showing one stays on the Chat tab", float.tab(), "Chat")
    eq("terminal: and the session is that terminal", float.session().id, "t1")

    -- A terminal has nothing to type INTO the way an agent does; it has the
    -- PTY. The composer is not hidden, it is gone.
    eq("terminal: a terminal session has no composer", chat.win_composer, nil)

    local view = terminal.view "t1"
    truthy("terminal: the PTY is attached", view ~= nil)
    local on_screen = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if view and vim.api.nvim_win_get_buf(win) == view.buf then
        on_screen = true
      end
    end
    truthy("terminal: and on screen", on_screen)

    -- The keys, in the PTY buffer. Bound in TERMINAL mode as well as normal,
    -- because a key you must press `<C-\><C-n>` to reach first is a key you
    -- do not reach -- and a bare digit is NOT bound, because `5` in a terminal
    -- costs you `50k` to scroll back.
    local function bound(lhs, mode)
      local found
      vim.api.nvim_buf_call(view.buf, function()
        found = vim.fn.maparg(lhs, mode, false, true)
      end)
      return type(found) == "table" and found.buffer == 1
    end
    truthy("terminal: <M-2> reaches a tab from normal mode", bound("<M-2>", "n"))
    truthy("terminal: and from inside the terminal", bound("<M-2>", "t"))
    truthy("terminal: <C-s> is the way out, in both", bound("<C-s>", "n") and bound("<C-s>", "t"))
    eq("terminal: a bare digit is left to the PTY", bound("2", "n"), false)
    eq("terminal: and so is <Esc>", bound("<Esc>", "t"), false)

    -- Back to the agent, and the composer comes back with it.
    float.show_session { kind = "agent", id = "a1" }
    eq("terminal: going back lands on the agent", float.session().kind, "agent")
    truthy("terminal: and the composer returns", chat.win_composer ~= nil)

    -- OPENING THE CHAT MEANS THE CONVERSATION, whatever the Chat tab was last
    -- left on. `state.session` outlives a trip through the panels, so `<C-s>`
    -- out of a terminal and the chat picked out of the session list came back
    -- to the Chat tab still pointed at the PTY: the screen did not change, and
    -- the key read as broken.
    float.show_session { kind = "terminal", id = "t1" }
    float.select "Agents & terminals"
    float.open(chat)
    eq("terminal: the session list is the way back to the chat", float.tab(), "Chat")
    eq("terminal: which is the agent, not the terminal", float.session().kind, "agent")
    truthy(
      "terminal: with its composer on screen",
      chat.win_composer ~= nil and vim.api.nvim_win_is_valid(chat.win_composer)
    )

    -- The same from the Chat tab itself, where there is no tab change to hang
    -- the rebuild off: the panes have to be swapped here or the PTY stays.
    float.show_session { kind = "terminal", id = "t1" }
    float.open(chat)
    eq(
      "terminal: and from the Chat tab, with no tab change to ride on",
      float.session().kind,
      "agent"
    )
    truthy(
      "terminal: the composer is back there too",
      chat.win_composer ~= nil and vim.api.nvim_win_is_valid(chat.win_composer)
    )

    -- THE ROW THAT SAYS WHERE YOU ARE, on every tab -- a terminal session has
    -- no header of its own and no transcript, so without it the dashboard
    -- could show a PTY with nothing naming it.
    float.show_session { kind = "terminal", id = "t1" }
    float.select "Usage"
    eq("terminal: the strip survives a tab change", float.session().id, "t1")

    ---The session strip, as `{ text = highlight }`. The header, the tab bar,
    ---the rule, then this -- except on the Chat tab, which has no header row:
    ---there the session's model, mode and directory are drawn on the bar over
    ---the composer instead, and everything below moves up a row.
    local function strip()
      local out = {}
      local buf = float.chrome_buf()
      local rows = require("paseo.ui.layout").rows(0, { header = float.tab() ~= "Chat" })
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if mark[2] + 1 == rows.strip then
          for _, cell in ipairs(mark[4].virt_text or {}) do
            local text = vim.trim(cell[1])
            if text ~= "" then
              out[text] = cell[2]
            end
          end
        end
      end
      return out
    end

    local on_terminal = strip()
    eq(
      "terminal: the strip lights the session you are in",
      on_terminal["󰆍 lazygit"],
      "PaseoChipFocus"
    )
    eq("terminal: and not the one you are not", on_terminal["󱙺 main"], "PaseoChipOff")

    float.show_session { kind = "agent", id = "a1" }
    local on_agent = strip()
    eq("terminal: and it follows you back", on_agent["󱙺 main"], "PaseoChipFocus")
    eq("terminal: leaving the terminal unlit", on_agent["󰆍 lazygit"], "PaseoChipOff")
  end)

  float.close()
  eq("terminal: closing takes the PTY window with it", #vim.api.nvim_list_wins(), wins_before)

  bridge.ensure, bridge.request, bridge.on = saved.ensure, saved.request, saved.on
  terminals.watch, terminals.ready = saved.watch, saved.ready
  terminals.for_root, terminals.get, terminals.summary = saved.for_root, saved.get, saved.summary
  agents.watch, agents.for_root = saved.awatch, saved.afor_root
  truthy("terminal: the session cases ran", ok, err)
end

--- The buffer mount: the same dashboard in a real window, on its own tab.
---
--- ASSERT ON `nvim_win_get_config`, NEVER ON SCREEN POSITION. Headless Neovim
--- does not re-anchor a win-relative float until something forces a full
--- redraw, so `win_screenpos` answers the float's stale coordinates and reads
--- as a bug that is not there. The config is exact the moment the window is
--- opened.
local function test_buffer_surface()
  local api = vim.api
  local float = require "paseo.ui.float"
  local layout = require "paseo.ui.layout"

  ---@return table
  local function new_chat()
    local chat = {
      root = vim.uv.cwd(),
      agent_id = "buffer-agent",
      provider = "test",
      streaming = false,
      pending = {},
      conversation = api.nvim_create_buf(false, true),
      composer = api.nvim_create_buf(false, true),
    }
    transcript.reset(chat)
    transcript.upsert(chat, { kind = "user", text = "hello" })
    return chat
  end

  -- The teardowns are scheduled -- `WinClosed` fires DURING the close, so
  -- `M.close` cannot run inline -- which means every assertion about them has
  -- to let the event loop turn first.
  local function settle()
    for _ = 1, 20 do
      vim.wait(10)
    end
  end

  ---@param buf integer
  ---@param key string
  ---@return boolean
  local function bound(buf, key)
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == key then
        return true
      end
    end
    return false
  end

  local tabs_before = #api.nvim_list_tabpages()
  local wins_before = #api.nvim_list_wins()

  local chat = new_chat()
  -- AFTER the chat, whose conversation and composer are not the surface's to
  -- collect: they belong to |paseo.ui.chat| and outlive every surface, which
  -- is what preserves your draft across a swap.
  local bufs_before = #api.nvim_list_bufs()
  float.open(chat, { mount = "buffer" })

  local chrome = float.chrome_buf()
  local host = api.nvim_win_get_config(chat.win_conversation).win

  eq("buffer: it opens on a tab page of its own", #api.nvim_list_tabpages(), tabs_before + 1)
  eq("buffer: holding nothing else", #api.nvim_tabpage_list_wins(0), 3)
  eq("buffer: and it knows which mount it is", float.mount(), "buffer")

  -- The nvim-tree half of the ask: a real window with a real buffer, carrying
  -- a name an `ftplugin/` can be hung off.
  eq("buffer: the chrome is a REAL window, not a float", api.nvim_win_get_config(host).relative, "")
  eq("buffer: with a filetype of its own", vim.bo[chrome].filetype, float.FILETYPE)
  eq("buffer: named for what it is", api.nvim_buf_get_name(chrome):match "dashboard", "dashboard")

  -- The two window options volt cannot be drawn in without. `wrap` would put
  -- every row below the first wrapped line one off its extmark; a gutter
  -- would offset the chrome text from the panes floated over it.
  eq("buffer: no wrap, so its rows are its lines", vim.wo[host].wrap, false)
  eq(
    "buffer: and no gutter, so its columns are the window's",
    vim.fn.getwininfo(host)[1].textoff,
    0
  )
  eq(
    "buffer: which is what lets the chrome fill the window exactly",
    api.nvim_buf_line_count(chrome),
    vim.fn.getwininfo(host)[1].height
  )

  -- The panes are anchored to the HOST, not to the editor -- which is what
  -- makes them follow it, and what puts them on its tab page rather than on
  -- whichever tab was current when a re-fit ran.
  local conversation = api.nvim_win_get_config(chat.win_conversation)
  local composer = api.nvim_win_get_config(chat.win_composer)
  eq("buffer: the conversation hangs off the host window", conversation.relative, "win")
  eq("buffer: so does the composer", composer.relative, "win")
  truthy("buffer: both off the SAME window", conversation.win == host and composer.win == host)

  -- THE REGRESSION GUARD FOR THE WHOLE DESIGN. `ui/layout.lua` needed no
  -- change for this mount because `g.row` carries the winbar row and `g.col`
  -- carries 'textoff' -- a win-relative float sits at the window's ORIGIN
  -- while volt draws from its TEXT AREA, and those two fields are exactly the
  -- difference. Anyone who "simplifies" either to a zero breaks the buffer
  -- mount alone, and only on a window with a gutter.
  local info = vim.fn.getwininfo(host)[1]
  local g = {
    row = 0,
    col = info.textoff,
    border = false,
    width = api.nvim_win_get_width(host) - info.textoff,
    height = info.height,
    composer = 7,
  }
  local panes = layout.panes(g, api.nvim_win_get_height(chat.win_composer))
  truthy(
    "buffer: and land exactly where layout.panes puts them",
    conversation.row == panes.top and conversation.col == panes.col
      and conversation.width == panes.width
  )

  eq("buffer: the cursor lands in the composer", api.nvim_get_current_buf(), chat.composer)
  truthy("buffer: q closes it, as nvim-tree does", bound(chrome, "q"))
  truthy(
    "buffer: but <Esc> does not -- it is a place you stand, not a thing in front of you",
    not bound(chrome, "<Esc>")
  )
  truthy("buffer: and <C-f> is not the swap here", not bound(chrome, "<C-F>"))

  -- A hint bar is the only place the surface says what its keys are, so one
  -- naming a key that does nothing is worse than a shorter bar.
  local footer = {}
  for _, mark in
    ipairs(api.nvim_buf_get_extmarks(chrome, -1, 0, -1, { details = true }))
  do
    for _, cell in ipairs(mark[4].virt_text or {}) do
      footer[#footer + 1] = cell[1]
    end
  end
  truthy(
    "buffer: and the footer does not advertise a swap it does not have",
    not table.concat(footer):find("<C%-f>")
  )

  float.select "Usage"
  float.select "Chat"
  truthy("buffer: a round trip through the panels leaves it open", float.is_open(chat))

  float.close()
  settle()
  eq("buffer: closing takes the tab page with it", #api.nvim_list_tabpages(), tabs_before)
  eq("buffer: leaving no windows behind", #api.nvim_list_wins(), wins_before)
  eq("buffer: nor buffers", #api.nvim_list_bufs(), bufs_before)

  -- THE DOOR THE FLOAT NEVER HAD. A window in the layout is closed by the
  -- user, and none of the ways they do it go anywhere near `M.close`.
  chat = new_chat()
  float.open(chat, { mount = "buffer" })
  api.nvim_set_current_win(api.nvim_win_get_config(chat.win_conversation).win)
  vim.cmd "q"
  settle()
  truthy("buffer: :q on the host takes the surface with it", float.chrome_buf() == nil)
  truthy(
    "buffer: panes and all",
    chat.win_composer == nil and chat.win_conversation == nil
  )
  eq("buffer: and the volt click handler stops dispatching at it", #require("volt.events").bufs, 0)
  eq("buffer: with the tab page gone too", #api.nvim_list_tabpages(), tabs_before)

  -- The case that makes the `WinClosed` handler load-bearing rather than
  -- tidy: with a second window on the dash tab, closing the host leaves the
  -- panes VALID, floating over what is left, anchored to a dead window id.
  chat = new_chat()
  float.open(chat, { mount = "buffer" })
  host = api.nvim_win_get_config(chat.win_conversation).win
  local stranded = { chat.win_conversation, chat.win_composer }
  api.nvim_set_current_win(host)
  vim.cmd "vsplit"
  vim.cmd "enew"
  api.nvim_win_close(host, true)
  settle()
  truthy(
    "buffer: closing the host on a split tab does not strand the panes",
    not api.nvim_win_is_valid(stranded[1]) and not api.nvim_win_is_valid(stranded[2])
  )
  truthy("buffer: and the surface knows it is gone", float.chrome_buf() == nil)
  vim.cmd "tabclose!"
  settle()

  -- A split on the dash tab is a resize, and a resize is the one thing a
  -- win-relative float does NOT follow on its own.
  chat = new_chat()
  float.open(chat, { mount = "buffer" })
  host = api.nvim_win_get_config(chat.win_conversation).win
  local wide = api.nvim_win_get_config(chat.win_conversation).width
  api.nvim_set_current_win(host)
  vim.cmd "vsplit"
  vim.cmd "enew"
  float.relayout()
  local narrow = api.nvim_win_get_config(chat.win_conversation)
  truthy("buffer: a split on its tab re-fits the panes", narrow.width < wide)
  eq("buffer: which stay anchored to the same host", narrow.win, host)

  -- A re-fit recreates the panes, and `show_agent_panes` ENTERS the composer
  -- -- which for a window on another tab page means switching to it. So a
  -- terminal resize while you worked in your code used to haul you over.
  vim.cmd "tabnew"
  local elsewhere = api.nvim_get_current_tabpage()
  float.relayout()
  eq(
    "buffer: a re-fit from another tab leaves you where you are",
    api.nvim_get_current_tabpage(),
    elsewhere
  )
  vim.cmd "tabclose"
  float.close()
  settle()

  -- `is_open` is tab-aware, and for a float that is right -- an invisible one
  -- is no use to you. A tab page is one `gt` away, and "open it" means go.
  chat = new_chat()
  float.open(chat, { mount = "buffer" })
  local dash_tab = api.nvim_get_current_tabpage()
  vim.cmd "tabnew"
  local tabs_now = #api.nvim_list_tabpages()
  float.open(chat, { mount = "buffer" })
  eq("buffer: reopening does not make a second dashboard", #api.nvim_list_tabpages(), tabs_now)
  eq("buffer: it goes to the one there is", api.nvim_get_current_tabpage(), dash_tab)

  -- And the two mounts swap rather than no-op on each other, which is what
  -- the `state.mount == mount` test in `M.open`'s fast path buys.
  float.open(chat, { mount = "float" })
  eq("buffer: :Paseo dash swaps a buffer surface for a float", float.mount(), "float")
  eq(
    "buffer: really a float",
    api.nvim_win_get_config(vim.fn.bufwinid(float.chrome_buf())).relative,
    "editor"
  )
  float.open(chat, { mount = "buffer" })
  eq("buffer: and :Paseo buf swaps back", float.mount(), "buffer")
  float.close()
  settle()
  while #api.nvim_list_tabpages() > tabs_before do
    vim.cmd "tabclose!"
  end

  -- The 10 Hz spinner drives `sidebar.refresh`, which used to ask the
  -- tab-aware `is_open` -- so with the dashboard on its own tab the answer
  -- was "no" and the fallback wrote a winbar onto the dashboard's OWN
  -- conversation pane. That pane's winbar is emptied deliberately, so the
  -- header was drawn twice and the pane lost a row, ten times a second.
  chat = new_chat()
  float.open(chat, { mount = "buffer" })
  local pane = chat.win_conversation
  vim.cmd "tabnew"
  require("paseo.ui.sidebar").refresh(chat)
  eq("buffer: the spinner repaints the chrome, not the pane's winbar", vim.wo[pane].winbar, "")
  vim.cmd "tabclose"
  float.close()
  settle()
  while #api.nvim_list_tabpages() > tabs_before do
    vim.cmd "tabclose!"
  end
end

return {
  { "ui.surfaces", test_surfaces },
  { "ui.terminal-session", test_terminal_session },
  { "ui.buffer-surface", test_buffer_surface },
}
