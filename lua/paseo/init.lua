--- paseo.nvim -- drive Paseo agents from Neovim, and ask one about the code
--- under your cursor.
---
--- Entry point. Holds `setup()`, the `:Paseo` command, and nothing else:
--- submodules are required lazily from the dispatch table below so that loading
--- this file costs a config merge and one autocmd.

local M = {}

M.config = require "paseo.config"

---The full-screen surface's actions: `require("paseo").native.toggle_rail()`
---and the rest, |paseo-native-api|. Loaded on first use.
---@module "paseo.native"
M.native = setmetatable({}, {
  __index = function(_, key)
    return require("paseo.native")[key]
  end,
})

---@type table<string, { run: fun(args: string[]), desc: string, complete?: fun(lead: string, args: string[]): string[] }>
local commands = {}

---@param args string[]
---@return table|nil m, string|nil root, string|nil err
local function project(args)
  local registry = require "paseo.registry"
  local root = registry.project_root(args and args.root)
  if not root then
    return nil,
      nil,
      "no .workspaces/workspace.toml here or above — `:Paseo new worktree` needs none, and "
        .. "writes one if this project turns out to want one"
  end
  local m, err = require("paseo.workspace.manifest").load(root)
  if not m then
    return nil, nil, err
  end
  return m, root, nil
end

---Split `a,b` or `a b` into a list.
---@param text string|nil
---@return string[]
local function split(text)
  if not text or text == "" then
    return {}
  end
  return vim.split(text, "[,%s]+", { trimempty = true })
end

