--- The native surface: one Paseo tab, every agent a buffer in it.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

local transcript = require "paseo.ui.transcript"

---A chat registered with |paseo.ui.chat| (so a buffer put in the middle is
---recognised as its), already initialised (so nothing dials a daemon).
---@param id string
---@return table
local function new_chat(id)
  local chat = require("paseo.ui.chat").prepare { agent_id = id, root = vim.uv.cwd(), title = id }
  chat.provider = "test"
  chat.initialised = true
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
  local home = api.nvim_get_current_tabpage()
  local a = new_chat "native-a"
  native.open(a)

  eq("native: Paseo is one tab page", #api.nvim_list_tabpages(), tabs_before + 1)
  local tab = native.tab()
  eq("native: rail, conversation and composer", #api.nvim_tabpage_list_wins(0), 3)
  eq(
    "native: the conversation window holds the conversation",
    api.nvim_win_get_buf(a.win_conversation),
    a.conversation
  )
  eq(
    "native: the composer window holds the composer",
    api.nvim_win_get_buf(a.win_composer),
    a.composer
  )
  eq(
    "native: every window is a split, not a float",
    api.nvim_win_get_config(a.win_conversation).relative,
    ""
  )
  eq("native: the cursor lands in the box", api.nvim_get_current_win(), a.win_composer)
  eq("native: and it is the current chat", chat_mod.current(), a)
  truthy("native: the conversation has a winbar", (vim.wo[a.win_conversation].winbar or "") ~= "")
  truthy(
    "native: naming the agent",
    vim.wo[a.win_conversation].winbar:find("native-a", 1, true) ~= nil
  )
  eq(
    "native: and the surface knows it is on screen",
    require("paseo.ui.surface").on_screen(),
    "native"
  )
  -- THE AGENT IS A BUFFER: listed, so a bufferline shows it, under its
  -- agent's name, which is what a bufferline prints.
  eq("native: the agent is a listed buffer", vim.bo[a.conversation].buflisted, true)
  truthy(
    "native: named after the agent",
    api.nvim_buf_get_name(a.conversation):find("paseo://agent/native-a", 1, true) ~= nil,
    api.nvim_buf_get_name(a.conversation)
  )
  eq("native: the composer is not", vim.bo[a.composer].buflisted, false)

  -- A SECOND AGENT IS A SECOND BUFFER, in the same windows on the same tab.
  local middle, box = a.win_conversation, a.win_composer
  local b = new_chat "native-b"
  native.open(b)
  eq("native: a second agent opens no second tab", #api.nvim_list_tabpages(), tabs_before + 1)
  eq("native: it is on the Paseo tab", api.nvim_get_current_tabpage(), tab)
  eq("native: in the same middle window", b.win_conversation, middle)
  eq("native: which holds its conversation", api.nvim_win_get_buf(middle), b.conversation)
  eq("native: and its composer took the box", api.nvim_win_get_buf(box), b.composer)
  eq("native: the first let go of the windows", a.win_conversation, nil)
  eq("native: which is now current", chat_mod.current(), b)
  eq("native: both are on the row, in order", native.listed(), { a, b })
  eq(
    "native: both listed",
    { vim.bo[a.conversation].buflisted, vim.bo[b.conversation].buflisted },
    { true, true }
  )

  -- `:b N`, `:bnext`, a bufferline click: the buffer is put in the middle by
  -- somebody else, and the composer, the keys and `current` follow it.
  api.nvim_set_current_win(middle)
  vim.cmd("buffer " .. a.conversation)
  settle()
  eq("native: an agent's buffer in the middle makes it current", chat_mod.current(), a)
  eq("native: its composer comes with it", api.nvim_win_get_buf(box), a.composer)
  eq("native: and it has the windows again", a.win_conversation, middle)
  eq("native: the cursor stays where you moved it", api.nvim_get_current_win(), middle)

  -- A buffer key pressed in the BOX: the composer keeps its window and the
  -- agent goes to the middle.
  api.nvim_set_current_win(box)
  vim.cmd("buffer " .. b.conversation)
  settle()
  eq(
    "native: from the box, the agent goes to the middle",
    api.nvim_win_get_buf(middle),
    b.conversation
  )
  eq("native: and the box holds its composer", api.nvim_win_get_buf(box), b.composer)

  -- LEAVING UNLISTS: the agents are not among your code's buffers.
  native.leave()
  eq("native: leaving goes to the tab you came from", api.nvim_get_current_tabpage(), home)
  eq("native: and unlists the agents", vim.bo[a.conversation].buflisted, false)
  native.open(b)
  eq("native: coming back is the same tab", api.nvim_get_current_tabpage(), tab)
  eq("native: and lists them again", vim.bo[a.conversation].buflisted, true)

  -- `<C-b>` takes the rail away and brings it back.
  native.toggle_rail()
  eq("native: the rail hides", #api.nvim_tabpage_list_wins(0), 2)
  native.toggle_rail()
  eq("native: and comes back", #api.nvim_tabpage_list_wins(0), 3)

  -- THE CURSOR GOES WITH IT, as with nvim-tree: opening the rail is going to
  -- it; closing it from there goes back where you were.
  local function rail_here()
    return vim.bo[api.nvim_get_current_buf()].filetype == "paseo-rail"
  end
  native.toggle_rail()
  api.nvim_set_current_win(middle)
  native.toggle_rail()
  truthy("focus: opening the rail puts the cursor in it", rail_here())
  native.toggle_rail()
  eq("focus: closing it from there goes back to where you were", api.nvim_get_current_win(), middle)
  api.nvim_set_current_win(box)
  native.toggle_rail()
  truthy("focus: from the box too", rail_here())
  native.toggle_rail()
  eq("focus: and back to the box", api.nvim_get_current_win(), box)
  -- Closed from somewhere else, the cursor stays there.
  native.toggle_rail()
  api.nvim_set_current_win(middle)
  native.toggle_rail()
  eq("focus: closed from elsewhere, the cursor stays put", api.nvim_get_current_win(), middle)
  native.toggle_rail()
  native.from_rail()
  eq("focus: the rail's own way back goes to where you were", api.nvim_get_current_win(), middle)

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

  -- REMOVING one is `:bdelete`-shaped: off the row, the neighbour in the
  -- middle, the tab still up.
  native.remove(b)
  eq("native: a removed chat leaves the row", native.listed(), { a })
  eq("native: and the neighbour takes the middle", api.nvim_win_get_buf(middle), a.conversation)
  eq("native: unlisted", vim.bo[b.conversation].buflisted, false)
  native.open(b)

  -- Removing one that is no longer in the middle -- a terminal it started
  -- has it -- takes it off the row and leaves the middle alone.
  native.open(a)
  native.remove(b)
  eq("native: removing one off screen leaves the middle", api.nvim_win_get_buf(middle), a.conversation)
  eq("native: and it is off the row", native.listed(), { a })
  native.open(b)

  -- CLOSING takes the Paseo tab and leaves the chats.
  native.close(b)
  eq("native: closing takes the Paseo tab", #api.nvim_list_tabpages(), tabs_before)
  eq("native: and forgets its windows", b.win_conversation, nil)
  truthy("native: but not its buffers", api.nvim_buf_is_valid(b.conversation))
  eq("native: which are no longer listed", vim.bo[a.conversation].buflisted, false)

  -- `:q` in the conversation takes the whole tab, not half of it.
  native.open(a)
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

  -- The rail going on or off changes the conversation's width. Raw markdown
  -- soft-wraps, so not one line of it is rewritten: a rewrite is what made
  -- render-markdown redraw the whole buffer a beat after every `<C-b>`.
  local width = api.nvim_win_get_width(chat.win_conversation)
  local tick = api.nvim_buf_get_changedtick(chat.conversation)
  native.toggle_rail()
  truthy(
    "native: the rail toggle changed the width",
    api.nvim_win_get_width(chat.win_conversation) ~= width
  )
  eq(
    "native: and prose was not rewritten for it",
    api.nvim_buf_get_changedtick(chat.conversation),
    tick
  )
  eq(
    "native: the transcript is drawn at the new width at once",
    chat.rendered_width,
    transcript.width(chat)
  )
  native.toggle_rail()

  -- Off the native surface it is drawn as it always was.
  native.close(chat)
  eq("native: closing turns markdown mode off", chat.markdown, nil)
  lines = text(chat.conversation)
  -- `render.wrap` reflows by word, so the code's indentation is what goes.
  truthy(
    "native: so the other surfaces get their own rendering back",
    not has(lines, "    local x = 1")
  )

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
      eq(
        "native: under auto the base tier IS the editor's background",
        base.bg,
        api.nvim_get_hl(0, { name = "Normal" }).bg
      )
    else
      local want = theme.FIXED[vim.o.background == "light" and "light" or "dark"].bg
      eq("native: under fixed it is the plugin's own", base.bg, tonumber(want:sub(2), 16))
    end

    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local what = vim.bo[api.nvim_win_get_buf(win)].filetype
      if what == "paseo-rail" then
        -- The rail is the one exception, on purpose: its own sidebar tier,
        -- `theme.SIDEBAR` below THIS base (|paseo.ui.theme|), so it follows
        -- the base under either palette.
        local want = theme.shift(string.format("#%06x", base.bg), theme.SIDEBAR)
        truthy(
          ("native: %s (%s) is on its sidebar tier, under the base"):format(what, mode),
          vim.wo[win].winhl:find("Normal:PaseoTreeNormal", 1, true) ~= nil
            and api.nvim_get_hl(0, { name = "PaseoTreeNormal", link = false }).bg
              == tonumber(want:sub(2), 16),
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
    .system(
      {
        "nvim",
        "--headless",
        "-i",
        "NONE",
        "-u",
        vim.fs.joinpath(t.repo_root, "tests", "minimal_init.lua"),
        "-c",
        "luafile " .. script,
      },
      { env = env, text = true }
    )
    :wait(60000)
  local fh = io.open(out)
  local said = fh and fh:read "*a"
    or ("no output; exit " .. tostring(result.code) .. "\n" .. (result.stderr or ""))
  if fh then
    fh:close()
  end
  eq("native: every paseo.ui module loads, and native opens, without volt", said, "OK")
  os.remove(script)
  os.remove(out)
end

---THE ROW IS WHAT YOU OPENED: agents of any workspace, side by side, in the
---order you opened them; nothing opened or closed for you. A subagent is a
---peek that leaves the row alone.
local function test_workspaces()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local agents = require "paseo.agents"
  local tree = require "paseo.ui.tree"
  local saved_current = chat_mod.current()

  local one, two = vim.fn.resolve(vim.fn.tempname()), vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(one, "p")
  vim.fn.mkdir(two, "p")
  local records = {
    ["ws-a1"] = { id = "ws-a1", workspaceId = "w1", cwd = one, title = "first", createdAt = "1" },
    ["ws-a2"] = { id = "ws-a2", workspaceId = "w1", cwd = one, title = "second", createdAt = "2" },
    ["ws-b1"] = { id = "ws-b1", workspaceId = "w2", cwd = two, title = "other", createdAt = "3" },
    ["ws-sub"] = {
      id = "ws-sub",
      workspaceId = "w2",
      cwd = two,
      title = "helper",
      createdAt = "4",
      labels = { [require("paseo.subagents").PARENT_LABEL] = "ws-b1" },
    },
  }
  local old_get, old_agents, old_terms = agents.get, tree.workspace_agents, tree.workspace_terminals
  agents.get = function(id)
    return records[id]
  end
  tree.workspace_agents = function(ws)
    local out = {}
    for _, record in pairs(records) do
      if record.workspaceId == ws.id then
        out[#out + 1] = record
      end
    end
    table.sort(out, function(x, y)
      return x.createdAt < y.createdAt
    end)
    return out
  end
  tree.workspace_terminals = function()
    return {}
  end

  local ok, err = pcall(function()
    local a1 = new_chat "ws-a1"
    a1.root, a1.local_root = one, one
    native.open(a1)
    eq("row: opening an agent is that agent alone -- nothing else is opened", native.listed(), { a1 })
    eq("row: listed", vim.bo[a1.conversation].buflisted, true)
    eq("row: the tab stands where it works", vim.fn.resolve(vim.fn.getcwd()), one)

    -- Another workspace's agent JOINS the row: nothing is closed for it.
    local b1 = new_chat "ws-b1"
    b1.root, b1.local_root = two, two
    native.open(b1)
    eq("row: another workspace's agent joins the row", native.listed(), { a1, b1 })
    eq("row: the first is still a live, listed buffer", vim.bo[a1.conversation].buflisted, true)
    eq("row: the tab follows the agent in the middle", vim.fn.resolve(vim.fn.getcwd()), two)

    -- A second agent of the first workspace, opened: one more, at the end.
    local a2 = new_chat "ws-a2"
    a2.root, a2.local_root = one, one
    native.open(a2)
    eq("row: in the order you opened them", native.listed(), { a1, b1, a2 })

    -- The daemon reporting agents does not open any.
    native.sync()
    eq("row: an agent change opens nothing", #native.listed(), 3)

    -- Back to one already open: the same buffer, no duplicate.
    native.open(a1)
    eq("row: reopening is the same buffer", native.listed(), { a1, b1, a2 })
    eq("row: and the tab went back with it", vim.fn.resolve(vim.fn.getcwd()), one)
    eq("row: on the one Paseo tab", api.nvim_get_current_tabpage(), native.tab())

    -- A SUBAGENT IS A PEEK: in the middle, off the row.
    native.open(b1)
    local sub = new_chat "ws-sub"
    sub.root, sub.local_root = two, two
    native.open(sub)
    eq("peek: the subagent takes the middle", api.nvim_win_get_buf(sub.win_conversation), sub.conversation)
    eq("peek: the row is unchanged", native.listed(), { a1, b1, a2 })
    eq("peek: and it is not listed", vim.bo[sub.conversation].buflisted, false)
    -- `q` goes back to the parent, not out of Paseo.
    native.close(sub)
    eq("peek: q goes back to the parent", api.nvim_win_get_buf(b1.win_conversation), b1.conversation)
    truthy("peek: with the Paseo tab still up", native.any())

    -- A read-only buffer -- a provider subagent's transcript -- the same way.
    local view = api.nvim_create_buf(false, true)
    local win = native.peek(view)
    eq("peek: a viewer goes in the middle", api.nvim_win_get_buf(win), view)
    native.unpeek()
    eq("peek: and back", api.nvim_win_get_buf(b1.win_conversation), b1.conversation)

    native.close(b1)
  end)

  agents.get, tree.workspace_agents, tree.workspace_terminals = old_get, old_agents, old_terms
  native.reset()
  chat_mod.set_current(saved_current)
  require("tests.spec.helpers").go_home()
  vim.fn.delete(one, "rf")
  vim.fn.delete(two, "rf")
  if not ok then
    error(err, 0)
  end
end

local function test_keys()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local config = require "paseo.config"
  local rail = require "paseo.ui.rail"
  local saved, saved_current = vim.deepcopy(config.get()), chat_mod.current()

  -- The rail's buffer is shared and built once: rebuild it with these keys.
  rail.reset()
  config.setup {
    ui = { native = { keys = { rail = { "<C-b>", "<leader>e" }, panel = false }, hints = true } },
  }
  local chat = new_chat "native-keys"
  native.open(chat)
  settle()
  local function bound(buf, lhs)
    return api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true).buffer == 1
    end)
  end
  truthy("keys: <leader>e toggles the rail from the composer", bound(chat.composer, "<leader>e"))
  truthy("keys: and from the conversation", bound(chat.conversation, "<leader>e"))
  truthy("keys: <C-b> is still there beside it", bound(chat.composer, "<C-b>"))
  truthy("keys: a key set to false is not bound", not bound(chat.composer, "<C-p>"))
  local bar = vim.wo[chat.win_conversation].winbar
  truthy("keys: and not advertised", not bar:find("panel", 1, true))
  truthy("keys: a bound one is, with hints on", bar:find("rail", 1, true), bar)

  native.close(chat)
  native.reset()
  config.setup(saved)
  chat_mod.set_current(saved_current)
end

local function test_hints()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local config = require "paseo.config"
  local saved, saved_current = vim.deepcopy(config.get()), chat_mod.current()

  -- The option's shapes: off by default, a boolean for both, the rail's old
  -- home honoured only where the new one is silent.
  config.setup {}
  eq("hints: off by default", config.get().ui.native.hints, { winbar = false, rail = false })
  config.setup { ui = { native = { hints = true } } }
  eq("hints: true is both", config.get().ui.native.hints, { winbar = true, rail = true })
  config.setup { ui = { float = { rail = { hints = true } } } }
  eq("hints: the rail's old name still works", config.get().ui.native.hints.rail, true)
  config.setup { ui = { float = { rail = { hints = true } }, native = { hints = { rail = false } } } }
  eq("hints: but the new one wins", config.get().ui.native.hints.rail, false)

  -- Off, the winbar is the agent and its status: no keys on the right.
  config.setup {}
  local chat = new_chat "native-hints"
  native.open(chat)
  settle()
  local bar = vim.wo[chat.win_conversation].winbar
  truthy("hints: the winbar names the agent", bar:find("native-hints", 1, true), bar)
  truthy("hints: and advertises no keys", not bar:find("rail", 1, true), bar)

  native.close(chat)
  native.reset()
  config.setup(saved)
  chat_mod.set_current(saved_current)
end

local function test_changes_async()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.system({ "git", "init", "-q", dir }):wait()
  local fd = assert(io.open(dir .. "/untracked-here.txt", "w"))
  fd:write "x\n"
  fd:close()
  require("paseo.repos").invalidate()

  local chat = new_chat "native-changes"
  chat.root = dir
  native.open(chat)
  settle()
  native.panel "Changes"
  local function panel_text()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "paseo-panel" then
        return table.concat(text(buf), "\n")
      end
    end
    return ""
  end
  truthy(
    "changes: the panel is up before git has answered",
    panel_text():find("loading", 1, true) ~= nil
  )
  truthy(
    "changes: and fills in when it does",
    vim.wait(3000, function()
      return panel_text():find("untracked-here.txt", 1, true) ~= nil
    end)
  )

  native.close(chat)
  native.reset()
  chat_mod.set_current(saved_current)
  vim.fn.delete(dir, "rf")
end

local function test_toggle()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local home = api.nvim_get_current_tabpage()
  local a = new_chat "native-toggle"
  native.open(a)
  settle()
  local agent_tab = native.tab()
  truthy("toggle: Paseo is on a tab of its own", agent_tab ~= home)

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

local function test_api()
  local native = require "paseo.ui.native"
  local api_ = require "paseo.native"
  local chat_mod = require "paseo.ui.chat"
  local rail = require "paseo.ui.rail"
  local saved_current = chat_mod.current()

  -- The public names, through `require("paseo")` too.
  eq("api: require(\"paseo\").native is the module", require("paseo").native.toggle_rail, api_.toggle_rail)

  -- EVERY ACTION A <Plug> NAME, and every panel one.
  for _, name in ipairs { "native", "rail", "focus", "panel", "panel-changes", "new", "next", "code" } do
    truthy(
      "api: <Plug>(paseo-" .. name .. ") is defined",
      vim.fn.maparg("<Plug>(paseo-" .. name .. ")", "n") ~= ""
    )
  end

  local chat = new_chat "native-api"
  native.open(chat)
  settle()
  local function panel_shown()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "paseo-panel" then
        return api.nvim_buf_get_name(buf):match "panel/(%a+)/"
      end
    end
  end

  -- `panel "Changes"` goes straight to one, any case.
  api_.panel "Changes"
  eq("api: panel(<name>) shows that panel", panel_shown(), "changes")
  api_.toggle_panel()
  eq("api: and toggle_panel() hides it", panel_shown(), nil)

  -- FROM YOUR CODE: the action takes you there and SHOWS, never hides.
  local shown_before = native.rail_shown() and true or false
  if shown_before then
    native.toggle_rail()
  end
  eq("api: the rail starts hidden here", native.rail_shown() and true or false, false)
  api_.code()
  eq("api: code() leaves the Paseo tab", native.on_tab(), false)
  api_.toggle_rail()
  eq("api: toggle_rail() from your code goes to the tab", native.on_tab(), true)
  eq("api: and shows the rail", native.rail_shown() and true or false, true)
  eq("api: remembered as shown", rail.visible(), true)
  eq("api: with the cursor in it", api.nvim_get_current_win(), rail.win())
  -- The rail is the LEFTMOST split: <C-h> there is <C-w>h, which goes
  -- nowhere. It went back out once, so a second <C-h> wrapped you round to
  -- the conversation on the right.
  api_.focus_rail()
  eq("api: focus_rail() from the rail stays in the rail", api.nvim_get_current_win(), rail.win())
  vim.api.nvim_feedkeys(vim.keycode "<C-h>", "x", false)
  eq("api: and so does the rail's own <C-h>", api.nvim_get_current_win(), rail.win())
  api_.code()
  api_.panel "usage"
  eq("api: panel(name) from your code shows it on the tab", panel_shown(), "usage")
  api_.toggle_panel()
  eq("api: toggle_panel() there closes it", panel_shown(), nil)
  if not shown_before then
    native.toggle_rail()
  end

  native.close(chat)
  native.reset()
  chat_mod.set_current(saved_current)
end

---Fill a chat with more than a screenful.
---@param chat table
---@param n integer
---@param tag string
local function fill(chat, n, tag)
  for i = 1, n do
    transcript.upsert(chat, { kind = "assistant", id = tag .. i, text = tag .. " line " .. i })
  end
end

---Where the middle window is: its top line, and whether its last is on screen.
---@param chat table
---@return integer top, boolean bottom
local function where(chat)
  local win = chat.win_conversation
  return vim.fn.line("w0", win), vim.fn.line("w$", win) >= api.nvim_buf_line_count(chat.conversation)
end

---Scroll the middle window the way a key would, and let `WinScrolled` see it.
---@param chat table
---@param keys string
local function scroll(chat, keys)
  api.nvim_win_call(chat.win_conversation, function()
    vim.cmd("normal! " .. api.nvim_replace_termcodes(keys, true, false, true))
  end)
  -- `WinScrolled` is the main loop's, and a script never gets back to it on
  -- its own. Fire it as the main loop would, naming the window.
  local win = chat.win_conversation
  api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win), data = { win = win } })
end

local function test_sticky()
  local native = require "paseo.ui.native"
  local chat_mod = require "paseo.ui.chat"
  local saved_current = chat_mod.current()

  local a = new_chat "sticky-a"
  local b = new_chat "sticky-b"
  native.open(a)
  fill(a, 200, "a")
  local _, bottom = where(a)
  eq("sticky: a new chat follows from the start", bottom, true)
  fill(a, 5, "more")
  _, bottom = where(a)
  eq("sticky: and keeps following what lands", bottom, true)

  -- SCROLL UP AND IT STAYS. The next chunk does not drag you back down.
  scroll(a, "gg")
  local top = where(a)
  eq("sticky: scrolled to the top", top, 1)
  eq("sticky: which is not following", a.sticky, false)
  fill(a, 5, "while-up")
  eq("sticky: a chunk while scrolled up leaves you there", (where(a)), 1)

  -- SWITCH AWAY AND BACK: still where you were.
  native.open(b)
  fill(a, 5, "while-away")
  native.open(a)
  eq("sticky: back from another agent, still where you left it", (where(a)), 1)
  api.nvim_set_current_win(a.win_conversation)
  vim.cmd("buffer " .. b.conversation)
  settle()
  vim.cmd("buffer " .. a.conversation)
  settle()
  eq("sticky: and through :buffer too", (where(a)), 1)

  -- G, AND IT FOLLOWS AGAIN.
  scroll(a, "G")
  eq("sticky: G is following again", a.sticky, true)
  fill(a, 5, "after-G")
  _, bottom = where(a)
  eq("sticky: so what lands next scrolls into view", bottom, true)

  -- FOLLOWING WHILE AWAY: back at the new end, not the old one.
  native.open(b)
  fill(a, 50, "away-following")
  native.open(a)
  _, bottom = where(a)
  eq("sticky: following while off screen lands at the new end", bottom, true)

  native.close(a)
  native.reset()
  chat_mod.set_current(saved_current)
end

return {
  { "ui.native.layout", test_layout },
  { "ui.native.toggle", test_toggle },
  { "ui.native.keys", test_keys },
  { "ui.native.hints", test_hints },
  { "ui.native.changes_async", test_changes_async },
  { "ui.native.workspaces", test_workspaces },
  { "ui.native.markdown", test_markdown },
  { "ui.native.panels", test_panels },
  { "ui.native.uniform", test_uniform },
  { "ui.native.novolt", test_without_volt },
  { "ui.native.api", test_api },
  { "ui.native.sticky", test_sticky },
}
