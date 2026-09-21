--- Assembling and dismantling workspaces.
---
--- A workspace is N git worktrees plus the untracked context they need, under
--- one name. This was a Go binary; it is Lua because the only argument for Go
--- was concurrency across ~66 git invocations, and `vim.system` gives that
--- natively -- so the binary bought a build step, a release pipeline and a
--- second language for nothing.

local manifest = require "paseo.workspace.manifest"

local M = {}

M.manifest = manifest

---@param dir string
---@param args string[]
---@return string|nil out, string|nil err
local function git(dir, args)
  local cmd = { "git", "-C", dir, "-c", "core.quotePath=false" }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "git failed")
  end
  return (res.stdout or ""):gsub("%s+$", ""), nil
end

---@param dir string
---@return boolean
local function is_repo(dir)
  local top = git(dir, { "rev-parse", "--show-toplevel" })
  return top ~= nil and vim.fn.resolve(top) == vim.fn.resolve(dir)
end

-- ---------------------------------------------------------------- discovery

--- Repositories may sit three levels below the project root, not one:
--- ~/Code/grasslabs/kora holds five of them two levels down.
local MAX_DEPTH = 3

--- Above this an ignored directory is worth linking rather than copying.
local HEAVY = 20 * 1024 * 1024

--- Copied data above this takes a repo out of the default set. LINKED data is
--- not counted: it is shared with the primary checkout and costs nothing per
--- workspace, and counting it excluded the two repos most workspaces are for.
local OPT_OUT = 200 * 1024 * 1024

--- Heavy directories above this count take a repo out of the default set even
--- when the bytes are shared. Each member is a worktree add, maybe a recursive
--- submodule init, and one more tree for the LSP and ripgrep to index.
local HEAVY_COUNT = 6

local COPY_NAMES = { [".env"] = true, [".envrc"] = true }

---@param bytes integer
---@return string
local function human(bytes)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local index = 1
  while bytes >= 1024 and index < #units do
    bytes, index = bytes / 1024, index + 1
  end
  return ("%d%s"):format(math.floor(bytes + 0.5), units[index])
end

---Sum a directory, NOT following symlinks -- a link into an Obsidian vault
---would otherwise charge the vault's size to the repository.
---@param dir string
---@return integer
local function dir_size(dir)
  local total = 0
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return 0
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = vim.fs.joinpath(dir, name)
    if kind == "directory" then
      total = total + dir_size(path)
    elseif kind == "file" then
      local stat = vim.uv.fs_lstat(path)
      total = total + ((stat and stat.size) or 0)
    end
  end
  return total
end

