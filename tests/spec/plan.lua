--- Plans, and deciding on one.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_plan()
  local plan = require "paseo.ui.plan"
  local render = require "paseo.ui.render"
  local timeline = require "paseo.ui.timeline"

  -- What the daemon actually sends: kind "plan", NO detail, and the markdown
  -- in `input.plan`.
  local request = {
    id = "req-1",
    kind = "plan",
    name = "ExitPlanMode",
    title = "Ready to code?",
    description = "Rip out the old permission dialog",
    input = { plan = "## Step one\n\nRip out the old thing.\n\n## Step two\n\nPut a new one in." },
    actions = {
      {
        id = "reject",
        label = "Reject",
        behavior = "deny",
        variant = "danger",
        intent = "dismiss",
      },
      {
        id = "implement",
        label = "Implement",
        behavior = "allow",
        variant = "primary",
        intent = "implement",
      },
    },
  }

  local claude = {
    { id = "plan", label = "Plan Mode" },
    { id = "default", label = "Always Ask" },
    { id = "acceptEdits", label = "Accept File Edits" },
    { id = "auto", label = "Auto mode" },
    { id = "bypassPermissions", label = "Bypass" },
  }

  truthy("plan: a plan request is recognised by kind", plan.parse(request))
  -- By `kind`, not by `name`: mapping ExitPlanMode onto it is the daemon's
  -- job, already done, for every provider rather than just for Claude.
  truthy(
    "plan: an ordinary tool permission is not one",
    not plan.parse { kind = "tool", name = "Write", input = {} }
  )
  truthy("plan: and neither is a question", not plan.parse { kind = "question" })

  -- The plan text. `detail` is nil for these, so a dialog rendering `detail`
  -- showed an empty box and asked you to approve it.
  truthy(
    "plan: the text comes from input.plan",
    plan.text(request):find("Step one", 1, true) ~= nil
  )
  eq(
    "plan: metadata.planText is the fallback",
    plan.text { kind = "plan", metadata = { planText = "from metadata" } },
    "from metadata"
  )
  eq(
    "plan: then description",
    plan.text { kind = "plan", description = "from description" },
    "from description"
  )
  eq("plan: and nothing at all is an empty string, not nil", plan.text { kind = "plan" }, "")

  local actions = plan.actions(request, claude)
  eq("plan: claude gets three Implement buttons and a Reject", #actions, 4)
  eq("plan: least rope first, so `y` is the cautious key", {
    actions[1].mode,
    actions[2].mode,
    actions[3].mode,
  }, { "acceptEdits", "auto", "default" })
  eq("plan: and the last one denies", actions[4].behavior, "deny")

  -- THE POINT. The daemon keys its own behaviour off `selectedActionId` and
  -- rejects an id it does not know, so all three Implements send its id and
  -- differ only by the mode applied afterwards.
  eq("plan: every Implement carries the daemon's own action id", {
    actions[1].id,
    actions[2].id,
    actions[3].id,
  }, { "implement", "implement", "implement" })

  -- Modes are per PROVIDER. codex has auto/auto-review/full-access and no
  -- `acceptEdits`, and offering it a button that cannot work would be worse
  -- than offering nothing.
  local codex = plan.actions(request, { { id = "auto", label = "Auto" }, { id = "full-access" } })
  eq("plan: a mode the provider does not have is dropped", #codex, 2)
  eq("plan: leaving the one that does exist", codex[1].mode, "auto")

  -- No modes reported means nothing honest to offer: the request's own
  -- Implement/Reject stands rather than a guess.
  truthy(
    "plan: no reported modes falls back to the request's buttons",
    plan.actions(request, {}) == nil
  )
  truthy(
    "plan: and so does a request with no allow action to build on",
    plan.actions({ kind = "plan", actions = { { id = "reject", behavior = "deny" } } }, claude)
      == nil
  )

  -- The daemon offers this one only when the session was in bypassPermissions
  -- before it entered plan mode, and restores that mode SERVER-side -- so it
  -- must come through untouched, with no mode of ours attached.
  local resumable = vim.deepcopy(request)
  resumable.actions[#resumable.actions + 1] = {
    id = "implement_resume",
    label = "Implement with Bypass",
    behavior = "allow",
    intent = "implement_resume",
  }
  local resumed = plan.actions(resumable, claude)
  eq("plan: the daemon's resume button survives", #resumed, 5)
  eq("plan: with its own id", resumed[4].id, "implement_resume")
  truthy("plan: and no mode of ours attached to it", resumed[4].mode == nil)

  -- The badge otherwise reads "allowed", which for a plan is true and useless:
  -- the whole point of the four buttons is that they differ.
  eq("plan: the badge says which mode you landed in", plan.label(actions[2]), "implemented, auto")
  eq(
    "plan: and a reject says you are still planning",
    plan.label(actions[4]),
    "rejected, still planning"
  )

  -- Long plans are capped, and say so rather than just stopping.
  local long = { kind = "plan", input = { plan = string.rep("a line\n", 40) } }
  local capped = plan.render(long, 5)
  eq("plan: a long plan is capped", #capped, 6)
  truthy("plan: and admits what it cut", capped[6]:find("35 more lines", 1, true) ~= nil, capped[6])

  -- The inline card showed `description` -- a summary line at best -- so the
  -- record of what was approved did not contain the plan.
  local card = timeline.card({ kind = "permission", request = request }, { width = 60 })
  local text = {}
  for _, line in ipairs(card.lines) do
    text[#text + 1] = render.concat(line)
  end
  text = table.concat(text, "\n")
  truthy("plan: the inline card shows the plan itself", text:find("Step two", 1, true) ~= nil, text)
end

return {
  { "plan", test_plan },
}
