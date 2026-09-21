--- The skills this plugin ships.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

---one and one file that is not a skill either.
---@param names string[]
---@return string root
local function fake_plugin(names)
  local root = vim.fn.tempname()
  local base = vim.fs.joinpath(root, ".agents", "skills")
  for _, name in ipairs(names) do
    local dir = vim.fs.joinpath(base, name)
    vim.fn.mkdir(dir, "p")
    local fd = assert(io.open(vim.fs.joinpath(dir, "SKILL.md"), "w"))
    fd:write(("---\nname: %s\ndescription: what %s is for\n---\n\n# %s\n"):format(name, name, name))
    fd:close()
  end
  -- A directory with no SKILL.md is not a skill, and a loose file is not one
  -- either. Both have to be skipped rather than offered.
  vim.fn.mkdir(vim.fs.joinpath(base, "notaskill"), "p")
  local fd = assert(io.open(vim.fs.joinpath(base, "README.md"), "w"))
  fd:write "not a skill\n"
  fd:close()
  return root
end

local function test_skills()
  local skills = require "paseo.skills"
  local config = require "paseo.config"

  local root = fake_plugin { "alpha", "beta" }

  local found = skills.bundled(root)
  eq("skills: discovered by SKILL.md, not by a list", #found, 2)
  eq("skills: and named after the directory", found[1].name, "alpha")
  eq("skills: with the front matter description", found[1].description, "what alpha is for")

  -- Read from `.agents/skills`, never `.claude/skills`: those are git symlinks
  -- and a clone without symlink support materialises them as text files
  -- holding a path, which scans as one-line "skills".
  eq("skills: the bundled directory is .agents/skills", skills.DIR, ".agents/skills")
  truthy(
    "skills: bundled() reads out of .agents/skills",
    found[1].path:find("%.agents/skills/alpha$") ~= nil,
    found[1].path
  )

  local state_home = vim.env.XDG_STATE_HOME
  local saved = vim.deepcopy(config.get().skills)
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  local target = vim.fn.tempname()
  vim.fn.mkdir(target, "p")
  config.setup { skills = { dirs = { target } } }

  local ok = pcall(function()
    -- `plan` is pure. Nothing it looked at may exist afterwards.
    local probe = vim.fn.tempname()
    config.setup { skills = { dirs = { probe } } }
    truthy("skills: plan() succeeds against a directory that does not exist", skills.plan {
      action = "install",
      root = root,
    } ~= nil)
    eq("skills: and plan() wrote nothing", vim.uv.fs_stat(probe), nil)
    config.setup { skills = { dirs = { target } } }

    local first = assert(skills.plan { action = "install", root = root })
    eq("skills: a fresh target is all installs", first[1].verb, "link")
    skills.apply(first)
    truthy(
      "skills: install makes a link to the bundled skill",
      vim.uv.fs_realpath(vim.fs.joinpath(target, "alpha"))
        == vim.uv.fs_realpath(vim.fs.joinpath(root, ".agents", "skills", "alpha"))
    )

    -- Idempotent: the second run is all `skip`, not a second link and not an
    -- error.
    local again = assert(skills.plan { action = "install", root = root })
    eq("skills: installing twice is a no-op", again[1].verb, "skip")
    eq("skills: for every skill", again[2].verb, "skip")

    -- A directory paseo did not install is REFUSED, and its contents survive.
    vim.fn.delete(vim.fs.joinpath(target, "beta"), "rf")
    vim.fn.mkdir(vim.fs.joinpath(target, "beta"), "p")
    local mine = vim.fs.joinpath(target, "beta", "MINE.md")
    local fd = assert(io.open(mine, "w"))
    fd:write "mine\n"
    fd:close()

    local squatter = assert(skills.plan { action = "install", root = root })
    eq("skills: a foreign directory is refused", squatter[2].verb, "refuse")
    local _, refused = skills.apply(squatter)
    truthy("skills: and the run reports the refusal", refused)
    truthy("skills: and the foreign contents survive", vim.uv.fs_stat(mine) ~= nil)

    -- `force` MOVES it aside. One level of force, and it still does not
    -- destroy anything.
    local forced = assert(skills.plan { action = "install", root = root, force = true })
    eq("skills: force replaces rather than refusing", forced[2].verb, "replace")
    local _, force_refused, backed_up = skills.apply(forced)
    truthy("skills: a forced run refuses nothing", not force_refused)
    truthy("skills: and says it took a backup", backed_up)
    truthy(
      "skills: force backs the directory up rather than deleting it",
      vim.uv.fs_stat(vim.fs.joinpath(target, "beta" .. skills.BACKUP, "MINE.md")) ~= nil
    )

    -- A link pointing somewhere else is refused, and force replaces it with
    -- NO backup: a symlink is a pointer, not data.
    vim.fn.delete(vim.fs.joinpath(target, "alpha"), "rf")
    -- The target has to EXIST, or this is the dangling case below rather than
    -- the foreign one: a link to nothing is nobody's data.
    local elsewhere = vim.fn.tempname()
    vim.fn.mkdir(elsewhere, "p")
    vim.uv.fs_symlink(elsewhere, vim.fs.joinpath(target, "alpha"), nil)
    local foreign = assert(skills.plan { action = "install", root = root })
    eq("skills: a link pointing elsewhere is refused", foreign[1].verb, "refuse")
    eq(
      "skills: and force replaces it with no backup, because a pointer is not data",
      assert(skills.plan { action = "install", root = root, force = true })[1].verb,
      "replace"
    )

    -- A DANGLING link repairs without force. This is what a plugin reinstall
    -- leaves behind, and needing `force` to recover from it would make the
    -- normal case feel dangerous.
    vim.fn.delete(vim.fs.joinpath(target, "alpha"), "rf")
    vim.uv.fs_symlink("/definitely/not/here", vim.fs.joinpath(target, "alpha"), nil)
    local dangling = assert(skills.plan { action = "install", root = root })
    eq("skills: a dangling link is repaired without force", dangling[1].verb, "repair")
    skills.apply(dangling)
    truthy(
      "skills: and the repair points back at the bundled skill",
      vim.uv.fs_realpath(vim.fs.joinpath(target, "alpha"))
        == vim.uv.fs_realpath(vim.fs.joinpath(root, ".agents", "skills", "alpha"))
    )

    -- Uninstall takes back only what we installed.
    local removal = assert(skills.plan { action = "uninstall", root = root })
    skills.apply(removal)
    eq("skills: uninstall removes ours", vim.uv.fs_lstat(vim.fs.joinpath(target, "alpha")), nil)
    truthy(
      "skills: and leaves a backup it did not create alone",
      vim.uv.fs_stat(vim.fs.joinpath(target, "beta" .. skills.BACKUP, "MINE.md")) ~= nil
    )

    -- A copy is tracked, so a plugin update is noticed and refreshed rather
    -- than reported as already installed.
    local copied = assert(skills.plan { action = "install", root = root, method = "copy" })
    eq("skills: copy is an available method", copied[1].verb, "copy")
    skills.apply(copied)
    truthy(
      "skills: a copy is a real directory, not a link",
      vim.uv.fs_lstat(vim.fs.joinpath(target, "alpha")).type == "directory"
    )
    local fresh = assert(skills.plan { action = "install", root = root })
    eq("skills: an unchanged copy is left alone", fresh[1].verb, "skip")
    local touch = assert(io.open(vim.fs.joinpath(target, "alpha", "SKILL.md"), "a"))
    touch:write "drifted\n"
    touch:close()
    local stale = assert(skills.plan { action = "install", root = root })
    eq("skills: a drifted copy is refreshed, not skipped", stale[1].verb, "refresh")

    -- An unknown name is an error naming it, never a silent no-op.
    local _, name_err = skills.plan { action = "install", root = root, names = { "nope" } }
    truthy("skills: an unknown skill name is an error", name_err ~= nil, tostring(name_err))
  end)

  vim.env.XDG_STATE_HOME = state_home
  config.setup { skills = saved }
  truthy("skills: the suite ran without throwing", ok, tostring(ok))
end

return {
  { "skills", test_skills },
}
