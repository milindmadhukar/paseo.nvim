--- Path completion in the boxes: `./` from the agent's directory.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_complete()
  local complete = require "paseo.ui.complete"
  local old_cmp = package.loaded.cmp
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, buf, "paseo://compose/complete-spec")

  local ok, err = pcall(function()
    vim.api.nvim_set_current_buf(buf)
    -- The reason for all of it: a URL-named buffer's directory is no directory.
    eq("complete: what a path source would have used", vim.fn.expand(("#%d:p:h"):format(buf)), "paseo://compose")

    package.loaded.cmp = nil
    complete.attach(buf, dir)
    eq("complete: the root is on the buffer", vim.b[buf].paseo_root, dir)
    eq("complete: and is where ./ starts", complete.cwd(buf), dir)

    -- No cmp yet (it loads on InsertEnter): nothing to tell, tried again later.
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })

    local told = {}
    local lsp = { name = "nvim_lsp" }
    package.loaded.cmp = {
      get_config = function()
        return { sources = { lsp, { name = "async_path", option = { trailing_slash = true } }, { name = "path" } } }
      end,
      setup = {
        buffer = function(c)
          told[#told + 1] = { buf = vim.api.nvim_get_current_buf(), config = c }
        end,
      },
    }
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
    eq("complete: cmp is told once it is there", #told, 1)
    eq("complete: about this buffer", told[1].buf, buf)
    local sources = told[1].config.sources
    eq("complete: every source kept", #sources, 3)
    eq("complete: the others as they were", sources[1].name, "nvim_lsp")
    eq("complete: and not shared with the global config", sources[1] ~= lsp, true)
    eq("complete: an option you set is kept", sources[2].option.trailing_slash, true)
    local params = { context = { bufnr = buf } }
    eq("complete: async_path from the agent's directory", sources[2].option.get_cwd(params), dir)
    eq("complete: path too", sources[3].option.get_cwd(params), dir)

    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
    eq("complete: and only once", #told, 1)

    -- A directory that is not here (a remote host's path): Neovim's cwd.
    complete.attach(buf, "/no/such/paseo/dir")
    eq("complete: a path not on this machine falls back", complete.cwd(buf), vim.fn.getcwd())
    eq("complete: a chat's local root", complete.root { root = "/remote/x", local_root = dir }, dir)
    eq("complete: a remote root alone is none", complete.root { root = "/no/such/paseo/dir" }, nil)
  end)

  package.loaded.cmp = old_cmp
  t.go_home()
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err)
  end
end

return {
  { "path completion in the boxes", test_complete },
}
