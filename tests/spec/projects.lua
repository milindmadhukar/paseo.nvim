--- When a folder becomes a Paseo project (|paseo.projects|).
---
--- The daemon registers any directory a first session starts in, so `nvim ~`
--- and a prompt used to make your home directory a project without a word.
--- What is held here: `~` and `/` are refused, a repo or a manifest goes
--- unasked, a plain folder is asked about ONCE, and one the daemon already has
--- is not asked about at all.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

---@return string
local function tmpdir()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  return dir
end

local function test_classify()
  local projects = require "paseo.projects"
  local old_home = vim.env.HOME
  local home = tmpdir()
  local ok, failure = pcall(function()
    vim.env.HOME = home
    eq("classify: / is refused", projects.classify "/", "refuse")
    eq("classify: $HOME is refused", projects.classify(home), "refuse")
    eq("classify: so is $HOME with a trailing slash", projects.classify(home .. "/"), "refuse")
    eq("classify: and anything above it", projects.classify(vim.fs.dirname(home)), "refuse")

    local plain = vim.fs.joinpath(home, "scratch")
    vim.fn.mkdir(plain, "p")
    eq("classify: a folder under $HOME is a plain one", projects.classify(plain), "plain")

    local repo = vim.fs.joinpath(home, "repo")
    vim.fn.mkdir(vim.fs.joinpath(repo, "lua"), "p")
    vim.system({ "git", "init", "-q", repo }):wait()
    eq("classify: a git repo is a project already", projects.classify(repo), "repo")
    eq(
      "classify: a folder inside one resolves to the repo",
      projects.resolve { root = vim.fs.joinpath(repo, "lua") },
      repo
    )

    local multi = vim.fs.joinpath(home, "multi")
    local manifest = require("paseo.workspace.manifest").path(multi)
    vim.fn.mkdir(vim.fs.dirname(manifest), "p")
    vim.fn.writefile({ "[workspace]" }, manifest)
    eq("classify: a manifested folder is a project already", projects.classify(multi), "manifest")
  end)
  vim.env.HOME = old_home
  vim.fn.delete(home, "rf")
  if not ok then
    error(failure, 0)
  end
end

local function test_ensure()
  local projects = require "paseo.projects"
  local bridge = require "paseo.bridge"
  local pick = require "paseo.ui.pick"
  local old_request, old_confirm, old_notify, old_home = bridge.request, pick.confirm, vim.notify, vim.env.HOME

  local home = tmpdir()
  local plain = vim.fs.joinpath(home, "scratch")
  local known = vim.fs.joinpath(home, "notes")
  local repo = vim.fs.joinpath(home, "repo")
  for _, dir in ipairs { plain, known, repo } do
    vim.fn.mkdir(dir, "p")
  end
  vim.system({ "git", "init", "-q", repo }):wait()

  local lists, asked, said, answer, fail = 0, {}, nil, false, nil
  bridge.request = function(op, _, cb)
    if op == "project.list" then
      lists = lists + 1
      if fail then
        return cb(fail)
      end
      return cb(nil, { projects = { { id = "prj_notes", root = known } } })
    end
    cb(nil, {})
  end
  pick.confirm = function(prompt, opts, cb)
    asked[#asked + 1] = { prompt = prompt, yes = opts.yes }
    cb(answer)
  end
  vim.notify = function(msg)
    said = msg
  end

  ---@return boolean|nil ok, string|nil err
  local function ensure(root)
    local got, done = nil, false
    projects.ensure({ root = root }, function(ok, err)
      got, done = { ok, err }, true
    end)
    vim.wait(1000, function()
      return done
    end)
    return got and got[1], got and got[2]
  end

  local ok, failure = pcall(function()
    vim.env.HOME = home
    projects.invalidate()

    local went, err = ensure(home)
    eq("ensure: $HOME is refused", { went, err }, { false, "cancelled" })
    truthy("ensure: and says why", said and said:find(":cd into one", 1, true), said)
    eq("ensure: without asking", #asked, 0)

    went = ensure(repo)
    eq("ensure: a repo goes", went, true)
    eq("ensure: unasked, and without asking the daemon", { #asked, lists }, { 0, 0 })

    went = ensure(known)
    eq("ensure: a plain folder the daemon has goes", went, true)
    eq("ensure: unasked", #asked, 0)

    answer = false
    went, err = ensure(plain)
    eq("ensure: a plain folder it has never seen is asked about", #asked, 1)
    truthy("ensure: by name", asked[1].prompt:find("scratch", 1, true), asked[1].prompt)
    eq("ensure: declining starts nothing", { went, err }, { false, "cancelled" })

    answer = true
    went = ensure(plain)
    eq("ensure: accepting goes", went, true)
    went = ensure(plain)
    eq("ensure: and it is not asked again", { went, #asked }, { true, 2 })

    -- The daemon could not be asked: you are, rather than adding it unseen.
    projects.invalidate()
    fail, answer = "daemon down", false
    went = ensure(vim.fs.joinpath(home, "scratch"))
    eq("ensure: an unanswered daemon asks rather than adds", { went, #asked }, { false, 3 })
  end)
  bridge.request, pick.confirm, vim.notify, vim.env.HOME = old_request, old_confirm, old_notify, old_home
  projects.invalidate()
  vim.fn.delete(home, "rf")
  if not ok then
    error(failure, 0)
  end
end

return {
  { "projects.classify", test_classify },
  { "projects.ensure", test_ensure },
}
