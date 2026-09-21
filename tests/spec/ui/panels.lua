--- The session panel, the settings popup and the sidebar that host it.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local render = require "paseo.ui.render"
local config = require "paseo.config"
local float = require "paseo.ui.float"
local session = require "paseo.ui.session"
local session_panel = require "paseo.ui.panels.session"
local widgets = require "paseo.ui.widgets"
local transcript = require "paseo.ui.transcript"

---A chat with buffers and no windows, which is all any of these open onto.
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

local function test_session_source()
  -- The session panel replaces four separate `vim.ui.select` prompts, so its
  -- rows have to be actionable -- a read-only list of settings you still have
  -- to leave the panel to change would be worse than the prompts.

  surface_chat.config_snapshot = {
    model = "opus",
    modeId = "default",
    thinkingOptionId = "low",
    availableModes = {
      { id = "plan", label = "Plan" },
      { id = "default", label = "Always ask" },
      { id = "bypassPermissions", label = "Bypass" },
    },
    thinkingOptions = { { id = "low", label = "Think", isDefault = true } },
    models = { { id = "opus", label = "Opus 5" }, { id = "sonnet", label = "Sonnet 5" } },
    features = { { id = "fast_mode", label = "Fast mode", type = "toggle", value = true } },
  }

  -- The daemon reports four lists that agree about nothing. One shape out, or
  -- the renderer has to know which group it is drawing.
  local groups = session.groups(surface_chat)
  eq("session: four groups come back", #groups, 4)
  local by_id = {}
  for _, group in ipairs(groups) do
    by_id[group.id] = group
  end
  eq("session: the mode group knows what is set", by_id.mode.current, "default")
  eq("session: the model group does too", by_id.model.current, "opus")
  eq("session: a toggle keeps its value", by_id.features.entries[1].value, true)
  eq("session: a default is noted", by_id.thinking.entries[1].note, "default")
  -- The one that matters: `bypassPermissions` cannot look like `plan`.
  eq("session: bypassing permissions is drawn as danger", by_id.mode.entries[3].tone, "danger")
  eq("session: and planning is not", by_id.mode.entries[1].tone, nil)

  local clickable = 0
  for _, line in ipairs(session_panel.lines(surface_chat, 80)) do
    for _, cell in ipairs(line) do
      -- A table, not a function: the cells carry `{ click = …, hover = … }`
      -- now, because hover has to paint a chip the same way focus does.
      if type(cell[3]) == "table" and type(cell[3].click) == "function" then
        clickable = clickable + 1
      end
    end
  end
  truthy("ui: the session panel's rows carry click actions", clickable >= 6)

  -- A card one cell narrower than its neighbour is instantly visible in a
  -- two-column layout, and `render.card` -- the older one -- had exactly that
  -- class of off-by-one in its header budget.
  local card = widgets.card {
    title = "Permission mode",
    icon = "",
    w = 40,
    lines = { { { "short" } }, { { string.rep("x", 90) } } },
  }
  local ragged = nil
  for i, line in ipairs(card) do
    if render.width(line) ~= 40 then
      ragged = ("row %d is %d wide"):format(i, render.width(line))
    end
  end
  eq("ui: every row of a card is exactly its width", ragged, nil)

  -- volt's `hpad` expands a cell whose text is the literal `_pad_`, and
  -- `line_w` skips it when measuring -- but `render.width` counts it as five
  -- columns of text. So the order is hpad THEN truncate, never the reverse,
  -- and `widgets.row` resolves the sentinel before returning.
  -- Every glyph in the registry has to BE something, and the check has to walk
  -- the WHOLE registry rather than the four markers it used to.
  --
  -- This has now happened twice. `check_on`/`check_off` were empty strings --
  -- the codepoints had been lost out of the file -- so the Session panel's
  -- feature toggles drew no marker at all and "off" was indistinguishable from
  -- "not drawn". That got fixed, and a test was added covering exactly those
  -- four names; meanwhile six slots in `render.icons`, the `permission` marker
  -- in the Sessions panel, two group icons and five inline glyphs elsewhere
  -- were empty the entire time, and the suite stayed green.
  --
  -- An empty icon is not a visible failure: the line still draws. So the check
  -- is width, over everything, with no list to keep in step.
  local registry = require "paseo.ui.icons"
  local blank = {}
  for name, glyph in pairs(registry.all()) do
    if vim.api.nvim_strwidth(glyph) < 1 then
      blank[#blank + 1] = name
    end
  end
  table.sort(blank)
  eq("ui: no glyph in the registry is empty", blank, {})

  -- The two selection markers additionally have to be exactly ONE cell. They
  -- are drawn in fixed-width rows, and a two-cell marker shifts everything to
  -- its right by a column on precisely the rows that are selected.
  for _, name in ipairs { "check_on", "check_off", "radio_on", "radio_off" } do
    eq(
      "ui: the " .. name .. " marker is exactly one cell",
      vim.api.nvim_strwidth(widgets.icons[name] or ""),
      1
    )
  end

  -- A key is spelled the way a keyboard spells it, and anything unrecognised
  -- comes back UNCHANGED rather than empty -- a hint bar that silently drops
  -- the key it is describing is worse than one that prints `<Plug>foo`.
  eq("ui: a chord is spelled out", registry.spell "<C-f>", "Ctrl + f")
  eq("ui: a bare key is left alone", registry.spell "q", "q")
  eq("ui: an unknown special key survives", registry.spell "<Plug>foo", "<Plug>foo")
end

local function test_panels()
  -- --------------------------------------------------------------- widgets

  local justified = widgets.row({ { "left" } }, { { "right" } }, 30)
  eq("ui: a justified row lands on its width", render.width(justified), 30)
  for _, cell in ipairs(justified) do
    truthy("ui: and leaves no _pad_ sentinel behind", cell[1] ~= "_pad_")
  end

  -- Keyboard, not just mouse: the panel used to have no mappings at all, so
  -- the only way to change a setting was to aim at it.
  local view = session_panel.new(require("paseo.ui.session").source(surface_chat))
  local _, focused = view:resolve()
  eq("session: focus starts on what is set", focused.id, "default")
  view:move(1)
  local _, after = view:resolve()
  eq("session: and moves on to the next entry", after.id, "bypassPermissions")
  view:jump "s"
  local jumped_group, jumped = view:resolve()
  eq("session: a mnemonic jumps to its group", jumped_group.id, "model")
  eq("session: landing on what that group has set", jumped.id, "opus")
  -- Running off the end of a group lands on the NEXT GROUP rather than
  -- wrapping inside itself, so `j` means "the next thing" everywhere and
  -- there is one traversal rather than one per card. `m` lands on the
  -- selected mode, which is the second of three; two steps back is one step
  -- past the top.
  view:jump "m"
  view:move(-1)
  view:move(-1)
  local wrapped_group, wrapped = view:resolve()
  eq("session: stepping off the top lands in the last group", wrapped_group.id, "model")
  eq("session: on its last entry", wrapped.id, "sonnet")

  -- `maparg` reads the CURRENT buffer, not the one being bound -- and at the
  -- moment the Session panel attaches, the current buffer is usually the
  -- COMPOSER, whose `<CR>` sends the prompt. Saving the displaced mapping from
  -- the wrong buffer restored "send the prompt" onto the chrome buffer.
  local host = vim.api.nvim_create_buf(false, true)
  local elsewhere = vim.api.nvim_create_buf(false, true)
  local host_cr = function() end
  local elsewhere_cr = function() end
  vim.keymap.set("n", "<CR>", host_cr, { buffer = host })
  vim.keymap.set("n", "<CR>", elsewhere_cr, { buffer = elsewhere })

  local was = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(elsewhere)
  session_panel.attach(surface_chat, host)
  session_panel.detach(surface_chat, host)

  vim.api.nvim_buf_call(host, function()
    eq(
      "session: detaching restores the mapping THAT BUFFER had",
      vim.fn.maparg("<CR>", "n", false, true).callback,
      host_cr
    )
  end)
  vim.api.nvim_buf_call(elsewhere, function()
    eq(
      "session: and leaves the buffer that happened to be current alone",
      vim.fn.maparg("<CR>", "n", false, true).callback,
      elsewhere_cr
    )
  end)
  vim.api.nvim_set_current_buf(was)
  vim.api.nvim_buf_delete(host, { force = true })
  vim.api.nvim_buf_delete(elsewhere, { force = true })

  -- `:Paseo mode` used to be a `vim.ui.select`. It is the same view object the
  -- dashboard draws, in a window of its own, which is why there is no second
  -- renderer to keep in step.
  local settings = require "paseo.ui.settings"
  local wins_before, bufs_before = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
  settings.open(surface_chat, "mode")
  truthy("settings: the popup opens", settings.is_open())

  local popup_buf = vim.api.nvim_get_current_buf()
  eq("settings: with a filetype of its own", vim.bo[popup_buf].ft, "paseo-settings")
  -- The height is VOLT'S, read back out of its state after `gen_data`. A
  -- window sized before the layout is built is sized against a guess, and this
  -- layout's size depends on how many models the provider has.
  eq(
    "settings: sized to the layout volt measured",
    vim.api.nvim_win_get_height(0),
    require("volt.state")[popup_buf].h
  )
  eq(
    "settings: and the buffer has exactly that many lines to anchor extmarks to",
    #vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false),
    require("volt.state")[popup_buf].h
  )
  -- `only` means one group, not a highlighted group in a list of four.
  local drawn_groups = 0
  for _, name in ipairs { "Permission mode", "Thinking", "Model", "Features" } do
    for _, line in ipairs(vim.api.nvim_buf_get_extmarks(popup_buf, -1, 0, -1, { details = true })) do
      for _, cell in ipairs(line[4].virt_text or {}) do
        if cell[1] == name then
          drawn_groups = drawn_groups + 1
        end
      end
    end
  end
  eq("settings: opened on one group, it draws one group", drawn_groups, 1)

  -- A section that changes height when you MOVE THE MOUSE is a crash. Volt
  -- records each section's starting row once, in `gen_data`, then draws at
  -- those offsets without clearing or re-padding -- so a description that
  -- appeared on hover wrote extmarks past the end of the buffer and raised
  -- "Invalid 'line': out of range" from inside `vim.on_key`.
  local tall = {
    agent_id = "x",
    config_snapshot = {
      modeId = "short",
      availableModes = {
        { id = "short", label = "Short", description = "One line." },
        {
          id = "long",
          label = "Long",
          description = ("wordy "):rep(60),
        },
      },
      thinkingOptions = {},
      models = {},
      features = {},
    },
  }
  local stable = session_panel.new(require("paseo.ui.session").source(tall))
  local on_short = #stable:lines(60)
  stable:move(1)
  local on_long = #stable:lines(60)
  eq("session: a card's height does not depend on which entry is focused", on_long, on_short)

  settings.close()
  truthy("settings: and closes", not settings.is_open())
  eq("settings: leaving no windows behind", #vim.api.nvim_list_wins(), wins_before)
  eq("settings: nor buffers", #vim.api.nvim_list_bufs(), bufs_before)
  eq("settings: nor an entry in volt's state", require("volt.state")[popup_buf], nil)

  -- Clamping the WINDOW without clamping the LAYOUT is worse than not
  -- clamping at all: `nvim_open_win` shrinks quietly, volt goes on drawing at
  -- the rows it recorded, and the throw lands between opening the window and
  -- binding `q` -- an empty popup over a full-screen backdrop with no key
  -- that dismisses either.
  local real_lines = vim.o.lines
  vim.o.lines = 20
  surface_chat.config_snapshot.models = {}
  for i = 1, 12 do
    surface_chat.config_snapshot.models[i] = { id = "m" .. i, label = "Model " .. i }
  end
  local opened = pcall(settings.open, surface_chat)
  truthy("settings: twelve models on a twenty-row editor still opens", opened)
  if opened then
    local squeezed = vim.api.nvim_get_current_buf()
    local drawn = #vim.api.nvim_buf_get_lines(squeezed, 0, -1, false)
    eq(
      "settings: the buffer is as long as the layout volt measured",
      drawn,
      require("volt.state")[squeezed].h
    )
    truthy("settings: and fits the editor", vim.api.nvim_win_get_height(0) <= vim.o.lines - 4)
    settings.close()
  end

  -- `nvim_buf_set_lines` collapses extmarks onto the last line rather than
  -- deleting them, so a redraw of a SHORTER layout stacked every row it no
  -- longer had on the popup's bottom row, overprinting there forever. Needs
  -- room to shrink into, so it is checked on a tall editor rather than the
  -- clamped one above.
  vim.o.lines = 40
  settings.open(surface_chat, "model")
  local shrinking = vim.api.nvim_get_current_buf()
  local before = #vim.api.nvim_buf_get_lines(shrinking, 0, -1, false)
  surface_chat.config_snapshot.models = {
    { id = "m1", label = "Model 1" },
    { id = "m2", label = "Model 2" },
  }
  vim.api.nvim_feedkeys(vim.keycode "l", "x", false)
  local after = #vim.api.nvim_buf_get_lines(shrinking, 0, -1, false)
  truthy(
    "settings: dropping ten models shrinks the buffer",
    after < before,
    before .. " -> " .. after
  )

  local per_row = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(shrinking, require("volt.state")[shrinking].ns, 0, -1, {}))
  do
    per_row[mark[2]] = (per_row[mark[2]] or 0) + 1
  end
  local stacked = nil
  for row, n in pairs(per_row) do
    if n > 1 then
      stacked = ("row %d carries %d"):format(row, n)
    end
  end
  eq("settings: and leaves no extmarks stacked on a row", stacked, nil)
  settings.close()

  vim.o.lines = real_lines

  -- Volt's convention is the cell's THIRD element, and everything between the
  -- panel and volt must preserve it -- truncate, flatten and to_volt all
  -- rebuild cell tables.
  local action = function() end
  local through = render.to_volt { render.truncate({ { "x", "PaseoDim", action } }, 40) }
  eq("ui: click actions survive truncate and to_volt", through[1][1][3], action)

  -- The dashboard is the DEFAULT surface: it is the one with everything on it,
  -- and the sidebar is what `<C-f>` switches to.
  local defaults = config.defaults()
  eq("ui: the configured default surface is the dashboard", defaults.ui.surface, "float")
  truthy("ui: whose z-index is below the 50 a float gets by default", defaults.ui.float.zindex < 50)

  -- Pasting an image is what `p` does now -- read the clipboard, fall through
  -- to an ordinary paste when it holds no picture -- so the composer no longer
  -- spends four columns of a narrow pane teaching you `^V`.
  local sidebar = require "paseo.ui.sidebar"
  local wins_at_hint = #vim.api.nvim_list_wins()
  sidebar.open(surface_chat)
  local hint = vim.wo[surface_chat.win_composer].winbar
  truthy("ui: the composer's hint does not advertise ^V", hint:find("^V", 1, true) == nil, hint)
  truthy("ui: it still says how to send", hint:find("send", 1, true) ~= nil, hint)

  -- THE HINT BAR DEGRADES RATHER THAN TRUNCATING, the way the tab bar does.
  -- A winbar wider than its window is cut, and the cut takes the LEFT -- so a
  -- narrow sidebar with five hints showed `<nd · <C-f> full screen · …`,
  -- having eaten the one thing you most need to know.
  local wide = widgets.hints({
    { "<CR>", "send" },
    { "<C-f>", "screen" },
    { "<C-c>", "stop" },
    { "q", "close" },
  }, nil, 200)
  local narrow = widgets.hints({
    { "<CR>", "send" },
    { "<C-f>", "screen" },
    { "<C-c>", "stop" },
    { "q", "close" },
  }, nil, 20)
  truthy("ui: a wide bar keeps every hint", render.width(wide) > render.width(narrow))
  truthy("ui: a narrow one keeps the first", render.to_winbar(narrow):find("send", 1, true) ~= nil)
  truthy(
    "ui: and drops whole hints rather than cutting one in half",
    render.width(narrow) <= 20,
    render.width(narrow)
  )
  sidebar.close(surface_chat)
  eq("ui: and the sidebar closes both its windows", #vim.api.nvim_list_wins(), wins_at_hint)

  -- The sidebar is configurable in the same units as the float, which is the
  -- point of the units: one number means one thing everywhere.
  config.setup {
    ui = {
      sidebar = {
        width = 30,
        min_width = 20,
        composer = 9,
        min_composer = 3,
        position = "left",
      },
    },
  }
  sidebar.open(surface_chat)
  eq(
    "ui: the sidebar takes a percentage too",
    vim.api.nvim_win_get_width(surface_chat.win_conversation),
    math.max(20, math.floor(vim.o.columns * 30 / 100))
  )

  -- THE BOX IS THE SIZE OF WHAT IS IN IT. `composer` is a ceiling, not a
  -- height: an empty composer sits at `min_composer`, which is where a fixed
  -- eight rows used to spend a third of a narrow sidebar on whitespace.
  --
  -- `nvim_win_get_height` counts the winbar row, and this composer carries the
  -- hint bar -- so every assertion here is `rows + 1`. Without adding it back
  -- in `fit_composer`, `min_composer = 3` would mean three rows of typing in
  -- the dashboard and two in the sidebar.
  local bar = vim.wo[surface_chat.win_composer].winbar ~= "" and 1 or 0
  eq(
    "ui: an empty composer sits at its floor",
    vim.api.nvim_win_get_height(surface_chat.win_composer),
    3 + bar
  )
  vim.api.nvim_buf_set_lines(surface_chat.composer, 0, -1, false, { "one", "two", "three", "four" })
  sidebar.fit_composer(surface_chat)
  eq(
    "ui: and grows with what you type",
    vim.api.nvim_win_get_height(surface_chat.win_composer),
    4 + bar
  )
  vim.api.nvim_buf_set_lines(surface_chat.composer, 0, -1, false, vim.split(("x\n"):rep(40), "\n"))
  sidebar.fit_composer(surface_chat)
  eq(
    "ui: up to the ceiling and no further",
    vim.api.nvim_win_get_height(surface_chat.win_composer),
    9 + bar
  )
  vim.api.nvim_buf_set_lines(surface_chat.composer, 0, -1, false, { "" })
  sidebar.fit_composer(surface_chat)
  eq(
    "ui: and shrinks back when it is sent",
    vim.api.nvim_win_get_height(surface_chat.win_composer),
    3 + bar
  )
  truthy(
    "ui: `position = left` puts it on the left",
    vim.api.nvim_win_get_position(surface_chat.win_conversation)[2] == 0,
    vim.inspect(vim.api.nvim_win_get_position(surface_chat.win_conversation))
  )
  sidebar.close(surface_chat)

  -- min_width is in CELLS and wins over the percentage: 40% of a small
  -- terminal is a pane too narrow to read a tool card in, and the percentage
  -- has no way to know that.
  config.setup { ui = { sidebar = { width = 1, min_width = 30 } } }
  sidebar.open(surface_chat)
  eq(
    "ui: min_width floors the percentage, in cells",
    vim.api.nvim_win_get_width(surface_chat.win_conversation),
    30
  )
  sidebar.close(surface_chat)

  -- And the cap is `winwidth`, not the editor: Neovim gives the window you
  -- came back to its minimum width and takes the difference out of ours, so
  -- asking for more than that is a number that quietly does not happen. Asking
  -- for the whole editor should land on the widest pane that actually holds.
  config.setup { ui = { sidebar = { width = 100, min_width = 1 } } }
  sidebar.open(surface_chat)
  eq(
    "ui: and the cap is what 'winwidth' leaves, so the number asked for holds",
    vim.api.nvim_win_get_width(surface_chat.win_conversation),
    math.max(20, vim.o.columns - math.max(vim.o.winwidth, 10) - 1)
  )
  sidebar.close(surface_chat)
  config.setup {}

  -- Both surfaces draw the header from ONE builder, so they cannot drift into
  -- disagreeing about which mode the session is in.
  surface_chat.mode = "acceptEdits"
  surface_chat.permissions = { { id = "x" } }
  local header = render.concat(sidebar.header(surface_chat))
  truthy("ui: the header shows the mode", header:find("acceptEdits", 1, true) ~= nil)
  truthy(
    "ui: and shouts when something is waiting on you",
    header:find("needs you", 1, true) ~= nil
  )

  -- The spinner. A static `●` looked identical at two seconds and at two
  -- minutes, so a wedged turn and a working one were the same picture; the
  -- elapsed count is the half that tells them apart.
  local chat = require "paseo.ui.chat"
  surface_chat.permissions = {}
  chat.set_streaming(surface_chat, true)
  local frame, seconds = chat.progress(surface_chat)
  local busy = render.concat(sidebar.header(surface_chat))
  truthy("ui: a running turn reports a frame", frame ~= nil, frame)
  truthy("ui: which the header draws", frame and busy:find(frame, 1, true) ~= nil, busy)
  eq("ui: alongside the seconds it has been running", seconds, 0)

  -- The invariant that keeps the timer honest: `streaming` is only ever set
  -- through the setter, so a timer can never outlive the turn it belongs to
  -- and redraw a header forever on a chat nobody is looking at.
  chat.set_streaming(surface_chat, false)
  truthy("ui: and the timer is closed when the turn ends", surface_chat.spinner == nil)
  eq("ui: an idle turn reports no frame", (chat.progress(surface_chat)), nil)

  -- `%` is the statusline escape character: a path or command containing one
  -- would be read as a format item and eat the rest of the bar.
  local escaped = render.to_winbar { { "50% done", "PaseoDim" } }
  truthy("ui: winbar text escapes %", escaped:find("50%% done", 1, true) ~= nil)
end

---A toggles card must not change height when focus moves onto an entry that
---has a description. Volt records each section's starting row once, in
---`gen_data`, then draws at those offsets without clearing or re-padding -- so
---a card that grew because you MOVED THE MOUSE writes extmarks past the end of
---the buffer and `handle_hover` raises "Invalid 'line': out of range" from
---inside `vim.on_key`. `chips_body` has always reserved that height; this is
---the same guard for the toggles that now carry descriptions.
local function test_toggle_height()
  local panel = require "paseo.ui.panels.session"

  local source = {
    keys = {},
    groups = function()
      return {
        {
          id = "g",
          key = "g",
          icon = "",
          label = "G",
          kind = "toggles",
          entries = {
            { id = "plain", label = "Plain", value = true },
            {
              id = "wordy",
              label = "Wordy",
              value = false,
              note = "dev",
              description = ("wordy "):rep(60),
            },
          },
        },
      }
    end,
    apply = function(_, _, _, done)
      done()
    end,
    load = function(_, done)
      done()
    end,
  }

  local view = panel.new(source)
  local on_plain = #view:draw(60)
  view:move(1)
  local on_wordy = #view:draw(60)
  eq("toggles: a card's height does not depend on which entry is focused", on_wordy, on_plain)

  -- The note is drawn, and on the row it belongs to rather than swallowed.
  local found = false
  for _, line in ipairs(view:draw(60)) do
    for _, cell in ipairs(line) do
      if type(cell[1]) == "string" and cell[1]:find "dev" then
        found = true
      end
    end
  end
  truthy("toggles: an entry's note is drawn beside it", found)

  -- Every cell of a toggle row is a click target, including the gap: the
  -- target is the row, not the two words on it.
  local clickable = 0
  for _, line in ipairs(view:draw(60)) do
    for _, cell in ipairs(line) do
      if type(cell[3]) == "table" and type(cell[3].click) == "function" then
        clickable = clickable + 1
      end
    end
  end
  truthy("toggles: the whole row is clickable, not just the label", clickable >= 4, clickable)
end

--- The Usage panel draws what it has and nothing else.
---
--- Two empty cards sat on that panel for most of every session, and it took
--- reading the daemon to find out why: `usage_updated` REPLACES `lastUsage`
--- with a payload carrying only the context window, so the tokens and cost
--- from `turn_completed` are wiped seconds after they arrive. The panel had no
--- opinion about that -- it drew three tiles unconditionally and put an em
--- dash in two of them.
local function test_usage_panel()
  local usage = require "paseo.ui.panels.usage"
  local bridge = require "paseo.bridge"

  -- The plan limits are a daemon round trip. Stub it, both because the sidecar
  -- is not running here and because the interesting assertions are about what
  -- the panel does with the answer.
  local old_ensure, old_request = bridge.ensure, bridge.request
  local fetched
  bridge.ensure = function(fn)
    fn(nil)
  end
  bridge.request = function(op, _args, cb)
    fetched = op
    cb(nil, {
      fetchedAt = "2026-09-21T10:00:00Z",
      providers = {
        {
          providerId = "claude",
          displayName = "Claude",
          status = "available",
          planLabel = "Max 20x",
          windows = {
            { id = "five_hour", label = "Session", usedPct = 23 },
            { id = "weekly", label = "Weekly", usedPct = 91 },
          },
        },
        {
          providerId = "codex",
          displayName = "Codex",
          status = "available",
          planLabel = "Pro",
          windows = { { id = "primary", label = "Session", usedPct = 12 } },
        },
      },
    })
  end

  ---@param chat table
  ---@return string
  local function drawn(chat)
    local out = {}
    for _, line in ipairs(usage.lines(chat, 100)) do
      for _, cell in ipairs(line) do
        out[#out + 1] = cell[1] or ""
      end
      out[#out + 1] = "\n"
    end
    return table.concat(out)
  end

  usage.invalidate()
  local chat = {
    provider = "claude/claude-opus-5",
    usage = { contextWindowUsedTokens = 236028, contextWindowMaxTokens = 1000000 },
  }
  -- The first draw is the one that ASKS; it returns "loading" because in
  -- production the answer is a round trip. The stub answers synchronously, so
  -- the second draw has it.
  drawn(chat)
  eq("ui: the Usage panel asks the daemon for plan limits", fetched, "providers.usage")
  local context_only = drawn(chat)
  truthy("ui: context is drawn when it is known", context_only:find("Context", 1, true) ~= nil)
  truthy(
    "ui: an empty turn tile is not drawn at all",
    context_only:find("This turn", 1, true) == nil
      and context_only:find("Last turn", 1, true) == nil
  )
  truthy("ui: nor an empty cost tile", context_only:find("Cost", 1, true) == nil)
  truthy("ui: nor a table of three em dashes", context_only:find("cached", 1, true) == nil)

  -- The plan is the thing the panel could not answer before.
  truthy("ui: the plan name is on the limits card", context_only:find("Max 20x", 1, true) ~= nil)
  truthy("ui: with the five-hour window", context_only:find("Session", 1, true) ~= nil)
  truthy("ui: and the weekly one", context_only:find("Weekly", 1, true) ~= nil)
  -- ONLY THE PROVIDER THIS SESSION IS ON. A daemon will report on every
  -- provider it can authenticate, and a wall of other people's quotas is
  -- neither the question nor affordable in rows -- the body is truncated,
  -- not scrolled.
  truthy(
    "ui: and nothing about a provider this session is not on",
    context_only:find("Codex", 1, true) == nil,
    context_only
  )

  -- What `chat.lua` kept off the `usage` event, because the snapshot will not
  -- keep it. Labelled as the LAST turn, since that is what it is by then.
  local after_turn = drawn {
    provider = "claude/claude-opus-5",
    usage = { contextWindowUsedTokens = 1, contextWindowMaxTokens = 10 },
    last_turn_usage = {
      inputTokens = 120,
      cachedInputTokens = 9400,
      outputTokens = 300,
      totalCostUsd = 0.1234,
    },
  }
  truthy(
    "ui: the last completed turn survives the snapshot",
    after_turn:find("Last turn", 1, true) ~= nil
  )
  truthy("ui: with its cost", after_turn:find("$0.1234", 1, true) ~= nil)
  truthy("ui: and its breakdown", after_turn:find("cached", 1, true) ~= nil)

  -- A provider the daemon has no quota fetcher for -- fable and gemini have
  -- none -- must say so rather than leave a gap.
  local no_fetcher = drawn { provider = "fable/fable-5-1" }
  truthy(
    "ui: a provider with no quota fetcher says so",
    no_fetcher:find("no plan limits reported for ", 1, true) ~= nil
  )

  bridge.ensure, bridge.request = old_ensure, old_request
  usage.invalidate()
end

--- Workspaces are grouped under the project they live in, not the one the
--- daemon invented for them.
local function test_workspaces_panel()
  local panel = require "paseo.ui.panels.workspaces"
  local workspaces = require "paseo.workspaces"
  local agents = require "paseo.agents"

  local old_list, old_watch, old_summary = workspaces.list, agents.watch, agents.summary
  agents.watch = function() end
  agents.summary = function()
    return "idle"
  end
  workspaces.list = function(cb)
    local list = {
      {
        id = "w1",
        name = "openfin",
        directory = "/x/Code/openfin",
        project = "openfin",
        projectId = "prj_root",
      },
      {
        id = "w2",
        name = "billing",
        directory = "/x/Code/openfin/.workspaces/billing",
        project = "billing",
        projectId = "prj_billing",
      },
      {
        id = "w3",
        name = "testing",
        directory = "/x/Code/paseo.nvim",
        project = "paseo.nvim",
        projectId = "prj_nvim",
      },
    }
    for _, ws in ipairs(list) do
      ws.group = workspaces.group(ws)
    end
    cb(list, nil)
  end

  panel.invalidate()
  local chat = { root = "/x/Code/openfin" }
  panel.lines(chat, 100)
  local drawn = {}
  for _, line in ipairs(panel.lines(chat, 100)) do
    local cells = {}
    for _, cell in ipairs(line) do
      cells[#cells + 1] = cell[1] or ""
    end
    drawn[#drawn + 1] = table.concat(cells)
  end
  local text = table.concat(drawn, "\n")

  -- `billing` is a directory inside `openfin`, so it must be drawn inside it
  -- -- not as a sibling project of the same name.
  local at_openfin, at_billing, at_nvim
  for i, line in ipairs(drawn) do
    at_openfin = at_openfin or (line:find("openfin", 1, true) and i or nil)
    at_billing = at_billing or (line:find("billing", 1, true) and i or nil)
    at_nvim = at_nvim or (line:find("paseo.nvim", 1, true) and i or nil)
  end
  truthy("ui: the workspaces panel draws a group heading", at_openfin ~= nil)
  truthy(
    "ui: with the .workspaces child under it rather than beside it",
    at_billing ~= nil and at_openfin ~= nil and at_billing > at_openfin,
    text
  )
  truthy(
    "ui: and the next group after both of them",
    at_nvim ~= nil and at_billing ~= nil and at_nvim > at_billing,
    text
  )
  -- Only ONE `billing` line now: it used to be both a group and a row.
  local billings = select(2, text:gsub("billing", ""))
  eq("ui: and billing is a workspace, not also a project", billings, 1)

  -- The keys are advertised once, at the bottom, rather than written out on
  -- every heading: a destructive action spelled out three times in a list you
  -- are reading for something else is three invitations to lose a record.
  truthy(
    "ui: the panel says how to archive and forget",
    text:find("forget project", 1, true) ~= nil,
    text
  )
  eq("ui: and does not offer it on every heading", select(2, text:gsub("forget project", "")), 1)

  -- WHICH LINE EACH ROW IS ON, and it has to be exact: `d` and `x` act on
  -- whatever `M._rows` says the cursor is over, so an entry recorded one line
  -- early puts `d` on a group heading over the first workspace under it --
  -- archiving the wrong thing without ever looking wrong.
  local offset = require("paseo.ui.float").body_row_offset()
  local checked = 0
  for line, row in pairs(panel._rows) do
    local drawn_at = drawn[line - offset]
    local name = row.name or (row.ws and row.ws.name)
    truthy(
      ("ui: the row map points `%s` at the line it is drawn on"):format(tostring(name)),
      drawn_at ~= nil and drawn_at:find(name, 1, true) ~= nil,
      ("line %d holds %q"):format(line, tostring(drawn_at))
    )
    checked = checked + 1
  end
  -- Three workspaces in two groups: every one of the five is addressable.
  eq("ui: every group and workspace is in the row map", checked, 5)

  workspaces.list, agents.watch, agents.summary = old_list, old_watch, old_summary
  panel.invalidate()
end

return {
  { "ui.session", test_session_source },
  { "ui.panels", test_panels },
  { "ui.toggles", test_toggle_height },
  { "ui.usage", test_usage_panel },
  { "ui.workspaces", test_workspaces_panel },
}
