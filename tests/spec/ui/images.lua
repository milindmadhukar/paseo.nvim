--- Pictures in the transcript: chips, the hit test, the float.
---
--- snacks.nvim is not on the suite's runtimepath, so everything here is the
--- path a terminal without kitty graphics takes -- which is also the part
--- that has to work for everyone.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

---A real PNG header, 80 x 60, and nothing after it.
local PNG = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\80\0\0\0\60\8\6\0\0\0"

local function write(path, bytes)
  local fd = assert(io.open(path, "wb"))
  fd:write(bytes)
  fd:close()
end

---A chat over a real buffer in a real window, rooted at `root`.
local function fake_chat(root)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 70,
    height = 20,
    style = "minimal",
  })
  local chat = { conversation = buf, win_conversation = win, root = root }
  require("paseo.ui.transcript").reset(chat)
  return chat
end

local function chips(chat)
  local images = require "paseo.ui.images"
  return api.nvim_buf_get_extmarks(chat.conversation, images.ns, 0, -1, { details = true })
end

local function test_images()
  local images = require "paseo.ui.images"
  local transcript = require "paseo.ui.transcript"

  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/shots", "p")
  local pic = root .. "/shots/pic.png"
  write(pic, PNG)
  local elsewhere = vim.fn.tempname() .. ".png"
  write(elsewhere, PNG)

  -- ----------------------------------------------------------- resolution
  local chat = fake_chat(root)
  eq("resolve: relative to the AGENT's directory", images.resolve(chat, "shots/pic.png"), pic)
  eq("resolve: not Neovim's cwd", images.resolve({ root = "/" }, "shots/pic.png"), nil)
  eq("resolve: an absolute path", images.resolve(chat, elsewhere), elsewhere)
  eq("resolve: a file:// URL", images.resolve(chat, "file://" .. pic), pic)
  eq("resolve: <angled>, as markdown allows", images.resolve(chat, "<shots/pic.png>"), pic)
  eq("resolve: a web address is not a file here", images.resolve(chat, "https://example.com/a.png"), nil)
  eq("resolve: a file that is not there", images.resolve(chat, "shots/gone.png"), nil)

  -- ---------------------------------------------------------------- chips
  transcript.upsert(chat, { kind = "user", text = "what is this" })
  transcript.upsert(chat, {
    kind = "text",
    text = table.concat({
      "Here it is:",
      "",
      "![the shot](shots/pic.png)",
      "",
      "```",
      "![not this](shots/pic.png)",
      "```",
      "and ![gone](shots/gone.png).",
    }, "\n"),
  })
  images.sync(chat)
  local marks = chips(chat)
  eq("chip: one, on the link that resolves outside a fence", #marks, 1)
  local lines = api.nvim_buf_get_lines(chat.conversation, 0, -1, false)
  local link_row
  for i, line in ipairs(lines) do
    if line == "![the shot](shots/pic.png)" then
      link_row = i - 1
    end
  end
  eq("chip: on the link's row", marks[1] and marks[1][2], link_row)
  eq("chip: from its first byte", marks[1] and marks[1][3], 0)
  eq("chip: to its last", marks[1] and marks[1][4].end_col, #"![the shot](shots/pic.png)")
  eq("chip: drawn as a reference", marks[1] and marks[1][4].hl_group, "PaseoRef")

  -- ------------------------------------------------------- the hit test
  api.nvim_win_set_cursor(chat.win_conversation, { link_row + 1, 3 })
  local hit = images.at_cursor(chat)
  eq("cursor: on the chip, the picture", hit and hit.src, pic)
  api.nvim_win_set_cursor(chat.win_conversation, { link_row, 0 })
  eq("cursor: a row away, nothing", images.at_cursor(chat), nil)
  local near = images.at_cursor(chat, { nearest = true })
  eq("cursor: but gx finds the nearest", near and near.src, pic)
  api.nvim_win_set_cursor(chat.win_conversation, { 1, 0 })
  eq("cursor: nothing on a block with no picture", images.at_cursor(chat, { nearest = true }), nil)

  -- -------------------------------------------------------- an image read
  transcript.upsert(chat, {
    kind = "tool",
    callId = "read-1",
    name = "Read",
    status = "completed",
    display = { summary = "shots/pic.png" },
    detail = { type = "read", filePath = pic, content = "iVBORw0KGgo=" },
  })
  local read_block = chat.blocks[chat.by_call["read-1"]]
  local read_row = transcript.row_of(chat, read_block)
  api.nvim_win_set_cursor(chat.win_conversation, { read_row + read_block.height, 0 })
  local read_hit = images.at_cursor(chat)
  eq("read: anywhere on the card is the picture", read_hit and read_hit.kind, "read")
  eq("read: the file it read", read_hit and read_hit.src, pic)
  local card = require("paseo.ui.timeline").card(read_block.item, { width = 60, expanded = true })
  local text = {}
  for _, line in ipairs(card.lines) do
    for _, cell in ipairs(line) do
      text[#text + 1] = cell[1]
    end
  end
  truthy(
    "read: the card does not dump the base64",
    not table.concat(text, "\n"):find("iVBORw0KGgo", 1, true)
  )

  -- ------------------------------------------------------------ the float
  local tabs = vim.fn.tabpagenr "$"
  local before = api.nvim_get_current_win()
  local win = images.open(pic)
  truthy("float: it is a float", win and api.nvim_win_get_config(win).relative ~= "")
  eq("float: never a tab", vim.fn.tabpagenr "$", tabs)
  local fbuf = api.nvim_win_get_buf(win)
  eq("float: without snacks, a card of its own", vim.bo[fbuf].filetype, "paseo_image")
  local said = table.concat(api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
  truthy("float: the card says how big it is", said:find("80 × 60", 1, true) ~= nil, said)
  api.nvim_feedkeys("q", "x", false)
  truthy("float: q closes it", not api.nvim_win_is_valid(win))
  eq("float: and it is gone with its buffer", api.nvim_buf_is_valid(fbuf), false)
  if api.nvim_win_is_valid(before) then
    api.nvim_set_current_win(before)
  end

  -- -------------------------------------------------- debounced, deferred
  images.clear(chat)
  local st_passes = function()
    return (chat.image_state and chat.image_state.passes) or 0
  end
  transcript.quietly(chat, function()
    for i = 1, 60 do
      transcript.upsert(chat, { kind = "text", text = ("line %d ![p](shots/pic.png)"):format(i) })
    end
  end)
  vim.wait(1000, function()
    return st_passes() > 0
  end, 10)
  vim.wait(300)
  eq("debounce: sixty writes are one pass", st_passes(), 1)
  eq("debounce: and every one of them has its chip", #chips(chat), 60)

  transcript.stream(chat, "streaming ![p](shots/pic.png)")
  local open = chat.open and chat.blocks[chat.open.id]
  images.sync(chat)
  local open_row = transcript.row_of(chat, open)
  -- Anywhere in the block: its first row is the gap above it.
  local function chip_on(row)
    local last = row + open.height - 1
    return #api.nvim_buf_get_extmarks(chat.conversation, images.ns, { row, 0 }, { last, -1 }, {}) > 0
  end
  eq("stream: the reply being written is left alone", chip_on(open_row), false)
  transcript.close(chat)
  images.sync(chat)
  eq("stream: and looked at once it ends", chip_on(open_row), true)

  -- --------------------------------------------------- reset takes them all
  transcript.reset(chat)
  eq("reset: no chip outlives its block", #chips(chat), 0)

  api.nvim_win_close(chat.win_conversation, true)
  api.nvim_buf_delete(chat.conversation, { force = true })
  vim.fn.delete(root, "rf")
  vim.fn.delete(elsewhere)
end

return {
  { "images", test_images },
}