commands.ws = {
  desc = "Manifest-level: init [raw] | edit | create <name> [repos] | rm <name> [force] | ls | status",
  run = function(args)
    local sub = args[1] or "ls"
    local workspace = require "paseo.workspace"
    local registry = require "paseo.registry"

    if sub == "init" then
      -- `raw` anywhere in the words after `init`; whatever else is there is
      -- the root. Same word-flag shape as `ws rm <name> force`.
      local raw, where = false, nil
      for i = 2, #args do
        if args[i] == "raw" then
          raw = true
        else
          where = args[i]
        end
      end
      -- The project the cwd is IN, when it has a manifest: run from inside a
      -- workspace or one of its repos, the cwd is not the project, and a
      -- screen opened on it would discover a different one.
      local root = where and vim.fn.fnamemodify(vim.fn.expand(where), ":p")
        or registry.project_root()
        or assert(vim.uv.cwd())
      root = root:gsub("/+$", "")

      local ui = require "paseo.ui.manifest"
      local draft, derr = ui.draft(root)
      if not draft then
        return vim.notify("paseo: " .. tostring(derr), vim.log.levels.ERROR)
      end

      -- `raw` is the old behaviour kept whole: the generated TOML in a buffer
      -- you `:w` yourself. It gets the same MERGED draft the dialog would, so
      -- opening the file by hand does not silently discard a pruned `shared`
      -- list the way re-running discovery into it would.
      if raw then
        return ui.edit(root, ui.result(draft), ui.notes(draft))
      end

      return ui.review({ root = root }, function(edited, notes)
        if not edited then
          return
        end
        local ok, save_err = workspace.manifest.save(root, edited, notes)
        if not ok then
          return vim.notify("paseo: " .. tostring(save_err), vim.log.levels.ERROR)
        end
        vim.notify(
          ("paseo: wrote %s"):format(vim.fn.fnamemodify(workspace.manifest.path(root), ":~")),
          vim.log.levels.INFO
        )
      end)
    end

    if sub == "edit" then
      -- The FILE, as it is on disk, comments and all -- where `init raw` hands
      -- you a freshly rendered draft under that name. No manifest yet means
      -- there is nothing to edit, so the screen that writes one opens instead.
      local where = args[2] and vim.fn.fnamemodify(vim.fn.expand(args[2]), ":p")
      local root = where or registry.project_root()
      local path = root and workspace.manifest.find((root:gsub("/+$", "")))
      if not path then
        vim.notify("paseo: no workspace.toml here or above; opening the setup screen", vim.log.levels.INFO)
        return commands.ws.run(where and { "init", where } or { "init" })
      end
      local native = package.loaded["paseo.ui.native"]
      if native and native.on_tab() then
        return native.edit(path)
      end
      vim.cmd.edit(vim.fn.fnameescape(path))
      return
    end

    local m, root, err = project { root = nil }
    if not m then
      -- `create` is the one subcommand that does not need a manifest: the
      -- unified path writes one when the project wants one, and skips assembly
      -- entirely when Paseo's own worktree isolation applies. Only a subcommand
      -- that must READ the manifest -- rm, ls, status -- fails here.
      if sub == "create" and args[2] and not args[3] then
        return require("paseo.new").open(nil, { where = "worktree" })
      end
      return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end

    if sub == "create" then
      local name = args[2]
      if not name then
        return vim.notify("paseo: usage :Paseo ws create <name> [repo,repo]", vim.log.levels.ERROR)
      end
      if registry.find(name, root) then
        return vim.notify(("paseo: workspace %q already exists"):format(name), vim.log.levels.ERROR)
      end

      local ws, create_err =
        workspace.create(m, { name = name, root = root, only = split(args[3]) })
      if not ws then
        return vim.notify("paseo: " .. create_err, vim.log.levels.ERROR)
      end
      registry.add(ws)

      -- Hand the assembled directory to the daemon as a plain local workspace.
      -- Best-effort: a daemon that is down must not cost you a workspace whose
      -- worktrees are already on disk.
      local bridge = require "paseo.bridge"
      bridge.ensure(function(bridge_err)
        if not bridge_err then
          bridge.request("workspace.open", { cwd = ws.root, project = root }, function() end)
        end
      end)

      local lines = { ws.root }
      for _, repo in ipairs(ws.repos) do
        if repo.state == "active" then
          lines[#lines + 1] = ("  %s  %s"):format(repo.name, repo.branch)
        end
      end
      return vim.notify(
        table.concat(lines, "\n"),
        vim.log.levels.INFO,
        { title = "paseo: created" }
      )
    end

    if sub == "rm" then
      local name = args[2]
      local ws = name and registry.find(name, root)
      if not ws then
        return vim.notify(
          ("paseo: no workspace %q here"):format(tostring(name)),
          vim.log.levels.ERROR
        )
      end
      local ok, rm_err = workspace.remove(ws, { force = args[3] == "force" })
      if not ok then
        return vim.notify("paseo: " .. rm_err, vim.log.levels.WARN)
      end
      registry.remove(name, root)
      return vim.notify("paseo: removed " .. name, vim.log.levels.INFO)
    end

    if sub == "status" then
      local lines = {}
      for _, ws in ipairs(registry.list()) do
        if ws.project == root then
          lines[#lines + 1] = ws.name
          for _, repo in ipairs(registry.active(ws)) do
            lines[#lines + 1] = ("  %-20s %s"):format(repo.name, repo.branch or "")
          end
        end
      end
      return vim.notify(
        #lines > 0 and table.concat(lines, "\n") or "no workspaces",
        vim.log.levels.INFO
      )
    end

    -- ls
    local lines = {}
    for _, ws in ipairs(registry.list()) do
      if ws.project == root then
        lines[#lines + 1] = ("%-24s %d repo(s)  %s"):format(ws.name, #registry.active(ws), ws.root)
      end
    end
    vim.notify(
      #lines > 0 and table.concat(lines, "\n") or "no workspaces here",
      vim.log.levels.INFO
    )
  end,
  complete = function(_, args)
    if #args <= 1 then
      return { "init", "edit", "create", "rm", "ls", "status" }
    end
    return {}
  end,
}

commands.workspaces = {
  desc = "Workspaces in this project (`all`: every project's)",
  run = function(args)
    M.workspaces { all = args[1] == "all" }
  end,
  complete = function()
    return { "all" }
  end,
}

commands.agents = {
  desc = "Agents in the workspace containing this directory",
  run = function()
    M.agents()
  end,
}

commands.new = {
  desc = "Start something: a chat here or in a new worktree, or a terminal",
  run = function(args)
    M.new_task(args[1] == "worktree" and { where = "worktree" } or nil)
  end,
  complete = function()
    return { "worktree" }
  end,
}

local REF_KINDS = { "hunk", "visual", "file", "cursor" }

commands.ask = {
  desc = "Ask about the hunk/selection/file (`qf`: every quickfix entry)",
  run = function(args)
    M.ask(args[1])
  end,
  complete = function()
    return vim.list_extend(vim.deepcopy(REF_KINDS), { "qf" })
  end,
}

commands.explain = {
  desc = "Explain the hunk/selection/file, using the rubric",
  run = function(args)
    M.explain(args[1])
  end,
  complete = function()
    return REF_KINDS
  end,
}

local SETTINGS = { "mode", "thinking", "model", "features" }

commands.settings = {
  desc = "The chat agent's settings: mode, thinking, model, features",
  run = function(args)
    M.settings(args[1])
  end,
  complete = function()
    return SETTINGS
  end,
}

commands.stop = {
  desc = "Interrupt the turn the chat's agent is running",
  run = function()
    M.stop()
  end,
}

-- ----------------------------------------------------------------- the API

---Open or close the chat, on the surface `ui.surface` names.
function M.toggle()
  require("paseo.ui.chat").toggle()
end

---Ask about code: the hunk, selection or file, or every quickfix entry.
---@param kind? "hunk"|"visual"|"file"|"cursor"|"qf"
function M.ask(kind)
  if kind == "qf" then
    return require("paseo.explain").quickfix()
  end
  require("paseo.explain").ask(kind)
end

---Explain the hunk, selection or file, using the bundled rubric.
---@param kind? "hunk"|"visual"|"file"|"cursor"
function M.explain(kind)
  require("paseo.explain").explain(kind)
end

---The chat agent's settings card, optionally on one group.
---@param group? "mode"|"thinking"|"model"|"features"
function M.settings(group)
  local session = require "paseo.ui.session"
  if group == "mode" then
    return session.mode()
  elseif group == "thinking" then
    return session.thinking()
  elseif group == "model" then
    return session.model()
  elseif group == nil then
    return session.status()
  end
  local chat = require("paseo.ui.chat").current()
  if not chat then
    return vim.notify("paseo: no chat open", vim.log.levels.WARN)
  end
  require("paseo.ui.settings").open(chat, group)
end

---Toggle a feature of the chat agent: Fast by default, or the one named.
---@param feature_id? string
function M.toggle_feature(feature_id)
  require("paseo.ui.session").toggle(feature_id)
end

---Toggle Plan: a Codex feature or a Claude mode.
function M.toggle_plan()
  require("paseo.ui.session").plan()
end

---Interrupt the turn the chat's agent is running.
function M.stop()
  require("paseo.ui.chat").stop()
end

---Attach an image to the chat: the clipboard's, or the file at `path`.
---@param path? string
---@return boolean attached
function M.paste_image(path)
  return require("paseo.ui.chat").paste_image { path = path }
end

---The workspaces in this project.
---@param opts? { all?: boolean }
function M.workspaces(opts)
  require("paseo.pickers.workspaces").open(opts)
end

---The agents in the workspace containing the cwd.
function M.agents()
  require("paseo.pickers.sessions").here()
end

---Start something from wherever you are: an agent here, in a new worktree,
---or a terminal -- see |paseo-new|.
---@param opts? { where?: "here"|"worktree", kind?: "chat"|"terminal" }
function M.new_task(opts)
  require("paseo.new").open(nil, opts)
end

---@param opts? table See |paseo-configuration|.

function M.setup(opts)
  M.config.setup(opts)
  require("paseo.hosts").setup()

  local repos = require "paseo.repos"

  -- Resolved-repo paths are cached, and a chdir is the one event that reliably
  -- means "the answer may have changed" -- project.nvim chdirs on every buffer
  -- switch, and switching workspaces is a chdir into a different worktree.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = vim.api.nvim_create_augroup("paseo.repos", { clear = true }),
    callback = function()
      repos.invalidate()
      require("paseo.registry").invalidate()
    end,
  })

  -- The chat's highlight groups, derived from whatever colourscheme is
  -- loaded, and re-derived on :colorscheme.
  require("paseo.ui.hl").attach()

  -- Streaming events have to be wired before anything can arrive on them.
  require("paseo.ui.chat").attach_events()

  -- After everything it wraps is loaded, so the wrapping takes.
  if require("paseo.perf").enabled then
    require("paseo.perf").enable()
  end

  -- Connect and fetch what the first open needs, a moment after startup --
  -- only if a local daemon is already running. See |paseo.prewarm|.
  require("paseo.prewarm").schedule()

  -- Guard the standard interactive routes. Existing command-line
  -- abbreviations and mappings are preserved; configs with a central quit
  -- router can call `require("paseo.quit").guard` directly.
  if M.config.get().quit.guard then
    require("paseo.quit").install()
  end

  -- NO KEYS, only names for them: map these (or the `:Paseo` commands) to
  -- whatever you like. `<Plug>` mappings cannot be typed, so defining them
  -- takes nothing from anybody. See |paseo-keys|.
  --
  -- One per action of |paseo-native-api|, and one per panel: `<Plug>(paseo-rail)`,
  -- `<Plug>(paseo-panel-changes)`. `<Plug>(paseo-native)` is the toggle.
  local native = require "paseo.native"
  local plugs = { native = native.toggle }
  for name, action in pairs(native.ACTIONS) do
    if name ~= "toggle" then
      plugs[name] = action.run
    end
    for _, arg in ipairs(action.args or {}) do
      plugs[name .. "-" .. arg] = function()
        action.run(arg)
      end
    end
  end
  for name, run in pairs(plugs) do
    vim.keymap.set({ "n", "t" }, ("<Plug>(paseo-%s)"):format(name), function()
      run()
    end, { desc = "paseo: " .. name })
  end

  -- The sidecar is a child process; leaving it behind on :qa would leak one per
  -- session.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("paseo.bridge", { clear = true }),
    callback = function()
      require("paseo.bridge").stop()
    end,
  })

  vim.api.nvim_create_user_command("Paseo", function(args)
    local sub = args.fargs[1]
    if not sub then
      return M.toggle()
    end
    local cmd = commands[sub]
    if not cmd then
      local names = vim.tbl_keys(commands)
      table.sort(names)
      vim.notify(
        ("paseo: no `:Paseo %s`; the commands are %s"):format(sub, table.concat(names, ", ")),
        vim.log.levels.ERROR
      )
      return
    end
    cmd.run(vim.list_slice(args.fargs, 2))
  end, {
    nargs = "*",
    desc = "paseo.nvim: :Paseo toggles the chat; see :help paseo-commands",
    complete = function(lead, line, pos)
      -- The words after `:Paseo`, up to the cursor; the one being typed is
      -- `lead` (empty right after a space).
      local words = vim.split(line:sub(1, pos), "%s+", { trimempty = true })
      table.remove(words, 1)
      if lead == "" then
        words[#words + 1] = ""
      end
      local function starting(list)
        local out = vim.tbl_filter(function(name)
          return vim.startswith(name, lead)
        end, list)
        table.sort(out)
        return out
      end
      if #words <= 1 then
        return starting(vim.tbl_keys(commands))
      end
      local cmd = commands[words[1]]
      if cmd and cmd.complete then
        return starting(cmd.complete(lead, vim.list_slice(words, 2)))
      end
      return {}
    end,
  })
end

return M
