--- Mode, model, thinking level and usage.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_settings()
  local chat_mod = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local render = require "paseo.ui.render"
  local sidebar = require "paseo.ui.sidebar"

  local modes = {
    { id = "plan", label = "Plan Mode" },
    { id = "default", label = "Always Ask" },
    { id = "acceptEdits", label = "Accept File Edits" },
    { id = "auto", label = "Auto mode" },
  }
  local chat = {
    root = assert(vim.uv.cwd()),
    agent_id = "spec-settings",
    mode = "Always Ask",
    config_snapshot = {
      modeId = "default",
      availableModes = modes,
      thinkingOptions = {},
      models = {},
      features = {},
    },
  }

  -- Redrawing the panels is a full repaint, so count the calls.
  local rebuilds = 0
  local real_rebuild = native.redraw_panels
  native.redraw_panels = function()
    rebuilds = rebuilds + 1
  end

  chat_mod.apply_settings(
    chat,
    { agentId = "spec-settings", modeId = "auto", availableModes = modes }
  )

  -- THE BUG: this stored the raw id, while `agent.config` stored the label, so
  -- one session read "Plan Mode" or "plan" in the header depending on which
  -- had spoken last.
  eq("settings: a pushed mode is stored as its label", chat.mode, "Auto mode")
  truthy(
    "settings: and the header says so",
    render.concat(sidebar.header(chat)):find("Auto mode", 1, true) ~= nil,
    render.concat(sidebar.header(chat))
  )
  -- The Agent panel draws its `●` from the snapshot, which nothing patched:
  -- the header could report a mode the panel below it still marked elsewhere.
  eq("settings: the panel's snapshot is patched too", chat.config_snapshot.modeId, "auto")
  eq("settings: a real change redraws the panel", rebuilds, 1)

  -- This payload arrives on every usage tick -- seven times in one short turn,
  -- measured against a live daemon -- and the mode is in all of them. A panel
  -- rebuild behind each would be a regeneration per token count.
  for used = 1000, 2000, 1000 do
    chat_mod.apply_settings(chat, {
      agentId = "spec-settings",
      modeId = "auto",
      availableModes = modes,
      usage = { contextWindowUsedTokens = used, contextWindowMaxTokens = 200000 },
    })
  end
  eq("settings: an unchanged mode does not redraw it again", rebuilds, 1)
  eq("settings: but the usage still lands", chat.usage.contextWindowUsedTokens, 2000)

  -- Features are compared by VALUE, not by the table they arrived in.
  chat_mod.apply_settings(chat, {
    agentId = "spec-settings",
    features = { { id = "fast_mode", value = true } },
  })
  eq("settings: a changed feature redraws the panel", rebuilds, 2)
  chat_mod.apply_settings(chat, {
    agentId = "spec-settings",
    features = { { id = "fast_mode", value = true } },
  })
  eq("settings: the same feature again does not", rebuilds, 2)

  -- A mode the provider did not report is still better shown than dropped.
  chat_mod.apply_settings(
    chat,
    { agentId = "spec-settings", modeId = "invented", availableModes = modes }
  )
  eq("settings: an unknown id falls back to itself", chat.mode, "invented")

  native.redraw_panels = real_rebuild

  -- Every live-agent model selector comes through `session.apply`. Selecting
  -- the current model is a no-op; an actual change asks whether to branch or
  -- affect future turns on the source agent.
  local session = require "paseo.ui.session"
  local bridge = require "paseo.bridge"
  local old_select, old_request = require("paseo.ui.choose").select, bridge.request
  local old_fork = package.loaded["paseo.fork"]
  local old_chat = package.loaded["paseo.ui.chat"]
  local prompts, forks, mutations = 0, 0, 0
  local choice, forked
  -- The destinations are the REAL ones. This dialog builds its fork entries
  -- from that table, so a stub with its own list would let the two drift
  -- apart -- which is the drift this dialog was changed to remove.
  local destinations = require("paseo.fork").DESTINATIONS
  package.loaded["paseo.fork"] = {
    DESTINATIONS = destinations,
    start = function(fork_chat, opts)
      eq("settings: a model fork targets this agent", fork_chat.agent_id, chat.agent_id)
      eq("settings: a model fork carries the selected model", opts.model_id, "new")
      forked = opts.destination
      forks = forks + 1
    end,
  }
  package.loaded["paseo.ui.chat"] = { load_settings = function() end }
  require("paseo.ui.choose").select = function(_, _, done)
    prompts = prompts + 1
    done(choice)
  end
  bridge.request = function(op, _, done)
    if op == "agent.setModel" then
      mutations = mutations + 1
      return done(nil, {})
    end
    if op == "agent.config" then
      return done(nil, chat.config_snapshot)
    end
    error("unexpected operation " .. op)
  end
  local model_group = {
    id = "model",
    kind = "radio",
    current = "old",
    op = "agent.setModel",
    arg = "modelId",
  }
  session.apply(chat, model_group, { id = "old" })
  eq("settings: reselecting the current model asks nothing", prompts, 0)

  choice = { id = "cancel" }
  session.apply(chat, model_group, { id = "new" })
  eq("settings: cancelling a model change mutates nothing", { forks, mutations }, { 0, 0 })
  -- BOTH FORKS ARE OFFERED HERE, under the same names the `f` key uses. The
  -- dialog used to have one "fork into a new workspace" and `f` had another,
  -- and a model change could only ever branch into a directory of its own.
  local offered = {}
  require("paseo.ui.choose").select = function(items, _, done)
    prompts = prompts + 1
    offered = vim.tbl_map(function(item)
      return item.id
    end, items)
    for _, item in ipairs(items) do
      if item.id == (choice or {}).id then
        return done(item)
      end
    end
    done(nil)
  end

  choice = { id = "session" }
  session.apply(chat, model_group, { id = "new" })
  eq("settings: the model dialog offers both forks", offered, {
    "session",
    "workspace",
    "future",
    "cancel",
  })
  eq("settings: a session fork leaves the source untouched", { forks, mutations }, { 1, 0 })
  eq("settings: and goes where the dialog said", forked, "session")

  choice = { id = "workspace" }
  session.apply(chat, model_group, { id = "new" })
  eq("settings: a workspace fork leaves the source untouched too", { forks, mutations }, { 2, 0 })
  eq("settings: and goes to a workspace", forked, "workspace")
  choice = { id = "future" }
  local completed = false
  session.apply(chat, model_group, { id = "new" }, function()
    completed = true
  end)
  vim.wait(100, function()
    return completed
  end)
  eq("settings: future turns uses the in-place model change", mutations, 1)

  require("paseo.ui.choose").select, bridge.request = old_select, old_request
  package.loaded["paseo.fork"] = old_fork
  package.loaded["paseo.ui.chat"] = old_chat
