--- Asking about the quickfix list.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local root = t.fixtures
local in_dir = t.in_dir

--- `:Paseo qfask` reads the PLAIN quickfix list now -- the hunk list moved out
--- to the user's config -- so the only thing it may assume is what every
--- quickfix entry has: a buffer, a line and some text. The chat is stubbed
--- because this is about what gets rendered, not about opening a window.
local function test_explain_quickfix()
  in_dir(root .. "/multi/.workspaces/otp", function()
    local attached
    local real_chat = package.loaded["paseo.ui.chat"]
    package.loaded["paseo.ui.chat"] = {
      attach = function(text, opts)
        attached = { text = text, opts = opts, via = "attach" }
      end,
      -- What `qfask` uses now: the box takes the question, then this sends.
      ask = function(prompt, opts)
        attached = { text = opts and opts.context, opts = opts, prompt = prompt, via = "ask" }
      end,
      attach_events = function() end,
    }
    -- The directory too, and not only for isolation: `siblings()` calls
    -- `agents.watch()`, which would spawn the real sidecar here and break the
    -- bridge suite's "not running before it is started".
    local real_agents = package.loaded["paseo.agents"]
    package.loaded["paseo.agents"] = {
      watch = function() end,
      for_root = function()
        return {
          { id = "ag_theirs", title = "otp flow", provider = "p/m", status = "idle" },
          { id = "ag_ours", title = "paseo.nvim review", labels = { ["paseo.nvim"] = "review" } },
        }
      end,
    }
    package.loaded["paseo.explain"] = nil

    local ok, err = pcall(function()
      local repos = require "paseo.repos"
      local git = require "paseo.git"

      local items = {}
      for _, repo in ipairs(repos.list()) do
        for _, hunk in ipairs(git.hunks(repo)) do
          items[#items + 1] = {
            filename = vim.fs.joinpath(repo.worktree, hunk.path),
            lnum = hunk.lnum,
            text = ("+%d -%d"):format(hunk.added, hunk.removed),
          }
        end
      end
      truthy("explain: the fixture produced hunks to list", #items >= 2, "items: " .. #items)
      vim.fn.setqflist({}, " ", { title = "spec", items = items })

      require("paseo.explain").quickfix()

      -- The box, not the chat: `qfask` asks what you want to know before it
      -- opens anything. Nothing is sent until it is answered.
      truthy(
        "explain: the ask box opens rather than the chat",
        require("paseo.ui.prompt").is_open()
      )
      truthy("explain: and nothing is sent until it is answered", attached == nil)

      vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "what broke?" })
      vim.cmd "stopinsert"
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      vim.wait(300, function()
        return attached ~= nil
      end)

      truthy("explain: answering the box sends", attached ~= nil)
      eq("explain: the question is the prompt", attached and attached.prompt, "what broke?")
      eq("explain: and the list rides along as context", attached and attached.via, "ask")
      if attached then
        truthy(
          "explain: paths are ABSOLUTE, so entries from sibling worktrees resolve",
          attached.text:find "\n%- /.*f%.txt:%d+" ~= nil,
          attached.text
        )
        truthy(
          "explain: the root is a worktree the entries came from",
          attached.opts and attached.opts.root ~= nil and vim.startswith(attached.opts.root, root)
            or false,
          vim.inspect(attached.opts)
        )
        truthy(
          "explain: sibling agents are listed for the review agent to ask",
          attached.text:find "ag_theirs" ~= nil,
          attached.text
        )
        truthy(
          "explain: but not paseo.nvim's own agents -- that would be a loop",
          attached.text:find "ag_ours" == nil,
          attached.text
        )
      end

      -- An empty list must not even open the box.
      attached = nil
      vim.fn.setqflist({}, " ", { title = "spec", items = {} })
      require("paseo.explain").quickfix()
      truthy("explain: an empty quickfix list sends nothing", attached == nil)
      truthy("explain: and does not open the box either", not require("paseo.ui.prompt").is_open())
    end)

    package.loaded["paseo.agents"] = real_agents
    package.loaded["paseo.ui.chat"] = real_chat
    package.loaded["paseo.explain"] = nil
    vim.fn.setqflist({}, " ", { title = "spec", items = {} })
    if not ok then
      error(err, 0)
    end
  end)
end

return {
  { "explain", test_explain_quickfix },
}
