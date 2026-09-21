--- `<project>/.ws/workspace.toml` -- reading and writing.
---
--- The manifest is project-local and uncommitted. "Committed" is not even
--- expressible for a project like ~/Code/openfin, which is a plain directory
--- holding six repositories and is not itself a repository.
---
--- TOML, not JSON or Lua: this file is meant to be read and edited by hand, and
--- the comments `init` writes into it -- why this base branch, why this repo is
--- opt-in -- are the most useful thing in it. JSON cannot carry them and an
--- executable Lua config is the wrong shape for a file agents may also write.
--- The parser below covers exactly the subset that shape needs.

local M = {}

M.DIR = ".ws"
M.FILE = "workspace.toml"

---@class paseo.ws.Repo
---@field base string            Ref new worktrees branch from.
---@field copy string[]          Untracked paths copied per workspace.
---@field link string[]          Heavy regenerable dirs symlinked to the primary.
---@field clone_symlinks string[] Symlinks recreated verbatim.
---@field setup string[]         Commands run in the new worktree.
---@field default boolean        Included when --repos is not given.
---@field submodules boolean

---@class paseo.ws.Manifest
---@field shared string[]        Untracked siblings symlinked into every workspace.
---@field workspaces_dir string
---@field branch_prefix string
---@field repos table<string, paseo.ws.Repo>

---@param root string
---@return string
function M.path(root)
  return vim.fs.joinpath(root, M.DIR, M.FILE)
end

