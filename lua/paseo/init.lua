--- paseo.nvim -- review every hunk by hand, and ask an agent when one is opaque.
---
--- Entry point. Holds `setup()`, the `:Paseo` command, and nothing else:
--- submodules are required lazily from the dispatch table below so that loading
--- this file costs a config merge and one autocmd.

local M = {}

M.config = require "paseo.config"

---@type table<string, { run: fun(args: string[]), desc: string }>
local commands = {}

commands.repos = {
  desc = "List the repos in the current unit of work",
  run = function()
    local repos = require("paseo.repos").list()
    if #repos == 0 then
      vim.notify("paseo: not inside a git repository", vim.log.levels.WARN)
      return
    end
    local lines = {}
    for i, repo in ipairs(repos) do
      local where = vim.fn.fnamemodify(repo.worktree, ":~")
      lines[#lines + 1] = ("%d. %s  %s"):format(i, repo.name, where)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "paseo: repos" })
  end,
}

commands.changes = {
  desc = "Changed-files picker for this unit of work",
  run = function()
    require("paseo.pickers.changes").open()
  end,
}

commands.hunks = {
  desc = "Every hunk in this unit of work, as a quickfix list",
  run = function()
    require("paseo.qf").all()
  end,
}

commands.stage = {
  desc = "Stage the hunk the quickfix list is on, then advance",
  run = function()
    require("paseo.qf").stage()
  end,
}

commands.review = {
  desc = "Diff panel, one tab per repo",
  run = function(args)
    require("paseo.review").open({ unified = args[1] == "unified" }, function(opened)
      if opened == 0 then
        vim.notify("paseo: no diff panel opened", vim.log.levels.WARN)
      end
    end)
  end,
}

---@param args string[]
---@return table|nil m, string|nil root, string|nil err
local function project(args)
  local registry = require "paseo.registry"
  local root = registry.project_root(args and args.root)
  if not root then
    return nil,
      nil,
      "no .ws/workspace.toml here or above — `:Paseo wcreate` needs none, and "
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
  desc = "Manifest-level: init | create <name> [repos] | rm <name> [force] | ls | status",
  run = function(args)
    local sub = args[1] or "ls"
    local workspace = require "paseo.workspace"
    local registry = require "paseo.registry"

    if sub == "init" then
      local root = args[2] and vim.fn.fnamemodify(vim.fn.expand(args[2]), ":p")
        or assert(vim.uv.cwd())
      root = root:gsub("/+$", "")

      local path = workspace.manifest.path(root)
      local existing = vim.uv.fs_stat(path)

      local m, notes = workspace.discover(root)
      if not m then
        return vim.notify("paseo: " .. tostring(notes), vim.log.levels.ERROR)
      end

      -- The directory has to exist BEFORE the buffer is named, or `:w` fails
      -- with E212 "Can't open file for writing: no such file or directory" --
      -- which reads like a permissions problem rather than a missing parent.
      -- Creating it is harmless even if you never write the file.
      vim.fn.mkdir(vim.fs.dirname(path), "p")

      -- A buffer may already be sitting on this path -- a second `init`, or the
      -- file simply being open. Reuse it rather than failing on a duplicate
      -- name.
      local buf = vim.fn.bufnr(path)
      vim.cmd "tabnew"
      if buf ~= -1 then
        vim.api.nvim_win_set_buf(0, buf)
      else
        buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(buf, path)
      end

      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        vim.split(workspace.manifest.render(m, notes), "\n")
      )
      vim.bo[buf].filetype = "toml"

      -- Shown before it is written, never written behind your back: the
      -- comments are the whole value of the file and they are what you have to
      -- check -- which base branch, which repo is opt-in, which shared siblings
      -- to prune.
      vim.notify(
        existing
            and ("paseo: %s already exists -- this REPLACES it. Review, then :w"):format(
              vim.fn.fnamemodify(path, ":~")
            )
          or "paseo: review this, then :w to accept it",
        existing and vim.log.levels.WARN or vim.log.levels.INFO
      )
      return
    end

    local m, root, err = project { root = nil }
    if not m then
      -- `create` is the one subcommand that does not need a manifest: the
      -- unified path writes one when the project wants one, and skips assembly
      -- entirely when Paseo's own worktree isolation applies. Only a subcommand
      -- that must READ the manifest -- rm, ls, status -- fails here.
      if sub == "create" and args[2] and not args[3] then
        return require("paseo.pickers.workspaces").named(args[2])
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
          bridge.request("workspace.open", { cwd = ws.root }, function() end)
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
}

commands.workspaces = {
  desc = "Workspace picker: open, sessions, new, archive",
  run = function()
    require("paseo.pickers.workspaces").open()
  end,
}

commands.wcreate = {
  desc = "Create a workspace here — assembled, worktree or plain, worked out for you",
  run = function()
    require("paseo.pickers.workspaces").create()
  end,
}

