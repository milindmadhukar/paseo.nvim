--- Path completion in the boxes you write a prompt in.
---
--- Every completion source for paths -- cmp-path, cmp-async-path, blink's --
--- resolves `./` and `../` against the directory of the BUFFER's file, not
--- Neovim's cwd. The composer is `paseo://compose/<dir>`, which Neovim reads
--- as a URL, so that directory came back as the string `paseo://compose` and
--- `./` completed nothing. The `<C-g>` editor is a real file, but one in the
--- cache, so `./` there completed the cache.
---
--- What a path in a prompt is relative to is the agent's directory: it is
--- where the agent will read it. So each box carries that directory as
--- `b:paseo_root`, and when nvim-cmp is there its path sources are pointed at
--- it for that buffer alone -- your other buffers, and every other source in
--- this one, are left as you configured them.

local api = vim.api

local M = {}

---nvim-cmp's path sources: each takes a `get_cwd(params)` option.
M.SOURCES = { path = true, async_path = true }

---Where relative paths in `buf` start: the agent's directory, else Neovim's.
---@param buf integer
---@return string
function M.cwd(buf)
  local root = api.nvim_buf_is_valid(buf) and vim.b[buf].paseo_root
  if type(root) == "string" and vim.fn.isdirectory(root) == 1 then
    return root
  end
  return vim.fn.getcwd()
end

---Point nvim-cmp's path sources, in the current buffer, at `M.cwd`.
---
---From the buffer's own config as cmp resolves it now (filetype and global
---merged in), so the other sources stay exactly as they were: a buffer's
---`sources` REPLACES the list, it does not add to it.
---@return boolean  Whether cmp was there to be told.
function M.cmp()
  local cmp = package.loaded.cmp
  if not (cmp and cmp.setup and cmp.get_config) then
    return false
  end
  local ok = pcall(function()
    local sources = vim.deepcopy(cmp.get_config().sources or {})
    for _, source in ipairs(sources) do
      if M.SOURCES[source.name] then
        source.option = vim.tbl_extend("force", source.option or {}, {
          get_cwd = function(params)
            local buf = params and params.context and params.context.bufnr or api.nvim_get_current_buf()
            return M.cwd(buf)
          end,
        })
      end
    end
    cmp.setup.buffer { sources = sources }
  end)
  return ok
end

---Make relative paths in `buf` complete from `root`.
---
---On the buffer's first InsertEnter rather than now: completion engines are
---usually loaded on InsertEnter, so at the time a box is made cmp is often not
---there yet. Tried again on the next one until it is.
---@param buf integer
---@param root? string  A LOCAL directory; a remote host's path is no use here.
function M.attach(buf, root)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  vim.b[buf].paseo_root = root
  if vim.b[buf].paseo_complete then
    return
  end
  vim.b[buf].paseo_complete = true
  api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    callback = function(args)
      if args.buf == api.nvim_get_current_buf() and M.cmp() then
        return true
      end
    end,
    desc = "paseo: complete paths from the agent's directory",
  })
end

---The local directory a chat's paths are relative to, if it has one here.
---@param chat? table
---@return string|nil
function M.root(chat)
  if not chat then
    return nil
  end
  local root = chat.local_root or chat.root
  if type(root) == "string" and vim.fn.isdirectory(root) == 1 then
    return root
  end
  return nil
end

return M