--- A TOML value: a quoted string, a bare bool, or an inline array of strings.
---@param text string
---@return any
local function value(text)
  text = vim.trim(text)

  if text == "true" then
    return true
  end
  if text == "false" then
    return false
  end

  local quoted = text:match '^"(.*)"$'
  if quoted then
    -- Only the escapes this file can contain. A full TOML unescaper would be
    -- dead code here.
    return (quoted:gsub("\\\\(.)", { ['"'] = '"', ["\\\\"] = "\\\\", n = "\n", t = "\t" }))
  end

  if text:match "^%[" then
    local items = {}
    -- Split on commas that are not inside quotes.
    local inside, current = false, {}
    for i = 2, #text do
      local char = text:sub(i, i)
      if char == '"' and text:sub(i - 1, i - 1) ~= "\\" then
        inside = not inside
        current[#current + 1] = char
      elseif (char == "," or char == "]") and not inside then
        local item = vim.trim(table.concat(current))
        if item ~= "" then
          items[#items + 1] = value(item)
        end
        current = {}
        if char == "]" then
          break
        end
      else
        current[#current + 1] = char
      end
    end
    return items
  end

  return tonumber(text) or text
end

---Parse the subset of TOML this manifest uses.
---@param text string
---@return paseo.ws.Manifest
function M.parse(text)
  ---@type paseo.ws.Manifest
  local out = { shared = {}, repos = {} }
  local target = out

  for line in (text .. "\n"):gmatch "(.-)\n" do
    local trimmed = vim.trim(line)

    if trimmed == "" or vim.startswith(trimmed, "#") then
      goto continue
    end

    local header = trimmed:match "^%[(.+)%]$"
    if header then
      -- `[repos.clm_api]`, and `[repos."odd name"]` for a name with a dot.
      local repo = header:match '^repos%."(.+)"$' or header:match "^repos%.(.+)$"
      if repo then
        out.repos[repo] = out.repos[repo] or {}
        target = out.repos[repo]
      else
        target = out
      end
      goto continue
    end

    local key, raw = trimmed:match "^([%w_%-]+)%s*=%s*(.+)$"
    if key then
      target[key] = value(raw)
    end

    ::continue::
  end

  out.workspaces_dir = out.workspaces_dir or ".workspaces"
  out.branch_prefix = out.branch_prefix or "ws/"
  return out
end

---@param root string
---@return paseo.ws.Manifest|nil, string|nil error
function M.load(root)
  local path = M.path(root)
  local fd = io.open(path, "r")
  if not fd then
    return nil, ("no %s -- run `:Paseo ws init` first"):format(path)
  end
  local text = fd:read "*a"
  fd:close()

  local ok, parsed = pcall(M.parse, text)
  if not ok then
    return nil, ("%s: %s"):format(path, parsed)
  end
  return parsed, nil
end

---Repo names, sorted.
---@param m paseo.ws.Manifest
---@return string[]
function M.names(m)
  local names = vim.tbl_keys(m.repos)
  table.sort(names)
  return names
end

---Resolve a repo selection: the defaults, plus `with`, or exactly `only`.
---@param m paseo.ws.Manifest
---@param only? string[]
---@param with? string[]
---@return string[]|nil, string|nil error
function M.select(m, only, with)
  if only and #only > 0 then
    for _, name in ipairs(only) do
      if not m.repos[name] then
        return nil, ("no repo %q in the manifest"):format(name)
      end
    end
    return only, nil
  end

  local chosen = {}
  for name, repo in pairs(m.repos) do
    -- Absent means included. Only an explicit `default = false` opts out.
    if repo.default ~= false then
      chosen[name] = true
    end
  end
  for _, name in ipairs(with or {}) do
    if not m.repos[name] then
      return nil, ("no repo %q in the manifest"):format(name)
    end
    chosen[name] = true
  end

  local names = vim.tbl_keys(chosen)
  table.sort(names)
  return names, nil
end

---@param items string[]
---@return string
local function list(items)
  local quoted = {}
  for _, item in ipairs(items) do
    quoted[#quoted + 1] = ("%q"):format(item)
  end
  return "[" .. table.concat(quoted, ", ") .. "]"
end

---Render the manifest as TOML, WITH COMMENTS.
---
---Hand-rolled because the comments are the point: a generated manifest that
---silently chose `dev` over `main`, or excluded a 2GB repo, has to say so where
---the reader will look.
---@param m paseo.ws.Manifest
---@param notes { repo: string, text: string }[]
---@return string
function M.render(m, notes)
  local by_repo = {}
  for _, note in ipairs(notes or {}) do
    by_repo[note.repo] = by_repo[note.repo] or {}
    table.insert(by_repo[note.repo], note.text)
  end

  local out = {
    "# Generated by `:Paseo ws init`. Project-local and uncommitted.",
    "# The comments are what discovery guessed rather than knew; `:Paseo ws init`",
    "# is the same file as a screen.",
    "",
  }

  if m.shared and #m.shared > 0 then
    vim.list_extend(out, {
      "# Untracked siblings symlinked into every workspace root.",
      "# Chosen on the Shared card of `:Paseo ws init`; re-run it to change the",
      "# list. Anything not named here is left out of every workspace.",
      "shared = " .. list(m.shared),
      "",
    })
  end

  vim.list_extend(out, {
    ("workspaces_dir = %q"):format(m.workspaces_dir or ".workspaces"),
    ("branch_prefix = %q"):format(m.branch_prefix or "ws/"),
    "",
  })

  for _, name in ipairs(M.names(m)) do
    local repo = m.repos[name]
    for _, text in ipairs(by_repo[name] or {}) do
      out[#out + 1] = "# " .. text
    end
    -- A name containing a dot would otherwise read as a nested table.
    out[#out + 1] = name:find "%." and ('[repos."%s"]'):format(name) or ("[repos.%s]"):format(name)
    out[#out + 1] = ("base = %q"):format(repo.base or "")
    for _, key in ipairs { "copy", "link", "clone_symlinks", "setup" } do
      if repo[key] and #repo[key] > 0 then
        out[#out + 1] = ("%s = %s"):format(key, list(repo[key]))
      end
    end
    if repo.submodules then
      out[#out + 1] = "submodules = true"
    end
    if repo.default == false then
      out[#out + 1] = "default = false"
    end
    out[#out + 1] = ""
  end

  return table.concat(out, "\n")
end

---@param root string
---@param m paseo.ws.Manifest
---@param notes { repo: string, text: string }[]
---@return boolean ok, string|nil error
function M.save(root, m, notes)
  local dir = vim.fs.joinpath(root, M.DIR)
  vim.fn.mkdir(dir, "p")
  local fd, err = io.open(M.path(root), "w")
  if not fd then
    return false, err
  end
  fd:write(M.render(m, notes))
  fd:close()
  return true, nil
end

return M
