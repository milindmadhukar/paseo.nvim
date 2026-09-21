--- The bundled agent skills, and getting them where an agent can see them.
---
--- This plugin ships five skills in `.agents/skills/`. A coding agent only
--- discovers those when its cwd is inside THIS repository -- which is exactly
--- backwards, because three of them describe how to work in a multi-repo
--- workspace, and the projects that are multi-repo workspaces are somewhere
--- else entirely. The skills are invisible in the one place they are for.
---
--- The plugin manager has already done the hard half: it fetched a versioned
--- directory onto disk and keeps it updated. What is missing is one symlink
--- per skill, which is what this file makes.
---
--- WHY GLOBAL IS THE DEFAULT, and it is not a matter of taste. An agent
--- working in a workspace has a cwd of `<project>/.workspaces/<name>/<repo>` --
--- a MEMBER worktree. Agents read project skills from the cwd and the repo
--- around it, so `<project>/.claude/skills` is two levels up and in a
--- different tree: invisible to the one agent that needs it. `~/.claude/skills`
--- is the only target that is visible from inside a member. It is also right
--- on the merits, because these describe a workflow rather than a project.
---
--- PLAN, THEN APPLY. `plan` is pure and `apply` is the only writer, so `dry`
--- costs nothing and the tests never go near a real `~/.claude`.

local config = require "paseo.config"

local M = {}

M.DIR = ".agents/skills"
M.BACKUP = ".paseo-backup"

---@class paseo.Skill
---@field name string
---@field path string         The bundled directory.
---@field description string|nil

---@class paseo.SkillAction
---@field skill paseo.Skill
---@field dir string          The target directory skills are installed into.
---@field path string         `<dir>/<name>`.
---@field state string
---@field verb "link"|"copy"|"refresh"|"repair"|"replace"|"remove"|"skip"|"refuse"
---@field reason string|nil

-- ------------------------------------------------------------------ bundled

