--- The native surface: a tab page per agent, out of plain splits.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

local transcript = require "paseo.ui.transcript"

---@param id string
---@return table
local function new_chat(id)
  local chat = {
    root = vim.uv.cwd(),
    agent_id = id,
    title = id,
    provider = "test",
    streaming = false,
    pending = {},
    images = {},
    conversation = api.nvim_create_buf(false, true),
    composer = api.nvim_create_buf(false, true),
  }
  vim.bo[chat.conversation].filetype = "markdown"
  transcript.reset(chat)
  transcript.upsert(chat, { kind = "user", text = "hello" })
  return chat
end

local function settle()
  for _ = 1, 10 do
    vim.wait(10)
  end
end

---@param buf integer
---@return string[]
local function text(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@param want string
---@return boolean
local function has(lines, want)
  for _, line in ipairs(lines) do
    if line == want then
      return true
    end
  end
  return false
end

local function test_layout()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local tabs_before = #api.nvim_list_tabpages()
  local a = new_chat "native-a"
  native.open(a)

  eq("native: an agent opens on a tab page of its own", #api.nvim_list_tabpages(), tabs_before + 1)
  eq("native: rail, conversation and composer", #api.nvim_tabpage_list_wins(0), 3)
  eq("native: the conversation window holds the conversation", api.nvim_win_get_buf(a.win_conversation), a.conversation)
  eq("native: the composer window holds the composer", api.nvim_win_get_buf(a.win_composer), a.composer)
  eq("native: every window is a split, not a float", api.nvim_win_get_config(a.win_conversation).relative, "")
  eq("native: the cursor lands in the box", api.nvim_get_current_win(), a.win_composer)
  eq("native: and it is the current chat", chat_mod.current(), a)
  truthy("native: the conversation has a winbar", (vim.wo[a.win_conversation].winbar or "") ~= "")
  truthy("native: naming the agent", vim.wo[a.win_conversation].winbar:find("native-a", 1, true) ~= nil)
  eq("native: and the surface knows it is on screen", require("paseo.ui.surface").on_screen(), "native")

  -- A SECOND AGENT IS A SECOND TAB.
  local b = new_chat "native-b"
  native.open(b)
  eq("native: a second agent gets a second tab", #api.nvim_list_tabpages(), tabs_before + 2)
  eq("native: which is now current", chat_mod.current(), b)
  truthy("native: the two do not share a tab", a.native_tab ~= b.native_tab)

  -- Opening the first again goes BACK to its tab rather than making a third.
  native.open(a)
  eq("native: reopening an agent goes to its tab", #api.nvim_list_tabpages(), tabs_before + 2)
  eq("native: and lands on it", api.nvim_get_current_tabpage(), a.native_tab)

  -- WHAT IS CURRENT FOLLOWS THE TAB. Plain `gt` -- not our own open -- has to
  -- move it, or `:Paseo mode` changes the agent you are not looking at.
  vim.cmd("tabnext " .. api.nvim_tabpage_get_number(b.native_tab))
  settle()
  eq("native: entering a tab makes its agent current", chat_mod.current(), b)
  vim.cmd("tabnext " .. api.nvim_tabpage_get_number(a.native_tab))
  settle()
  eq("native: and back", chat_mod.current(), a)

  -- `<C-b>` takes the rail away and brings it back.
  native.toggle_rail()
  eq("native: the rail hides", #api.nvim_tabpage_list_wins(0), 2)
  native.toggle_rail()
  eq("native: and comes back", #api.nvim_tabpage_list_wins(0), 3)

  -- A RAIL YOU WIDENED STAYS WIDE through `<C-b>` off and on.
  local function rail_win()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if vim.bo[api.nvim_win_get_buf(win)].filetype == "paseo-rail" then
        return win
      end
    end
  end
  api.nvim_win_set_width(rail_win(), 41)
  native.toggle_rail()
  native.toggle_rail()
  eq("native: the rail comes back at the width you left it", api.nvim_win_get_width(rail_win()), 41)
  -- And a mouse drag or `<C-w>>` (WinResized, no toggle) is kept too.
  api.nvim_win_set_width(rail_win(), 37)
  native._resized { rail_win() }
  eq("native: a drag is remembered", require("paseo.ui.rail").width "rail", 37)
  require("paseo.ui.rail").set_width("rail", 32)

  -- CLOSING takes the tab and leaves the chat.
  native.close(b)
  eq("native: closing takes its tab", #api.nvim_list_tabpages(), tabs_before + 1)
  eq("native: and forgets its windows", b.win_conversation, nil)
  truthy("native: but not its buffers", api.nvim_buf_is_valid(b.conversation))

  -- `:q` in the conversation takes the whole tab, not half of it.
  api.nvim_set_current_win(a.win_conversation)
  vim.cmd "quit"
  settle()
  eq("native: :q in the conversation closes the tab", #api.nvim_list_tabpages(), tabs_before)
  eq("native: and leaves nothing claiming to be on screen", native.has(a), false)

  native.reset()
  chat_mod.set_current(saved_current)
end

local function test_markdown()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local chat = new_chat "native-md"
  native.open(chat)
  eq("native: the conversation is markdown here", chat.markdown, true)

  transcript.upsert(chat, {
    kind = "text",
    text = "# A heading\n\nSome **bold** words.\n\n```lua\n    local x = 1\n",
  })
  local lines = text(chat.conversation)
  truthy("native: prose is written as RAW markdown", has(lines, "# A heading"))
  truthy("native: emphasis markers kept for treesitter", has(lines, "Some **bold** words."))
  truthy("native: code keeps its indentation", has(lines, "    local x = 1"))
  truthy("native: and an unclosed fence is closed on screen", has(lines, "```"))

  -- Off the native surface it is drawn as it always was.
  native.close(chat)
  eq("native: closing turns markdown mode off", chat.markdown, nil)
  lines = text(chat.conversation)
  -- `render.wrap` reflows by word, so the code's indentation is what goes.
  truthy("native: so the other surfaces get their own rendering back", not has(lines, "    local x = 1"))

  native.reset()
  chat_mod.set_current(saved_current)
end

local function test_panels()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local chat = new_chat "native-panel"
  native.open(chat)
  local base = #api.nvim_tabpage_list_wins(0)

  local function shown()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "paseo-panel" then
        return api.nvim_buf_get_name(buf):match "panel/(%a+)/", buf
      end
    end
  end

  -- `<C-p>` TOGGLES. It used to step Settings -> Changes -> Usage -> closed,
  -- so reaching Usage was three presses.
  native.toggle_panel()
  eq("native: <C-p> opens a split", #api.nvim_tabpage_list_wins(0), base + 1)
  eq("native: on Settings the first time", (shown()), "settings")

  -- Every panel one key away, from inside it.
  for i, want in ipairs(native.PANELS) do
    local _, buf = shown()
    vim.api.nvim_feedkeys(tostring(i), "x", false)
    local name, now = shown()
    eq("native: " .. i .. " jumps straight to " .. want, name, want:lower())
    truthy("native: the " .. want .. " panel has lines", api.nvim_buf_line_count(now) >= 1)
    eq("native: still one panel split", #api.nvim_tabpage_list_wins(0), base + 1)
    local _ = buf
  end

  native.toggle_panel()
  eq("native: <C-p> again closes it", #api.nvim_tabpage_list_wins(0), base)
  native.toggle_panel()
  eq("native: and reopens the one you last looked at", (shown()), "usage")
  native.toggle_panel()

  native.close(chat)
  native.reset()
  chat_mod.set_current(saved_current)
end

---ONE BACKGROUND for the whole tab, under either palette. The regression: the
---rail, the panel and the box were on the plugin's tiers while the
---conversation was on the editor's `Normal` -- under `ui.colors = "fixed"`, two
---different colours side by side.
local function test_uniform()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local config = require "paseo.config"
  local hl = require "paseo.ui.hl"
  local theme = require "paseo.ui.theme"
  local saved_current = chat_mod.current()

  for _, mode in ipairs { "auto", "fixed" } do
    config.setup { ui = { colors = mode } }
    hl.setup()
    local chat = new_chat("native-" .. mode)
    native.open(chat)
    native.toggle_panel()

    local base = api.nvim_get_hl(0, { name = "PaseoBase" })
    if mode == "auto" then
      eq("native: under auto the base tier IS the editor's background", base.bg, api.nvim_get_hl(0, { name = "Normal" }).bg)
    else
      local want = theme.FIXED[vim.o.background == "light" and "light" or "dark"].bg
      eq("native: under fixed it is the plugin's own", base.bg, tonumber(want:sub(2), 16))
    end

    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local what = vim.bo[api.nvim_win_get_buf(win)].filetype
      if what == "paseo-rail" then
        -- The rail is coloured as nvim-tree is (|paseo.ui.theme|): its own
        -- group, which with no nvim-tree colours to borrow IS the base tier.
        truthy(
          ("native: %s (%s) is on the base tier"):format(what, mode),
          vim.wo[win].winhl:find("Normal:PaseoTreeNormal", 1, true) ~= nil
            and api.nvim_get_hl(0, { name = "PaseoTreeNormal", link = false }).bg == base.bg,
          vim.wo[win].winhl
        )
      elseif win ~= chat.win_composer then
        truthy(
          ("native: %s (%s) is on the base tier"):format(what, mode),
          vim.wo[win].winhl:find("Normal:PaseoBase", 1, true) ~= nil,
          vim.wo[win].winhl
        )
      end
    end

    native.close(chat)
  end

  config.setup {}
  hl.setup()
  native.reset()
  chat_mod.set_current(saved_current)
end

---The whole UI LOADS with volt off the runtimepath, and the native surface
---opens: in a child Neovim, since this one already has volt loaded.
local function test_without_volt()
  local script = vim.fn.tempname() .. ".lua"
  local out = vim.fn.tempname()
  local f = assert(io.open(script, "w"))
  f:write(([[
local ok_all, failures = true, {}
assert(not pcall(require, "volt"), "volt is on the runtimepath")
for _, path in ipairs(vim.fn.globpath(%q, "lua/paseo/ui/**/*.lua", false, true)) do
  local mod = path:match("lua/(paseo/ui/.*)%%.lua$"):gsub("/", ".")
  local ok, err = pcall(require, mod)
  if not ok then ok_all = false; failures[#failures + 1] = mod .. ": " .. tostring(err) end
end
local chat = { root = vim.uv.cwd(), agent_id = "nv", title = "nv", streaming = false, pending = {}, images = {},
  conversation = vim.api.nvim_create_buf(false, true), composer = vim.api.nvim_create_buf(false, true) }
require("paseo.ui.transcript").reset(chat)
require("paseo.ui.transcript").upsert(chat, { kind = "text", text = "# hi" })
local ok, err = pcall(require("paseo.ui.native").open, chat)
if not ok then ok_all = false; failures[#failures + 1] = "native.open: " .. tostring(err) end
local w = require "paseo.ui.widgets"
local ok2, err2 = pcall(w.table, { { "a", "b" }, { "1", "2" } }, "fit", {})
if not ok2 then ok_all = false; failures[#failures + 1] = "widgets.table: " .. tostring(err2) end
local fh = io.open(%q, "w")
fh:write(ok_all and "OK" or table.concat(failures, "\n"))
fh:close()
vim.cmd "qa!"
]]):format(t.repo_root, out))
  f:close()

  local env = vim.fn.environ()
  env.PASEO_TEST_NOVOLT = "1"
  local result = vim
    .system({ "nvim", "--headless", "-i", "NONE", "-u", vim.fs.joinpath(t.repo_root, "tests", "minimal_init.lua"), "-c", "luafile " .. script }, { env = env, text = true })
    :wait(60000)
  local fh = io.open(out)
  local said = fh and fh:read "*a" or ("no output; exit " .. tostring(result.code) .. "\n" .. (result.stderr or ""))
  if fh then
    fh:close()
  end
  eq("native: every paseo.ui module loads, and native opens, without volt", said, "OK")
  os.remove(script)
  os.remove(out)
end

---A tab that is not an agent's -- the read-only subagent view -- gets the
---rail too. The regression: `tabnew` left you on a bare tab, rail gone.
local function test_rail_beside()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()
  local chat = new_chat "native-side-rail"
  native.open(chat)
  eq("native: the rail is up on the agent's tab", native.rail_shown(), true)

  vim.cmd "tabnew"
  local tab = api.nvim_get_current_tabpage()
  local viewer = api.nvim_get_current_win()
  native.rail_beside()
  local rails = 0
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if vim.bo[api.nvim_win_get_buf(win)].filetype == "paseo-rail" then
      rails = rails + 1
    end
  end
  eq("native: a non-agent tab gets the rail beside it", rails, 1)
  eq("native: and the cursor stays where it was", api.nvim_get_current_win(), viewer)
  native.rail_beside()
  eq("native: asking twice does not add a second", #api.nvim_tabpage_list_wins(tab), 2)
  vim.cmd "tabclose"

  native.close(chat)
  native.reset()
  chat_mod.set_current(saved_current)
end

local function test_toggle()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local home = api.nvim_get_current_tabpage()
  local a = new_chat "native-toggle"
  native.open(a)
  settle()
  local agent_tab = a.native_tab
  truthy("toggle: the agent is on a tab of its own", agent_tab ~= home)

  -- `:Paseo native` ON the agent's tab goes back where you came from...
  chat_mod.surface("native", { toggle = true })
  eq("toggle: out lands on the tab you came from", api.nvim_get_current_tabpage(), home)
  truthy("toggle: and the agent's tab is still there", api.nvim_tabpage_is_valid(agent_tab))

  -- ...and again from there lands straight back on it.
  chat_mod.surface("native", { toggle = true })
  eq("toggle: in lands on the same agent tab", api.nvim_get_current_tabpage(), agent_tab)

  native.close(a)
  native.reset()
  chat_mod.set_current(saved_current)
end

return {
  { "ui.native.layout", test_layout },
  { "ui.native.toggle", test_toggle },
  { "ui.native.rail_beside", test_rail_beside },
  { "ui.native.markdown", test_markdown },
  { "ui.native.panels", test_panels },
  { "ui.native.uniform", test_uniform },
  { "ui.native.novolt", test_without_volt },
}
