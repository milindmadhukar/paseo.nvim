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
      -- What the quickfix ask is now: one chip in the composer beside the
      -- code, `@quickfix`, carrying the list.
      add_ref = function(item, opts)
        attached = { item = item, opts = opts }
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

      truthy("explain: the list becomes a chip", attached ~= nil)
      local item = attached and attached.item or {}
      eq("explain: named @quickfix in the composer", item.token, "@quickfix")
      eq("explain: nothing is sent until you have written the question", attached and attached.opts, nil)
      truthy(
        "explain: paths are ABSOLUTE, so entries from sibling worktrees resolve",
        (item.context or ""):find "\n%- /.*f%.txt:%d+" ~= nil,
        item.context
      )
      truthy(
        "explain: the root is a worktree the entries came from",
        item.root ~= nil and vim.startswith(item.root, root) or false,
        vim.inspect(item)
      )
      truthy("explain: and the first entry's file says which chat covers it", item.abs ~= nil)

      -- The sibling block is added at SEND, once per message; it is still
      -- explain's to write.
      local others = require("paseo.explain").siblings(item.root) or ""
      truthy("explain: sibling agents are listed for the review agent to ask", others:find "ag_theirs" ~= nil, others)
      truthy(
        "explain: but not paseo.nvim's own agents -- that would be a loop",
        others:find "ag_ours" == nil,
        others
      )

      -- An empty list adds nothing.
      attached = nil
      vim.fn.setqflist({}, " ", { title = "spec", items = {} })
      require("paseo.explain").quickfix()
      truthy("explain: an empty quickfix list adds nothing", attached == nil)
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
