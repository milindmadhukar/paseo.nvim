--- The ask box.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

--- The ask box. It is a WINDOW, not a blocking prompt, so every exit has to
--- answer the caller exactly once -- including the ones nobody chose.
local function test_prompt()
  local prompt = require "paseo.ui.prompt"

  local function box(fn)
    local got, calls = "unset", 0
    prompt.open({ title = "app/main.py:42" }, function(q)
      calls = calls + 1
      got = q
    end)
    local buf = vim.api.nvim_get_current_buf()
    fn(buf)
    vim.wait(200, function()
      return calls > 0
    end)
    return got, calls
  end

  -- NOT `vim.ui.input`: a one-line field cannot hold a question with a blank
  -- line in it and throws away your insert-mode keymaps and undo.
  prompt.open({ title = "x" }, function() end)
  local buf = vim.api.nvim_get_current_buf()
  truthy("prompt: the box is a real, modifiable buffer", vim.bo[buf].modifiable)
  eq("prompt: with the composer's filetype, so your keymaps work", vim.bo[buf].filetype, "markdown")
  local cfg = vim.api.nvim_win_get_config(0)
  eq("prompt: floating over the editor", cfg.relative, "editor")
  -- Above the dashboard's 30, below the permission dialog's 200: a permission
  -- request must never come up behind a box you are typing in.
  truthy(
    "prompt: z-index sits above the dashboard, below the dialog",
    cfg.zindex > 30 and cfg.zindex < 200,
    tostring(cfg.zindex)
  )
  vim.api.nvim_win_close(0, true)
  vim.wait(100)

  local text, calls = box(function(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "why is this here?", "", "second paragraph" })
    vim.cmd "stopinsert"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end)
  eq(
    "prompt: <CR> sends the question, blank lines and all",
    text,
    "why is this here?\n\nsecond paragraph"
  )
  eq("prompt: and answers the caller exactly once", calls, 1)

  -- Grows with the question: "why?" and a paragraph are different shapes, and
  -- a fixed height makes one of them unreadable.
  prompt.open({ title = "x" }, function() end)
  local grow = vim.api.nvim_get_current_buf()
  local before = vim.api.nvim_win_get_config(0).height
  vim.api.nvim_buf_set_lines(grow, 0, -1, false, vim.split(("l\n"):rep(40), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = grow })
  local after = vim.api.nvim_win_get_config(0).height
  truthy(
    "prompt: the box grows with the question",
    after > before,
    ("%d -> %d"):format(before, after)
  )
  truthy("prompt: but is capped, not unbounded", after <= 14, tostring(after))
  vim.api.nvim_win_close(0, true)
  vim.wait(100)

  -- An empty box is a cancel. Sending one costs a turn and gets you "what
  -- would you like to know?".
  local empty, empty_calls = box(function(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "", "   " })
    vim.cmd "stopinsert"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end)
  eq("prompt: an empty box cancels rather than sending nothing", empty, nil)
  eq("prompt: and still answers the caller", empty_calls, 1)

  local escaped, esc_calls = box(function(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "never mind" })
    vim.cmd "stopinsert"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  end)
  eq("prompt: <Esc> cancels and throws the draft away", escaped, nil)
  eq("prompt: answering the caller, not leaving it hanging", esc_calls, 1)

  -- THE ONE THAT BITES: closed by `:q` or a window command rather than by a
  -- key we bound. Without the WinClosed guard the reference is queued and
  -- nothing ever sends it.
  local closed, closed_calls = box(function()
    vim.cmd "stopinsert"
    vim.api.nvim_win_close(0, true)
  end)
  eq("prompt: a window closed from outside still cancels", closed, nil)
  eq("prompt: exactly once", closed_calls, 1)

  truthy("prompt: nothing is left open", not prompt.is_open())
end

return {
  { "prompt", test_prompt },
}