end

---Model, thinking, provider and mode open in the user's own picker.
local function test_pick()
  local pick = require "paseo.ui.pick"
  local choose = require "paseo.ui.choose"
  local real_select, real_choose = vim.ui.select, choose.select

  -- No picker plugin: the builtin `vim.ui.select` is `inputlist`, which cannot
  -- be searched, so the Paseo chooser stands in for it.
  eq("pick: the builtin vim.ui.select is not an override", pick.overridden(), false)
  local via
  choose.select = function(_, _, done)
    via = "choose"
    done(nil)
  end
  pick.select({ "a" }, {}, function() end)
  eq("pick: without a picker plugin, the Paseo chooser", via, "choose")

  -- snacks, telescope, fzf-lua: anything that replaces `vim.ui.select`.
  local seen
  vim.ui.select = function(items, opts, done)
    via = "vim.ui.select"
    seen = { items = items, opts = opts }
    done(items[2])
  end
  eq("pick: a replaced vim.ui.select is noticed", pick.overridden(), true)

  local group = {
    id = "thinking",
    label = "Thinking",
    current = "high",
    entries = {
      { id = "low", label = "Low" },
      { id = "high", label = "High", note = "default" },
    },
  }
  local got = {}
  truthy(
    "pick: a group opens",
    pick.group(group, function(entry)
      got[#got + 1] = entry.id
    end)
  )
  eq("pick: through the user's picker", via, "vim.ui.select")
  eq("pick: titled by the group", seen.opts.prompt, "Thinking")
  eq("pick: with a kind to theme by", seen.opts.kind, "paseo.thinking")
  eq("pick: what is set comes first", seen.items[1].id, "high")
  eq("pick: and is marked, with its note", seen.opts.format_item(seen.items[1]), "● High · default")
  eq("pick: the rest are not marked", seen.opts.format_item(seen.items[2]), "  Low")
  eq("pick: the answer comes back", got, { "low" })

  -- Picking what is already set is "leave it", not a round trip.
  vim.ui.select = function(items, _, done)
    done(items[1])
  end
  pick.group(group, function(entry)
    got[#got + 1] = entry.id
  end)
  eq("pick: re-picking what is set changes nothing", got, { "low" })

  -- An empty list says why instead of opening an empty picker.
  local notified
  local real_notify = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  local opened = pick.group({ id = "model", label = "Model", entries = {} }, function() end)
  vim.notify = real_notify
  eq("pick: an empty group does not open", opened, false)
  truthy("pick: and says so", notified and notified:find("no model", 1, true) ~= nil, notified)

  -- `:Paseo settings mode` is the picker, straight away: no card in front.
  local bridge = require "paseo.bridge"
  local old_request, old_chat = bridge.request, package.loaded["paseo.ui.chat"]
  local chat = {
    agent_id = "spec-pick",
    config_snapshot = nil,
  }
  local config = {
    modeId = "default",
    availableModes = {
      { id = "plan", label = "Plan" },
      { id = "default", label = "Always ask" },
    },
    thinkingOptions = {},
    models = {},
    features = {},
  }
  package.loaded["paseo.ui.chat"] = {
    current = function()
      return chat
    end,
    load_settings = function() end,
  }
  local set_to
  bridge.request = function(op, args, done)
    if op == "agent.config" then
      return done(nil, config)
    end
    if op == "agent.setMode" then
      set_to = args.modeId
      return done(nil, {})
    end
    error("unexpected operation " .. op)
  end
  local offered
  vim.ui.select = function(items, opts, done)
    offered = opts.kind
    done(items[2])
  end
  require("paseo.ui.session").mode()
  vim.wait(200, function()
    return set_to ~= nil
  end)
  eq("pick: :Paseo settings mode opens the mode picker", offered, "paseo.mode")
  eq("pick: and the answer is written to the agent", set_to, "plan")
  eq("pick: with no settings popup in between", require("paseo.ui.settings").is_open(), false)

  -- A yes-or-no is asked in the same picker, the safe answer first.
  local asked
  vim.ui.select = function(items, opts, done)
    asked = { items = items, opts = opts }
    done(items[2], 2)
  end
  local yes
  pick.confirm("Archive this agent?", { yes = "Archive" }, function(answer)
    yes = answer
  end)
  eq("pick: confirm goes through the user's picker", asked.opts.kind, "paseo.confirm")
  eq("pick: with the safe answer first", asked.items, { "Cancel", "Archive" })
  eq("pick: and the yes comes back as true", yes, true)
  vim.ui.select = function(_, _, done)
    done(nil, nil)
  end
  pick.confirm("Archive this agent?", {}, function(answer)
    yes = answer
  end)
  eq("pick: cancelling a confirm is a no", yes, false)

  -- Archiving an agent from the tree asks through it.
  local archived
  bridge.request = function(op, args)
    if op == "agent.archive" then
      archived = args.agentId
    end
  end
  vim.ui.select = function(items, opts, done)
    asked = { items = items, opts = opts }
    done(items[1], 1)
  end
  require("paseo.ui.tree").remove({ kind = "agent", item = { id = "spec-archive" } }, {})
  eq("pick: the tree's archive asks in the picker", asked.opts.prompt, "Archive this agent?")
  eq("pick: and a no archives nothing", archived, nil)
  vim.ui.select = function(items, _, done)
    done(items[2], 2)
  end
  require("paseo.ui.tree").remove({ kind = "agent", item = { id = "spec-archive" } }, {})
  eq("pick: a yes archives it", archived, "spec-archive")

  bridge.request, package.loaded["paseo.ui.chat"] = old_request, old_chat
  vim.ui.select, choose.select = real_select, real_choose
end

return {
  { "settings", test_settings },
  { "pick", test_pick },
}
