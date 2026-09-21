--- Style, colour, layout and motion.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local function test_style()
  -- ----------------------------------------------------------------- style

  -- Every style has to produce the SAME number of rows for the same content.
  -- volt records a section's start row when the layout is measured and never
  -- recomputes it on redraw, so a card whose height depended on the frame
  -- would move every section below it the moment `ui.style` changed -- and
  -- two cards paired side by side would stop squaring up.
  local style = require "paseo.ui.style"
  local heights = {}
  for _, kind in ipairs(style.CARDS) do
    heights[#heights + 1] = #widgets.card {
      title = "Title",
      w = 40,
      kind = kind,
      lines = { { { "one" } }, { { "two" } }, { { "three" } } },
    }
  end
  eq("ui: every card style is the same height", heights, { 5, 5, 5, 5 })

  local widths = {}
  for _, kind in ipairs(style.CARDS) do
    for _, line in
      ipairs(widgets.card {
        title = "Title",
        w = 40,
        kind = kind,
        lines = { { { string.rep("z", 200) } } },
      })
    do
      if render.width(line) ~= 40 then
        widths[#widths + 1] = kind .. ":" .. render.width(line)
      end
    end
  end
  eq("ui: every panel card row is exactly its width", widths, {})

  -- A preset name and the table form have to mean the same thing, and a table
  -- only has to name what it changes.
  eq("ui: a preset resolves", style.resolve "rounded", { card = "rounded", border = "rounded" })
  eq(
    "ui: a table layers over its preset",
    style.resolve { preset = "rounded", border = "none" },
    { card = "rounded", border = "none" }
  )
  eq(
    "ui: nothing resolves to the default",
    style.resolve(nil),
    { card = "plate", border = "invisible" }
  )
  truthy("ui: a known preset validates", style.valid "square")
  truthy("ui: an unknown preset does not", not style.valid "hexagonal")
  truthy("ui: an unknown card does not", not style.valid { card = "hexagonal" })
  -- "invisible" keeps a real border and paints it fg == bg. Dropping the
  -- border instead would take its one cell of padding with it and put the
  -- content hard against the window edge.
  eq(
    "ui: an invisible border is still a border",
    (style.window_border { border = "invisible" }),
    "rounded"
  )
end

local function test_theme()
  -- ----------------------------------------------------------------- theme

  -- The elevation ladder has to actually STEP, in the right direction, or
  -- every "raised" surface washes into the one under it. Light themes step the
  -- other way; that sign is the whole reason this is derived rather than
  -- written down.
  local theme = require "paseo.ui.theme"
  local previous_bg = vim.o.background
  for _, background in ipairs { "dark", "light" } do
    vim.o.background = background
    local t = theme.derive()
    if t.opaque then
      local seen, duplicate = {}, nil
      for _, tier in ipairs { "bg0", "bg1", "bg2", "bg3", "bg4" } do
        if seen[t.bg[tier]] then
          duplicate = tier
        end
        seen[t.bg[tier]] = true
      end
      eq("ui: the " .. background .. " elevation ladder has five distinct tiers", duplicate, nil)
      eq("ui: and it steps " .. background, t.sign, background == "dark" and 1 or -1)
    end

    -- An accent used as text has to be legible on the plate it sits on. This
    -- is measured rather than assumed: `morning`'s "added" is #90ee90, which
    -- is unreadable on a plate tinted with that same green, while `default`'s
    -- is already dark enough that pushing it further lands on black.
    local groups = theme.groups()
    local illegible = {}
    for _, name in ipairs {
      "PaseoChipOn",
      "PaseoChipFocus",
      "PaseoChipWarn",
      "PaseoChipDanger",
      "PaseoKeycap",
      "PaseoGreenTile",
      "PaseoRedTile",
      "PaseoBlueTile",
      "PaseoYellowTile",
    } do
      local group = groups[name]
      if group.bg and theme.contrast(group.fg, group.bg) < theme.MIN_CONTRAST then
        illegible[#illegible + 1] = name
      end
    end
    eq("ui: every " .. background .. " plate is legible", illegible, {})
  end
  vim.o.background = previous_bg

  -- A colour already clear of the target is left exactly alone -- a theme that
  -- had its accents right keeps them.
  eq("ui: a legible colour is untouched", theme.readable("#ffffff", "#000000", 3.2), "#ffffff")

  -- Three rules that only a real colourscheme can break, so they are checked
  -- against several. All three were found by looking at `morning`.
  local scheme_before = vim.g.colors_name
  for _, scheme in ipairs { "habamax", "morning", "default", "desert" } do
    if pcall(vim.cmd.colorscheme, scheme) then
      local c = theme.palette()

      -- 1. Dim has to be DIMMER than body text. `morning` sets `Comment` to
      -- pure blue against a black `Normal`, so every quiet label came out
      -- louder than the words it was qualifying.
      truthy(
        "ui: dim text recedes behind body text on " .. scheme,
        theme.contrast(c.grey, c.bg) <= theme.contrast(c.text, c.bg),
        ("grey %s (%.1f) vs text %s (%.1f)"):format(
          c.grey,
          theme.contrast(c.grey, c.bg),
          c.text,
          theme.contrast(c.text, c.bg)
        )
      )

      -- 2. ...and it has to be chrome-coloured, not syntax-coloured. A
      -- saturated comment colour is quiet by luminance and loud by saturation,
      -- which is the half a contrast check does not catch.
      truthy(
        "ui: dim text is neutral on " .. scheme,
        theme.saturation(c.grey) <= theme.MAX_CHROME_SATURATION,
        ("%s at %.2f"):format(c.grey, theme.saturation(c.grey))
      )

      -- 3. "Green" has to be green. Sourcing it from `String` meant that on
      -- `morning` a tool that SUCCEEDED was drawn in magenta -- the colour of
      -- a string literal, which is not a shade of "it worked". `Added` means
      -- what we mean; `String` only happens to.
      local hue = select(1, require("volt.color").hex2hsl(c.green))
      truthy(
        "ui: the success accent is actually green on " .. scheme,
        hue >= 60 and hue <= 190,
        ("%s at hue %.0f"):format(c.green, hue)
      )
    end
  end
  if scheme_before then
    pcall(vim.cmd.colorscheme, scheme_before)
  end

  -- A bar's track is the ABSENCE of fill, so it is derived from the background
  -- rather than from the comment colour. On `morning` a comment-derived track
  -- came out pale blue and a 42% bar looked full.
  local track = vim.api.nvim_get_hl(0, { name = "PaseoTrack" })
  truthy("ui: the bar track is defined", track.fg ~= nil)
end

local function test_layout()
  -- ---------------------------------------------------------------- layout

  -- The chrome's row budget was three independent copies of the same
  -- arithmetic -- `g.height - 4` in one place, `g.row + 3` in another, and a
  -- bare `row - 5` in a third to turn a cursor line into a list index. The one
  -- that got missed would not error; it would put the click targets a row off.
  local layout = require "paseo.ui.layout"
  for _, height in ipairs { 24, 40, 60 } do
    local rows = layout.rows(height)
    eq("ui: the body gets height - 5 rows at " .. height, rows.body_height, height - 5)
    eq("ui: the footer owns the last row at " .. height, rows.footer, height)
    eq("ui: the body ends above it at " .. height, rows.body_last, height - 1)

    -- BORDERED, which every `ui.style` but `border = "none"` is. That matters
    -- and is where an off-by-one lived: `nvim_open_win` is handed the BORDER's
    -- row, not the content's, so chrome buffer line 1 is at `g.row + 1`. The
    -- panes were floated a row too high for as long as the row they covered
    -- was blank; the session strip put content there and it became visible as
    -- a strip you could see the last three columns of.
    local g = { row = 2, col = 3, width = 100, height = height, composer = 7, border = true }
    local panes = layout.panes(g)
    eq("ui: the panes start below the strip at " .. height, panes.top, g.row + 5)
    eq(
      "ui: and the strip is the row above them at " .. height,
      layout.screen_row(g, rows.strip),
      panes.top - 1
    )

    -- Unbordered, the content starts where it was asked to.
    local flat = vim.tbl_extend("force", g, { border = false })
    eq(
      "ui: without a border there is no row to skip at " .. height,
      layout.panes(flat).top,
      g.row + 4
    )

    -- A terminal session has no composer and gets the body outright. Same
    -- left edge and same width as the conversation, so switching session kind
    -- does not shift the frame under you.
    eq(
      "ui: the body pane is the whole panel area at " .. height,
      panes.body.height,
      rows.body_height
    )
    eq("ui: and shares the conversation's left edge at " .. height, panes.body.col, panes.col)
    eq("ui: and its width at " .. height, panes.body.width, panes.width)
    -- The composer's bottom border lands ON the last body row, never on the
    -- footer.
    -- The composer is bordered too, so it costs `composer + 2` rows and its
    -- BOTTOM BORDER is at `row + composer + 1`. That border belongs on the
    -- last body row; a row lower is the footer, which is the row that says
    -- which keys the surface has.
    eq(
      "ui: the composer's border lands on the last body row at " .. height,
      panes.composer_row + panes.composer + 1,
      layout.screen_row(g, rows.body_last)
    )
    truthy(
      "ui: so the footer is never covered at " .. height,
      panes.composer_row + panes.composer + 1 < layout.screen_row(g, rows.footer)
    )
  end

  -- The chrome's height is the sum of its named parts, not a literal. That is
  -- the file's whole argument, and adding the session strip is what made the
  -- difference matter: with a literal it is "find every 3 and hope".
  local parts = layout.PARTS
  eq(
    "ui: the chrome above the body is its parts",
    layout.CHROME.above,
    parts.header + parts.tabs + parts.rule + parts.strip
  )
  eq("ui: and below it is the footer", layout.CHROME.below, parts.footer)
end

local function test_animate()
  -- --------------------------------------------------------------- animate

  local animate = require "paseo.ui.animate"
  local scratch = vim.api.nvim_create_buf(false, true)

  -- `animate = false` has to be INSTANT, not fast: a tween that still eases
  -- when motion is off is motion.
  require("paseo.config").setup { ui = { animate = false } }
  eq("ui: motion off reports disabled", animate.enabled "bars", false)
  eq(
    "ui: motion off returns the target immediately",
    animate.tween { key = "t.off", buf = scratch, section = "body", target = 73 },
    73
  )

  require("paseo.config").setup {}

  -- The FIRST sight of a value is not a transition. Animating from zero on the
  -- first draw makes every panel open by sweeping its bars up, which is a lot
  -- of motion to say nothing.
  eq(
    "ui: a first value is not animated",
    animate.tween { key = "t.first", buf = scratch, section = "body", target = 61 },
    61
  )

  -- Each effect checks its OWN setting. They shared a clock, and `flash` was
  -- the one that gated it, so turning flash off silently turned the other off
  -- too.
  require("paseo.config").setup { ui = { animate = { flash = false, bars = true, fps = 30 } } }
  eq("ui: bars stay on with flash off", animate.enabled "bars", true)
  animate.flash { key = "t.indep.flash", buf = scratch, section = "body" }
  eq("ui: and flash stays off", animate.flash_stop "t.indep.flash", nil)
  require("paseo.config").setup {}

  -- Tearing down must not throw. Every live effect holds a `uv` timer, which
  -- is userdata -- so the obvious `vim.deepcopy(live)` to iterate safely over
  -- a table being mutated raises "Cannot deepcopy object of type userdata",
  -- from inside the dashboard's close path.
  animate.flash { key = "t.flash", buf = scratch, section = "body" }
  local torn = pcall(animate.stop_all)
  truthy("ui: stopping every effect does not throw", torn)
  eq("ui: and a stopped flash reports no stop", animate.flash_stop "t.flash", nil)
end

return {
  { "ui.style", test_style },
  { "ui.theme", test_theme },
  { "ui.layout", test_layout },
  { "ui.animate", test_animate },
}
