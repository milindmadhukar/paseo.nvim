--- The new-session draft.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

--- The new-session draft: the model behind the screen that sets a session up
--- before it exists.
---
--- All of this used to live inside the rendering function of a plain buffer,
--- which is why none of it was tested and why the race below was only ever
--- found by changing a mode twice quickly.
local function test_draft()
  local draft_model = require "paseo.ui.draft"
  local bridge = require "paseo.bridge"
  local old_request = bridge.request
  local held = {}
  local hold = false

  local entries = {
    {
      provider = "claude",
      status = "ready",
      label = "Claude",
      defaultModeId = "default",
      modes = { { id = "default", label = "Ask" }, { id = "bypassPermissions", label = "Bypass" } },
      models = {
        {
          id = "opus",
          label = "Opus",
          isDefault = true,
          thinkingOptions = {
            { id = "think", label = "Think", isDefault = true },
          },
        },
      },
    },
    {
      provider = "codex",
      status = "ready",
      label = "Codex",
      defaultModeId = "auto",
      modes = { { id = "auto", label = "Auto" } },
      models = { { id = "gpt", label = "GPT", isDefault = true, thinkingOptions = {} } },
    },
    -- Neither offerable: one is not ready, the other has no model to run.
    { provider = "pi", status = "unavailable", models = {} },
    { provider = "omp", status = "ready", models = {} },
  }

  local ok, err = pcall(function()
    bridge.request = function(op, args, callback)
      if op == "providers.features" then
        if hold then
          held[#held + 1] = callback
          return
        end
        return callback(nil, {
          features = {
            { id = "fast_mode", type = "toggle", label = "Fast", value = false },
            { id = "plan_mode", type = "toggle", label = "Plan", value = false },
          },
        })
      end
      callback(nil, {})
    end

    local selection = draft_model.first(entries)
    eq("draft: the first offerable provider is chosen", selection.entry.provider, "claude")
    local draft = draft_model.new("/work", entries, selection)
    eq("draft: its default mode comes from the daemon", draft.modeId, "default")
    eq("draft: its default reasoning comes from the model", draft.thinkingOptionId, "think")

    local groups = draft_model.groups(draft)
    eq("draft: five cards, not four", #groups, 5)
    local by_id = {}
    for i, group in ipairs(groups) do
      by_id[group.id] = group
      by_id[group.id].at = i
    end
    eq("draft: provider comes first", groups[1].id, "provider")
    eq("draft: a provider with no model is not offered", #by_id.provider.entries, 2)
    eq("draft: the provider card knows what is set", by_id.provider.current, "claude")
    eq("draft: and the model card does", by_id.model.current, "opus")
    eq(
      "draft: bypassing permissions is still drawn as danger",
      by_id.mode.entries[2].tone,
      "danger"
    )

    -- Switching provider takes its modes and models with it, and carries no
    -- feature values across: a feature id means what the provider saying it
    -- means, and `fast_mode` on claude is not `fast_mode` on codex.
    draft_model.refresh_features(draft, false, function() end)
    vim.wait(200, function()
      return not draft.loading
    end)
    draft.featureValues.fast_mode = true
    draft_model.apply(draft, by_id.provider, { id = "codex" }, function() end)
    vim.wait(200, function()
      return not draft.loading
    end)
    eq("draft: switching provider switches model", draft.model.id, "gpt")
    eq("draft: and mode", draft.modeId, "auto")
    eq("draft: and carries no feature value across", draft.featureValues.fast_mode, false)

    -- THE RACE. Two mode changes in flight, and the first to come back is not
    -- the first that was sent. A stale reply must be dropped, not applied.
    hold = true
    local codex = draft_model.groups(draft)[3]
    draft_model.apply(draft, codex, { id = "auto" }, function() end)
    draft.modeId = "default"
    draft_model.refresh_features(draft, true, function() end)
    draft_model.refresh_features(draft, true, function() end)
    eq("draft: every change in flight is counted", #held, 2)
    truthy("draft: and the card holds its height meanwhile", draft_model.groups(draft)[5].rows >= 1)
    held[1](
      nil,
      { features = { { id = "stale", type = "toggle", label = "Stale", value = true } } }
    )
    vim.wait(100)
    eq("draft: the stale reply is dropped", draft.featureValues.stale, nil)
    truthy("draft: and it is still waiting", draft.loading)
    held[2](nil, { features = { { id = "live", type = "toggle", label = "Live", value = true } } })
    vim.wait(200, function()
      return not draft.loading
    end)
    eq("draft: the reply that was asked for lands", draft.featureValues.live, true)
    hold = false

    local result = draft_model.result(draft)
    eq("draft: the result carries provider and model together", result.provider, "codex/gpt")
    eq("draft: and the mode", result.modeId, "default")
    eq("draft: and the feature values", result.featureValues.live, true)
    -- A model with no thinking options reports no reasoning, rather than
    -- inventing one for `agent.create` to reject.
    eq("draft: and no reasoning when the model has none", result.thinkingOptionId, nil)
  end)

  bridge.request = old_request
  truthy("draft: the cases ran", ok, err)
end

return {
  { "draft", test_draft },
}
