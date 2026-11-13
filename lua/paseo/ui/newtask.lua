--- The new-task screen: everything there is to start, on one screen, with the
--- box you type the first prompt in already focused.
---
--- WHAT IT REPLACED was a chain of `vim.ui.select`s -- "new agent / new agent
--- in a new workspace / new terminal", then "here / a new workspace", then a
--- name for the workspace, then the settings popup -- which asked, in Paseo's
--- own nouns, the question the app does not: what is an agent, what is a
--- workspace, which one do you want. The app answers with ONE screen: a box
--- for the first message, and chips under it for what can vary. So does this.
---
--- THE LAYOUT IS THE CHAT'S OWN. It is a draft chat (|paseo.ui.chat|.draft)
--- -- the composer you will keep typing in, with its images, dictation and
--- keys -- whose conversation window shows the choices until the first
--- message turns the draft into a real agent. Then the conversation comes
--- back and nothing else moves.
---
---   ┌ Chat | Terminal ─────── Here | New worktree ┐
---   │ Base   main  dev  feat/x  …                  │
---   │ Provider · Model · Mode · Thinking · Features│   (a chat)
---   │ Preset  Shell  claude  codex  pi  Command…   │   (a terminal)
---   ├──────────────────────────────────────────────┤
---   │ ▌ the first prompt                           │   composer, insert mode
---   └──────────────────────────────────────────────┘
---
--- Every choice is PREFILLED: from what you chose last in this project, else
--- last anywhere, else the config and the daemon (|paseo.new|). Nothing is
--- asked that this Neovim already knows -- the project and the host are
--- where you are -- and a worktree is not named: the daemon names it.

local new = require "paseo.new"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.newtask"

M.FILETYPE = "paseo-new"

---The mnemonics. `a` for what to start (Agent or terminal) because `c`,
---`t` and `s` are taken by the settings cards it shares a screen with.
M.KEYS = {
  kind = "a",
  where = "w",
  base = "b",
  preset = "c",
  provider = "p",
  model = "s",
  mode = "m",
  thinking = "t",
  features = "f",
}

---How many of the most recent branches are chips; the rest are a `…` away.
local RECENT = 4

---The task being set up, per draft chat.
---@class paseo.NewTask
---@field ctx paseo.StartContext
---@field chat table           The draft chat.
---@field kind "chat"|"terminal"
---@field where "here"|"worktree"
---@field iso table|nil        |paseo.new|.isolation: can a new one be made here?
---@field base string|nil      An explicit base; nil is what is checked out.
---@field branches string[]|nil
---@field draft paseo.Draft|nil  Provider, model, mode… once the catalogue lands.
---@field presets table[]|nil
---@field preset string|nil    A preset's label.
---@field remembered table
---@field error string|nil
---@field buf integer|nil      The options buffer.
---@field view table|nil       The settings View drawing it.
---@field busy boolean

---@type table<table, paseo.NewTask>
local tasks = {}

-- ------------------------------------------------------------------ choice

---What the screen says right now, as |paseo.new| takes it.
---@param task paseo.NewTask
---@return paseo.NewChoice
local function choice(task)
  local out = {
    kind = task.kind,
    where = task.where,
    base = task.base,
    preset = task.preset,
  }
  if task.draft then
    local settings = require("paseo.ui.draft").result(task.draft)
    out.provider = settings.provider
    out.modeId = settings.modeId
    out.thinkingOptionId = settings.thinkingOptionId
    out.featureValues = settings.featureValues
  end
  return out
end

---The base a worktree will be cut from.
---@param task paseo.NewTask
---@return string|nil
local function base_of(task)
  return task.base or (task.iso and task.iso.base)
end

---Keep the draft chat's own idea of its settings in step: its bar shows the
---provider and mode, and binding the agent remembers the provider.
---@param task paseo.NewTask
local function sync(task)
  local chat = task.chat
  if not (chat and chat.draft and task.draft) then
    return
  end
  local c = choice(task)
  chat.draft.settings = {
    provider = c.provider,
    modeId = c.modeId,
    thinkingOptionId = c.thinkingOptionId,
    featureValues = c.featureValues,
  }
  chat.provider = c.provider
  chat.mode = c.modeId
  pcall(function()
    require("paseo.ui.composer").refresh(chat)
  end)
end

