--- The workspace manifest, as a screen you answer rather than a file you find.
---
--- `<project>/.ws/workspace.toml` used to arrive one of two ways, and neither
--- of them asked you anything. `:Paseo wcreate` in a multi-repo directory
--- discovered a manifest and WROTE it, reporting what it had guessed through a
--- `vim.notify` you cannot act on; `:Paseo ws init` dropped you into a raw TOML
--- buffer you had to already know about. The file itself then carries the
--- questions in comments -- `# init lists every non-repo directory it found;
--- PRUNE THIS` -- which is a question asked in a medium you cannot answer in,
--- and the openfin manifest still lists `test quotes` and `test-s3` because of
--- it.
---
--- The two things discovery genuinely cannot decide are the BASE BRANCH per
--- repo and WHICH SIBLINGS are shared context rather than junk that happens to
--- sit in the directory. Both are one keypress here.
---
--- It is |paseo.ui.panels.settings|'s view over a draft, the way the new-session
--- screen is -- same cards, same focus model, same footer. A second renderer of
--- "a list of things with a state each" is how the two drift.
---
--- `workspaces_dir` is deliberately NOT offered. Assembly builds the workspace
--- path from the manifest's value (`workspace/init.lua`), but `repos.lua`
--- detects a workspace using `config.workspaces.dir` -- so a manifest that
--- disagrees with the Lua config assembles workspaces the repo layer cannot
--- see. Until those two are one value, a control for it is a control for
--- breaking the review surface.

local icons = require "paseo.ui.icons"

local M = {}

-- `m` for members and `s` for shared. NOT `r`: the view binds `r` to reload
-- after it binds the source's mnemonics, so a group keyed `r` is a group you
-- can never jump to.
M.KEYS = { repos = "m", shared = "s" }

---@class paseo.ManifestDraft
---@field root string
---@field manifest paseo.ws.Manifest  Repos and their settings, mutated in place.
---@field notes table<string, string[]>  Discovery's remarks, by repo name.
---@field include table<string, boolean>  Repo name -> in the default set.
---@field shared table<string, boolean>   Sibling -> keep it.
---@field order string[]   Siblings in display order, kept across a reload.
---@field loading boolean

-- --------------------------------------------------------------- git

