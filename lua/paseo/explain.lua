--- Pointing the chat at something.
---
--- Thin on purpose. The chat window owns the conversation; this only decides
--- WHAT gets attached and whether you are asked to type a question first.

local chat = require "paseo.ui.chat"
local ref = require "paseo.ref"

local M = {}

---The rubric.
---
---The last line is the load-bearing one. "Explain this" invites a summary you
---nod along to; asking what to push back on forces a posture where you argue
---with the answer. That is what actually addresses not being able to explain
---your own code.
M.RUBRIC = table.concat({
  "Explain this change. Be specific and brief.",
  "",
  "1. What changed, in one or two sentences.",
  "2. What invariant or assumption it altered — what was true before that is not true now.",
  "3. The call sites or callers affected. Name files and lines.",
  "4. What I should push back on: what is unproven, riskier than it looks, or worth arguing about.",
}, "\n")

---@param kind? "cursor"|"visual"|"hunk"|"file"
---@return paseo.Ref|nil
local function locate(kind)
  local location = ref.get(kind)
  if not location then
    vim.notify("paseo: nothing here to point at", vim.log.levels.WARN)
  end
  return location
end

---Explain the hunk, selection or file, using the rubric.
---@param kind? "cursor"|"visual"|"hunk"|"file"
function M.explain(kind)
  local location = locate(kind)
  if not location then
    return
  end
  chat.ask(M.RUBRIC, { root = location.root, context = ref.render(location) })
end

---Attach the hunk, selection or file and let you type the question.
---
---This is the common case and it deliberately does NOT prompt through
---`vim.ui.input`: a one-line input box is the wrong shape for a question you
---want to think about, and it throws away your keymaps and completion. The
---composer is a real buffer.
---@param kind? "cursor"|"visual"|"hunk"|"file"
function M.ask(kind)
  local location = locate(kind)
  if not location then
    return
  end
  chat.attach(ref.render(location), { root = location.root })
end

---Attach the whole quickfix list -- every hunk under review at once.
function M.quickfix()
  local items = vim.fn.getqflist()
  if #items == 0 then
    vim.notify("paseo: the quickfix list is empty", vim.log.levels.WARN)
    return
  end

  local qf = require "paseo.qf"
  local lines, root = { "The changes currently under review:" }, nil
  for index = 1, #items do
    local hunk = qf.hunk(index)
    if hunk then
      root = root or hunk.repo.worktree
      lines[#lines + 1] = ("- %s:%d  +%d -%d"):format(
        hunk.path,
        hunk.lnum,
        hunk.added,
        hunk.removed
      )
    end
  end

  chat.attach(table.concat(lines, "\n"), { root = root })
end

function M.attach()
  chat.attach_events()
end

return M
