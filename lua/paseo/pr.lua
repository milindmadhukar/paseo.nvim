--- What GitHub thinks of the branch each repo is standing on.
---
--- The half of a unit of work that is not on disk. `git status` says what you
--- changed; this says whether what you already pushed passed, whether anyone
--- reviewed it, and whether it landed -- which is the question you actually
--- have when an agent tells you it opened a PR and you are sitting in Neovim
--- with no browser open.
---
--- ASKED OF `gh`, NOT OF AN API. `gh pr view` already knows which pull request
--- belongs to the branch you are on, which remote is GitHub, and how you are
--- authenticated. Reimplementing any of that against the REST API would mean
--- owning a token, and the one thing this plugin must not do is become a
--- second place credentials live.
---
--- CACHED, BECAUSE IT IS THE NETWORK. Every other status column here is
--- push-fed by the sidecar at about a millisecond. This one is a subprocess
--- and a round trip to github.com, and it is read by panels that repaint ten
--- times a second while a turn runs. So the surfaces read `get` and `rollup`,
--- which answer instantly from a table, and `watch` is what refreshes that
--- table behind them.
---
--- A repo with no pull request, no GitHub remote, or no `gh` is a repo this
--- module says NOTHING about. It has to be: most branches most of the time
--- have no pull request, and a column that draws "none" on every row is a
--- column that made every row wider in order to say nothing.

local config = require "paseo.config"

local M = {}

---One repo's answer.
---@class paseo.PullRequest
---@field repo string        Repo name, as |paseo.repos| spells it.
---@field worktree string    Absolute path the answer is about.
---@field branch string      The local branch at the time of asking.
---@field number integer
---@field title string|nil
---@field url string|nil
---@field state "OPEN"|"MERGED"|"CLOSED"
---@field draft boolean
---@field checks "passing"|"failing"|"pending"|"none"
---@field review "approved"|"changes"|"required"|nil
---@field at integer         `uv.now()` when it was fetched.

---What is known about one worktree.
---
---`pr` is nil for "asked, and there is no pull request" -- which is most
---branches most of the time, and is cached exactly as hard as a positive.
---Without that, a branch with no PR costs a subprocess on every redraw for as
---long as the panel is open.
---@class paseo.PullRequestEntry
---@field at integer          `uv.now()` when `gh` answered.
---@field branch string       The branch it answered about.
---@field pr paseo.PullRequest|nil

---@type table<string, paseo.PullRequestEntry>
local entries = {}

---When each worktree was last asked which branch it is on.
---
---A SECOND, SHORTER CLOCK than the pull request's. Reading the branch is a
---local file read; asking GitHub about it is a round trip. Throttling both on
---the network TTL means a branch you just switched to shows the previous
---branch's pull request for a minute; throttling neither means a fork per repo
---per frame on a panel that repaints ten times a second.
---@type table<string, integer>
local probed = {}

---@type table<string, boolean>
local inflight = {}

---@type fun()[]
local listeners = {}

---Whether `gh` is worth trying. Resolved once: `executable()` stats every
---entry on `$PATH`, and this is asked from a panel's draw.
---@type boolean|nil
local have_gh

---@return boolean
local function usable()
  if not config.get().ui.pr.enabled then
    return false
  end
  if have_gh == nil then
    have_gh = vim.fn.executable "gh" == 1
  end
  return have_gh
end

---Whether this module can say anything at all.
---
---Exposed so a surface can leave the column out entirely rather than drawing
---an empty one.
---@return boolean
function M.available()
  return usable()
end

local function announce()
  for _, fn in ipairs(listeners) do
    pcall(fn)
  end
end

---Call `fn` whenever an answer lands.
---@param fn fun()
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

-- -------------------------------------------------------------------- shapes

