--- The prompt editor: `<C-g>` in the composer, as in Claude Code.
---
--- The composer is a box for a question. A prompt that is a page long wants an
--- editor, and the editor you already have is this one -- so `<C-g>` moves the
--- WHOLE of the box into a real `.md` file and opens it in the box's own window,
--- grown to the height of the column. A few lines of the conversation stay up
--- above it, because what you are writing is usually a reply to them.
---
--- A REAL FILE, not a scratch buffer, so the way out is Vim's own: `:w` puts
--- the text in the box and stays, `:wq` (`:x`, `ZZ`) puts it there and goes
--- back, `:q!` (`ZQ`) goes back without what was not written. `:q` over unsaved
--- edits is Vim's E37 -- nothing is ever lost by a stray keystroke. And because
--- it is a file, a markdown LSP, spell and your ftplugins all attach to it.
--- `<C-g>` again is the quick way back: written, and in the box.
---
--- ONE WAY OUT. However the buffer goes -- `<C-g>`, `:wq`, `:q!`, a `:b` away
--- -- it is wiped (`bufhidden=wipe`), and `BufWipeout` is the single place the
--- box is put back. The text itself only ever moves on a write.

local api = vim.api

local M = {}

---Rows of conversation left showing above the editor.
M.CONTEXT = 5

---@type table<integer, table>  editor buffer -> chat
local editors = {}

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

---Where a chat's prompt is written: the cache, never `/tmp`.
---@param chat table
---@return string
function M.file(chat)
  -- Named after the agent, so a tab line or a statusline showing the path
  -- reads as whose prompt it is; the id keeps two same-named agents apart.
  local title = require("paseo.ui.chat").label(chat):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):sub(1, 32):gsub("%-+$", "")
  local id = chat.agent_id and chat.agent_id:sub(1, 8) or ("draft-" .. tostring(chat.composer))
  local name = (title ~= "" and (title .. "-") or "") .. id:gsub("[^%w%-_]", "-")
  return vim.fn.stdpath "cache" .. "/paseo/prompts/" .. name .. ".md"
end

---The chat whose prompt `buf` is, if it is one.
---@param buf integer
---@return table|nil
function M.of(buf)
  return editors[buf]
end

