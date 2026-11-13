--- What the performance work must not change: an answer kept for speed is
--- still the answer. Each case here is a way a cache goes stale or leaks.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function ids(list)
  return vim.tbl_map(function(a)
    return a.id
  end, list)
end

local function test_agent_memo()
  local agents = require "paseo.agents"
  local host = require("paseo.hosts").selected()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/b", "p")
  agents._apply {
    kind = "snapshot",
    hostId = host,
    entries = {
      { id = "a", title = "alpha", cwd = root, workspaceId = "w1" },
      { id = "b", title = "beta", cwd = root .. "/b", workspaceId = "w1" },
      { id = "c", title = "gamma", cwd = root .. "-elsewhere", workspaceId = "w2" },
    },
  }
  local first = agents.for_root(root, host)
  eq("memo: the agents under a root", ids(first), { "a", "b" })

  -- A caller sorting what it was handed -- the tree does -- must not reorder
  -- what the next caller is handed.
  table.sort(first, function(x, y)
    return x.id > y.id
  end)
  table.insert(first, { id = "intruder" })
  eq("memo: a caller's sort does not reach the kept list", ids(agents.for_root(root, host)), { "a", "b" })
  local all = agents.all(host)
  all[1] = nil
  eq("memo: nor does a caller emptying `all`", #agents.all(host), 3)

  -- Any change to the directory is a new answer, not the kept one.
  local before = agents.generation()
  agents._apply {
    kind = "upsert",
    hostId = host,
    agent = { id = "c", title = "gamma", cwd = root, workspaceId = "w1" },
  }
  truthy("memo: an upsert is a new generation", agents.generation() > before)
  eq("memo: a moved agent is found where it went", ids(agents.for_root(root, host)), { "a", "b", "c" })
  eq(
    "memo: and in its new workspace",
    ids(agents.for_workspace({ id = "w1", directory = root, hostId = host }, host)),
    { "a", "b", "c" }
  )
  eq(
    "memo: and gone from its old one",
    #agents.for_workspace({ id = "w2", directory = root .. "-elsewhere", hostId = host }, host),
    0
  )
  agents._apply { kind = "remove", hostId = host, id = "a" }
  eq("memo: a removal is seen", ids(agents.for_root(root, host)), { "b", "c" })
  agents._apply { kind = "snapshot", hostId = host, entries = {} }
  eq("memo: and a fresh snapshot replaces everything", #agents.all(host), 0)
end

local function test_subagent_memo()
  local agents = require "paseo.agents"
  local subagents = require "paseo.subagents"
  local host = require("paseo.hosts").selected()
  agents._apply {
    kind = "snapshot",
    hostId = host,
    entries = { { id = "parent", title = "p", status = "idle" } },
  }
  eq("memo: no subagents yet", #subagents.list("parent", host), 0)
  agents._apply {
    kind = "upsert",
    hostId = host,
    agent = {
      id = "kid",
      title = "k",
      status = "running",
      labels = { [subagents.PARENT_LABEL] = "parent" },
    },
  }
  local list = subagents.list("parent", host)
  eq("memo: a new Paseo subagent is listed", #list, 1)
  eq("memo: and counted as running", select(1, subagents.counts("parent", host)), 1)
  list[1] = nil
  eq("memo: a caller's edit does not reach the kept list", #subagents.list("parent", host), 1)
  agents._apply {
    kind = "upsert",
    hostId = host,
    agent = { id = "kid", title = "k", status = "idle", labels = { [subagents.PARENT_LABEL] = "parent" } },
  }
  eq("memo: and it stops running when it stops", select(1, subagents.counts("parent", host)), 0)
  agents._apply { kind = "snapshot", hostId = host, entries = {} }
end

local function test_paths()
  local paths = require "paseo.paths"
  local a, b = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(a, "p")
  vim.fn.mkdir(b, "p")
  local link = vim.fn.tempname()
  vim.uv.fs_symlink(a, link)
  local cwd = vim.uv.cwd()
  eq("paths: a symlink resolves", paths.canonical(link), vim.fn.resolve(a))
  eq("paths: and a trailing slash goes", paths.canonical(a .. "/"), vim.fn.resolve(a))
  -- RELATIVE is never kept: it means something else after a :cd.
  vim.cmd.cd(a)
  local in_a = paths.canonical "x"
  vim.cmd.cd(b)
  local in_b = paths.canonical "x"
  vim.cmd.cd(cwd)
  truthy("paths: a relative path follows the cwd", in_a ~= in_b)
  vim.fn.delete(link)
  vim.fn.delete(a, "rf")
  vim.fn.delete(b, "rf")
end

return {
  { "perf: the agent directory's kept answers", test_agent_memo },
  { "perf: the subagent lists' kept answers", test_subagent_memo },
  { "perf: kept path spellings", test_paths },
}