---Roll a `statusCheckRollup` up into one word.
---
---TWO SHAPES IN ONE LIST. GitHub returns `CheckRun` entries, which carry
---`status` and `conclusion`, alongside `StatusContext` entries from the older
---commit-status API, which carry only `state`. A reader that knows about one
---of them reports a green build as pending forever on any repo whose CI posts
---the other -- and Netlify, Vercel and most deploy previews post the other.
---
---FAILING BEATS PENDING, which beats passing. What this word is for is
---deciding whether to go and look, and a half-finished run with one red check
---in it is worth looking at now rather than in five minutes.
---@param rollup table[]|nil
---@return "passing"|"failing"|"pending"|"none"
function M.checks(rollup)
  local seen, pending = false, false
  for _, check in ipairs(rollup or {}) do
    seen = true
    local verdict = check.conclusion or check.state
    if check.status and check.status ~= "COMPLETED" and not check.conclusion then
      -- A run that has not finished has no conclusion yet, and `state` is not
      -- a field on a CheckRun, so this is the only signal there is.
      pending = true
    elseif verdict == "SUCCESS" or verdict == "NEUTRAL" or verdict == "SKIPPED" then
      -- Neutral and skipped are not failures: a path-filtered workflow that
      -- skipped itself is the normal state of most pull requests.
    elseif verdict == nil or verdict == "PENDING" or verdict == "EXPECTED" then
      pending = true
    else
      -- FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED, STARTUP_FAILURE.
      return "failing"
    end
  end
  if not seen then
    return "none"
  end
  return pending and "pending" or "passing"
end

---@param decision string|nil
---@return "approved"|"changes"|"required"|nil
local function review_of(decision)
  if decision == "APPROVED" then
    return "approved"
  end
  if decision == "CHANGES_REQUESTED" then
    return "changes"
  end
  if decision == "REVIEW_REQUIRED" then
    return "required"
  end
  return nil
end

---What `gh` printed, as one of ours.
---@param repo paseo.Repo
---@param branch string
---@param raw table
---@return paseo.PullRequest
function M.normalise(repo, branch, raw)
  return {
    repo = repo.name,
    worktree = repo.worktree,
    branch = branch,
    number = raw.number,
    title = raw.title,
    url = raw.url,
    state = raw.state or "OPEN",
    draft = raw.isDraft == true,
    checks = M.checks(raw.statusCheckRollup),
    review = review_of(raw.reviewDecision),
    at = vim.uv.now(),
  }
end

---The answer for one repo, or nil while there is not one.
---@param worktree string
---@return paseo.PullRequest|nil
function M.get(worktree)
  local entry = entries[worktree]
  return entry and entry.pr or nil
end

-- ------------------------------------------------------------------- fetching

---The fields worth one round trip.
---
---`statusCheckRollup` is the expensive one and it is the whole point: without
---it "there is a pull request" is all this could say, and "there is a pull
---request" was never the question.
local FIELDS = "number,title,url,state,isDraft,reviewDecision,statusCheckRollup"

---How often the local branch is re-read, in milliseconds. See `probed`.
local PROBE_MS = 2000

---@param repo paseo.Repo
---@param branch string
local function fetch(repo, branch)
  inflight[repo.worktree] = true
  vim.system(
    { "gh", "pr", "view", "--json", FIELDS },
    { cwd = repo.worktree, text = true },
    function(result)
      vim.schedule(function()
        inflight[repo.worktree] = nil

        -- EVERY FAILURE IS THE SAME ANSWER HERE, deliberately. `gh` exits
        -- non-zero for "no pull requests found", for "no GitHub remote", for
        -- "not logged in" and for "the network is down", and none of those is
        -- worth interrupting someone mid-turn about: this is a status column,
        -- not an operation anyone asked for. `:checkhealth paseo` is where
        -- "you are not logged in to gh" belongs.
        local pr = nil
        if result.code == 0 then
          local ok, raw = pcall(vim.json.decode, result.stdout or "")
          if ok and type(raw) == "table" and raw.number then
            pr = M.normalise(repo, branch, raw)
          end
        end
        entries[repo.worktree] = { at = vim.uv.now(), branch = branch, pr = pr }
        announce()
      end)
    end
  )
end

