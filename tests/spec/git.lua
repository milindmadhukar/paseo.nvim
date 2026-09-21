--- What git actually says, against real repositories.
---
--- Four suites over the fixture tree: which repos a directory is part of, what
--- changed in them, the hunks that describes, and staging those hunks back.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local in_dir = t.in_dir

---Reset a fixture repo's index so staging tests start clean.
local function reset_index(worktree)
  vim.system({ "git", "-C", worktree, "reset", "-q", "HEAD", "--", "." }):wait()
end

---@param hunks paseo.Hunk[]
---@param path string
---@return paseo.Hunk[]
local function for_path(hunks, path)
  return vim.tbl_filter(function(h)
    return h.path == path
  end, hunks)
end

local function test_repos()
  local repos = require "paseo.repos"

  in_dir(root .. "/solo", function()
    local list = repos.list()
    eq("repos: plain repo yields exactly one", #list, 1)
    eq("repos: named after the repo", list[1] and list[1].name, "solo")
  end)

  in_dir(root .. "/multi/.workspaces/otp", function()
    local names = vim.tbl_map(function(r)
      return r.name
    end, repos.list())
    eq("repos: multi-repo workspace yields every member, sorted", names, { "clm", "clm_api" })
  end)

  in_dir(root .. "/multi/.workspaces/otp/Docs", function()
    local names = vim.tbl_map(function(r)
      return r.name
    end, repos.list())
    eq("repos: found from a non-repo sibling inside the workspace", names, { "clm", "clm_api" })
  end)

  in_dir(root .. "/solo/.workspaces/inner", function()
    local list = repos.list()
    eq("repos: single-repo workspace yields one", #list, 1)
    -- The regression: a linked worktree's basename is the WORKSPACE name, so
    -- naming by basename reported this as "inner" rather than "solo".
    eq(
      "repos: named from the common dir, not the worktree basename",
      list[1] and list[1].name,
      "solo"
    )
    truthy(
      "repos: gitdir is the per-worktree dir, not the common dir",
      list[1] and list[1].gitdir:find("worktrees/inner", 1, true) ~= nil,
      list[1] and list[1].gitdir
    )
  end)

  in_dir(root .. "/plain", function()
    eq("repos: outside any repo yields an empty list, not nil", repos.list(), {})
  end)

  -- THE WALK HAS TO END. `workspace_root` climbs with `vim.fs.dirname` and
  -- used to stop only at `/`, which assumes it was handed an absolute path.
  -- Delete the directory Neovim is standing in and it is not: `getcwd()`
  -- answers `""` and `:p` answers `"./"`, and `dirname` is a FIXED POINT for
  -- `"."`. The editor went into that loop and never came back -- no redraw, no
  -- keys, one core at 100% -- and it got there through `:Paseo chat`, which
  -- asks this about the cwd before it does anything else.
  do
    local gone = root .. "/gone"
    vim.fn.mkdir(gone, "p")
    local back = assert(vim.uv.cwd())
    vim.uv.chdir(gone)
    vim.fn.delete(gone, "rf")
    local ok, walked = pcall(repos.workspace_root, ".")
    vim.uv.chdir(back)
    truthy("repos: the workspace walk ends when the cwd is gone", ok, walked)
    eq("repos: answering nothing rather than spinning", walked, nil)
  end

  eq("repos: and a relative path is not a workspace either", repos.workspace_root "a/b", nil)
end

local function test_status()
  local git, repos = require "paseo.git", require "paseo.repos"

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    local changes = git.status(repo)
    local by_path = {}
    for _, c in ipairs(changes) do
      by_path[c.path] = c
    end

    -- The rename is the parsing trap: its record is followed by a SECOND
    -- NUL-terminated field. Split naively and every entry after it shifts.
    truthy("status: rename is parsed", by_path["new-name.txt"] ~= nil)
    eq(
      "status: rename carries its source",
      by_path["new-name.txt"] and by_path["new-name.txt"].orig_path,
      "old-name.txt"
    )
    -- The proof the stream did not desync: entries after the rename survive.
    truthy("status: entries after the rename survive", by_path["untracked.txt"] ~= nil)
    truthy(
      "status: untracked is flagged",
      by_path["untracked.txt"] and by_path["untracked.txt"].untracked
    )
    truthy("status: path with a space", by_path["dir with space/odd name.txt"] ~= nil)
    truthy("status: non-ASCII path arrives unquoted", by_path["ünïcode ✓.txt"] ~= nil)
    truthy("status: deleted file is listed", by_path["deleted-file.txt"] ~= nil)
    truthy(
      "status: .workspaces is excluded, so a worktree does not pollute the list",
      by_path[".workspaces/"] == nil
    )
  end)
end

local function test_hunks()
  local git, repos = require "paseo.git", require "paseo.repos"

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    local hunks = git.hunks(repo, git.status(repo))

    local bof = for_path(hunks, "bof.txt")[1]
    eq("hunks: beginning-of-file delete is kind=delete", bof and bof.kind, "delete")
    -- `@@ -1 +0,0 @@` gives c = 0, which is not a valid quickfix line.
    eq("hunks: BOF delete clamps lnum to 1", bof and bof.lnum, 1)

    local eof = for_path(hunks, "eof.txt")[1]
    eq("hunks: end-of-file delete is kind=delete", eof and eof.kind, "delete")
    eq("hunks: EOF delete lands on the last remaining line", eof and eof.lnum, 1)

    local whole = for_path(hunks, "deleted-file.txt")[1]
    truthy("hunks: whole-file deletion is flagged", whole and whole.file_deleted)

    local untracked = for_path(hunks, "untracked.txt")[1]
    eq("hunks: untracked file is one synthetic entry", untracked and untracked.kind, "new")

    -- A pure rename has no content change, so rename detection must pair the
    -- two sides. Without the source in the pathspec it reports as a whole-file
    -- add instead.
    eq("hunks: a pure rename produces no hunks", #for_path(hunks, "new-name.txt"), 0)

    local many = for_path(hunks, "many-hunks.txt")
    eq("hunks: multi-hunk file splits into three", #many, 3)
    local kinds = vim.tbl_map(function(h)
      return h.kind
    end, many)
    eq("hunks: kinds are classified", kinds, { "change", "delete", "add" })
    -- The omitted-count trap: `@@ -2 +2 @@` means -2,1 +2,1. Read the missing
    -- count as 0 and this single-line change becomes a phantom deletion.
    eq("hunks: a single-line change is not read as a deletion", many[1] and many[1].added, 1)

    truthy("hunks: each carries its patch text", many[1] and #many[1].lines > 1)
  end)
end

local function test_stage()
  local git, repos = require "paseo.git", require "paseo.repos"

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    reset_index(repo.worktree)

    -- Partial staging: one hunk of three, the others untouched. This is the
    -- assertion that `--unidiff-zero` placement is right.
    local many = for_path(git.hunks(repo, git.status(repo)), "many-hunks.txt")
    local target
    for _, h in ipairs(many) do
      if h.kind == "delete" then
        target = h
      end
    end

    local err
    git.stage(target, function(e)
      err = e or false
    end)
    vim.wait(3000, function()
      return err ~= nil
    end)
    eq("stage: the delete hunk applies", err, false)

    local staged =
      vim.system({ "git", "-C", repo.worktree, "diff", "--cached" }, { text = true }):wait().stdout
    truthy("stage: the deletion is in the index", staged:find("-10", 1, true) ~= nil)
    truthy(
      "stage: the OTHER hunks are not",
      staged:find "TWO%-CHANGED" == nil and staged:find "APPENDED" == nil
    )

    local unstaged =
      vim.system({ "git", "-C", repo.worktree, "diff" }, { text = true }):wait().stdout
    truthy(
      "stage: the other two hunks remain unstaged",
      unstaged:find("TWO-CHANGED", 1, true) ~= nil
    )
  end)

  in_dir(root .. "/solo", function()
    local repo = repos.list()[1]
    reset_index(repo.worktree)

    -- Every hunk, including the two gitsigns structurally cannot do.
    local hunks = git.hunks(repo, git.status(repo))
    local remaining = #hunks
    for _, hunk in ipairs(hunks) do
      git.stage(hunk, function()
        remaining = remaining - 1
      end)
    end
    vim.wait(8000, function()
      return remaining == 0
    end)

    local left = vim
      .system({ "git", "-C", repo.worktree, "diff", "--name-only" }, { text = true })
      :wait().stdout
    eq("stage: staging every hunk leaves nothing unstaged", vim.trim(left), "")

    local cached = vim
      .system({ "git", "-C", repo.worktree, "diff", "--cached", "--name-only" }, { text = true })
      :wait().stdout
    truthy(
      "stage: the whole-file deletion reached the index (gitsigns cannot do this)",
      cached:find("deleted-file.txt", 1, true) ~= nil
    )
    truthy(
      "stage: the untracked file reached the index",
      cached:find("untracked.txt", 1, true) ~= nil
    )
    reset_index(repo.worktree)
  end)
end

return {
  { "repos", test_repos },
  { "git.status", test_status },
  { "git.hunks", test_hunks },
  { "git.stage", test_stage },
}