---The editor's bar: whose prompt this is, and the ways out. On the composer
---bar's rule, so the box reads as the same object grown, not a new one.
---@param chat table
---@param width integer
---@return table[]
function M.bar(chat, width)
  local composer = require "paseo.ui.composer"
  local icons = require "paseo.ui.icons"
  local keys = require "paseo.ui.keys"
  local render = require "paseo.ui.render"

  local left = {
    { " ", "PaseoComposerHint" },
    { require("paseo.ui.chat").label(chat), "PaseoComposerKey" },
    { " ", "PaseoComposerHint" },
  }
  local hints = {}
  local back = keys.label("composer", "<C-g>")
  if back then
    hints[#hints + 1] = { icons.spell(back), "back" }
  end
  local send = keys.label("composer", "<M-CR>")
  if send then
    hints[#hints + 1] = { icons.spell(send), "send" }
  end
  hints[#hints + 1] = { ":q!", "drop unsaved" }

  -- As many of the hints as fit, the most useful first.
  local right = {}
  for _, hint in ipairs(hints) do
    local more = {
      { (#right == 0 and " " or " · "), "PaseoComposerHint" },
      { hint[1], "PaseoComposerKey" },
      { " " .. hint[2], "PaseoComposerHint" },
    }
    local candidate = vim.list_extend(vim.deepcopy(right), more)
    if render.width(left) + render.width(candidate) + 8 > width then
      break
    end
    right = candidate
  end
  if #right > 0 then
    right[#right + 1] = { " ", "PaseoComposerHint" }
  end
  return composer.rule(left, right, width)
end

---Give the box's window the column, but for `M.CONTEXT` rows of conversation.
---@param chat table
local function grow(chat)
  local win, conv = chat.editing.win, chat.win_conversation
  if not valid_win(win) then
    return
  end
  local total = api.nvim_win_get_height(win)
  if valid_win(conv) then
    local transcript = require "paseo.ui.transcript"
    local stick = transcript.at_bottom(chat)
    local conv_bar = (vim.wo[conv].winbar or "") ~= "" and 1 or 0
    total = total + api.nvim_win_get_height(conv)
    api.nvim_win_set_height(win, math.max(3, total - M.CONTEXT - conv_bar))
    if stick then
      transcript.to_bottom(chat)
    end
  end
end

---Copy what the editor holds into the box. The `TextChanged` is what every
---watcher of the box listens to -- the chips, a draft's save and its rail row
----- and `nvim_buf_set_lines` does not fire it by itself.
---@param chat table
local function sync(chat)
  local e = chat.editing
  if not (e and valid_buf(e.buf) and valid_buf(chat.composer)) then
    return
  end
  local lines = api.nvim_buf_get_lines(e.buf, 0, -1, false)
  api.nvim_buf_set_lines(chat.composer, 0, -1, false, lines)
  pcall(api.nvim_exec_autocmds, "TextChanged", { buffer = chat.composer, modeline = false })
end

---The box back, after the editor buffer went.
---@param chat table
---@param e table  What `chat.editing` was.
local function finish(chat, e)
  pcall(vim.fn.delete, e.file)
  if not valid_buf(chat.composer) then
    return
  end
  local chat_ui = require "paseo.ui.chat"

  local win = e.win
  if valid_win(win) then
    -- `<C-g>` put the box back already. A `:b` away put something else here
    -- instead, and what you asked for is left where you put it.
    if api.nvim_win_get_buf(win) ~= chat.composer then
      return
    end
  elseif chat.surface == "native" then
    -- `:wq` / `:q!` closed the window. The native surface builds its box
    -- again when it shows the chat.
    require("paseo.ui.native").show(chat, { focus = true })
  else
    local sidebar = require "paseo.ui.sidebar"
    chat.win_composer = nil
    sidebar.ensure_composer(chat)
  end

  chat_ui.fit_composer(chat)
  require("paseo.ui.composer").refresh(chat)
  local box = chat.win_composer
  if valid_win(box) and api.nvim_win_get_buf(box) == chat.composer then
    api.nvim_set_current_win(box)
    if e.cursor then
      local last = api.nvim_buf_line_count(chat.composer)
      local row = math.min(e.cursor[1], last)
      pcall(api.nvim_win_set_cursor, box, { row, e.cursor[2] })
    end
  end
  if e.send then
    chat_ui.send(chat)
  end
end

---Write the editor if it has unsaved edits, and go back to the box.
---@param chat table
---@param opts? { send?: boolean }  Send it, too.
function M.close(chat, opts)
  local e = chat.editing
  if not (e and valid_buf(e.buf)) then
    return
  end
  e.send = opts and opts.send or false
  if vim.bo[e.buf].modified then
    -- A real `:write`: its `BufWritePost` is the sync, and yours (a
    -- formatter, an LSP) run as they would on any file.
    api.nvim_buf_call(e.buf, function()
      vim.cmd "silent keepalt write"
    end)
  end
  if vim.fn.mode() ~= "n" then
    vim.cmd.stopinsert()
  end
  if valid_win(e.win) and api.nvim_win_get_buf(e.win) == e.buf then
    e.cursor = api.nvim_win_get_cursor(e.win)
    -- The buffer is hidden here, and `bufhidden=wipe` does the rest.
    api.nvim_win_set_buf(e.win, chat.composer)
  else
    pcall(api.nvim_buf_delete, e.buf, { force = true })
  end
end

---The editor's own keys: the way back, and sending from it.
---@param chat table
---@param buf integer
local function bind(chat, buf)
  local keys = require "paseo.ui.keys"
  local opts = { buffer = buf, nowait = true }
  keys.set("composer", { "n", "i" }, "<C-g>", function()
    M.close(chat)
  end, vim.tbl_extend("force", opts, { desc = "paseo: back to the box, written" }))
  for _, key in ipairs { "<M-CR>", "<C-CR>" } do
    keys.set("composer", { "n", "i" }, key, function()
      M.close(chat, { send = true })
    end, vim.tbl_extend("force", opts, { desc = "paseo: send it" }))
  end
  keys.newline("composer", buf)
end

---Open the box's prompt in the editor. Insert mode stays insert mode, and the
---cursor stays where it was in the text.
---@param chat table
function M.open(chat)
  if chat.editing then
    if valid_win(chat.editing.win) then
      api.nvim_set_current_win(chat.editing.win)
    end
    return
  end
  local win = chat.win_composer
  if not (valid_win(win) and valid_buf(chat.composer)) then
    return
  end

  local cursor = api.nvim_get_current_win() == win and api.nvim_win_get_cursor(win) or nil
  local file = M.file(chat)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.fn.writefile(api.nvim_buf_get_lines(chat.composer, 0, -1, false), file)
  -- A buffer left on that file -- a crash, a `:e` of it -- is stale now.
  local stale = vim.fn.bufnr(file)
  if stale ~= -1 then
    pcall(api.nvim_buf_delete, stale, { force = true })
  end

  local e = { win = win, file = file }
  chat.editing = e
  api.nvim_set_current_win(win)
  local ok, err = pcall(vim.cmd, "keepalt noswapfile edit " .. vim.fn.fnameescape(file))
  local buf = api.nvim_win_get_buf(win)
  if not ok or buf == chat.composer then
    chat.editing = nil
    pcall(vim.fn.delete, file)
    vim.notify("paseo: could not open the prompt editor: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  e.buf = buf
  editors[buf] = chat
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  if vim.bo[buf].filetype ~= "markdown" then
    vim.bo[buf].filetype = "markdown"
  end
  bind(chat, buf)
  -- The box's look, which `:edit` reset for the new buffer: no `~` rows.
  vim.wo[win].fillchars = "eob: "

  local group = api.nvim_create_augroup("paseo.editor." .. buf, { clear = true })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    desc = "paseo: a written prompt goes into the box",
    callback = function()
      sync(chat)
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    desc = "paseo: where the cursor was in the prompt",
    callback = function()
      if valid_win(e.win) and api.nvim_win_get_buf(e.win) == buf then
        e.cursor = api.nvim_win_get_cursor(e.win)
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    desc = "paseo: the box back when the prompt editor goes",
    callback = function()
      editors[buf] = nil
      pcall(api.nvim_del_augroup_by_id, group)
      if chat.editing == e then
        chat.editing = nil
      end
      vim.schedule(function()
        finish(chat, e)
      end)
    end,
  })

  grow(chat)
  require("paseo.ui.composer").refresh(chat)
  if cursor then
    local last = api.nvim_buf_line_count(buf)
    pcall(api.nvim_win_set_cursor, win, { math.min(cursor[1], last), cursor[2] })
  end
end

return M
