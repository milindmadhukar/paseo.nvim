--- The test suite. Run it with `tests/run.sh`.
---
--- This file is only the runner: every suite lives in `tests/spec/`, one file
--- per area, each returning a list of `{ name, function }` pairs.
---
--- The files are listed below rather than discovered, because the ORDER still
--- matters: the suites share one Neovim and one fixture tree, and several of
--- them depend on what the ones before them left behind (the git suites want
--- the fixture index untouched; the dashboard wants no other float open). A
--- file missing from the list is an error rather than a skip, so the price of
--- being explicit is never a suite that silently stopped running.
---
--- The harness itself -- `eq`, `truthy`, and the handful of shared fixtures --
--- is `tests/spec/helpers.lua`.
---
--- No plenary, no busted: the interesting assertions are all about what real
--- git and real gitsigns do, so the suite needs a real Neovim and real
--- repositories far more than it needs a framework.
---
--- Every case here corresponds to something that was actually wrong at some
--- point, not to a line of code that wanted covering.

local t = require "tests.spec.helpers"

local M = {}

---The suite files, in the order they run.
local files = {
  "git",
  "explain",
  "prompt",
  "daemon",
  "bridge",
  "image",
  "registry",
  "ref",
  "workspace",
  "ui.render",
  "ui.surfaces",
  "ui.panels",
  "ui.theme",
  "ui.invariants",
  "provider",
  "questions",
  "plan",
  "answer",
  "permission",
  "terminals",
  "draft",
  "settings",
  "fork",
  "quit",
  "workspace_create",
  "skills",
  "chat",
}

---Every `.lua` under `tests/spec/`, as module suffixes -- so a new file that
---nobody listed is caught here rather than quietly never running.
---@return string[]
local function on_disk()
  local found = {}
  local function scan(dir, prefix)
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        scan(vim.fs.joinpath(dir, name), prefix .. name .. ".")
      elseif name:match "%.lua$" and name ~= "helpers.lua" then
        found[#found + 1] = prefix .. name:sub(1, -5)
      end
    end
  end
  scan(vim.fs.joinpath(t.repo_root, "tests", "spec"), "")
  return found
end

---A buffer left naming a file the suite has deleted is not that suite's
---problem until it is someone else's: the next thing to check timestamps takes
---`E211: File ... no longer available` and fails THERE. On nightly that was
---eight suites later, inside a `vim.wait` in the provider suite, and the log
---blamed the wrong one. Reported against the suite that leaked it, and wiped,
---so it is named once rather than by everything that follows.
---@param suite string
local function sweep(suite)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(buf)
    if path:sub(1, 1) == "/" and not vim.uv.fs_stat(path) then
      t.record(("%s left a buffer on %s, which no longer exists"):format(suite, path), false)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---@param filter? string  run only the suites whose name or file matches
---@return integer failed
function M.run(filter)
  filter = (filter ~= nil and filter ~= "") and filter or nil
  local results = t.results
  local ran = 0

  -- Written out as each suite finishes rather than in one block at the end: a
  -- suite that hangs -- on a `vim.wait` that never resolves, on a prompt with
  -- nobody to answer it -- otherwise takes every line before it down too, and
  -- the log says nothing about where it stopped.
  local flushed = 0
  local function flush()
    if #results.lines > flushed then
      io.stdout:write(table.concat(results.lines, "\n", flushed + 1, #results.lines) .. "\n")
      flushed = #results.lines
    end
  end

  local listed = {}
  for _, file in ipairs(files) do
    listed[file] = true
  end
  for _, file in ipairs(on_disk()) do
    if not listed[file] then
      results.failed = results.failed + 1
      local path = (file:gsub("%.", "/"))
      results.lines[#results.lines + 1] = ("  FAIL  %s.lua is listed nowhere"):format(path)
    end
  end

  for _, file in ipairs(files) do
    local module = "tests.spec." .. file
    local loaded, suites = pcall(require, module)
    if not loaded then
      results.failed = results.failed + 1
      results.lines[#results.lines + 1] = ("  FAIL  %s does not load\n          %s"):format(
        module,
        suites
      )
    else
      for _, suite in ipairs(suites) do
        local name = suite[1]
        if not filter or name:find(filter, 1, true) or file:find(filter, 1, true) then
          ran = ran + 1
          results.lines[#results.lines + 1] = name
          flush()
          local ok, err = xpcall(suite[2], debug.traceback)
          if not ok then
            results.failed = results.failed + 1
            results.lines[#results.lines + 1] = ("  FAIL  %s threw\n          %s"):format(name, err)
          end
          sweep(name)
          flush()
        end
      end
    end
  end

  -- A filter that matches nothing is a typo, not a clean run.
  if filter and ran == 0 then
    results.failed = results.failed + 1
    results.lines[#results.lines + 1] = ("  FAIL  no suite matches %q"):format(filter)
  end

  flush()
  io.stdout:write(("\n%d passed, %d failed\n"):format(results.passed, results.failed))
  return results.failed
end

return M
