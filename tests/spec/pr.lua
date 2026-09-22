--- Pull request status: what `gh` says, rolled up into one word.
---
--- Nothing here goes near the network. `gh` is not a test dependency and a
--- suite that needed a GitHub login would not run on anybody's machine but
--- one -- so the subprocess boundary is the seam: `_seed` records exactly what
--- `fetch` records, and everything after it is ours.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_checks()
  local pr = require "paseo.pr"

  eq("pr: no checks at all is not a verdict", pr.checks(nil), "none")
  eq("pr: and neither is an empty list", pr.checks {}, "none")

  -- THE CHECK-RUN SHAPE: `status` plus `conclusion`.
  eq("pr: a finished successful run passes", pr.checks {
    { status = "COMPLETED", conclusion = "SUCCESS" },
  }, "passing")
  eq("pr: an unfinished run is pending", pr.checks {
    { status = "IN_PROGRESS" },
  }, "pending")
  eq("pr: and so is a queued one", pr.checks {
    { status = "QUEUED" },
  }, "pending")

  -- THE STATUS-CONTEXT SHAPE: `state` alone, which is what the commit-status
  -- API posts -- Netlify, Vercel and most deploy previews use it. A reader
  -- that only knew about check runs reported these as pending forever.
  eq("pr: a bare SUCCESS state passes", pr.checks {
    { state = "SUCCESS" },
  }, "passing")
  eq("pr: a bare PENDING state is pending", pr.checks {
    { state = "PENDING" },
  }, "pending")
  eq("pr: a bare FAILURE state fails", pr.checks {
    { state = "FAILURE" },
  }, "failing")

  -- Neither of these is a failure, and treating them as one makes every
  -- path-filtered workflow look broken.
  eq("pr: skipped is not failed", pr.checks {
    { status = "COMPLETED", conclusion = "SKIPPED" },
  }, "passing")
  eq("pr: nor is neutral", pr.checks {
    { status = "COMPLETED", conclusion = "NEUTRAL" },
  }, "passing")

  -- FAILING BEATS PENDING, in both orders, because the point of the word is
  -- deciding whether to look now.
  eq("pr: one red check decides a half-finished run", pr.checks {
    { status = "IN_PROGRESS" },
    { status = "COMPLETED", conclusion = "FAILURE" },
  }, "failing")
  eq("pr: whichever order they arrive in", pr.checks {
    { status = "COMPLETED", conclusion = "TIMED_OUT" },
    { status = "IN_PROGRESS" },
  }, "failing")
  eq("pr: a cancelled run is a failure too", pr.checks {
    { status = "COMPLETED", conclusion = "CANCELLED" },
  }, "failing")

  -- And the two shapes side by side in one list, which is the case that put
  -- the two-shape reader in.
  eq("pr: mixed shapes roll up together", pr.checks {
    { status = "COMPLETED", conclusion = "SUCCESS" },
    { state = "PENDING" },
  }, "pending")
end

---@param over table
---@return table
local function raw(over)
  return vim.tbl_extend("force", {
    number = 412,
    state = "OPEN",
    isDraft = false,
    statusCheckRollup = { { status = "COMPLETED", conclusion = "SUCCESS" } },
  }, over)
end

local function test_state()
  local pr = require "paseo.pr"
  local repo = { name = "clm", worktree = "/nowhere/clm" }

  ---@param over table
  ---@return string
  local function state(over)
    return pr.state(pr.normalise(repo, "ws/x", raw(over)))
  end

  eq("pr: a green open PR is open", state {}, "open")
  eq("pr: merged wins over everything", state {
    state = "MERGED",
    statusCheckRollup = { { state = "FAILURE" } },
  }, "merged")
  eq("pr: and so does closed", state { state = "CLOSED" }, "closed")

  -- THE ORDER IS THE ORDER YOU ACT ON IT. A red check and a draft flag are
  -- both true at once on plenty of pull requests, and which one the row says
  -- decides whether you go and look.
  eq("pr: a failing check outranks a draft", state {
    isDraft = true,
    statusCheckRollup = { { state = "FAILURE" } },
  }, "failing")
  eq("pr: changes requested outranks a running check", state {
    reviewDecision = "CHANGES_REQUESTED",
    statusCheckRollup = { { status = "IN_PROGRESS" } },
  }, "changes")
  eq("pr: a running check outranks a draft", state {
    isDraft = true,
    statusCheckRollup = { { status = "IN_PROGRESS" } },
  }, "pending")
  eq("pr: a green draft is a draft", state { isDraft = true }, "draft")
  eq("pr: waiting on a reviewer says so", state { reviewDecision = "REVIEW_REQUIRED" }, "review")
  eq("pr: and an approved one says that", state { reviewDecision = "APPROVED" }, "approved")

  -- A pull request with no checks configured at all is not pending forever.
  eq("pr: no CI is not a pending CI", state { statusCheckRollup = {} }, "open")