commands.sessions = {
  desc = "Sessions in the workspace containing this directory",
  run = function()
    require("paseo.pickers.sessions").here()
  end,
}

commands.terminals = {
  desc = "The Paseo terminals in this workspace",
  run = function()
    -- Through the dashboard rather than a picker: a terminal is a live PTY
    -- floated over the body, so it needs the surface that owns that space.
    local float = require "paseo.ui.float"
    if float.geometry_of() then
      return float.select "Terminals"
    end
    require("paseo.ui.chat").open({}, function(_, err)
      if err then
        return
      end
      vim.schedule(function()
        float.select "Terminals"
      end)
    end)
  end,
}

commands.chat = {
  desc = "Open the chat for this directory (toggle)",
  run = function()
    require("paseo.ui.chat").toggle()
  end,
}

commands.dash = {
  desc = "Open the chat full screen, with the session panels",
  run = function()
    -- Not `fullscreen()`, which is the `<C-f>` TOGGLE: `:Paseo dash` asked for
    -- the dashboard, and with the dashboard already the default surface a
    -- toggle would have answered by closing it.
    require("paseo.ui.chat").surface "float"
  end,
}

commands.sidebar = {
  desc = "Open the chat in the sidebar, beside your code",
  run = function()
    require("paseo.ui.chat").surface "sidebar"
  end,
}

commands.explain = {
  desc = "Explain the hunk/selection/file, using the rubric",
  run = function(args)
    require("paseo.explain").explain(args[1])
  end,
}

commands.ask = {
  desc = "Attach the hunk/selection/file and type a question",
  run = function(args)
    require("paseo.explain").ask(args[1])
  end,
}

commands.qfask = {
  desc = "Attach every hunk in the quickfix list",
  run = function()
    require("paseo.explain").quickfix()
  end,
}

commands.mode = {
  desc = "Permission / operating mode for this session",
  run = function()
    require("paseo.ui.session").mode()
  end,
}

commands.thinking = {
  desc = "Reasoning level for this session",
  run = function()
    require("paseo.ui.session").thinking()
  end,
}

commands.fast = {
  desc = "Toggle fast mode (or pick another feature toggle)",
  run = function(args)
    require("paseo.ui.session").toggle(args[1])
  end,
}

commands.plan = {
  desc = "Toggle this session's planning mode",
  run = function()
    require("paseo.ui.session").plan()
  end,
}

commands.session = {
  desc = "What this session is set to",
  run = function()
    require("paseo.ui.session").status()
  end,
}

commands.switchmodel = {
  desc = "Change the running session's model",
  run = function()
    require("paseo.ui.session").model()
  end,
}

commands.image = {
  desc = "Attach an image to the chat: the clipboard, or a path",
  run = function(args)
    require("paseo.ui.chat").paste_image { path = args[1] }
  end,
}

commands.model = {
  desc = "Choose the provider/model new agents are created with",
  run = function(args)
    require("paseo.ui.create").preference(args[1], function(selection, err)
      if err then
        return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      end
      if selection then
        vim.notify("paseo: new agents will use " .. selection.provider, vim.log.levels.INFO)
      end
    end)
  end,
}

commands.agent = {
  desc = "Sidecar status; `agent stop` shuts it down",
  run = function(args)
    local b = require "paseo.bridge"
    if args[1] == "stop" then
      b.stop()
      vim.notify("paseo: sidecar stopped", vim.log.levels.INFO)
      return
    end
    if not b.running() then
      vim.notify("paseo: sidecar is not running", vim.log.levels.INFO)
      return
    end
    b.request("agents.list", {}, function(err, result)
      if err then
        vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        return
      end
      local lines = {}
      for _, agent in ipairs(result.entries or {}) do
        lines[#lines + 1] = ("%s  %s  %s"):format(
          agent.status,
          agent.provider or "?",
          agent.title or agent.id
        )
      end
      vim.notify(#lines > 0 and table.concat(lines, "\n") or "no agents", vim.log.levels.INFO, {
        title = "paseo: agents",
      })
    end)
  end,
}

commands.health = {
  desc = "Run :checkhealth paseo",
  run = function()
    vim.cmd "checkhealth paseo"
  end,
}

---@param opts? table See `paseo.Config`.
function M.setup(opts)
  M.config.setup(opts)

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

  -- The sidecar is a child process; leaving it behind on :qa would leak one per
  -- session.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("paseo.bridge", { clear = true }),
    callback = function()
      require("paseo.bridge").stop()
    end,
  })

  vim.api.nvim_create_user_command("Paseo", function(args)
    local sub = args.fargs[1] or "repos"
    local cmd = commands[sub]
    if not cmd then
      vim.notify(("paseo: unknown subcommand `%s`"):format(sub), vim.log.levels.ERROR)
      return
    end
    cmd.run(vim.list_slice(args.fargs, 2))
  end, {
    nargs = "*",
    desc = "paseo.nvim",
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, vim.tbl_keys(commands))
    end,
  })
end

return M
