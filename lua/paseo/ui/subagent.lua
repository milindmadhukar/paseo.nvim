--- A provider subagent's conversation, read-only, in a tab of its own.
---
--- READ-ONLY IS THE PROTOCOL'S ANSWER, NOT A SHORTCUT. Paseo lists a provider
--- subagent, fetches its timeline and pushes what it does next, and has no
--- message that sends it anything: Claude's Task tool runs on what its parent
--- told it. What you CAN do is tell the parent, which is what `i` here does --
--- it opens the parent's chat with a line naming this subagent, so "stop
--- exploring the tests, look at the auth module" reaches the one agent that can
--- act on it.
---
--- A Paseo subagent never comes here. It is an ordinary agent and opens as an
--- ordinary chat -- see |paseo.pickers.subagents|.
---
--- The cards are the chat's own: |paseo.ui.transcript| needs a buffer, a window
--- and its block tables, and that is all this hands it.

local bridge = require "paseo.bridge"
local transcript = require "paseo.ui.transcript"

local M = {}

---Open views, by `parent:subagent`, so a live item finds its buffer.
---@type table<string, table>
local views = {}
local attached = false

---@param parent string
---@param id string
local function key(parent, id)
  return parent .. ":" .. id
end

---Is `payload` newer than what `view` already drew? History and the live
---stream overlap -- the stream is followed before history is fetched -- and
---this is what keeps the overlap from drawing twice.
local function fresh(view, payload)
  if payload.epoch and view.epoch and payload.epoch ~= view.epoch then
    return true
  end
  return not (payload.seq and view.seq and payload.seq <= view.seq)
end

local function attach()
  if attached then
    return
  end
  attached = true
  bridge.on("subagent_item", function(payload)
    vim.schedule(function()
      local view = views[key(payload.parentAgentId or "", payload.subagentId or "")]
      if not view or not vim.api.nvim_buf_is_valid(view.conversation) then
        return
      end
      if fresh(view, payload) then
        transcript.upsert(view, payload)
        view.seq = payload.seq or view.seq
      end
    end)
  end)
  require("paseo.subagents").on_change(function()
    for _, view in pairs(views) do
      if vim.api.nvim_buf_is_valid(view.conversation) then
        M.title(view)
      end
    end
  end)
end

---The winbar: what it is, whether it is still going, and what `i` does.
---@param view table
function M.title(view)
  local win = view.win_conversation
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local current
  for _, s in ipairs(require("paseo.subagents").list(view.parent, view.host_id)) do
    if s.id == view.id then
      current = s
    end
  end
  local s = current or view.subagent
  local text = (" %s %s · %s · read-only  ·  i tell the parent  q close"):format(
    require("paseo.ui.icons").tool.sub_agent or "",
    s.title,
    s.status
  )
  vim.wo[win].winbar = text:gsub("%%", "%%%%")
end

---Open `subagent` -- a row of |paseo.subagents|.list, of the provider kind.
---@param subagent paseo.Subagent
---@param opts { host_id?: string, parent_chat?: table }
function M.open(subagent, opts)
  opts = opts or {}
  attach()

  local k = key(subagent.parent, subagent.id)
  local existing = views[k]
  if existing and vim.api.nvim_buf_is_valid(existing.conversation) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == existing.conversation then
        vim.api.nvim_set_current_win(win)
        return existing
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, ("paseo://subagent/%s/%s"):format(subagent.parent, subagent.id))

  vim.cmd "tabnew"
  local scratch = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  if scratch ~= buf and vim.api.nvim_buf_is_valid(scratch) then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  local view = {
    conversation = buf,
    win_conversation = win,
    parent = subagent.parent,
    id = subagent.id,
    subagent = subagent,
    host_id = opts.host_id,
    parent_chat = opts.parent_chat,
  }
  transcript.reset(view)
  views[k] = view

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      views[k] = nil
    end,
  })

  local map = { buffer = buf, nowait = true }
  for _, lhs in ipairs { "<Tab>", "<CR>", "za" } do
    vim.keymap.set("n", lhs, function()
      transcript.toggle_at_cursor(view)
    end, vim.tbl_extend("force", map, { desc = "paseo: expand/collapse" }))
  end
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", vim.tbl_extend("force", map, { desc = "paseo: close" }))
  vim.keymap.set("n", "i", function()
    M.tell_parent(view)
  end, vim.tbl_extend("force", map, { desc = "paseo: tell the parent agent about this subagent" }))

  M.title(view)
  transcript.upsert(view, { kind = "notice", level = "info", message = "loading…" })

  -- Follow BEFORE fetching, as the chat does, so nothing between is lost.
  bridge.request("subagents.follow", {}, function()
    bridge.request(
      "subagent.history",
      { agentId = subagent.parent, subagentId = subagent.id },
      function(err, result)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then
            return
          end
          transcript.reset(view)
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
          vim.bo[buf].modifiable = false
          if err then
            transcript.upsert(view, { kind = "notice", level = "error", message = err })
            return
          end
          for _, item in ipairs(result and result.items or {}) do
            transcript.upsert(view, item)
          end
          view.epoch = result and result.epoch or nil
          view.seq = result and result.seq or nil
          if #(result and result.items or {}) == 0 then
            transcript.upsert(view, { kind = "notice", level = "info", message = "nothing yet" })
          end
        end)
      end,
      opts.host_id
    )
  end, opts.host_id)

  return view
end

---Open the parent's chat with a line about this subagent in the composer.
---@param view table
function M.tell_parent(view)
  local chat = require "paseo.ui.chat"
  local parent = view.parent_chat
  local text = ("About your subagent %q: "):format(view.subagent.title)
  if parent and parent.composer and vim.api.nvim_buf_is_valid(parent.composer) then
    chat.open({
      root = parent.root,
      local_root = parent.local_root,
      remote = true,
      agent_id = parent.agent_id,
      host_id = parent.host_id,
    }, function(opened)
      if opened then
        chat.insert(opened, text)
        vim.cmd.startinsert { bang = true }
      end
    end)
    return
  end
  vim.notify("paseo: the parent's chat is not open", vim.log.levels.WARN)
end

-- Exposed for tests.
M._views = views

return M