-- ------------------------------------------------------------------ groups

---@param task paseo.NewTask
---@return table[]
local function groups(task)
  local out = {
    {
      id = "kind",
      key = M.KEYS.kind,
      icon = "",
      label = "Start",
      kind = "chips",
      entries = {
        { id = "chat", label = "Chat", description = "an agent, with your first message as its prompt" },
        { id = "terminal", label = "Terminal", description = "a shell, or claude / codex / pi in one" },
      },
      current = task.kind,
    },
  }

  if task.iso then
    out[#out + 1] = {
      id = "where",
      key = M.KEYS.where,
      icon = "",
      label = "Where",
      kind = "chips",
      entries = {
        { id = "here", label = "Here", description = "in this checkout, beside whatever else works in it" },
        {
          id = "worktree",
          label = task.iso.label,
          description = task.iso.kind == "worktree"
              and "a directory and branch of its own -- named for you from your first message"
            or "every repo's worktree, assembled -- named for you from your first message",
        },
      },
      current = task.where,
    }
  end

  if task.where == "worktree" and task.iso and task.iso.kind == "worktree" then
    local current = base_of(task)
    local entries, seen = {}, {}
    local function add(name, note)
      if name and not seen[name] then
        seen[name] = true
        entries[#entries + 1] = { id = name, label = name, note = note }
      end
    end
    add(current)
    for _, branch in ipairs(task.branches or {}) do
      if #entries > RECENT then
        break
      end
      add(branch)
    end
    entries[#entries + 1] = { id = "@pick", label = "…", description = "any branch, local or remote" }
    out[#out + 1] = {
      id = "base",
      key = M.KEYS.base,
      icon = "",
      label = "Base",
      kind = "chips",
      entries = entries,
      current = current,
    }
  end

  if task.kind == "terminal" then
    local entries = {}
    for _, preset in ipairs(task.presets or {}) do
      entries[#entries + 1] = {
        id = preset.label,
        label = preset.label,
        note = preset.note or preset.command,
        preset = preset,
      }
    end
    out[#out + 1] = {
      id = "preset",
      key = M.KEYS.preset,
      icon = "",
      label = "Run",
      kind = "radio",
      entries = entries,
      current = task.preset,
      placeholder = task.presets and "nothing to run" or "loading…",
    }
    return out
  end

  if task.draft then
    vim.list_extend(out, require("paseo.ui.draft").groups(task.draft))
  else
    out[#out + 1] = {
      id = "provider",
      key = M.KEYS.provider,
      icon = "󱚠",
      label = "Provider",
      kind = "chips",
      entries = {},
      placeholder = task.error or "loading…",
    }
  end
  return out
end

-- ------------------------------------------------------------------ drawing

---@param task paseo.NewTask
---@return integer|nil
local function win_of(task)
  local win = task.chat and task.chat.win_conversation
  if win and api.nvim_win_is_valid(win) and task.buf and api.nvim_win_get_buf(win) == task.buf then
    return win
  end
end

---@param task paseo.NewTask
local function draw(task)
  local win = win_of(task)
  if not (win and task.view and task.buf and api.nvim_buf_is_valid(task.buf)) then
    return
  end
  local width = math.max(20, api.nvim_win_get_width(win) - 2)
  local height = api.nvim_win_get_height(win)
  local ok, lines = pcall(task.view.lines, task.view, width, height)
  if not ok then
    lines = { { { "  " .. tostring(lines), "PaseoToolFail" } } }
  end
  local render = require "paseo.ui.render"
  vim.bo[task.buf].modifiable = true
  render.to_buffer(task.buf, ns, 0, -1, lines)
  vim.bo[task.buf].modifiable = false
end

---The row under the cards: what happens next, in words.
---@param task paseo.NewTask
---@return fun(width: integer): table[][]
local function footer(task)
  local widgets = require "paseo.ui.widgets"
  local keys = require "paseo.ui.keys"
  return function(w)
    local line
    if task.busy then
      line = { { "  starting…", "PaseoDim" } }
    elseif task.kind == "terminal" then
      line = { widgets.keycap "<CR>", { "  on one of them starts it", "PaseoDim" } }
    else
      local send = keys.label("composer", "<CR>") or "<M-CR>"
      local where = task.where == "worktree"
          and (task.iso and task.iso.kind == "worktree" and ("a worktree off " .. (base_of(task) or "?")) or "a new workspace")
        or "here"
      line = {
        { "  Type below; ", "PaseoDim" },
        widgets.keycap(send),
        { (" sends it, %s"):format(where), "PaseoDim" },
      }
    end
    return { line, {} }
  end
end

-- ------------------------------------------------------------------ actions

---Take the screen down, leaving the draft chat as an ordinary chat (or not at
---all, when what was made lives elsewhere).
---@param task paseo.NewTask
local function unmount(task)
  local chat = task.chat
  tasks[chat] = nil
  if task.view and task.buf and api.nvim_buf_is_valid(task.buf) then
    task.view:unbind(task.buf)
  end
  local win = chat.win_conversation
  if win and api.nvim_win_is_valid(win) and chat.conversation and api.nvim_buf_is_valid(chat.conversation) then
    if task.buf and api.nvim_win_get_buf(win) == task.buf then
      api.nvim_win_set_buf(win, chat.conversation)
      vim.wo[win].wrap = true
      vim.wo[win].cursorline = false
    end
  end
  if chat.composer and api.nvim_buf_is_valid(chat.composer) then
    for _, lhs in ipairs(task.composer_keys or {}) do
      pcall(vim.keymap.del, "n", lhs, { buffer = chat.composer })
    end
  end
  if task.buf and api.nvim_buf_is_valid(task.buf) then
    pcall(api.nvim_buf_delete, task.buf, { force = true })
  end
  task.buf = nil
end

---Throw the draft away: what was made opened somewhere of its own, or you
---backed out.
---@param task paseo.NewTask
local function abandon(task)
  local chat = task.chat
  unmount(task)
  local chats = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  if native.has(chat) then
    native.close(chat)
  elseif chats.current() == chat then
    pcall(chats.close)
  end
  chats.discard(chat)
end

---@param task paseo.NewTask
local function remember(task)
  new.remember(task.ctx, choice(task))
end

---Start the terminal `entry` names.
---@param task paseo.NewTask
---@param preset table
local function start_terminal(task, preset)
  local function go(resolved)
    task.busy = true
    draw(task)
    new.terminal(task.ctx, choice(task), resolved, function(_, err)
      task.busy = false
      if err then
        draw(task)
        return vim.notify("paseo: could not start a terminal — " .. tostring(err), vim.log.levels.ERROR)
      end
      remember(task)
      -- The terminal is on a tab of its own now; the draft has nothing left
      -- to be. Closed AFTER, so its tab is not what the new one replaces.
      vim.schedule(function()
        abandon(task)
      end)
    end)
  end
  if preset.prompt then
    return vim.ui.input({ prompt = "Command: " }, function(command)
      if command and vim.trim(command) ~= "" then
        go { command = command, label = command }
      end
    end)
  end
  go(preset)
end

---Apply one chip.
---@param task paseo.NewTask
---@param group table
---@param entry table
---@param done fun()
local function apply(task, group, entry, done)
  if group.id == "kind" then
    task.kind = entry.id
    return done()
  end
  if group.id == "where" then
    task.where = entry.id
    return done()
  end
  if group.id == "base" then
    if entry.id ~= "@pick" then
      -- The checked-out branch is "no explicit choice": remembered as that,
      -- so it follows you when you switch branch.
      task.base = entry.id ~= (task.iso and task.iso.base) and entry.id or nil
      return done()
    end
    local list = task.branches or {}
    return vim.ui.select(list, { prompt = "Cut the worktree from…" }, function(branch)
      if branch then
        task.base = branch ~= (task.iso and task.iso.base) and branch or nil
      end
      done()
    end)
  end
  if group.id == "preset" then
    task.preset = entry.id
    done()
    return start_terminal(task, entry.preset or {})
  end
  if task.draft then
    return require("paseo.ui.draft").apply(task.draft, group, entry, function()
      sync(task)
      done()
    end)
  end
  done()
end

---The first message, from the composer: |paseo.ui.chat|'s draft calls this.
---@param task paseo.NewTask
---@param prompt string
---@param images table[]
---@param done fun(err: string|nil, agent_id: string|nil)
local function start_chat(task, prompt, images, done)
  if task.kind == "terminal" then
    return done "a terminal takes no prompt — pick what to run above and press <CR> on it"
  end
  if not task.draft then
    return done(task.error or "still asking the daemon which models there are")
  end
  if task.draft.loading then
    return done "still reading this model's features — send again in a moment"
  end
  task.busy = true
  draw(task)
  local switch = not require("paseo.ui.native").has(task.chat)
  new.chat(task.ctx, choice(task), prompt, images, function(err, agent_id)
    task.busy = false
    if err then
      draw(task)
      return done(err)
    end
    remember(task)
    if agent_id then
      -- HERE: this chat becomes the agent. The conversation comes back.
      unmount(task)
      return done(nil, agent_id)
    end
    -- A new worktree: its chat is open on a tab of its own.
    abandon(task)
    done(nil, nil)
  end, { switch = switch })
end

-- ----------------------------------------------------------------- loading

---Ask the daemon what there is: the models, the terminals, the branches.
---Each lands on its own and redraws.
---@param task paseo.NewTask
---@param done fun()
local function load(task, done)
  local ctx, remembered = task.ctx, task.remembered
  local cwd = ctx.root
  local draft_model = require "paseo.ui.draft"

  require("paseo.ui.create").catalogue(cwd, function(entries, err)
    vim.schedule(function()
      if not tasks[task.chat] then
        return
      end
      if err or not entries then
        task.error = "could not ask the daemon: " .. tostring(err)
        return done()
      end
      local create = require "paseo.ui.create"
      local selection = create.find(entries, remembered.provider)
        or create.find(entries, ctx.preferred)
        or draft_model.first(entries)
      if not selection then
        task.error = "no provider on this daemon has a model ready"
        return done()
      end
      local draft = draft_model.new(cwd, entries, selection, ctx.host_id)
      -- What you chose last, where this provider and model still offer it.
      if remembered.provider == selection.provider then
        for _, mode in ipairs(selection.entry.modes or {}) do
          if mode.id == remembered.modeId then
            draft.modeId = mode.id
          end
        end
        for _, option in ipairs(selection.model.thinkingOptions or {}) do
          if option.id == remembered.thinkingOptionId then
            draft.thinkingOptionId = option.id
          end
        end
        if type(remembered.featureValues) == "table" then
          draft.featureValues = vim.deepcopy(remembered.featureValues)
        end
      end
      task.draft = draft
      sync(task)
      draft_model.refresh_features(draft, true, function()
        sync(task)
        done()
      end)
    end)
  end, ctx.host_id)

  require("paseo.terminals").presets(cwd, function(presets)
    vim.schedule(function()
      task.presets = presets
      local known = false
      for _, preset in ipairs(presets) do
        known = known or preset.label == task.preset
      end
      if not known then
        task.preset = presets[1] and presets[1].label or nil
      end
      done()
    end)
  end, ctx.host_id)

  if task.iso and task.iso.kind == "worktree" then
    require("paseo.workspaces").branches(cwd, function(branches)
      vim.schedule(function()
        task.branches = branches
        -- A remembered base that is gone is no base: what is checked out.
        if task.base and not vim.tbl_contains(branches, task.base) then
          task.base = nil
        end
        done()
      end)
    end, ctx.host_id, ctx.local_root)
  end
end

-- -------------------------------------------------------------------- open

---Focus the box you type in, in insert mode.
---@param task paseo.NewTask
local function to_composer(task)
  local win = task.chat.win_composer
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
    vim.cmd.startinsert { bang = true }
  end
end

---Focus the choices.
---@param task paseo.NewTask
local function to_options(task)
  local win = win_of(task)
  if win then
    pcall(vim.cmd.stopinsert)
    api.nvim_set_current_win(win)
  end
end

---Put the choices in the draft chat's conversation window.
---@param task paseo.NewTask
local function mount(task)
  local chat = task.chat
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local buf = api.nvim_create_buf(false, true)
  task.buf = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = M.FILETYPE
  vim.bo[buf].modifiable = false
  pcall(api.nvim_buf_set_name, buf, ("paseo://new/%d"):format(buf))
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].fillchars = "eob: "

  local keys = require "paseo.ui.keys"
  local view = require("paseo.ui.panels.settings").new({
    keys = M.KEYS,
    pairs = { { "kind", "where" }, { "provider", "mode" }, { "thinking", "features" } },
    groups = function()
      return groups(task)
    end,
    apply = function(_, group, entry, done)
      apply(task, group, entry, done)
    end,
    load = function(_, done)
      load(task, done)
    end,
  }, {
    hints = {
      { keys.label("composer", "i") or "i", "type" },
      { "q", "cancel" },
    },
    redraw = function()
      vim.schedule(function()
        draw(task)
      end)
    end,
  })
  view.footer = footer(task)
  task.view = view
  view:bind(buf)

  local opts = { buffer = buf, nowait = true, silent = true }
  local function map(lhs, fn, desc)
    for _, key in ipairs(keys.list(lhs)) do
      vim.keymap.set("n", key, fn, vim.tbl_extend("force", opts, { desc = "paseo: " .. desc }))
    end
  end
  -- Back to the box: `i`, `<Tab>`, or just `<C-w>j` -- it is a split.
  map({ "i", "<Tab>", "A", "o" }, function()
    to_composer(task)
  end, "type the first message")
  map("q", function()
    abandon(task)
  end, "cancel")
  -- The surface's own keys work here too, as on every one of its buffers.
  local nkeys = require("paseo.config").get().ui.native.keys or {}
  map(nkeys.rail, function()
    require("paseo.ui.native").toggle_rail()
  end, "show or hide the workspace rail")
  map(nkeys.focus, function()
    require("paseo.ui.native").focus_rail()
  end, "into the workspace rail")

  -- From the box to the choices: `<Tab>` in normal mode, where it means
  -- nothing in a composer.
  task.composer_keys = {}
  if chat.composer and api.nvim_buf_is_valid(chat.composer) then
    for _, lhs in ipairs(keys.resolve("composer", "<Tab>")) do
      vim.keymap.set("n", lhs, function()
        to_options(task)
      end, { buffer = chat.composer, nowait = true, silent = true, desc = "paseo: the choices" })
      task.composer_keys[#task.composer_keys + 1] = lhs
    end
  end

  draw(task)
  load(task, function()
    draw(task)
  end)
end

---Open the screen.
---
---On the chat's surface, as a draft: the native surface gives it a tab of its
---own, the sidebar its window. The composer is focused, in insert mode, so
---the first thing you do is type.
---@param ctx paseo.StartContext
---@param opts { kind?: "chat"|"terminal", where?: "here"|"worktree" }
---@return table chat  The draft chat.
function M.open(ctx, opts)
  if api.nvim_get_mode().mode == "t" then
    pcall(vim.cmd.stopinsert)
  end
  local remembered = new.remembered(ctx)
  local iso = new.isolation(ctx)
  local task = {
    ctx = ctx,
    remembered = remembered,
    iso = iso,
    kind = opts.kind or remembered.kind or "chat",
    where = opts.where or remembered.where or "here",
    base = remembered.base,
    preset = remembered.preset,
    busy = false,
  }
  if not iso then
    task.where = "here"
  end
  if ctx.project == nil then
    local host = require("paseo.hosts").get(ctx.host_id)
    if host and host.local_host then
      ctx.project = require("paseo.workspaces").parent_project(ctx.local_root or ctx.root)
    end
  end

  local chat = require("paseo.ui.chat").draft {
    root = ctx.root,
    local_root = ctx.local_root,
    host_id = ctx.host_id,
    project = ctx.project,
    settings = {},
    banner = "new task",
    start = function(prompt, images, done)
      start_chat(task, prompt, images, done)
    end,
  }
  task.chat = chat
  tasks[chat] = task
  mount(task)
  to_composer(task)
  -- Again on the next tick: opened from TERMINAL mode (a key mapped in `t`),
  -- leaving the terminal's window ends terminal mode after this has run and
  -- takes the insert with it, so the first words typed were normal-mode
  -- commands -- "Fix the invoice" arrived as "nvoice".
  vim.schedule(function()
    if tasks[chat] and api.nvim_get_current_win() == chat.win_composer and api.nvim_get_mode().mode ~= "i" then
      to_composer(task)
    end
  end)
  return chat
end

---The task a draft chat is setting up, if it is one.
---@param chat table
---@return paseo.NewTask|nil
function M.task(chat)
  return tasks[chat]
end

---Redraw every open screen (a resize).
function M.redraw()
  for _, task in pairs(tasks) do
    draw(task)
  end
end

return M