end

local function test_rollup()
  local pr = require "paseo.pr"
  local repos = require "paseo.repos"

  -- The two-repo workspace from the fixtures: one unit of work, two branches,
  -- two pull requests. This is the shape the rollup exists for -- a single
  -- repo needs no rolling up.
  local root = vim.fs.joinpath(t.fixtures, "multi", ".workspaces", "otp")
  repos.invalidate()
  local members = repos.list { path = root }
  eq("pr: the fixture workspace has two members", #members, 2)

  pr.invalidate()
  eq("pr: an unasked workspace says nothing", pr.rollup(root), nil)

  -- One repo answered, the other not yet. The row must still draw: a unit of
  -- work whose second `gh` call is in flight is not a unit of work with no
  -- pull requests.
  pr._seed(members[1], "ws/otp", raw {})
  local partial = pr.rollup(root)
  eq("pr: one answer is enough to draw a row", { partial.count, partial.state }, { 1, "open" })
  eq("pr: and it carries the number, because there is one", partial.number, 412)

  -- THE WORST STATE WINS. Six repos in one unit of work still answer one
  -- question -- is this landable -- and one red check answers it.
  pr._seed(
    members[2],
    "ws/otp",
    raw { number = 413, statusCheckRollup = { { state = "FAILURE" } } }
  )
  local both = pr.rollup(root)
  eq("pr: two answers roll into one state", { both.count, both.state }, { 2, "failing" })
  eq("pr: with no single number to give", both.number, nil)
  eq("pr: which is what the row is titled", pr.title(both), "2 PRs")

  -- Half merged is the status, when a unit of work is landing repo by repo.
  pr._seed(members[2], "ws/otp", raw { number = 413, state = "MERGED" })
  local landing = pr.rollup(root)
  eq("pr: the unmerged half is still the state", landing.state, "open")
  eq("pr: and the title says how far through it is", pr.title(landing), "1/2 merged")

  pr._seed(members[1], "ws/otp", raw { state = "MERGED" })
  local done = pr.rollup(root)
  eq("pr: all merged is merged", done.state, "merged")
  eq("pr: and stops counting them out", pr.title(done), "2 PRs")

  -- A repo that was asked and has no pull request contributes nothing, rather
  -- than contributing a row that says "none".
  pr.invalidate()
  pr._seed(members[1], "ws/otp", nil)
  pr._seed(members[2], "ws/otp", nil)
  eq("pr: a workspace with no pull requests says nothing", pr.rollup(root), nil)

  pr.invalidate()
end

local function test_drawing()
  local pr = require "paseo.pr"
  local render = require "paseo.ui.render"
  local repo = { name = "clm", worktree = "/nowhere/clm" }

  ---@param over table
  ---@return paseo.PullRequestRollup
  local function one(over)
    pr.invalidate()
    pr._seed(repo, "ws/x", raw(over))
    return {
      count = 1,
      number = raw(over).number,
      state = pr.state(pr.normalise(repo, "ws/x", raw(over))),
      merged = 0,
      prs = {},
    }
  end

  local failing = one { statusCheckRollup = { { state = "FAILURE" } } }
  -- The glyph comes from the registry rather than being written here: a
  -- literal nerd-font byte sequence in a source file is the one thing
  -- |paseo.ui.icons| exists to keep out of them.
  local mark = pr.glyph "failing"
  eq(
    "pr: the long form spells the state out",
    render.concat(pr.cells(failing)),
    mark .. " #412 checks failing"
  )
  eq("pr: the short form keeps the number", render.concat(pr.short(failing)), mark .. " #412")

  -- THE TONE CARRIES THE URGENCY, and a merged pull request gets a glyph of
  -- its own rather than only a colour: colour alone does not reach a reader
  -- who cannot tell green from amber.
  eq("pr: a failure is drawn as one", pr.tone "failing", "PaseoToolFail")
  eq("pr: a running check is not", pr.tone "pending", "PaseoToolRunning")
  eq("pr: and neither is a merge", pr.tone "merged", "PaseoToolOk")
  truthy("pr: merged has a glyph of its own", pr.glyph "merged" ~= pr.glyph "open")
  eq(
    "pr: every state has a keycap-wide glyph",
    vim.tbl_map(function(state)
      return vim.api.nvim_strwidth(pr.glyph(state)) >= 1
    end, {
      "merged",
      "closed",
      "failing",
      "changes",
      "pending",
      "draft",
      "review",
      "approved",
      "open",
    }),
    { true, true, true, true, true, true, true, true, true }
  )

  pr.invalidate()
end

return {
  { "pr.checks", test_checks },
  { "pr.state", test_state },
  { "pr.rollup", test_rollup },
  { "pr.drawing", test_drawing },
}