---@param repo paseo.Repo
local function consider(repo)
  local worktree = repo.worktree
  if inflight[worktree] then
    return
  end
  local now = vim.uv.now()
  if probed[worktree] and now - probed[worktree] < PROBE_MS then
    return
  end
  probed[worktree] = now

  -- THE BRANCH FIRST, and locally. It invalidates the cache for free when you
  -- switch branch, and a detached HEAD -- which is what a `git bisect` and
  -- every checked-out tag is -- has no pull request to ask about by
  -- definition, so it never reaches the network at all.
  --
  -- Asynchronous like the fetch, and for the same reason: this runs from a
  -- panel's draw, where a `:wait()` is a fork the redraw blocks on.
  vim.system(
    { "git", "-C", worktree, "symbolic-ref", "--quiet", "--short", "HEAD" },
    { text = true },
    function(head)
      vim.schedule(function()
        if head.code ~= 0 then
          return
        end
        local branch = (head.stdout or ""):gsub("%s+$", "")
        if branch == "" then
          return
        end

        local known = entries[worktree]
        local ttl = config.get().ui.pr.ttl * 1000
        if known and known.branch == branch and vim.uv.now() - known.at < ttl then
          return
        end
        fetch(repo, branch)
      end)
    end
  )
end

---Refresh, at most once per TTL, every repo in the unit of work at `root`.
---
---Safe to call from a draw: everything it does is a table read or an
---asynchronous callback, and the two clocks above are what keep the second one
---rare.
---@param root string
function M.watch(root)
  if not usable() then
    return
  end
  for _, repo in ipairs(require("paseo.repos").list { path = root }) do
    consider(repo)
  end
end

---Record an answer without going near the network.
---
---Exposed for the suite, which has to be able to say "this repo's branch has a
---pull request in state X" and then ask what the row says about it. The
---production path is `fetch`, and it stores exactly this.
---@param repo paseo.Repo
---@param branch string
---@param raw table|nil  `nil` records "asked, and there is no pull request".
function M._seed(repo, branch, raw)
  entries[repo.worktree] = {
    at = vim.uv.now(),
    branch = branch,
    pr = raw and M.normalise(repo, branch, raw) or nil,
  }
  probed[repo.worktree] = vim.uv.now()
end

---Forget everything, so the next `watch` asks again.
---
---For the things that have just CHANGED the answer -- a push, a merge -- where
---waiting out a TTL would go on showing the old one.
function M.invalidate()
  entries, probed = {}, {}
end

-- -------------------------------------------------------------------- rollup

---What a set of pull requests amounts to, as one state.
---
---ONE WORD FOR N REPOS, because a unit of work spanning six repos has six
---pull requests and the question is still singular: is this landable. So the
---worst state wins -- one red check in one repo is the state of the whole
---thing, exactly as it is for a single repo whose checks half-passed.
---
---The order is the order you act on. A failing check is yours to fix now;
---changes requested is yours to fix now; pending is a wait; review is someone
---else's turn; approved and merged are done.
local SEVERITY = {
  failing = 1,
  changes = 2,
  pending = 3,
  review = 4,
  draft = 5,
  open = 6,
  approved = 7,
  merged = 8,
  closed = 9,
}

---@param pr paseo.PullRequest
---@return string
function M.state(pr)
  if pr.state == "MERGED" then
    return "merged"
  end
  if pr.state == "CLOSED" then
    return "closed"
  end
  if pr.checks == "failing" then
    return "failing"
  end
  if pr.review == "changes" then
    return "changes"
  end
  if pr.checks == "pending" then
    return "pending"
  end
  if pr.draft then
    return "draft"
  end
  if pr.review == "required" then
    return "review"
  end
  if pr.review == "approved" then
    return "approved"
  end
  return "open"
end

---@class paseo.PullRequestRollup
---@field count integer          How many repos here have one.
---@field number integer|nil     The number, when there is exactly one.
---@field state string           The worst state among them. See `SEVERITY`.
---@field merged integer         How many have landed.
---@field prs paseo.PullRequest[]

