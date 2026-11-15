--- The prompt editor: `<C-g>` in the composer.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_editor()
  local bridge = require "paseo.bridge"
  local chat = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local sidebar = require "paseo.ui.sidebar"
  local surface = require "paseo.ui.surface"
  local config = require "paseo.config"
  local editor = require "paseo.ui.editor"

  local old_ensure, old_request = bridge.ensure, bridge.request
  local old_settings = chat.load_settings
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/a.lua"
  vim.fn.writefile({ "one", "two" }, file)
  local sent

  local ok, err = pcall(function()
    config.setup {}
    surface.reset()
    chat.load_settings = function() end
    bridge.ensure = function(callback)
      callback(nil)
    end
    bridge.request = function(op, args, callback)
      if op == "agent.find" then
        return callback(nil, { id = "editor-agent", provider = "test" })
      end
      if op == "timeline.history" then
        return callback(nil, { items = {} })
      end
      if op == "agent.send" then
        sent = args
      end
      callback(nil, {})
    end

    vim.cmd("edit " .. vim.fn.fnameescape(file))
    chat.add_ref { token = "@a.lua:1", context = "CTX", root = dir, abs = file }
    local mine
    truthy("editor: the chat comes up", vim.wait(1000, function()
      mine = chat.current()
      return mine ~= nil
        and table.concat(vim.api.nvim_buf_get_lines(mine.composer, 0, -1, false), "\n"):find("@a.lua:1", 1, true) ~= nil
    end))
    truthy("editor: in the sidebar", sidebar.is_open(mine))
    local function box()
      return table.concat(vim.api.nvim_buf_get_lines(mine.composer, 0, -1, false), "\n")
    end
    local function settle()
      vim.wait(50, function()
        return false
      end)
    end

    vim.cmd "stopinsert"
    vim.api.nvim_buf_set_lines(mine.composer, 0, -1, false, { "@a.lua:1 first", "second" })
    vim.api.nvim_set_current_win(mine.win_composer)
    vim.api.nvim_win_set_cursor(mine.win_composer, { 2, 3 })
    local small = vim.api.nvim_win_get_height(mine.win_composer)

    -- In: the whole box, in a markdown file, in the box's window, grown.
    vim.api.nvim_feedkeys(vim.keycode "<C-g>", "x", false)
    local e = mine.editing
    truthy("editor: <C-g> opens it", e ~= nil)
    local buf = vim.api.nvim_get_current_buf()
    eq("editor: in the box's window", vim.api.nvim_get_current_win(), mine.win_composer)
    eq("editor: on its file", vim.api.nvim_buf_get_name(buf), vim.fn.fnamemodify(editor.file(mine), ":p"))
    eq("editor: a .md file", vim.bo[buf].filetype, "markdown")
    eq("editor: holding the box", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "@a.lua:1 first\nsecond")
    eq("editor: the cursor where it was", vim.api.nvim_win_get_cursor(0), { 2, 3 })
    eq("editor: off the buffer row", vim.bo[buf].buflisted, false)
    truthy("editor: the window grew", vim.api.nvim_win_get_height(mine.win_composer) > small)
    truthy("editor: wearing its own bar", vim.wo[mine.win_composer].winbar:find("back", 1, true) ~= nil, vim.wo[mine.win_composer].winbar)

    -- <S-CR> is a newline here too; `:w` puts it in the box and stays.
    vim.api.nvim_feedkeys(vim.keycode "Go<S-CR>third<Esc>", "x", false)
    eq("editor: unwritten, the box is as it was", box(), "@a.lua:1 first\nsecond")
    vim.cmd "write"
    eq("editor: :w puts it in the box", box(), "@a.lua:1 first\nsecond\n\nthird")
    eq("editor: and stays", vim.api.nvim_get_current_buf(), buf)

    -- `:q!` drops what was not written, and the box comes back.
    vim.api.nvim_feedkeys(vim.keycode "Gofourth<Esc>", "x", false)
    vim.cmd "quit!"
    settle()
    eq("editor: :q! goes back", mine.editing, nil)
    eq("editor: without the unwritten line", box(), "@a.lua:1 first\nsecond\n\nthird")
    truthy("editor: the sidebar still has a box", vim.api.nvim_win_is_valid(mine.win_composer))
    eq("editor: showing the composer", vim.api.nvim_win_get_buf(mine.win_composer), mine.composer)
    eq("editor: and you are in it", vim.api.nvim_get_current_win(), mine.win_composer)
    eq("editor: the buffer is gone", vim.api.nvim_buf_is_valid(buf), false)
    eq("editor: and its file", vim.fn.filereadable(e.file), 0)
    truthy("editor: the box is a box again", vim.api.nvim_win_get_height(mine.win_composer) <= config.get().ui.sidebar.composer + 1)

    -- <C-g> from insert mode, and <C-g> back: written, in the box.
    vim.api.nvim_feedkeys(vim.keycode "A<C-g>", "x", false)
    truthy("editor: <C-g> from insert mode", mine.editing ~= nil)
    -- (`feedkeys` "x" ends insert mode when its keys run out.)
    vim.api.nvim_feedkeys(vim.keycode "A more<C-g>", "x", false)
    settle()
    eq("editor: <C-g> back writes it", box(), "@a.lua:1 first\nsecond\n\nthird more")
    eq("editor: back in the box", vim.api.nvim_get_current_buf(), mine.composer)
    eq("editor: in normal mode", vim.fn.mode(), "n")

    -- Full screen: `:wq` closes the window the editor was in, and the Paseo
    -- tab stays up with its box made again.
    chat.fullscreen()
    truthy("editor: full screen", native.has(mine))
    vim.api.nvim_set_current_win(mine.win_composer)
    vim.api.nvim_feedkeys(vim.keycode "<C-g>", "x", false)
    truthy("editor: opens on the full screen", mine.editing ~= nil)
    vim.api.nvim_feedkeys(vim.keycode "ggdGinative<Esc>", "x", false)
    vim.cmd "wq"
    settle()
    truthy("editor: the Paseo tab stays", native.has(mine) and native.on_tab())
    eq("editor: :wq puts it in the box", box(), "native")
    truthy("editor: with a box again", vim.api.nvim_win_is_valid(mine.win_composer) and vim.api.nvim_win_get_buf(mine.win_composer) == mine.composer)

    -- <M-CR> in the editor sends it.
    vim.api.nvim_set_current_win(mine.win_composer)
    vim.api.nvim_feedkeys(vim.keycode "<C-g>", "x", false)
    vim.api.nvim_feedkeys(vim.keycode "A sent<M-CR>", "x", false)
    truthy("editor: <M-CR> sends", vim.wait(1000, function()
      return sent ~= nil
    end))
    truthy("editor: what was written", sent and sent.prompt:find("native sent", 1, true) ~= nil, sent and sent.prompt)
    eq("editor: and the box is empty", box(), "")
    eq("editor: no editor left", mine.editing, nil)
  end)

  bridge.ensure, bridge.request = old_ensure, old_request
  chat.load_settings = old_settings
  config.setup {}
  t.go_home()
  pcall(vim.cmd, "bwipeout! " .. vim.fn.bufnr(file))
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err)
  end
end

return {
  { "prompt editor", test_editor },
}
