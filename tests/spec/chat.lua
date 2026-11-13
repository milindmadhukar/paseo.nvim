--- The chat window, and what it follows.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local go_home = t.go_home

--- The chat window follows a workspace switch.
---
--- The bug: with the chat up full screen, `<CR>` in the workspace picker moved
--- the editor and left the chat describing the workspace you had just left.
local function test_chat_follow()
  local bridge = require "paseo.bridge"
  local chat = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local config = require "paseo.config"
  local workspaces = require "paseo.workspaces"

  local old_ensure, old_request = bridge.ensure, bridge.request
  local old_settings = chat.load_settings

  local here = vim.fn.tempname()
  local there = vim.fn.tempname()
  local empty = vim.fn.tempname()
  for _, dir in ipairs { here, there, empty } do
    vim.fn.mkdir(dir, "p")
  end

  local ok, err = pcall(function()
    config.setup {}
    chat.load_settings = function() end
    bridge.ensure = function(callback)
      callback(nil)
    end
    -- One agent per directory, except `empty`, which has none -- the case that
    -- must NOT turn into a provider picker.
    bridge.request = function(op, args, callback)
      if op == "agent.find" then
        if args.cwd == empty then
          return callback(nil, nil)
        end
        return callback(nil, { id = "agent-" .. vim.fs.basename(args.cwd), provider = "test" })
      end
      if op == "timeline.history" then
        return callback(nil, { items = {} })
      end
      callback(nil, {})
    end

    -- Nothing open: changing directory is not a request for a chat.
    eq("follow: no chat open, nothing happens", chat.follow(there), false)

    -- `:Paseo buf` FROM A COLD START LANDS ON ONE SURFACE, not two -- and
    -- `buf` means the native surface now, the old dashboard being gone.
    -- Counted, because "it is on the right surface now" is exactly what a
    -- two-step open (default surface first, then the real one) also answered.
    local opens = 0
    local opened = native.open
    native.open = function(...)
      opens = opens + 1
      return opened(...)
    end
    chat.surface "buffer"
    truthy(
      "surface: :Paseo buf with no chat opens one, on the native surface",
      vim.wait(1000, function()
        return chat.current() ~= nil and native.has(chat.current())
      end)
    )
    eq("surface: and opens it exactly once", opens, 1)
    native.open = opened

    -- AND IT IS A TOGGLE, IN AND OUT: the key that opened it is the way
    -- back to the code, and the agent's tab is kept for the next press.
    chat.surface("buffer", { toggle = true })
    truthy("surface: pressing it again leaves the agent's tab", not native.is_open(chat.current()))
    truthy("surface: without closing it", native.has(chat.current()))
    chat.surface("buffer", { toggle = true })
    truthy("surface: and a third press goes back to it", native.is_open(chat.current()))
    chat.close()
    chat.forget()

    chat.open { root = here }
    truthy(
      "follow: the chat opens on the directory asked for",
      vim.wait(1000, function()
        return chat.current() ~= nil
          and chat.current().agent_id == "agent-" .. vim.fs.basename(here)
      end)
    )
    truthy("follow: on the full-screen surface", native.has(chat.current()))

    -- The bug, directly: the open window must end up on the new workspace.
    truthy("follow: an open chat follows the switch", chat.follow(there))
    truthy(
      "follow: onto the new workspace's agent",
      vim.wait(1000, function()
        return chat.current().agent_id == "agent-" .. vim.fs.basename(there)
      end)
    )
    eq("follow: and its root came with it", chat.current().root, there)
    truthy("follow: still on the full-screen surface", native.has(chat.current()))
    chat.close()
    native.reset()

    -- THE CRASH. Closing the surface from a tab page other than its own left
    -- the tab it was on pointing at a window that no longer existed; the next
    -- `:tabclose` died with `E315: ml_get: Invalid lnum`, or took the process
    -- down outright. It predates the follow -- open the chat, `gt`, close it --
    -- but the `"tab"` switch does exactly that shape of thing every time.
    local tabs = #vim.api.nvim_list_tabpages()
    chat.open { root = here }
    vim.wait(200)
    vim.cmd.tabnew()
    chat.close()
    truthy(
      "follow: closing the chat from another tab does not corrupt its own",
      (pcall(vim.cmd.tabclose))
    )
    eq("follow: and the tab really closed", #vim.api.nvim_list_tabpages(), tabs)

    -- An AUTOMATIC re-point must never interrogate you. A workspace with no
    -- agent says so; it does not open the new-task screen (|paseo-new|) --
    -- which is a whole draft chat, and would put a screen in front of
    -- someone who only changed directory.
    local new = require "paseo.new"
    local old_new_open = new.open
    local offered, offered_at = false, nil
    new.open = function(ctx)
      offered = true
      offered_at = ctx and ctx.root
    end
    chat.follow(empty)
    vim.wait(200)
    eq("follow: an agentless workspace asks nothing at all", offered, false)

    -- ...but asking for a chat there yourself gets you the screen, on it.
    chat.open { root = empty }
    truthy("follow: `create` defaults back on for a chat you asked for", vim.wait(1000, function()
      return offered
    end))
    eq("follow: and the screen is for that directory", offered_at, empty)

    -- OPENING A WORKSPACE is not merely changing directory: one with no agent
    -- yet offers the screen, whether or not a chat is on screen.
    offered = false
    chat.open { root = here }
    vim.wait(200)
    chat.follow(empty, { offer = true })
    truthy("follow: opening an agentless workspace offers the screen", vim.wait(1000, function()
      return offered
    end))
    chat.close()
    chat.forget()
    offered = false
    chat.follow(empty, { offer = true })
    truthy("follow: even with no chat on screen", vim.wait(1000, function()
      return offered
    end))
    chat.close()
    chat.forget()
    offered = false
    chat.follow(there, { offer = true })
    vim.wait(200)
    eq("follow: but one with an agent opens nothing unbidden", { offered, chat.current() }, { false, nil })
    new.open = old_new_open

    -- The switch itself carries the chat: this is the reported bug end to end,
    -- through the function the picker's <CR> actually calls.
    chat.open { root = here }
    vim.wait(200)
    config.setup { workspaces = { open = "tcd" } }
    workspaces.open { directory = there, name = "there" }
    truthy(
      "follow: switching workspace moves the chat with it",
      vim.wait(1000, function()
        return chat.current() ~= nil and chat.current().root == there
      end)
    )

    -- THE REPORTED BUG, in the shape it was actually hit: switch FIRST, open
    -- the chat SECOND, with a file from the workspace you left still the
    -- current buffer.
    --
    -- `follow` deliberately does nothing when no chat is on screen, so the
    -- whole answer comes from how `chat.open {}` resolves "here" -- and it
    -- used to resolve it from `ref.file()`, the git toplevel of the BUFFER.
    -- With `workspaces.open = "tcd"` the switch reuses the tab, so that buffer
    -- is still the old worktree's file and the chat opened on the workspace
    -- you had just left.
    chat.close()
    chat.forget()
    config.setup { workspaces = { open = "tcd" } }

    -- A real file, in a real repo, in the workspace we are about to leave.
    vim.fn.system { "git", "-C", here, "init", "-q" }
    local stale = here .. "/stale.txt"
    vim.fn.writefile({ "left open behind us" }, stale)
    vim.cmd.edit(vim.fn.fnameescape(stale))
    eq("follow: the old workspace's file is the current buffer", vim.fn.expand "%:p", stale)

    workspaces.open { directory = there, name = "there" }
    eq("follow: and the switch moved the editor", vim.fn.getcwd(), there)
    truthy(
      "follow: the old workspace's file is STILL the current buffer",
      vim.fn.expand "%:p" == stale
    )

    chat.toggle()
    truthy(
      "follow: opening the chat after a switch lands on the new workspace",
      vim.wait(1000, function()
        return chat.current() ~= nil and chat.current().root == there
      end)
    )
    eq(
      "follow: and on that workspace's agent, not the one we left",
      chat.current().agent_id,
      "agent-" .. vim.fs.basename(there)
    )
    chat.close()
    vim.cmd "silent! bwipeout!"

    -- A handler that opens its own window is on its own: we did not move, so
    -- neither does the chat.
    chat.open { root = here }
    vim.wait(200)
    config.setup {
      workspaces = {
        open = function()
          return true
        end,
      },
    }
    workspaces.open { directory = there, name = "there" }
    vim.wait(200)
    eq("follow: a handler that spawns elsewhere leaves this chat alone", chat.current().root, here)

    chat.close()
  end)

  bridge.ensure, bridge.request = old_ensure, old_request
  chat.load_settings = old_settings
  config.setup {}
  go_home()
  for _, dir in ipairs { here, there, empty } do
    vim.fn.delete(dir, "rf")
  end
  if not ok then
    error(err)
  end
end

local function test_follow()
  local transcript = require "paseo.ui.transcript"

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 60,
    height = 10,
    style = "minimal",
  })
  vim.wo[win].scrolloff = 0

  local chat = { conversation = buf, win_conversation = win }
  transcript.reset(chat)

  -- Twelve lines, which is both realistic for a tool card and comfortably more
  -- than the three the old heuristic allowed.
  local lines = {}
  for i = 1, 12 do
    lines[i] = "line " .. i
  end
  local block = table.concat(lines, "\n")

  local function showing_last()
    return vim.fn.line("w$", win) >= vim.api.nvim_buf_line_count(buf)
  end

  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: the first block scrolls into view", showing_last())
  -- The old code failed HERE and never recovered.
  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: and so does a second taller than three lines", showing_last())
  for _ = 1, 3 do
    transcript.upsert(chat, { kind = "text", text = block })
  end
  truthy("follow: still following five blocks later", showing_last())

  -- Streaming is the case that matters most: `stream` re-renders the open text
  -- block on every chunk rather than appending, so following has to survive a
  -- block that grows under it.
  for i = 1, 10 do
    transcript.stream(chat, ("chunk %d\n"):format(i))
  end
  truthy("follow: a streaming reply keeps the tail in view", showing_last())

  -- Scrolling back to reread something must not be yanked away.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: scrolled up, it stays where you put it", not showing_last())

  -- And returning to the bottom resumes it, with no flag to reset.
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  transcript.upsert(chat, { kind = "text", text = block })
  truthy("follow: and back at the bottom it picks up again", showing_last())

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--- Stopping a turn.
---
--- The plugin had no way to do this at all. The only interrupt it owned was
--- the permission dialog's "decline AND stop the turn", which is reachable
--- only while something is waiting to be answered -- so a turn that had gone
--- off on its own could be watched and not halted.
local function test_stop()
  local bridge = require "paseo.bridge"
  local chat = require "paseo.ui.chat"

  local old_request = bridge.request
  local asked = {}
  bridge.request = function(op, args, callback)
    asked[#asked + 1] = { op = op, agentId = args and args.agentId }
    if callback then
      callback(nil, { canceled = true })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local session = {
    agent_id = "a1",
    conversation = buf,
    streaming = true,
    root = vim.uv.cwd(),
    pending = {},
  }
  require("paseo.ui.transcript").reset(session)

  chat.stop(session)
  eq("stop: the daemon is asked to cancel", asked[1] and asked[1].op, "agent.cancel")
  eq("stop: for this chat's agent", asked[1] and asked[1].agentId, "a1")
  -- Optimistic, and it has to be: the header is the only thing saying a turn
  -- is running, and leaving the spinner going until the daemon says otherwise
  -- reads as the key not having worked.
  eq("stop: and the header stops spinning straight away", session.streaming, false)
  truthy(
    "stop: with a line in the transcript saying so",
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("stopped", 1, true)
      ~= nil
  )

  -- Nothing running is a no-op, never an error: `<C-c>` is a reflex, and being
  -- told off for stopping something already stopped is noise.
  asked = {}
  chat.stop(session)
  eq("stop: an idle agent is left alone", #asked, 0)

  local agentless = { conversation = buf, streaming = true, pending = {} }
  chat.stop(agentless)
  eq("stop: and so is a chat with no agent yet", #asked, 0)

  bridge.request = old_request
  vim.api.nvim_buf_delete(buf, { force = true })
end

--- The surface is yours, not the conversation's.
---
--- The bug: switching to a workspace whose chat had been open before landed
--- you on the default surface, whatever you had been on -- the chat
--- `agent.find` handed back was laid out with nothing to go on but
--- `ui.surface`.
local function test_surface_memory()
  local bridge = require "paseo.bridge"
  local chat = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local sidebar = require "paseo.ui.sidebar"
  local surface = require "paseo.ui.surface"
  local config = require "paseo.config"

  local old_ensure, old_request = bridge.ensure, bridge.request
  local old_settings = chat.load_settings
  local here, there = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(here, "p")
  vim.fn.mkdir(there, "p")
  local tabs = #vim.api.nvim_list_tabpages()

  local ok, err = pcall(function()
    config.setup {}
    surface.reset()
    chat.load_settings = function() end
    bridge.ensure = function(callback)
      callback(nil)
    end
    bridge.request = function(op, args, callback)
      if op == "agent.find" then
        return callback(nil, { id = "mem-" .. vim.fs.basename(args.cwd), provider = "test" })
      end
      if op == "timeline.history" then
        return callback(nil, { items = {} })
      end
      callback(nil, {})
    end
    local function on(root)
      return vim.wait(1000, function()
        return chat.current() ~= nil and chat.current().agent_id == "mem-" .. vim.fs.basename(root)
      end)
    end

    -- The sidebar first, because the native surface is the default and a
    -- memory that only ever answers the default proves nothing.
    chat.open { root = here, surface = "sidebar" }
    truthy("surface memory: opened on the sidebar", on(here) and sidebar.is_open(chat.current()))
    chat.follow(there)
    truthy("surface memory: a new workspace keeps the sidebar", on(there) and sidebar.is_open(chat.current()))
    -- The reported one: back to a chat this session has already seen.
    chat.follow(here)
    truthy("surface memory: so does one you have been to before", on(here))
    truthy("surface memory: and it is still the sidebar", sidebar.is_open(chat.current()))
    eq("surface memory: not the native surface", native.has(chat.current()), false)

    -- Closed and reopened: the surface you left on, not the default.
    chat.close()
    chat.forget()
    chat.open { root = there }
    truthy("surface memory: reopening comes back on the sidebar", on(there) and sidebar.is_open(chat.current()))

    -- `<C-f>` from the sidebar goes full screen: the native surface.
    chat.fullscreen()
    truthy("surface memory: <C-f> from the sidebar goes full screen", native.has(chat.current()))
    chat.surface "sidebar"
    truthy("surface memory: and back onto the sidebar", sidebar.is_open(chat.current()))
    chat.follow(here)
    truthy("surface memory: then home", on(here))

    -- COMING BACK TO A WORKSPACE: the draft you left in its composer is still
    -- there, and the conversation is at its END, not wherever you had last
    -- scrolled to.
    local mine = chat.current()
    local lines = {}
    for i = 1, 200 do
      lines[i] = "line " .. i
    end
    vim.bo[mine.conversation].modifiable = true
    vim.api.nvim_buf_set_lines(mine.conversation, 0, -1, false, lines)
    vim.bo[mine.conversation].modifiable = false
    vim.api.nvim_buf_set_lines(mine.composer, 0, -1, false, { "half a thought", "about the auth flow" })
    vim.api.nvim_win_set_cursor(mine.win_conversation, { 20, 0 })
    chat.follow(there)
    truthy("surface memory: away", on(there))
    chat.follow(here)
    truthy("surface memory: and back", on(here))
    eq("surface memory: it is the same chat", chat.current(), mine)
    eq(
      "surface memory: the draft came back with it",
      vim.api.nvim_buf_get_lines(mine.composer, 0, -1, false),
      { "half a thought", "about the auth flow" }
    )
    eq(
      "surface memory: and the conversation is at its end",
      vim.api.nvim_win_get_cursor(mine.win_conversation)[1],
      vim.api.nvim_buf_line_count(mine.conversation)
    )
    chat.close()
  end)

  chat.close()
  chat.forget()
  surface.reset()
  bridge.ensure, bridge.request = old_ensure, old_request
  chat.load_settings = old_settings
  while #vim.api.nvim_list_tabpages() > tabs do
    vim.cmd "tabclose!"
  end
  if not ok then
    error(err, 0)
  end
end

--- The "thinking…" line under the transcript (|paseo.ui.pending|).
---
--- With the rail shut, the gap between your first message and the first word
--- back showed nothing at all in the conversation -- a chat that was working
--- looked like one that had died. The line is the in-buffer answer.
local function test_pending()
  local chat = require "paseo.ui.chat"
  local hl = require "paseo.ui.hl"
  local transcript = require "paseo.ui.transcript"

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 60,
    height = 10,
    style = "minimal",
  })
  vim.wo[win].scrolloff = 0
  local session = { conversation = buf, win_conversation = win, root = vim.uv.cwd(), pending = {} }
  transcript.reset(session)
  transcript.upsert(session, { kind = "user", text = "hello" })

  local function marks()
    return vim.api.nvim_buf_get_extmarks(buf, hl.ns_pending, 0, -1, { details = true })
  end
  local function said(mark)
    local out = {}
    for _, chunk in ipairs(((mark or {})[4] or {}).virt_lines and mark[4].virt_lines[1] or {}) do
      out[#out + 1] = chunk[1]
    end
    return table.concat(out)
  end
  local function last_row()
    return vim.api.nvim_buf_line_count(buf) - 1
  end

  eq("pending: nothing while idle", #marks(), 0)

  chat.set_streaming(session, true)
  local now = marks()
  eq("pending: one line once the agent works", #now, 1)
  eq("pending: under the last line", now[1] and now[1][2], last_row())
  truthy("pending: saying so", said(now[1]):find("thinking", 1, true) ~= nil)

  -- A block landing moves it down: it never strands in the middle.
  local lines = {}
  for i = 1, 30 do
    lines[i] = "line " .. i
  end
  transcript.upsert(session, { kind = "text", text = table.concat(lines, "\n") })
  now = marks()
  eq("pending: still one after a block lands", #now, 1)
  eq("pending: and under the new last line", now[1] and now[1][2], last_row())

  -- Following the end, the virtual line is ON SCREEN -- Neovim leaves one
  -- below the last buffer line clipped unless something scrolls for it.
  local top = vim.fn.line("w0", win)
  local size = vim.api.nvim_win_text_height(win, { start_row = top - 1, end_row = last_row() })
  truthy("pending: scrolled into view", size.all + 1 <= vim.api.nvim_win_get_height(win))

  for i = 1, 5 do
    transcript.stream(session, ("chunk %d\n"):format(i))
  end
  eq("pending: streaming keeps it at the end", marks()[1] and marks()[1][2], last_row())

  -- A reset mid-turn -- the first message, between the agent being made and
  -- its history landing -- keeps it, on the emptied buffer.
  transcript.reset(session)
  eq("pending: a reset mid-turn keeps one", #marks(), 1)

  chat.set_streaming(session, false)
  eq("pending: gone when the turn ends", #marks(), 0)

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return {
  { "chat follows", test_chat_follow },
  { "surface memory", test_surface_memory },
  { "follow", test_follow },
  { "stop", test_stop },
  { "pending", test_pending },
}
