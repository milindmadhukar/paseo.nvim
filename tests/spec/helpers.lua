--- The harness: assertions, the results they accumulate, and the few things
--- more than one suite needs.
---
--- No plenary, no busted: the interesting assertions are all about what real
--- git and real gitsigns do, so the suite needs a real Neovim and real
--- repositories far more than it needs a framework.
---
--- Suites live beside this file, in `tests/spec/`, and are run by
--- `tests/spec.lua`. It lives in there with them rather than at `tests/` for
--- one dull reason: telescope ships a `lua/tests/helpers.lua` of its own, and
--- a plugin's `lua/` directory wins over `package.path` -- so `tests.helpers`
--- loaded telescope's.

local M = {}

---The fixture tree `tests/fixtures.sh` builds. Suites read it as `root`.
M.fixtures = assert(vim.env.PASEO_FIXTURES, "PASEO_FIXTURES is not set")

---This checkout, for the suites that read the source itself.
M.repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

M.results = { passed = 0, failed = 0, lines = {} }

---Scan every owned TypeScript file, including new modules. A negative check
---against only the executable entry point becomes vacuous after a refactor.
function M.sidecar_source()
  local parts = {}
  local function scan(dir)
    for name, kind in vim.fs.dir(dir) do
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" and name ~= "node_modules" then
        scan(path)
      elseif kind == "file" and name:match "%.ts$" then
        local fd = assert(io.open(path, "r"))
        parts[#parts + 1] = fd:read "*a"
        fd:close()
      end
    end
  end
  scan(vim.fs.joinpath(M.repo_root, "sidecar"))
  return table.concat(parts, "\n")
end

---@param name string
---@param ok boolean
---@param detail? string
function M.record(name, ok, detail)
  local results = M.results
  if ok then
    results.passed = results.passed + 1
    results.lines[#results.lines + 1] = ("  ok    %s"):format(name)
  else
    results.failed = results.failed + 1
    results.lines[#results.lines + 1] = ("  FAIL  %s%s"):format(
      name,
      detail and ("\n          " .. detail) or ""
    )
  end
end

function M.eq(name, got, want)
  local same = vim.deep_equal(got, want)
  M.record(
    name,
    same,
    not same and ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)) or nil
  )
end

function M.truthy(name, value, detail)
  M.record(name, value and true or false, detail)
end

-- Where the suite was started from: the one directory still guaranteed to be
-- there after every fixture has been deleted.
M.home = assert(vim.uv.cwd(), "the suite must start in a directory that exists")

---Stand somewhere that exists again, before a fixture is removed out from
---under us. Neovim keeps standing in a deleted cwd quite happily, but
---`vim.uv.cwd()` answers nil from that moment on -- and anything that reads it
---on redraw throws for the rest of the run, not just in the suite that did it.
---(NvChad's `cwd` statusline module is the one that surfaced this: every
---`vim.wait` in a later suite took a traceback from a snacks notification.)
---`:cd` also drops the tab-local directory, which is what `workspaces.open`
---set in the first place.
function M.go_home()
  vim.cmd.cd(vim.fn.fnameescape(M.home))
  require("paseo.repos").invalidate()
end

---@param dir string
---@param fn fun()
function M.in_dir(dir, fn)
  local prev = vim.uv.cwd() or M.home
  vim.cmd.cd(vim.fn.fnameescape(dir))
  require("paseo.repos").invalidate()
  local ok, err = pcall(fn)
  vim.cmd.cd(vim.fn.fnameescape(prev))
  require("paseo.repos").invalidate()
  if not ok then
    error(err, 0)
  end
end

return M
