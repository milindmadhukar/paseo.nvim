--- Every glyph the UI draws, in one place, defined by CODEPOINT.
---
--- The codepoints are the point. Twice now the literal bytes of a nerd-font
--- glyph have been lost out of a source file -- `widgets.icons` was fixed once
--- for exactly this (see the comment it used to carry), and at the time of
--- writing six slots in `render.icons`, the `permission` marker in
--- `panels/sessions.lua` and a handful of inline glyphs elsewhere were still
--- empty strings. An empty icon is not a visible failure: it renders as
--- nothing, the line still draws, and "off" and "broken" look identical.
---
--- `nr2char` is immune to that. A codepoint written as `0xf05e0` survives
--- every transfer, diff, editor and terminal that a four-byte UTF-8 sequence
--- in the Private Use Area does not, and it says WHICH glyph it is rather than
--- leaving you to paste it somewhere that can tell you.
---
--- Every glyph here is verified present in the Nerd Font v3 cmap and named
--- after its upstream name, so a replacement can be looked up rather than
--- guessed at. A nerd font is a hard requirement of this plugin -- the tests
--- assert every entry is at least one cell wide, which is the check that would
--- have caught all of the above.

local M = {}

---@param cp integer
---@return string
local function g(cp)
  return vim.fn.nr2char(cp)
end

-- ------------------------------------------------------------------ status
--
-- What a unit of work is doing. Used by the timeline's tool cards, the
-- Sessions panel and the Terminals panel -- one vocabulary, so a running tool
-- and a running agent are the same shape.

M.status = {
  running = g(0xf0996), -- md-progress_clock
  completed = g(0xf05e0), -- md-check_circle
  failed = g(0xf0159), -- md-close_circle
  canceled = g(0xf073a), -- md-cancel
  pending = g(0xf0130), -- md-checkbox_blank_circle_outline
  permission = g(0xf0026), -- md-alert
  thinking = g(0xf09d1), -- md-brain
  todo = g(0xf0279), -- md-format_list_bulleted
  note = g(0xf039e), -- md-note_text
  idle = g(0xf09de), -- md-circle_medium
}

-- ------------------------------------------------------------------ markers
--
-- Selection state. Geometric Shapes rather than nerd-font glyphs for the radio
-- and checkbox pair, deliberately: these are the two that must never be absent
-- because absent is indistinguishable from "off", and Geometric Shapes is in
-- every font on earth.

M.marker = {
  radio_on = g(0x25cf), -- BLACK CIRCLE
  radio_off = g(0x25cb), -- WHITE CIRCLE
  -- BLACK/WHITE SQUARE, not the nicer-looking WHITE SQUARE CONTAINING BLACK
  -- SMALL SQUARE (U+25A3) that was here before: that one is not in the Nerd
  -- Font cmap, so it fell through to whatever the terminal could find and came
  -- back at a width we had not measured for.
  check_on = g(0x25a0), -- BLACK SQUARE
  check_off = g(0x25a1), -- WHITE SQUARE
  mine = g(0x258c), -- LEFT HALF BLOCK -- the "this one is yours" gutter
  bullet = g(0x00b7), -- MIDDLE DOT
  swatch = g(0xf14fb), -- md-square_rounded -- repo/agent accent dots
  more_up = g(0x2191), -- UPWARDS ARROW
  more_down = g(0x2193), -- DOWNWARDS ARROW
  ellipsis = g(0x2026), -- HORIZONTAL ELLIPSIS
  newline = g(0x23ce), -- RETURN SYMBOL -- a collapsed "\n" in a one-line cell
  -- The composer's label, in its top border. A prompt chevron rather than a
  -- nerd-font glyph: this one has to say "type here" to someone who has never
  -- seen the plugin, and a shell prompt is the most widely understood mark
  -- there is for that.
  prompt = g(0x276f), -- HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT
}

-- --------------------------------------------------------------------- tools
--
-- One glyph per kind of thing an agent does. The timeline reads this by the
-- detail type it got from the daemon, so an unknown type falls back rather
-- than drawing nothing.

M.tool = {
  shell = g(0xf018d), -- md-console
  read = g(0xf0219), -- md-file_document
  edit = g(0xf03eb), -- md-pencil
  write = g(0xf0219), -- md-file_document
  search = g(0xf0349), -- md-magnify
  fetch = g(0xf059f), -- md-web
  sub_agent = g(0xf167a), -- md-robot_outline
  worktree_setup = g(0xf062c), -- md-source_branch
  plan = g(0xf014d), -- md-clipboard_text
  default = g(0xf01a7), -- md-cube_outline
}

