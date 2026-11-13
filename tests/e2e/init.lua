--- The Neovim the end-to-end scenarios drive.
---
--- Like tests/minimal_init.lua -- no user config, dependencies from
--- $PASEO_TEST_DEPS -- except that it talks to a REAL daemon: the throwaway one
--- tests/e2e/daemon.sh started, never the live one on 6767. `autostart` is off
--- so a mistyped port fails loudly instead of quietly starting a daemon
--- against the wrong home.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:prepend(root)
package.path = ("%s/?.lua;%s"):format(root, package.path)

local deps = assert(vim.env.PASEO_TEST_DEPS, "PASEO_TEST_DEPS is not set; run tests/e2e/nvim.sh")
for name, kind in vim.fs.dir(deps) do
  -- Never volt, even when an old cache still has it: nothing needs it.
  if kind == "directory" and name ~= "volt" then
    vim.opt.runtimepath:append(vim.fs.joinpath(deps, name))
  end
end

local url = assert(vim.env.PASEO_E2E_URL, "PASEO_E2E_URL is not set; start tests/e2e/daemon.sh")
assert(not url:match ":6767/", "refusing to drive the live daemon on 6767")

vim.opt.swapfile = false
vim.opt.termguicolors = true
vim.cmd.colorscheme(vim.env.PASEO_E2E_COLORS or "habamax")

require("paseo").setup {
  paseo = {
    url = url,
    home = vim.env.PASEO_E2E_HOME,
    autostart = false,
    provider = vim.env.PASEO_E2E_PROVIDER or "fake/scripted",
  },
  ui = {
    surface = vim.env.PASEO_E2E_SURFACE or "native",
    -- PASEO_E2E_UI_COLORS=fixed checks the plugin's own palette.
    colors = vim.env.PASEO_E2E_UI_COLORS or "auto",
  },
}

--- Read by scenarios over `--remote-expr`: one JSON line describing what is on
--- screen, so a scenario asserts on facts rather than on pixels.
_G.paseo_e2e = {}

function _G.paseo_e2e.state()
  local native = require "paseo.ui.native"
  local chat = native.chat() or require("paseo.ui.chat").current()
  local blocks = {}
  if chat and chat.blocks then
    for _, id in ipairs(chat.order or {}) do
      local block = chat.blocks[id]
      if block then
        blocks[#blocks + 1] = { kind = block.item.kind, text = block.item.text }
      end
    end
  end
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    wins[#wins + 1] = {
      float = cfg.relative ~= "",
      buf = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)),
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
    }
  end
  return vim.json.encode {
    -- Which surface the chat is on: "native" (its own tab page) or "sidebar".
    mount = (chat and native.has(chat) and "native")
      or (chat and require("paseo.ui.sidebar").is_open(chat) and "sidebar")
      or nil,
    tabpages = #vim.api.nvim_list_tabpages(),
    agent = chat and chat.agent_id or nil,
    streaming = chat and chat.streaming or false,
    blocks = blocks,
    wins = wins,
  }
end

local function current()
  return require("paseo.ui.native").chat() or require("paseo.ui.chat").current()
end

---How many user messages the transcript shows.
function _G.paseo_e2e.users()
  local chat, n = current(), 0
  for _, id in ipairs(chat and chat.order or {}) do
    local block = chat.blocks[id]
    if block and block.item.kind == "user" then
      n = n + 1
    end
  end
  return n
end

---A turn begun after `before` user messages has finished: a newer user
---message is on screen, the chat is no longer streaming, and the last block is
---the answer.
function _G.paseo_e2e.turn_done(before)
  local chat = current()
  if not chat or chat.streaming or _G.paseo_e2e.users() <= before then
    return false
  end
  local last = chat.blocks[chat.order[#chat.order]]
  return last ~= nil and last.item.kind == "text"
end
