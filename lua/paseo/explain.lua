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
  "Read the reference below first — the code is not quoted for you, on purpose.",
  "",
  "1. What changed, in one or two sentences.",
  "2. What invariant or assumption it altered — what was true before that is not true now.",
  "3. The call sites or callers affected. Name files and lines.",
  "4. Who made this change: check the sibling agents listed below, if any, before"
    .. " answering, and say what that agent was asked to do.",
  "5. What I should push back on: what is unproven, riskier than it looks, or worth arguing about.",
}, "\n")

---The sibling agents that have been working in `root`.
---
---THIS IS THE ATTRIBUTION MECHANISM, and it is deliberately not a local blame
---map. Paseo already knows which agent ran where and what it was told to do;
---the review agent has tools to ask. So rather than reconstructing authorship
---from git, hand it the ids and let it look.
---
---Agents carrying a `paseo.nvim` label are OURS -- the review agent itself, and
---any agent-session chat -- and are filtered out. Listing the agent you are talking
---to as a source to interrogate is a loop, and a confusing one.
---@param root string
---@return string|nil
local function siblings(root)
  if require("paseo.config").get().review.agents == false then
    return nil
  end

  local directory = require "paseo.agents"
  -- Idempotent, and deliberately not waited on: the directory is push-fed and
  -- usually already warm by the time you ask about a hunk. A cold one costs
  -- this prompt its agent block, not its answer.
  directory.watch()

  local lines = {}
  for _, agent in ipairs(directory.for_root(root)) do
    if not (agent.labels and agent.labels["paseo.nvim"]) then
      lines[#lines + 1] = ("- %s  %s  ·  %s  ·  %s"):format(
        agent.id,
        agent.title or "(untitled)",
        agent.provider or "?",
        agent.status or "?"
      )
    end
  end

  if #lines == 0 then
    return nil
  end

  return table.concat({
    "Other Paseo agents have worked in this tree. If you have Paseo tools, call",
    "`get_agent_activity` on these ids to find which one made this change and",
    "what it was asked to do:",
    "",
    table.concat(lines, "\n"),
  }, "\n")
end

---`text` with the sibling-agent block appended, when there is one.
---@param text string
---@param root string
---@return string
local function with_siblings(text, root)
  local block = siblings(root)
  return block and (text .. "\n\n" .. block) or text
end

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
  chat.ask(M.RUBRIC, {
    root = location.root,
    context = with_siblings(ref.render(location), location.root),
  })
end

---Ask about the hunk, selection or file: a box, your question, then send.
---
---This is the common case, and it used to open the entire chat surface with
---the reference queued in its composer -- a lot of window for one sentence,
---and it put you in the conversation before you had said anything. Now the
---box takes the question and the chat opens behind the answer.
---
---Still NOT `vim.ui.input`. |paseo.ui.prompt| is a real buffer for the same
---reason the composer is one: a one-line field throws away your keymaps,
---completion and undo, and cannot hold a question with a blank line in it.
---@param kind? "cursor"|"visual"|"hunk"|"file"
function M.ask(kind)
  local location = locate(kind)
  if not location then
    return
  end

  -- Rendered NOW, not in the callback. The box is a window and you may be in
  -- it for a while; by the time you send, the cursor has moved off the hunk
  -- and `ref.get()` would answer about wherever it now sits.
  local context = with_siblings(ref.render(location), location.root)

  require("paseo.ui.prompt").open({
    title = ref.format(location),
    root = location.root,
  }, function(question)
    if not question then
      return
    end
    chat.ask(question, { root = location.root, context = context })
  end)
end

---Ask about the whole quickfix list -- every location under review at once.
---
---Reads the PLAIN quickfix list, not one this plugin built. The hunk list is
---your config's to populate now, so the only contract here is the one every
---quickfix list already honours: a buffer, a line, and some text. That also
---means this works over `:grep`, LSP references or anything else you have in
---there.
function M.quickfix()
  local items = vim.fn.getqflist()
  if #items == 0 then
    vim.notify("paseo: the quickfix list is empty", vim.log.levels.WARN)
    return
  end

  local repos = require "paseo.repos"
  local lines, root =
    {
      "The changes currently under review. The code is not quoted -- open the",
      "files and read them:",
    }, nil

  for _, item in ipairs(items) do
    local name = item.bufnr ~= 0 and vim.api.nvim_buf_get_name(item.bufnr) or (item.filename or "")
    if name ~= "" then
      local absolute = vim.fn.fnamemodify(name, ":p")
      local repo = repos.resolve(absolute)
      root = root or (repo and repo.worktree)

      -- ABSOLUTE, for the same reason |paseo.Ref| carries `abs`: `root` is the
      -- FIRST entry's worktree, and in a workspace the rest of the list comes
      -- from sibling worktrees that nothing relative to `root` can name. A
      -- repo-relative path resolves for entry one and silently misses the
      -- others.
      local text = (item.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      lines[#lines + 1] = ("- %s:%d%s"):format(
        absolute,
        item.lnum or 0,
        text ~= "" and ("  " .. text) or ""
      )
    end
  end

  if #lines == 2 then
    vim.notify("paseo: no quickfix entry names a file", vim.log.levels.WARN)
    return
  end

  root = root or assert(vim.uv.cwd())
  local context = with_siblings(table.concat(lines, "\n"), root)

  require("paseo.ui.prompt").open({
    title = ("quickfix · %d entries"):format(#lines - 2),
    root = root,
  }, function(question)
    if not question then
      return
    end
    chat.ask(question, { root = root, context = context })
  end)
end

function M.attach()
  chat.attach_events()
end

return M
