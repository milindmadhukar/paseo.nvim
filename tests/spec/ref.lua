--- The hunk under the cursor, as a reference an agent can read.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local in_dir = t.in_dir

local function test_ref()
  local ref = require "paseo.ref"

  -- A file with no repository at all. This was impossible: build() required
  -- repos.resolve() to succeed, so "ask about this file" silently did nothing
  -- for a scratch file, a note, or anything under ~/.config.
  local loose = vim.fn.tempname() .. ".txt"
  local fd = assert(io.open(loose, "w"))
  fd:write "alpha\nbeta\ngamma\ndelta\n"
  fd:close()

  -- A fresh tab, so nothing another suite left current can set 'winfixbuf' on
  -- us -- that makes :edit fail with E1513.
  vim.cmd "tabnew"
  vim.cmd.edit(vim.fn.fnameescape(loose))
  local loose_buf = vim.api.nvim_get_current_buf()
  local file = ref.file()
  truthy("ref: a file outside any git repo still yields a reference", file ~= nil)
  eq("ref: and it has no repo", file and file.repo, nil)
  eq("ref: its root is the file's directory", file and file.root, vim.fs.dirname(loose))
  truthy(
    "ref: render() does not require a repo",
    file and ref.render(file):find(loose, 1, true) ~= nil
  )
  -- The prompt names the file and stops. Inlining made it scale with whatever
  -- you asked about -- a long hunk, or a new file, which is one all-added
  -- hunk and which therefore pasted the file in whole.
  truthy(
    "ref: render() points at the file rather than quoting it",
    file and ref.render(file):find("alpha", 1, true) == nil,
    file and ref.render(file)
  )
  truthy(
    "ref: and gives an ABSOLUTE path -- `path` is workspace-relative, `root` is not",
    file and ref.render(file):find(vim.fn.fnamemodify(loose, ":p"), 1, true) ~= nil
  )

  -- A <cmd> mapping fires while visual mode is STILL ACTIVE, so '< and '> hold
  -- the PREVIOUS selection. Reading them sent the agent the wrong lines with no
  -- error at all.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd "normal! Vj"
  vim.cmd [[execute "normal! \<Esc>"]]
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd "normal! V"

  local marks = vim.api.nvim_buf_get_mark(0, "<")[1]
  local visual = ref.visual()
  eq("ref: the marks are indeed stale mid-selection", marks, 1)
  eq("ref: visual() reads the LIVE selection, not the marks", visual and visual.lnum, 4)
  eq("ref: and its text is the selected line", visual and visual.lines[1], "delta")

  vim.cmd [[execute "normal! \<Esc>"]]

  -- THE ONE CARVE-OUT, on a hand-built ref so the wording is pinned exactly;
  -- `test_hunk` below drives real deletions.
  --
  -- A pure deletion's lines are not in the file, so "go and read it" sends the
  -- agent to the code that SURVIVED -- `lnum` is the line ABOVE the removed
  -- block -- and it explains the wrong thing confidently. Those lines are the
  -- one thing that must still be quoted.
  local deleted = {
    repo = nil,
    root = "/tmp",
    path = "app/main.py",
    abs = "/tmp/app/main.py",
    lnum = 42,
    end_lnum = 42,
    lines = { "@@ -42,2 +42,0 @@", "-gone", "-also gone" },
    detached = true,
    modified = false,
    kind = "hunk",
  }
  local rendered = ref.render(deleted)
  truthy(
    "ref: a deleted hunk is still quoted -- it is not in the file to read",
    rendered:find("-also gone", 1, true) ~= nil,
    rendered
  )
  truthy(
    "ref: and is fenced as a diff, not as the file's language",
    rendered:find("```diff", 1, true) ~= nil,
    rendered
  )
  truthy(
    "ref: and says the line is ABOVE the removed block, not the removal",
    rendered:find("ABOVE", 1, true) ~= nil,
    rendered
  )

  deleted.detached = false
  deleted.modified = true
  local live = ref.render(deleted)
  truthy(
    "ref: an attached hunk is a location, not a quotation",
    live:find("gone", 1, true) == nil,
    live
  )
  truthy(
    "ref: an unsaved buffer is declared, since the agent reads disk",
    live:find("unsaved changes", 1, true) ~= nil,
    live
  )

  -- `tabclose` closes the WINDOW; the buffer stays loaded, and it is about to
  -- name a file that no longer exists. The next time anything checks
  -- timestamps -- which on nightly is inside the `vim.wait` the provider suite
  -- makes eight suites later -- Neovim answers `E211: File ... no longer
  -- available` for it, and that suite fails for something this one did.
  vim.cmd "tabclose"
  pcall(vim.api.nvim_buf_delete, loose_buf, { force = true })
  os.remove(loose)
end

