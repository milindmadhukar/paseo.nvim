-- Driven over `nvim --server`: open a chat, and report what is on screen.
local M = {}

function M.open(agent_id, surface)
  require("paseo.ui.chat").open {
    root = vim.fn.getcwd(),
    agent_id = agent_id,
    surface = (surface ~= "" and surface ~= vim.NIL) and surface or nil,
  }
  return "opened"
end

function M.state()
  local chat = require("paseo.ui.chat").current()
  local perm = require "paseo.ui.permission"
  local ok, answer = pcall(require, "paseo.ui.answer")
  return vim.inspect {
    mode = vim.api.nvim_get_mode().mode,
    buf = vim.api.nvim_buf_get_name(0),
    mount = require("paseo.ui.float").mount(),
    sidebar = chat and require("paseo.ui.sidebar").is_open(chat) or false,
    held = chat and vim.tbl_map(function(r) return r.id end, chat.permissions or {}) or nil,
    dialog = perm._showing(),
    overlay = ok and answer.showing() or nil,
    tab = require("paseo.ui.float").tab(),
  }
end

setmetatable(M, { __call = function() return M.state() end })
return M
