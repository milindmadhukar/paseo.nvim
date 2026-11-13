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

  -- The buttons are the daemon's: there is no list of modes here to fall out
  -- of step with the app, which is how "Implement with Bypass" went missing.
  eq("plan: no button list of our own", plan.actions, nil)

  -- The badge otherwise reads "allowed", which for a plan is true and useless.
  eq("plan: a plain Implement is implemented", plan.label(request.actions[2]), "implemented")
  eq(
    "plan: the resume button says which mode it went back to, in the daemon's words",
    plan.label {
      id = "implement_resume",
      label = "Implement with Bypass Permissions",
      behavior = "allow",
      intent = "implement_resume",
    },
    "implemented (Implement with Bypass Permissions)"
  )
  eq(
    "plan: and a reject says you are still planning",
    plan.label(request.actions[1]),
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