---A repo of its own, committed once, so no other suite's staging or commits
---move what HEAD says.
---@param files table<string, string>
---@return string dir
local function repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(...)
    local res = vim.system({ "git", "-C", dir, "-c", "commit.gpgsign=false", ... }):wait()
    assert(res.code == 0, res.stderr)
  end
  git("init", "-q", "-b", "main", ".")
  for name, text in pairs(files) do
    local fd = assert(io.open(dir .. "/" .. name, "w"))
    fd:write(text)
    fd:close()
  end
  git("add", "-A")
  git("commit", "-qm", "init")
  return dir, git
end

---@param path string
---@param text string
local function write(path, text)
  local fd = assert(io.open(path, "w"))
  fd:write(text)
  fd:close()
end

local function test_hunk()
  local ref = require "paseo.ref"
  local seq = table.concat(vim.fn.range(1, 20), "\n") .. "\n"
  local dir, git = repo {
    ["many.txt"] = seq,
    ["bof.txt"] = "one\ntwo\nthree\n",
    ["eof.txt"] = "alpha\nbeta\n",
    ["clean.txt"] = "a\nb\nc\n",
    ["staged.txt"] = "s1\ns2\n",
    ["old.txt"] = "x\ny\nz\n",
    [".gitignore"] = "ignored.txt\n",
  }

  local lines = vim.split(seq, "\n", { trimempty = true })
  lines[2] = "TWO-CHANGED"
  table.remove(lines, 12)
  table.remove(lines, 11)
  table.remove(lines, 10)
  lines[#lines + 1] = "APPENDED"
  write(dir .. "/many.txt", table.concat(lines, "\n") .. "\n")
  write(dir .. "/bof.txt", "two\nthree\n")
  write(dir .. "/eof.txt", "alpha\n")
  write(dir .. "/new.txt", "fresh\nfile\n")
  write(dir .. "/ignored.txt", "nobody\n")
  write(dir .. "/staged.txt", "s1\nS2\n")
  git("add", "staged.txt")
  git("mv", "old.txt", "renamed.txt")

  vim.cmd "tabnew"
  local bufs = {}
  ---The hunk with the cursor on `lnum` of `name`.
  local function at(name, lnum)
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/" .. name))
    bufs[#bufs + 1] = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    return ref.hunk()
  end

  local change = at("many.txt", 2)
  eq("hunk: a one-line change is that line", change and { change.lnum, change.end_lnum }, { 2, 2 })
  eq("hunk: and it is a location, not detached", change and change.detached, false)

  -- 10-12 removed: the deletion sits on 9, the line ABOVE the block.
  local gone = at("many.txt", 9)
  eq("hunk: a deletion is found on the line above it", gone and gone.lnum, 9)
  eq("hunk: and is detached", gone and gone.detached, true)
  eq(
    "hunk: carrying exactly the deleted lines",
    gone and gone.lines,
    { "@@ -10,3 +9,0 @@", "-10", "-11", "-12" }
  )

  local added = at("many.txt", 18)
  eq("hunk: an append at the end", added and added.lines, { "APPENDED" })

  eq("hunk: an unchanged line is no hunk", at("many.txt", 5), nil)
  eq("hunk: so ref.get() falls back to the cursor", ref.get().kind, "cursor")

  -- gitsigns' get_hunks() gave this as start 0, and `0 <= 1 <= 0` never
  -- matched, so a deletion at the very top could not be asked about.
  local top = at("bof.txt", 1)
  eq("hunk: a deletion at the top of the file is found on line 1", top and top.lnum, 1)
  eq("hunk: with its text", top and top.lines, { "@@ -1 +0,0 @@", "-one" })

  local tail = at("eof.txt", 1)
  eq("hunk: a deletion at the end of the file", tail and tail.lines, { "@@ -2 +1,0 @@", "-beta" })

  local fresh = at("new.txt", 2)
  eq("hunk: an untracked file is one all-added hunk", fresh and { fresh.lnum, fresh.end_lnum }, { 1, 2 })

  local staged = at("staged.txt", 2)
  eq("hunk: a STAGED change is still a hunk -- the base is HEAD", staged and staged.lnum, 2)

  eq("hunk: a pure rename is diffed against its source, so has no hunks", at("renamed.txt", 1), nil)
  eq("hunk: an ignored file has no hunks", at("ignored.txt", 1), nil)

  -- What is on screen, not what is on disk: nothing was written.
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/clean.txt"))
  bufs[#bufs + 1] = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { "B" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local unsaved = ref.hunk()
  eq("hunk: an unsaved edit is a hunk", unsaved and unsaved.lnum, 2)
  eq("hunk: and says the buffer is modified", unsaved and unsaved.modified, true)

  vim.cmd "tabclose!"
  for _, buf in ipairs(bufs) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  t.go_home()
  vim.fn.delete(dir, "rf")
end

return {
  { "ref", test_ref },
  { "ref: the hunk under the cursor", test_hunk },
}