---Gitignored top-level entries: the copy/link candidates.
---@param dir string
---@return string[]
local function ignored(dir)
  local out = git(dir, { "ls-files", "--others", "--ignored", "--exclude-standard", "--directory" })
  if not out or out == "" then
    return {}
  end
  local names = {}
  for line in (out .. "\n"):gmatch "(.-)\n" do
    local name = vim.trim(line):gsub("/$", "")
    -- Nested entries are noise; the manifest deals in top-level names.
    if name ~= "" and not name:find "/" then
      names[#names + 1] = name
    end
  end
  return names
end

---@param root string
---@param name string
---@param path string
---@return paseo.ws.Repo, { repo: string, text: string }[]
local function describe(root, name, path)
  local notes = {}
  local function note(fmt, ...)
    notes[#notes + 1] = { repo = name, text = fmt:format(...) }
  end

  local branch = git(path, { "branch", "--show-current" }) or ""
  local head = (git(path, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }) or ""):gsub(
    "^origin/",
    ""
  )

  ---@type paseo.ws.Repo
  local repo = { base = branch, copy = {}, link = {}, clone_symlinks = {} }

  if repo.base == "" then
    repo.base = head
    note "detached HEAD; base guessed from origin/HEAD. CHECK THIS."
  end

  -- The base is what is CHECKED OUT, never origin/HEAD. Every openfin repo sits
  -- on dev while clm_api and fos-pwa report origin/HEAD as main, so origin/HEAD
  -- would silently base the work on the wrong history.
  if head ~= "" and branch ~= "" and head ~= branch then
    note('origin/HEAD is "%s" but "%s" is checked out; base follows the checkout.', head, branch)
  end

  if git(path, { "config", "--file", ".gitmodules", "--get-regexp", "path" }) then
    repo.submodules = true
    note "has submodules; they are initialised after `worktree add`."
  end

  local copied, heavy = 0, 0
  for _, entry in ipairs(ignored(path)) do
    local full = vim.fs.joinpath(path, entry)
    local stat = vim.uv.fs_lstat(full)
    if stat then
      if stat.type == "link" then
        -- Recreated VERBATIM, not linked to. A link to a link resolves fine
        -- right up until the primary checkout moves.
        table.insert(repo.clone_symlinks, entry)
        note("%s is a symlink; recreated verbatim rather than linked to.", entry)
      elseif COPY_NAMES[entry] or vim.startswith(entry, ".env") then
        table.insert(repo.copy, entry)
      elseif stat.type == "directory" then
        local size = dir_size(full)
        if size >= HEAVY then
          table.insert(repo.link, entry)
          heavy = heavy + 1
          note("%s is %s; linked to the primary checkout, not copied.", entry, human(size))
        else
          copied = copied + size
        end
      end
    end
  end

  if copied >= OPT_OUT then
    repo.default = false
    note(
      "%s of per-workspace data; excluded from the default set. Opt in with --with %s.",
      human(copied),
      name
    )
  elseif heavy >= HEAVY_COUNT then
    repo.default = false
    note(
      "%d heavy directories to link and a tree this size to index; excluded from the default set. Opt in with --with %s.",
      heavy,
      name
    )
  end

  for _, key in ipairs { "copy", "link", "clone_symlinks" } do
    table.sort(repo[key])
  end
  return repo, notes
end

---Generate a manifest by looking at a project on disk.
---
---Non-negotiable: hand-writing eleven manifests, each with six repos and their
---own base branch and ignored-directory list, is the failure mode this removes.
---@param root string
---@return paseo.ws.Manifest|nil, { repo: string, text: string }[]|string
function M.discover(root)
  root = vim.fn.fnamemodify(vim.fn.expand(root), ":p"):gsub("/+$", "")
  if vim.fn.isdirectory(root) == 0 then
    return nil, root .. " is not a directory"
  end

  local repos, candidates = {}, {}

  local function walk(dir, depth)
    if depth > MAX_DEPTH then
      return
    end
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = vim.fs.joinpath(dir, name)
      if
        (kind == "directory" or kind == "link")
        and name ~= ".git"
        and name ~= ".ws"
        and name ~= ".workspaces"
        and name ~= "node_modules"
      then
        if is_repo(path) then
          -- Do not descend: submodules are the repo's business, not members.
          repos[#repos + 1] = { name = path:sub(#root + 2), path = path }
        else
          if dir == root and not vim.startswith(name, ".") then
            candidates[#candidates + 1] = path
          end
          walk(path, depth + 1)
        end
      end
    end
  end
  walk(root, 1)

  if #repos == 0 then
    return nil, ("no git repositories under %s (searched %d levels)"):format(root, MAX_DEPTH)
  end
  table.sort(repos, function(a, b)
    return a.name < b.name
  end)

  -- A candidate that an accepted repository lives beneath is a PARENT, not a
  -- sibling. Symlinking ~/Code/openfin/archive into every workspace would drag
  -- the repo inside it in sideways.
  local shared = {}
  for _, candidate in ipairs(candidates) do
    local contains = false
    for _, repo in ipairs(repos) do
      if vim.startswith(repo.path, candidate .. "/") then
        contains = true
        break
      end
    end
    if not contains then
      shared[#shared + 1] = vim.fs.basename(candidate)
    end
  end
  table.sort(shared)

  ---@type paseo.ws.Manifest
  local m = { shared = shared, workspaces_dir = ".workspaces", branch_prefix = "ws/", repos = {} }
  local notes = {}
  for _, found in ipairs(repos) do
    local repo, repo_notes = describe(root, found.name, found.path)
    m.repos[found.name] = repo
    vim.list_extend(notes, repo_notes)
  end
  table.sort(notes, function(a, b)
    return a.repo < b.repo
  end)

  return m, notes
end

-- ---------------------------------------------------------------- assembly

---@param target string
---@param dst string
---@return boolean ok, string|nil err
local function relink(target, dst)
  vim.fn.mkdir(vim.fs.dirname(dst), "p")
  if vim.uv.fs_lstat(dst) then
    vim.uv.fs_unlink(dst)
  end
  local ok, err = vim.uv.fs_symlink(target, dst)
  return ok == true, err
end

---Stop ws's own symlinks showing up as untracked.
---
---A repo that gitignores `node_modules/` -- with the trailing slash, which is
---how everyone writes it -- does NOT ignore a SYMLINK of that name, because the
---slash means "directory". Every linked directory otherwise shows as
---`?? node_modules` forever, and removal then refuses over files we created.
---
---It must go in the COMMON info/exclude: a per-worktree $GIT_DIR/info/exclude
---is silently ignored, because git reads that file only from the common dir.
---Tested, not assumed.
---@param dest string
---@param repo paseo.ws.Repo
local function exclude_managed(dest, repo)
  local managed = {}
  vim.list_extend(managed, repo.link or {})
  vim.list_extend(managed, repo.clone_symlinks or {})
  if #managed == 0 then
    return
  end

  local common = git(dest, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if not common then
    return
  end
  local path = vim.fs.joinpath(common, "info", "exclude")
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  local BEGIN, END = "# >>> paseo.nvim managed >>>", "# <<< paseo.nvim managed <<<"
  local kept, inside = {}, false
  local fd = io.open(path, "r")
  if fd then
    for line in fd:lines() do
      if line == BEGIN then
        inside = true
      elseif line == END then
        inside = false
      elseif not inside then
        kept[#kept + 1] = line
      end
    end
    fd:close()
  end
  while #kept > 0 and vim.trim(kept[#kept]) == "" do
    table.remove(kept)
  end

  vim.list_extend(
    kept,
    { BEGIN, "# symlinks paseo.nvim creates in worktrees; delete this block to undo." }
  )
  vim.list_extend(kept, managed)
  vim.list_extend(kept, { END, "" })

  local out = io.open(path, "w")
  if out then
    out:write(table.concat(kept, "\n"))
    out:close()
  end
end

---@param origin string
---@param dest string
---@param repo paseo.ws.Repo
---@return string|nil err
local function materialise(origin, dest, repo)
  for _, name in ipairs(repo.copy or {}) do
    local src = vim.fs.joinpath(origin, name)
    if vim.uv.fs_lstat(src) then
      -- COPIED, never linked: an agent editing PORT= in a shared .env breaks
      -- the primary checkout and every sibling workspace at once.
      local data = io.open(src, "r")
      if data then
        local content = data:read "*a"
        data:close()
        local out = io.open(vim.fs.joinpath(dest, name), "w")
        if out then
          out:write(content)
          out:close()
        end
      end
    end
  end

  for _, name in ipairs(repo.link or {}) do
    local src = vim.fs.joinpath(origin, name)
    if vim.uv.fs_stat(src) then
      local ok, err = relink(src, vim.fs.joinpath(dest, name))
      if not ok then
        return ("link %s: %s"):format(name, err)
      end
    end
  end

  for _, name in ipairs(repo.clone_symlinks or {}) do
    local target = vim.uv.fs_readlink(vim.fs.joinpath(origin, name))
    if target then
      local ok, err = relink(target, vim.fs.joinpath(dest, name))
      if not ok then
        return ("clone symlink %s: %s"):format(name, err)
      end
    end
  end

  return nil
end

---@param origin string
---@param dest string
---@param branch string
---@param base string
---@return string|nil err
local function add_worktree(origin, dest, branch, base)
  if not is_repo(origin) then
    return origin .. " is not a git work tree"
  end

  -- Branch from `origin/<base>` when that ref exists. Branching from the LOCAL
  -- branch bases the work on whatever is checked out in the primary tree,
  -- including unpushed commits and a stale position -- and the primary being
  -- behind is the normal case, not the exception.
  local start = base
  if git(origin, { "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" .. base }) then
    start = "origin/" .. base
  end

  local _, err = git(origin, { "worktree", "add", "-b", branch, dest, start })
  if err and err:find "already exists" then
    -- The common second run: reuse the branch, which `-b` cannot do.
    local _, retry = git(origin, { "worktree", "add", dest, branch })
    return retry
  end
  return err
end

---@class paseo.ws.CreateOpts
---@field name string
---@field root string     Project root.
---@field only string[]?
---@field with string[]?
---@field setup boolean?

---Assemble a workspace.
---@param m paseo.ws.Manifest
---@param opts paseo.ws.CreateOpts
---@return table|nil workspace, string|nil err
function M.create(m, opts)
  if not opts.name or opts.name == "" then
    return nil, "a workspace needs a name"
  end
  if opts.name:find "[/\\ ]" then
    return nil, ("workspace names may not contain slashes or spaces: %q"):format(opts.name)
  end

  local names, err = manifest.select(m, opts.only, opts.with)
  if not names then
    return nil, err
  end
  if #names == 0 then
    return nil, "no repos selected; every repo is default = false, so name some with --repos"
  end

  local root = vim.fs.joinpath(opts.root, m.workspaces_dir, opts.name)
  if vim.uv.fs_stat(root) then
    return nil, root .. " already exists"
  end
  vim.fn.mkdir(root, "p")

  local branch = (m.branch_prefix or "ws/") .. opts.name
  local ws = {
    name = opts.name,
    project = opts.root,
    root = root,
    branch = branch,
    repos = {},
    createdAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
  }

  -- A single-repo project puts the worktree AT the workspace root, so paths
  -- stay `app/main.py` rather than `myrepo/app/main.py` for no reason.
  local single = #names == 1 and vim.tbl_count(m.repos) == 1

  for _, name in ipairs(names) do
    local repo = m.repos[name]
    local origin = vim.fs.joinpath(opts.root, name)
    local dest = single and root or vim.fs.joinpath(root, name)

    local add_err = add_worktree(origin, dest, branch, repo.base)
    if add_err then
      -- Leave what was assembled: dismantling on failure throws away the
      -- members that DID come up, and removal can do it deliberately.
      return nil, ("%s: %s"):format(name, add_err)
    end

    if repo.submodules then
      local _, sub_err = git(dest, { "submodule", "update", "--init", "--recursive" })
      if sub_err then
        return nil, ("%s: submodules: %s"):format(name, sub_err)
      end
    end

    local mat_err = materialise(origin, dest, repo)
    if mat_err then
      return nil, ("%s: %s"):format(name, mat_err)
    end
    exclude_managed(dest, repo)

    for _, command in ipairs(opts.setup and repo.setup or {}) do
      vim.system({ "sh", "-c", command }, { cwd = dest }):wait()
    end

    table.insert(ws.repos, {
      name = name,
      path = dest,
      origin = origin,
      branch = branch,
      base = repo.base,
      state = "active",
    })
  end

  -- Members named but not selected are `declared`, so a picker can show what a
  -- workspace could still pull in.
  for _, name in ipairs(manifest.names(m)) do
    if not vim.tbl_contains(names, name) then
      table.insert(ws.repos, {
        name = name,
        origin = vim.fs.joinpath(opts.root, name),
        state = "declared",
      })
    end
  end

  for _, name in ipairs(m.shared or {}) do
    local src = vim.fs.joinpath(opts.root, name)
    if vim.uv.fs_stat(src) then
      relink(src, vim.fs.joinpath(root, name))
    end
  end

  return ws, nil
end

---Work that removing the workspace would destroy.
---@param ws table
---@return string[]
function M.unsaved(ws)
  local blockers = {}
  for _, repo in ipairs(ws.repos or {}) do
    if repo.state == "active" and repo.path and repo.path ~= "" then
      local dirty = git(repo.path, { "status", "--porcelain" })
      if dirty and dirty ~= "" then
        blockers[#blockers + 1] = repo.name .. " has uncommitted changes"
      end

      -- Work CREATED HERE: reachable from HEAD, not from any remote, and not
      -- from the base the branch was cut from. Without the base term,
      -- `HEAD --not --remotes` lists the ENTIRE history in a repo with no
      -- remote, so every workspace in such a repo was unremovable.
      local args = { "log", "--oneline", "HEAD", "--not", "--remotes" }
      if repo.base and repo.base ~= "" then
        args[#args + 1] = repo.base
      end
      -- The `--` is load-bearing. `repo.base` is a bare name, and kora-backend
      -- has a directory called `main` next to a branch called `main` -- git
      -- refuses that as ambiguous, `git` here returns nil, and a nil answer to
      -- "is there unpushed work?" reads as NO. So the one repository where the
      -- check could not run was the one where removal went ahead and took the
      -- commits with it.
      args[#args + 1] = "--"
      local commits = git(repo.path, args)
      if commits and commits ~= "" then
        local count = #vim.split(commits, "\n")
        blockers[#blockers + 1] = ("%s has %d unpushed commit(s)"):format(repo.name, count)
      end
    end
  end
  return blockers
end

---Dismantle a workspace.
---
---NEVER `rm -rf` a member. `git worktree remove` is what keeps .git/worktrees
---consistent; deleting the directory is exactly how stale prunable entries get
---left behind.
---@param ws table
---@param opts? { force: boolean }
---@return boolean ok, string|nil err
function M.remove(ws, opts)
  opts = opts or {}

  if not opts.force then
    local blockers = M.unsaved(ws)
    if #blockers > 0 then
      return false,
        ("refusing to remove: %s\npass force to discard"):format(table.concat(blockers, "; "))
    end
  end

  for _, repo in ipairs(ws.repos or {}) do
    if repo.state == "active" and repo.path and repo.path ~= "" then
      local args = { "worktree", "remove" }
      if opts.force then
        args[#args + 1] = "--force"
      end
      args[#args + 1] = repo.path
      local _, err = git(repo.origin, args)
      if err then
        return false, ("%s: %s"):format(repo.name, err)
      end
    end
  end

  -- What remains is ours: the workspace directory and the shared symlinks in
  -- it. Removing a symlink never touches what it points at.
  vim.fn.delete(ws.root, "rf")

  -- Stale administrative entries are the failure this function exists to
  -- avoid, so prune regardless.
  for _, repo in ipairs(ws.repos or {}) do
    if repo.origin then
      git(repo.origin, { "worktree", "prune" })
    end
  end

  -- And the BRANCH the worktree was on, which `git worktree remove` leaves
  -- behind. It is not administrative debris that only git can see: `ws/billing`
  -- and `ws/test-workspace` sit in `git branch` forever, one per member repo,
  -- so a project accumulates five dead branches per workspace anyone ever made.
  -- ~/Code/grasslabs/kora had a full set from a workspace removed three days
  -- earlier.
  --
  -- `-d`, not `-D`, even here: it refuses a branch that is not merged, and
  -- refusing is right. The `unsaved` check above is the one that decides
  -- whether work may be discarded; this is only tidying up after it, and an
  -- unmerged branch left standing is recoverable where a deleted one is not.
  for _, repo in ipairs(ws.repos or {}) do
    if repo.state == "active" and repo.origin and repo.branch and repo.branch ~= "" then
      git(repo.origin, { "branch", opts.force and "-D" or "-d", repo.branch })
    end
  end

  return true, nil
end

return M