---Every ref this repo could sensibly be based on: its local branches, then its
---remote ones. `origin/HEAD` is dropped -- it is a symbolic alias for one of
---the entries already in the list, and offering both invites picking the alias
---and losing which branch it meant.
---@param path string
---@return string[]
function M.refs(path)
  local res = vim
    .system({
      "git",
      "-C",
      path,
      "for-each-ref",
      "--format=%(refname:short)",
      "--sort=-committerdate",
      "refs/heads",
      "refs/remotes",
    }, { text = true })
    :wait()
  if res.code ~= 0 then
    return {}
  end
  local out, seen = {}, {}
  for _, ref in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    ref = vim.trim(ref)
    if ref ~= "" and not ref:match "/HEAD$" and not seen[ref] then
      seen[ref] = true
      out[#out + 1] = ref
    end
  end
  return out
end

-- --------------------------------------------------------------- the draft

---@param notes { repo: string, text: string }[]|nil
---@return table<string, string[]>
local function by_repo(notes)
  local out = {}
  for _, note in ipairs(notes or {}) do
    out[note.repo] = out[note.repo] or {}
    table.insert(out[note.repo], note.text)
  end
  return out
end

---Fold a freshly discovered manifest into what is already on disk.
---
---SAVED VALUES WIN, and an absence is a decision. A sibling that discovery
---finds but the saved `shared` list does not name was PRUNED -- re-adding it
---because it is still there on disk would undo the pruning on every visit,
---which is the one thing this screen exists to make stick.
---@param draft paseo.ManifestDraft
---@param found paseo.ws.Manifest
---@param notes { repo: string, text: string }[]|nil
---@param saved paseo.ws.Manifest|nil  Absent on a first run.
local function merge(draft, found, notes, saved)
  draft.notes = by_repo(notes)
  draft.manifest = {
    workspaces_dir = (saved and saved.workspaces_dir) or found.workspaces_dir or ".workspaces",
    branch_prefix = (saved and saved.branch_prefix) or found.branch_prefix or "ws/",
    repos = {},
    shared = {},
  }

  for name, repo in pairs(found.repos or {}) do
    local kept = saved and saved.repos and saved.repos[name]
    -- The saved table wholesale, not field by field: `copy`/`link` were
    -- tuned by hand as often as they were generated, and a merge that took
    -- discovery's list for those would silently undo that on every open.
    draft.manifest.repos[name] = kept and vim.deepcopy(kept) or repo
    if draft.include[name] == nil then
      local from = kept or repo
      draft.include[name] = from.default ~= false
    end
  end

  -- A repo named in the manifest but gone from disk stays, and says so. It is
  -- far more often a checkout that has not been cloned on this machine than a
  -- repo that was deleted, and dropping it silently loses its `base`.
  for name, repo in pairs((saved and saved.repos) or {}) do
    if not draft.manifest.repos[name] then
      draft.manifest.repos[name] = vim.deepcopy(repo)
      draft.notes[name] = { "named in the manifest but not found on disk." }
      if draft.include[name] == nil then
        draft.include[name] = repo.default ~= false
      end
    end
  end

  local order, seen = {}, {}
  local function offer(dir, keep)
    if not seen[dir] then
      seen[dir] = true
      order[#order + 1] = dir
      if draft.shared[dir] == nil then
        draft.shared[dir] = keep
      end
    end
  end
  for _, dir in ipairs((saved and saved.shared) or {}) do
    offer(dir, true)
  end
  for _, dir in ipairs(found.shared or {}) do
    offer(dir, saved == nil)
  end
  table.sort(order)
  draft.order = order
end

---@param root string
---@param found paseo.ws.Manifest
---@param notes { repo: string, text: string }[]|nil
---@param saved paseo.ws.Manifest|nil
---@return paseo.ManifestDraft
function M.new(root, found, notes, saved)
  local draft = {
    root = root,
    manifest = {},
    notes = {},
    include = {},
    shared = {},
    order = {},
    loading = false,
  }
  merge(draft, found, notes, saved)
  return draft
end

---Re-walk the project. Toggles survive, because `merge` only fills a decision
---that has not been made.
---@param draft paseo.ManifestDraft
---@param done? fun()
function M.reload(draft, done)
  done = done or function() end
  local found, notes = require("paseo.workspace").discover(draft.root)
  if not found then
    vim.notify("paseo: could not re-read this project — " .. tostring(notes), vim.log.levels.WARN)
    return done()
  end
  merge(draft, found, notes, M.result(draft))
  done()
end

---The draft as a manifest, ready for `manifest.save`.
---@param draft paseo.ManifestDraft
---@return paseo.ws.Manifest
function M.result(draft)
  local repos = {}
  for name, repo in pairs(draft.manifest.repos or {}) do
    local copy = vim.deepcopy(repo)
    -- Absent means included; only an explicit `false` opts a repo out, which
    -- is what `manifest.select` reads and what `render` writes.
    --
    -- NOT `include[name] and nil or false`: `true and nil` is nil, which then
    -- falls through to the `or`, so that expression yields `false` for every
    -- repo and opts the whole project out.
    if draft.include[name] then
      copy.default = nil
    else
      copy.default = false
    end
    repos[name] = copy
  end

  local shared = {}
  for _, dir in ipairs(draft.order) do
    if draft.shared[dir] then
      shared[#shared + 1] = dir
    end
  end

  return {
    workspaces_dir = draft.manifest.workspaces_dir,
    branch_prefix = draft.manifest.branch_prefix,
    repos = repos,
    shared = shared,
  }
end

---The notes still worth writing into the file: the ones about repos that
---survived. A comment explaining why a repo nobody kept was excluded is a
---comment about nothing.
---@param draft paseo.ManifestDraft
---@return { repo: string, text: string }[]
function M.notes(draft)
  local out = {}
  for _, name in ipairs(vim.tbl_keys(draft.manifest.repos or {})) do
    for _, text in ipairs(draft.notes[name] or {}) do
      out[#out + 1] = { repo = name, text = text }
    end
  end
  return out
end

-- --------------------------------------------------------------- groups

---@param draft paseo.ManifestDraft
---@return table[]
function M.groups(draft)
  local repos = {}
  for _, name in ipairs(require("paseo.workspace.manifest").names(draft.manifest)) do
    local repo = draft.manifest.repos[name]
    local notes = draft.notes[name] or {}
    repos[#repos + 1] = {
      id = name,
      label = name,
      -- The base on the right of its own row, so the thing discovery most
      -- often gets wrong is readable without focusing every repo in turn.
      note = repo.base ~= "" and repo.base or "?",
      description = #notes > 0 and table.concat(notes, " ") or nil,
      value = draft.include[name] and true or false,
    }
  end

  local shared = {}
  for _, dir in ipairs(draft.order) do
    shared[#shared + 1] = {
      id = dir,
      label = dir,
      value = draft.shared[dir] and true or false,
    }
  end

  return {
    {
      id = "repos",
      key = M.KEYS.repos,
      icon = icons.ui.repo,
      label = "Repos",
      kind = "toggles",
      entries = repos,
      placeholder = "(no git repositories found here)",
    },
    {
      id = "shared",
      key = M.KEYS.shared,
      icon = icons.ui.folder,
      label = "Shared",
      kind = "toggles",
      entries = shared,
      placeholder = "(nothing else in this directory)",
    },
  }
end

---@param draft paseo.ManifestDraft
---@param group table
---@param entry table
---@param done? fun()
function M.apply(draft, group, entry, done)
  done = done or function() end
  if not (group and entry) then
    return done()
  end
  if group.id == "repos" then
    draft.include[entry.id] = not draft.include[entry.id]
  elseif group.id == "shared" then
    draft.shared[entry.id] = not draft.shared[entry.id]
  end
  return done()
end

---Set one repo's base branch.
---
---`vim.ui.select` rather than a box floated over the card. A branch name is a
---value you PICK, not prose you compose -- which is the line |paseo.ui.prompt|
---draws -- and the candidates are the answer nearly every time.
---@param draft paseo.ManifestDraft
---@param name string
---@param done? fun()
function M.choose_base(draft, name, done)
  done = done or function() end
  local repo = draft.manifest.repos[name]
  if not repo then
    return done()
  end

  local path = vim.fs.joinpath(draft.root, name)
  local choices = M.refs(path)
  if #choices == 0 then
    return vim.ui.input(
      { prompt = ("base for %s: "):format(name), default = repo.base },
      function(value)
        if value and vim.trim(value) ~= "" then
          repo.base = vim.trim(value)
        end
        done()
      end
    )
  end

  choices[#choices + 1] = "other…"
  vim.ui.select(choices, {
    prompt = ("base branch for %s"):format(name),
  }, function(choice)
    if not choice then
      return done()
    end
    if choice == "other…" then
      -- NO `default`. `vim.ui.input` puts the cursor after what it pre-fills,
      -- so seeding it with the current base turns "dev" plus a typed
      -- "release/2026" into "devrelease/2026". Picking "other" is saying none
      -- of the listed refs is the one, which makes the old value the least
      -- useful thing to start from.
      return vim.ui.input({ prompt = ("base for %s: "):format(name) }, function(value)
        if value and vim.trim(value) ~= "" then
          repo.base = vim.trim(value)
        end
        done()
      end)
    end
    -- Stored WITHOUT the remote prefix. `worktree add` resolves `dev` against
    -- `origin/dev` on its own, and a base recorded as `origin/dev` names a ref
    -- that cannot be checked out.
    repo.base = (choice:gsub("^[^/]+/", ""))
    done()
  end)
end

---@param draft paseo.ManifestDraft
---@return paseo.SettingsSource
function M.source(draft)
  return {
    draft = draft,
    keys = M.KEYS,
    pairs = { { "repos", "shared" } },
    groups = function()
      return M.groups(draft)
    end,
    apply = function(_, group, entry, done)
      M.apply(draft, group, entry, done)
    end,
    load = function(_, done)
      M.reload(draft, done)
    end,
  }
end

---A draft for this project: what is on disk, folded into what is there now.
---
---An existing file is LOADED, not replaced. Going back to prune a `shared`
---list you accepted too fast is the main reason to open this twice, and a
---screen that re-added everything discovery can still see would undo that
---every time.
---@param root string
---@param found? paseo.ws.Manifest  Discovery's answer, when the caller already has it.
---@param notes? { repo: string, text: string }[]
---@return paseo.ManifestDraft|nil, string|nil err
function M.draft(root, found, notes)
  if not found then
    found, notes = require("paseo.workspace").discover(root)
    if not found then
      return nil, tostring(notes)
    end
  end
  local saved = require("paseo.workspace.manifest").load(root)
  return M.new(root, found, notes, saved), nil
end

-- --------------------------------------------------------------- surfaces

---The manifest as a TOML buffer you write yourself.
---
---What `:Paseo ws init` always did, kept as the escape hatch behind `t`: the
---dialog covers the two decisions discovery cannot make, and this covers
---everything else the file can express -- `copy`, `link`, `setup`, a repo name
---with a dot in it. Still never written behind your back; you `:w` it.
---@param root string
---@param m paseo.ws.Manifest
---@param notes { repo: string, text: string }[]
function M.edit(root, m, notes)
  local manifest = require "paseo.workspace.manifest"
  local path = manifest.path(root)

  -- The directory has to exist BEFORE the buffer is named, or `:w` fails with
  -- E212 "Can't open file for writing: no such file or directory" -- which
  -- reads like a permissions problem rather than a missing parent. Creating it
  -- is harmless even if you never write the file.
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  -- A buffer may already be sitting on this path -- a second run, or the file
  -- simply being open. Reuse it rather than failing on a duplicate name.
  local buf = vim.fn.bufnr(path)
  vim.cmd "tabnew"
  if buf ~= -1 then
    vim.api.nvim_win_set_buf(0, buf)
  else
    buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, path)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(manifest.render(m, notes), "\n"))
  vim.bo[buf].filetype = "toml"

  vim.notify("paseo: review this, then :w to accept it", vim.log.levels.INFO)
end

---Configure a manifest before anything is written.
---
---Opened by `:Paseo wcreate` in a multi-repo directory and by `:Paseo ws init`.
---`callback(manifest, notes)` on confirm; `callback(nil)` on every other exit,
---including `t` -- which hands the file over to you and so is not a confirm.
---@param opts { root: string, manifest?: paseo.ws.Manifest, notes?: table[] }
---@param callback fun(m: paseo.ws.Manifest|nil, notes: table[]|nil)
function M.review(opts, callback)
  local panel = require "paseo.ui.panels.settings"
  local popup = require "paseo.ui.popup"
  local render = require "paseo.ui.render"
  local widgets = require "paseo.ui.widgets"

  local handle
  local done = false

  ---Exactly once, whatever got us here: `q`, `<Esc>`, `c`, `t`, a `WinClosed`,
  ---or a failure before there was ever a window. volt's own `q` routes through
  ---`after_close`, which is `handle.close`, which is `on_close`, which is this
  ----- so the cancel path and the confirm path meet in one place.
  local function finish(m, notes)
    if done then
      return
    end
    done = true
    if handle then
      handle.close()
    end
    callback(m, notes)
  end

  local draft, err = M.draft(opts.root, opts.manifest, opts.notes)
  if not draft then
    vim.notify("paseo: " .. tostring(err), vim.log.levels.ERROR)
    return callback(nil, nil)
  end

  local function confirm()
    finish(M.result(draft), M.notes(draft))
  end

  local function as_toml()
    local m, n = M.result(draft), M.notes(draft)
    finish(nil, nil)
    M.edit(opts.root, m, n)
  end

  local view = panel.new(M.source(draft), {
    section = "manifest",
    hints = { { "b", "base" }, { "t", "toml" }, { "q", "cancel" } },
    redraw = function()
      if handle then
        handle.rebuild()
      end
    end,
  })

  local function base()
    local group, entry = view:resolve()
    if not (group and entry and group.id == "repos") then
      return
    end
    M.choose_base(draft, entry.id, function()
      if handle and not done then
        handle.rebuild()
      end
    end)
  end

  -- `confirm` is not a settings group -- a card that is not a setting reads as
  -- one -- so it is a row of its own under the cards, clickable the way
  -- `widgets.radio` is clickable: the action on every cell, so the target is
  -- the row and not the two words on it.
  view.footer = function(w)
    local repos, shared = 0, 0
    for _, keep in pairs(draft.include) do
      repos = repos + (keep and 1 or 0)
    end
    for _, keep in pairs(draft.shared) do
      shared = shared + (keep and 1 or 0)
    end
    local line = widgets.row(
      { widgets.keycap "c", { "  write the manifest" } },
      { { ("%d repo(s), %d shared"):format(repos, shared), "PaseoDim" } },
      w
    )
    for _, cell in ipairs(line) do
      cell[3] = cell[3] or confirm
    end
    return { line, {} }
  end

  handle = popup.open {
    view = view,
    width = function()
      return math.max(60, math.min(96, vim.o.columns - 8))
    end,
    zindex = 60,
    filetype = "paseo-manifest",
    title = function(h)
      local inner = h.w - 4
      return {
        render.truncate(
          widgets.row(
            { { icons.panel.Workspaces .. "  Workspace", "PaseoHeader" } },
            { { vim.fn.fnamemodify(opts.root, ":~"), "PaseoDim" } },
            inner,
            "PaseoNormal"
          ),
          inner
        ),
        { { string.rep("─", inner), "PaseoBorder" } },
        {},
      }
    end,
    keys = {
      { "c", confirm, "paseo: write this manifest" },
      { "b", base, "paseo: set this repo's base branch" },
      { "t", as_toml, "paseo: edit the manifest as TOML" },
    },
    -- volt owns `q` and `<Esc>`; both land here.
    on_close = function()
      finish(nil, nil)
    end,
  }
end

return M
