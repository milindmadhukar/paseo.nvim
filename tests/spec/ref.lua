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
  local file = ref.file()
  truthy("ref: a file outside any git repo still yields a reference", file ~= nil)
  eq("ref: and it has no repo", file and file.repo, nil)
  eq("ref: its root is the file's directory", file and file.root, vim.fs.dirname(loose))
  truthy(
    "ref: render() does not require a repo",
    file and ref.render(file):find(loose, 1, true) ~= nil
  )
  -- The prompt names the file and stops. Inlining made it scale with whatever
  -- you asked about -- a long hunk, or a new file, which gitsigns reports as
  -- one all-added hunk and which therefore pasted the file in whole.
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

  -- THE ONE CARVE-OUT, tested on a hand-built ref because driving a real
  -- deletion needs gitsigns attached asynchronously to a fixture repo.
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

  vim.cmd "tabclose"
  os.remove(loose)
end

return {
  { "ref", test_ref },
}
