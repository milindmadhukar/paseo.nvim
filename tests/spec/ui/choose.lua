--- The one chooser: a real buffer, the cursor is the selection.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

local function press(keys)
  api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function test_choose()
  local choose = require "paseo.ui.choose"
  local from = api.nvim_get_current_win()

  -- select: vim.ui.select's signature, and its answer.
  local got, idx = "unset", "unset"
  local h = choose.select({ "alpha", "beta", "gamma" }, { prompt = "Pick one" }, function(item, i)
    got, idx = item, i
  end)
  eq("choose: the chooser is the current window", api.nvim_get_current_win(), h.win)
  eq("choose: it is a real buffer of its own filetype", vim.bo[h.buf].filetype, choose.FILETYPE)
  eq("choose: the cursor starts on the first choice", h.current().text, "alpha")
  press "j"
  eq("choose: j moves to the next choice", h.current().text, "beta")
  press "G"
  eq("choose: G lands on the last choice, not the footer", h.current().text, "gamma")
  press "gg"
  eq("choose: gg lands on the first choice, not the title", h.current().text, "alpha")
  press "j<CR>"
  eq("choose: <CR> picks the choice under the cursor", got, "beta")
  eq("choose: and passes its index", idx, 2)
  truthy("choose: the window is gone", not api.nvim_win_is_valid(h.win))
  eq("choose: focus is back where it was", api.nvim_get_current_win(), from)

  -- Digits pick directly.
  got = nil
  choose.select({ "one", "two", "three" }, {}, function(item)
    got = item
  end)
  press "3"
  eq("choose: 3 picks the third", got, "three")

  -- Cancel answers nil, once.
  local calls = 0
  got = "unset"
  choose.select({ "x" }, {}, function(item)
    calls = calls + 1
    got = item
  end)
  press "q"
  vim.wait(50)
  eq("choose: q answers nil", got, nil)
  eq("choose: and answers once", calls, 1)

  -- format_item, and a value that is a table.
  got = nil
  choose.select({ { id = "a", label = "First" }, { id = "b", label = "Second" } }, {
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    got = item
  end)
  local lines = api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)
  truthy("choose: format_item is what is drawn", table.concat(lines, "\n"):find("Second", 1, true))
  press "2"
  eq("choose: the table itself comes back", got and got.id, "b")

  -- Verbs, and update keeping the cursor on the same item.
  local verbed
  local handle = choose.open {
    title = "Things",
    items = { { id = 1, text = "one" }, { id = 2, text = "two" } },
    verbs = {
      {
        "d",
        "drop",
        function(item)
          verbed = item and item.id
        end,
      },
    },
    on_pick = function() end,
  }
  press "j"
  press "d"
  eq("choose: a verb acts on the row under the cursor", verbed, 2)
  local footer = api.nvim_buf_get_lines(handle.buf, -2, -1, false)[1]
  truthy("choose: verbs are listed in the footer", footer:find("drop", 1, true), footer)
  truthy("choose: and so is cancel, however many verbs", footer:find("cancel", 1, true), footer)
  eq("choose: the selection is a band, whatever cursorlineopt says", vim.wo[handle.win].cursorlineopt, "line")
  handle.update { { id = 0, text = "zero" }, { id = 1, text = "one" }, { id = 2, text = "two" } }
  eq("choose: update keeps the cursor on the same item", handle.current().id, 2)
  handle.close()
  truthy("choose: close closes", not api.nvim_win_is_valid(handle.win))

  -- Right-hand fields line up as columns, whatever their widths.
  local cols = choose.open {
    title = "Columns",
    items = {
      { id = 1, text = "a", right = { { "local     " }, { "idle" } } },
      { id = 2, text = "b", right = { { "worktree  " }, { "1 running" } } },
    },
    on_pick = function() end,
  }
  local rows = api.nvim_buf_get_lines(cols.buf, 0, -1, false)
  local function col_of(word)
    for _, row in ipairs(rows) do
      local at = row:find(word, 1, true)
      if at then
        return vim.fn.strdisplaywidth(row:sub(1, at - 1))
      end
    end
  end
  eq("choose: right-hand fields start at one column", col_of "local", col_of "worktree")
  cols.close()

  -- confirm: the safe answer is first.
  local answer
  choose.confirm("Archive it?", { yes = "Archive" }, function(yes)
    answer = yes
  end)
  press "<CR>"
  eq("choose: confirm's first row is no", answer, false)
  choose.confirm("Archive it?", { yes = "Archive" }, function(yes)
    answer = yes
  end)
  press "2"
  eq("choose: and the second is yes", answer, true)

  -- A long prompt is a sentence under a title, wrapped, not a title cut off.
  local long = string.rep("word ", 30)
  local lh = choose.select({ "ok" }, { prompt = long }, function() end)
  local text = table.concat(api.nvim_buf_get_lines(lh.buf, 0, -1, false), " ")
  local words = select(2, text:gsub("word", ""))
  eq("choose: every word of a long prompt is on screen", words, 30)
  lh.close()
end

return {
  { "choose", test_choose },
}