---Every pull request in the unit of work at `root`, rolled into one answer.
---
---Reads only; `watch` is what fills the table. A caller that draws this must
---call `watch` too, or the column is empty forever.
---@param root string
---@return paseo.PullRequestRollup|nil  nil when there is nothing to say.
function M.rollup(root)
  -- NOT GATED ON `usable`. It cannot need to be: nothing reaches the table
  -- without `gh` having answered, so an unusable host has an empty table and
  -- this returns nil on its own. Checking twice would only make this
  -- untestable without `gh` installed, which is exactly the wrong thing to
  -- need in order to test what a rolled-up state is.
  local found, worst, merged = {}, nil, 0
  for _, repo in ipairs(require("paseo.repos").list { path = root }) do
    local pr = M.get(repo.worktree)
    if pr then
      found[#found + 1] = pr
      local state = M.state(pr)
      if state == "merged" then
        merged = merged + 1
      end
      if not worst or SEVERITY[state] < SEVERITY[worst] then
        worst = state
      end
    end
  end
  if #found == 0 then
    return nil
  end
  return {
    count = #found,
    number = #found == 1 and found[1].number or nil,
    state = worst,
    merged = merged,
    prs = found,
  }
end

-- ------------------------------------------------------------------- drawing

---The glyph, the tone and the word for each state.
---
---THREE TABLES AND NOT AN `if` CHAIN, because two surfaces draw this and they
---must not disagree: the composer's bar has room for the word, a workspace row
---has room for the glyph, and a reader who sees both on one screen is reading
---one fact twice.
---
---`merged` gets a glyph of its own rather than a colour of its own. It is the
---one state on the row worth recognising without reading it, and colour alone
---does not carry to a reader who cannot tell green from amber.
local GLYPH = {
  merged = function()
    return require("paseo.ui.icons").ui.merged
  end,
  closed = function()
    return require("paseo.ui.icons").status.canceled
  end,
  failing = function()
    return require("paseo.ui.icons").status.failed
  end,
  changes = function()
    return require("paseo.ui.icons").status.permission
  end,
  pending = function()
    return require("paseo.ui.icons").status.running
  end,
  approved = function()
    return require("paseo.ui.icons").status.completed
  end,
}

local TONE = {
  merged = "PaseoToolOk",
  closed = "PaseoDim",
  failing = "PaseoToolFail",
  changes = "PaseoDanger",
  pending = "PaseoToolRunning",
  draft = "PaseoDim",
  review = "PaseoToolRunning",
  approved = "PaseoToolOk",
  open = "PaseoDim",
}

local WORD = {
  merged = "merged",
  closed = "closed",
  failing = "checks failing",
  changes = "changes requested",
  pending = "checks running",
  draft = "draft",
  review = "in review",
  approved = "approved",
  open = "open",
}

---@param state string
---@return string
function M.glyph(state)
  local named = GLYPH[state]
  if named then
    return named()
  end
  return require("paseo.ui.icons").ui.pull_request
end

---@param state string
---@return string
function M.tone(state)
  return TONE[state] or "PaseoDim"
end

---@param state string
---@return string
function M.word(state)
  return WORD[state] or state
end

---What to call the pull requests in a rollup.
---
---A NUMBER WHEN THERE IS ONE, because `#412` is a thing you can type into
---`gh pr view` and `3 PRs` is not. Above one there is no single number to
---give, and naming the first would be a lie about the other two.
---@param rollup paseo.PullRequestRollup
---@return string
function M.title(rollup)
  if rollup.number then
    return "#" .. rollup.number
  end
  -- `N of M merged` while some have landed and some have not: with six repos
  -- in one unit of work, how far through the merge you are IS the status.
  if rollup.merged > 0 and rollup.merged < rollup.count then
    return ("%d/%d merged"):format(rollup.merged, rollup.count)
  end
  return ("%d PRs"):format(rollup.count)
end

---The long form: glyph, name, and what state it is in.
---@param rollup paseo.PullRequestRollup
---@return table[]
function M.cells(rollup)
  local tone = M.tone(rollup.state)
  return {
    { M.glyph(rollup.state) .. " ", tone },
    { M.title(rollup), tone },
    { " " .. M.word(rollup.state), "PaseoDim" },
  }
end

---The short form: glyph and name, for a row that has no columns to spare.
---@param rollup paseo.PullRequestRollup
---@return table[]
function M.short(rollup)
  local tone = M.tone(rollup.state)
  return {
    { M.glyph(rollup.state) .. " ", tone },
    { M.title(rollup), tone },
  }
end

return M