-- -------------------------------------------------------------------- panels
--
-- The seven dashboard tabs, plus the surfaces that open on their own. Keyed by
-- the tab name exactly as `float.M.TABS` spells it.

M.panel = {
  Chat = g(0xf0004), -- md-account
  Session = g(0xf1542), -- md-tune_variant
  Sessions = g(0xf167a), -- md-robot_outline
  Changes = g(0xf062c), -- md-source_branch
  Usage = g(0xf0128), -- md-chart_bar
  Workspaces = g(0xf0645), -- md-file_tree
  Terminals = g(0xf018d), -- md-console
}

-- --------------------------------------------------------------------- misc

M.ui = {
  mode = g(0xf033e), -- md-lock -- permission mode
  thinking = g(0xf09d1), -- md-brain
  features = g(0xf140b), -- md-lightning_bolt
  model = g(0xf09d1), -- md-brain
  settings = g(0xf0493), -- md-cog
  question = g(0xf173a), -- md-message_question
  repo = g(0xf0ccf), -- md-source_repository
  folder = g(0xf024b), -- md-folder
  tokens = g(0xf01bc), -- md-database
  cost = g(0xf01c1), -- md-currency_usd
  context = g(0xf035b), -- md-memory
  reload = g(0xf0450), -- md-refresh
  new = g(0xf0415), -- md-plus
  more = g(0xf01d9), -- md-dots_vertical
  switch = g(0xf04e1), -- md-swap_horizontal
}

---Braille spinner. Ten frames, so a full cycle is a round second at 100ms --
---which is what makes the elapsed counter beside it readable rather than
---strobing.
M.spinner = {
  g(0x280b),
  g(0x2819),
  g(0x2839),
  g(0x2838),
  g(0x283c),
  g(0x2834),
  g(0x2826),
  g(0x2827),
  g(0x2807),
  g(0x280f),
}

-- -------------------------------------------------------------------- keycaps
--
-- Rendering a key as it LOOKS on the keyboard rather than as Vim spells it.
-- Lifted from nvzone/showkeys, which solves exactly this and solves it well:
-- `<C-w>` should read `Ctrl + w`, not `<C-w>`, on a hint bar someone is
-- scanning rather than parsing.

M.key = {
  ["<BS>"] = g(0xf006e), -- md-backspace
  ["<CR>"] = g(0xf0311), -- md-keyboard_return
  ["<Space>"] = g(0xf1050), -- md-keyboard_space
  ["<Tab>"] = g(0xf0312), -- md-keyboard_tab
  ["<Esc>"] = g(0xf12b7), -- md-keyboard_esc
  ["<Up>"] = g(0xf005d), -- md-arrow_up
  ["<Down>"] = g(0xf0045), -- md-arrow_down
  ["<Left>"] = g(0xf004d), -- md-arrow_left
  ["<Right>"] = g(0xf0054), -- md-arrow_right
  ["<C>"] = "Ctrl",
  ["<M>"] = "Alt",
  ["<S>"] = "Shift",
  ["<D>"] = g(0xf0633), -- md-apple_keyboard_command
}

---Spell a key the way a keyboard does.
---
---`<C-w>` becomes `Ctrl + w`; a bare `<CR>` becomes its glyph; anything with
---no entry is returned unchanged, so `q` stays `q` and an unrecognised
---`<Plug>…` degrades to itself rather than to nothing.
---@param key string
---@return string
function M.spell(key)
  local direct = M.key[key]
  if direct then
    return direct
  end

  local inner = key:match "^<(.-)>$"
  if not inner then
    return key
  end

  local modifier, rest = inner:match "^([^%-]+)%-(.+)$"
  if not modifier then
    return key
  end

  local prefix = M.key["<" .. modifier:upper() .. ">"]
  if not prefix then
    return key
  end

  -- A chord's second half is shown lowercase -- `Ctrl + w`, not `Ctrl + W` --
  -- because an uppercase letter in a chord means Shift was also held, and
  -- printing it that way says something the binding does not.
  return prefix .. " + " .. rest:lower()
end

---Every glyph, flattened, for the test that asserts none of them is empty.
---@return table<string, string>
function M.all()
  local flat = {}
  for group, entries in pairs(M) do
    if type(entries) == "table" then
      for name, glyph in pairs(entries) do
        if type(glyph) == "string" then
          flat[("%s.%s"):format(group, tostring(name))] = glyph
        end
      end
    end
  end
  return flat
end

return M
