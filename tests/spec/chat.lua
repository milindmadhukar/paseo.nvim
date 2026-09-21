--- The chat window, and what it follows.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local go_home = t.go_home

--- The chat window follows a workspace switch.
---
--- The bug: with the dashboard up full screen, `<CR>` in the workspace picker
--- moved the editor and left the chat describing the workspace you had just
--- left -- and because a float belongs to the tab page it was opened on, the
--- default `"tab"` switch did not even leave it on screen.
local function test_chat_follow()
  local bridge = require "paseo.bridge"
  local chat = require "paseo.ui.chat"
  local float = require "paseo.ui.float"
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

    chat.open { root = here }
    truthy(
      "follow: the chat opens on the directory asked for",
      vim.wait(1000, function()
        return chat.current() ~= nil
          and chat.current().agent_id == "agent-" .. vim.fs.basename(here)
      end)
    )
    truthy("follow: on the full-screen surface", float.is_open(chat.current()))

    -- The bug, directly: the open window must end up on the new workspace.
    truthy("follow: an open chat follows the switch", chat.follow(there))
    truthy(
      "follow: onto the new workspace's agent",
      vim.wait(1000, function()
        return chat.current().agent_id == "agent-" .. vim.fs.basename(there)
      end)
    )
    eq("follow: and its root came with it", chat.current().root, there)
    truthy("follow: still on the full-screen surface", float.is_open(chat.current()))

    -- A float belongs to the tab page it was opened on, so the surface has to
    -- be rebuilt on the tab you are now standing on -- not merely refocused.
    local tabs = #vim.api.nvim_list_tabpages()
    local came_from = vim.api.nvim_get_current_tabpage()
    vim.cmd.tabnew()
    local landed_on = vim.api.nvim_get_current_tabpage()
    chat.follow(here)
    eq(
      "follow: the surface is rebuilt on the tab you are on now",
      vim.api.nvim_win_get_tabpage(chat.current().win_conversation),
      landed_on
    )
    truthy("follow: which is not the one it was opened on", landed_on ~= came_from)
    truthy("follow: and it is genuinely open there", float.is_open(chat.current()))
    chat.close()
    if vim.api.nvim_tabpage_is_valid(landed_on) then
      vim.api.nvim_set_current_tabpage(landed_on)
      vim.cmd.tabclose()
    end
    eq("follow: without leaking the tab", #vim.api.nvim_list_tabpages(), tabs)

    -- THE CRASH. Closing the surface from a tab page other than its own left
    -- the tab it was on pointing at a window that no longer existed; the next
    -- `:tabclose` died with `E315: ml_get: Invalid lnum`, or took the process
    -- down outright. It predates the follow -- open the chat, `gt`, close it --
    -- but the `"tab"` switch does exactly that shape of thing every time.
    tabs = #vim.api.nvim_list_tabpages()
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
    -- agent says so; it does not open a provider picker.
    local asked = false
    local create = require "paseo.ui.create"
    local old_review = create.review
    create.review = function()
      asked = true
    end
    chat.follow(empty)
    vim.wait(200)
    eq("follow: an agentless workspace does not open a provider picker", asked, false)
    create.review = old_review

    -- ...but asking for a chat there yourself still does.
    eq(
      "follow: `create` defaults back on for a chat you asked for",
      (function()
        local seen = false
        create.review = function()
          seen = true
        end
        chat.open { root = empty }
        vim.wait(200)
        create.review = old_review
        return seen
      end)(),
      true
    )

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

return {
  { "chat follows", test_chat_follow },
  { "follow", test_follow },
  { "stop", test_stop },
}