---`name:` and `description:` out of the front matter, and nothing else.
---
---Deliberately not a YAML parser: two line matches, bounded to the block
---between the opening `---` and the next one, so a `description:` in the body
---prose cannot be picked up as the real one.
---@param path string
---@return string|nil name, string|nil description
local function front_matter(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, nil
  end
  local name, description
  local lines, open = 0, false
  for line in fd:lines() do
    lines = lines + 1
    if lines == 1 then
      if vim.trim(line) ~= "---" then
        break
      end
      open = true
    elseif vim.trim(line) == "---" then
      break
    elseif open then
      name = name or line:match "^name:%s*(.+)$"
      description = description or line:match "^description:%s*(.+)$"
    end
    if lines > 40 then
      break
    end
  end
  fd:close()
  return name and vim.trim(name) or nil, description and vim.trim(description) or nil
end

---Every skill this plugin ships.
---
---DISCOVERED by scanning for `SKILL.md`, never listed in code. This repo went
---from zero skills to five inside a week; a hardcoded list would already be
---wrong, and a skill that exists but is not offered is the same invisibility
---this file exists to fix.
---
---Read from `.agents/skills`, NEVER `.claude/skills`. Those are git symlinks,
---and a clone on a filesystem without symlink support materialises them as
---text files containing a path -- which scans as five one-line "skills".
---@param root? string  The plugin root; defaults to the real one.
---@return paseo.Skill[]
function M.bundled(root)
  root = root or require("paseo.plugin").root()
  if not root then
    return {}
  end
  local base = vim.fs.joinpath(root, M.DIR)
  if not vim.uv.fs_stat(base) then
    return {}
  end

  local out = {}
  for entry, kind in vim.fs.dir(base) do
    local path = vim.fs.joinpath(base, entry)
    local real = kind == "directory" or (kind == "link" and (vim.uv.fs_stat(path) or {}).type == "directory")
    if real and vim.uv.fs_stat(vim.fs.joinpath(path, "SKILL.md")) then
      local name, description = front_matter(vim.fs.joinpath(path, "SKILL.md"))
      out[#out + 1] = {
        -- The directory name wins over the front matter: it is what the
        -- target is called, and a skill whose two names disagree should still
        -- install rather than vanish.
        name = entry,
        path = path,
        description = description or name,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

-- ------------------------------------------------------------------ targets

---@param spec? "global"|"project"
---@param from? string  Where to resolve a project root from.
---@return string[]|nil dirs, string|nil err
function M.targets(spec, from)
  local cfg = config.get().skills
  if spec == nil or spec == "global" then
    return vim.deepcopy(cfg.dirs), nil
  end

  local root = require("paseo.registry").project_root(from)
  if not root then
    return nil, "no .ws/workspace.toml here or above — `project` needs a ws project"
  end
  -- Writing `.claude/skills/` into somebody's REPOSITORY is not a thing a
  -- plugin does uninvited. A ws project root is a plain directory holding
  -- repos, so there is nothing there to pollute; a repo is the other case.
  local git = vim.system({ "git", "-C", root, "rev-parse", "--show-toplevel" }, { text = true })
    :wait()
  if git.code == 0 then
    return nil,
      ("%s is itself a git repository; installing into it would add files to your repo"):format(
        vim.fn.fnamemodify(root, ":~")
      )
  end

  local out = {}
  for _, dir in ipairs(cfg.project_dirs) do
    out[#out + 1] = vim.fs.joinpath(root, dir)
  end
  return out, nil
end

-- -------------------------------------------------------------------- state

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath "state", "paseo", "skills.json")
end

---What we installed as a COPY, and what it looked like. The filesystem is
---truth; this only answers "was this copy ours?", which a copy cannot say
---about itself. A marker file inside the directory would be read by the agent.
---@return table<string, string>
local function read_state()
  local fd = io.open(state_path(), "r")
  if not fd then
    return {}
  end
  local text = fd:read "*a"
  fd:close()
  local ok, parsed = pcall(vim.json.decode, text)
  return (ok and type(parsed) == "table") and parsed or {}
end

---@param state table<string, string>
local function write_state(state)
  local path = state_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if not fd then
    return
  end
  fd:write(vim.json.encode(state))
  fd:close()
end

---A cheap content signature: every file's path and size, sorted. Enough to
---notice a plugin update, which is the only drift that matters here.
---@param dir string
---@return string
local function signature(dir)
  local parts = {}
  local function scan(at, prefix)
    for entry, kind in vim.fs.dir(at) do
      local path = vim.fs.joinpath(at, entry)
      if kind == "directory" then
        scan(path, prefix .. entry .. "/")
      else
        local stat = vim.uv.fs_stat(path)
        parts[#parts + 1] = ("%s%s:%d"):format(prefix, entry, stat and stat.size or -1)
      end
    end
  end
  local ok = pcall(scan, dir, "")
  if not ok then
    return ""
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

-- ------------------------------------------------------------------ inspect

---What is sitting at `<dir>/<skill>`, and whose it is.
---@param skill paseo.Skill
---@param dir string
---@param state? table<string, string>
---@return string state, string|nil detail
function M.inspect(skill, dir, state)
  state = state or read_state()
  local path = vim.fs.joinpath(dir, skill.name)
  local lstat = vim.uv.fs_lstat(path)
  if not lstat then
    return "absent", nil
  end

  if lstat.type == "link" then
    local target = vim.uv.fs_readlink(path)
    if not vim.uv.fs_stat(path) then
      -- Nobody's data. The plugin manager reinstalling at the same path heals
      -- this by itself; anything else wanted it gone.
      return "dangling", target
    end
    local resolved = vim.uv.fs_realpath(path)
    local ours = vim.uv.fs_realpath(skill.path)
    if resolved and ours and resolved == ours then
      return "ours_link", target
    end
    return "foreign_link", target
  end

  local recorded = state[path]
  if recorded then
    return recorded == signature(path) and "ours_copy" or "stale_copy", nil
  end
  return "foreign", nil
end

-- --------------------------------------------------------------------- plan

---What an install or an uninstall WOULD do. Pure: reads the filesystem, writes
---nothing.
---@param opts { action?: "install"|"uninstall", target?: string, names?: string[], force?: boolean, method?: string, root?: string, from?: string }
---@return paseo.SkillAction[]|nil, string|nil err
function M.plan(opts)
  opts = opts or {}
  local dirs, err = M.targets(opts.target, opts.from)
  if not dirs then
    return nil, err
  end

  local bundled = M.bundled(opts.root)
  if #bundled == 0 then
    return nil, "no skills are bundled with this plugin — is the install complete?"
  end

  local wanted
  if opts.names and #opts.names > 0 then
    wanted = {}
    for _, name in ipairs(opts.names) do
      wanted[name] = true
    end
    for _, name in ipairs(opts.names) do
      local known = false
      for _, skill in ipairs(bundled) do
        known = known or skill.name == name
      end
      if not known then
        return nil, ("no bundled skill called %q"):format(name)
      end
    end
  end

  local uninstall = opts.action == "uninstall"
  local method = opts.method or config.get().skills.method
  local state = read_state()
  local out = {}

  for _, dir in ipairs(dirs) do
    for _, skill in ipairs(bundled) do
      if not wanted or wanted[skill.name] then
        local at, detail = M.inspect(skill, dir, state)
        local verb, reason = "skip", nil

        if uninstall then
          if at == "absent" then
            verb = "skip"
          elseif at == "ours_link" or at == "dangling" or at == "ours_copy" or at == "stale_copy" then
            verb = "remove"
          else
            verb, reason = "refuse", (at == "foreign_link" and ("points at %s"):format(detail) or "not installed by paseo")
          end
        elseif at == "absent" then
          verb = method
        elseif at == "ours_link" then
          verb = "skip"
        elseif at == "dangling" then
          -- No `force`: a link to nothing is nobody's data, and this is what
          -- a plugin reinstall leaves behind.
          verb, reason = "repair", "was dangling"
        elseif at == "ours_copy" then
          verb = "skip"
        elseif at == "stale_copy" then
          verb, reason = "refresh", "the bundled copy changed"
        elseif at == "foreign_link" then
          verb = opts.force and "replace" or "refuse"
          reason = ("points at %s"):format(detail or "?")
        elseif at == "foreign" then
          verb = opts.force and "replace" or "refuse"
          reason = "a directory that paseo did not install"
        end

        out[#out + 1] = {
          skill = skill,
          dir = dir,
          path = vim.fs.joinpath(dir, skill.name),
          state = at,
          verb = verb,
          reason = reason,
        }
      end
    end
  end

  return out, nil
end

-- -------------------------------------------------------------------- apply

---@param src string
---@param dst string
---@return boolean ok, string|nil err
local function copy_tree(src, dst)
  if vim.fn.mkdir(dst, "p") == 0 then
    return false, ("could not create %s"):format(dst)
  end
  for entry, kind in vim.fs.dir(src) do
    local from, to = vim.fs.joinpath(src, entry), vim.fs.joinpath(dst, entry)
    if kind == "directory" then
      local ok, err = copy_tree(from, to)
      if not ok then
        return false, err
      end
    elseif kind == "file" then
      local ok, err = vim.uv.fs_copyfile(from, to)
      if not ok then
        return false, ("%s: %s"):format(from, tostring(err))
      end
    else
      return false, ("%s is neither a file nor a directory"):format(from)
    end
  end
  return true, nil
end

---@param path string
local function remove(path)
  vim.fn.delete(path, "rf")
end

---The only writer.
---@param actions paseo.SkillAction[]
---@return string[] lines, boolean refused, boolean backed_up
function M.apply(actions)
  local state = read_state()
  local lines, refused, backed_up = {}, false, false

  for _, action in ipairs(actions) do
    local short = vim.fn.fnamemodify(action.path, ":~")

    if action.verb == "skip" then
      -- Said, not silent: "already installed" is the answer to the question
      -- most people are actually asking when they run this twice.
      lines[#lines + 1] = ("  ok      %s"):format(short)
    elseif action.verb == "refuse" then
      refused = true
      lines[#lines + 1] = ("  refused %s — %s"):format(short, action.reason or "?")
    else
      if action.verb == "replace" then
        if action.state == "foreign" then
          -- A real directory is MOVED, never deleted. `force` means "get out
          -- of the way", not "destroy what is there".
          local backup = action.path .. M.BACKUP
          remove(backup)
          vim.uv.fs_rename(action.path, backup)
          backed_up = true
          lines[#lines + 1] = ("  moved   %s -> %s"):format(short, vim.fn.fnamemodify(backup, ":~"))
        else
          -- A symlink is a pointer, not data; there is nothing to back up.
          remove(action.path)
        end
      elseif action.verb ~= "link" and action.verb ~= "copy" then
        remove(action.path)
      end
      state[action.path] = nil

      if action.verb == "remove" then
        lines[#lines + 1] = ("  removed %s"):format(short)
      else
        vim.fn.mkdir(action.dir, "p")
        local method = (action.verb == "copy" or action.state == "ours_copy" or action.state == "stale_copy")
            and "copy"
          or config.get().skills.method
        if action.verb == "link" then
          method = "link"
        end

        local ok, err
        if method == "copy" then
          ok, err = copy_tree(action.skill.path, action.path)
          if ok then
            state[action.path] = signature(action.path)
          end
        else
          -- `dir` and `junction` are required on Windows and ignored
          -- elsewhere; a directory symlink without them fails there.
          ok, err = vim.uv.fs_symlink(
            action.skill.path,
            action.path,
            vim.fn.has "win32" == 1 and { dir = true, junction = true } or nil
          )
        end

        if ok then
          -- The plan's reason describes the state we found, which reads as a
          -- description of what we just made: "linked <path> - a directory
          -- that paseo did not install" is a sentence about the wrong thing.
          -- A replace has already logged the move, so it needs no reason.
          local why = action.verb ~= "replace" and action.reason or nil
          lines[#lines + 1] = ("  %-7s %s%s"):format(
            method == "copy" and "copied" or "linked",
            short,
            why and (" — " .. why) or ""
          )
        else
          refused = true
          lines[#lines + 1] = ("  failed  %s — %s"):format(short, tostring(err))
        end
      end
    end
  end

  write_state(state)
  return lines, refused, backed_up
end

-- ------------------------------------------------------------------- status

---What is bundled and where it has got to, as lines.
---@param opts? { target?: string, root?: string, from?: string }
---@return string[]
function M.status(opts)
  opts = opts or {}
  local bundled = M.bundled(opts.root)
  local lines = {}

  if #bundled == 0 then
    return { "no skills are bundled with this plugin — is the install complete?" }
  end

  lines[#lines + 1] = ("bundled (%d):"):format(#bundled)
  for _, skill in ipairs(bundled) do
    lines[#lines + 1] = ("  %-18s %s"):format(skill.name, (skill.description or ""):sub(1, 60))
  end

  local dirs, err = M.targets(opts.target, opts.from)
  if not dirs then
    lines[#lines + 1] = ""
    lines[#lines + 1] = tostring(err)
    return lines
  end

  local state = read_state()
  for _, dir in ipairs(dirs) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = vim.fn.fnamemodify(dir, ":~") .. ":"
    local installed = 0
    for _, skill in ipairs(bundled) do
      local at = M.inspect(skill, dir, state)
      if at == "ours_link" or at == "ours_copy" then
        installed = installed + 1
      else
        lines[#lines + 1] = ("  %-18s %s"):format(skill.name, at)
      end
    end
    if installed == #bundled then
      lines[#lines + 1] = ("  all %d installed"):format(installed)
    elseif installed == 0 then
      lines[#lines + 1] = "  none installed — run `:Paseo skills install`"
    end
  end

  return lines
end

return M
