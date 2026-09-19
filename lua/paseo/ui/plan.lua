--- A finished plan, and what to do about it.
---
--- A plan arrives as a PERMISSION REQUEST like any other -- the daemon gives it
--- `kind == "plan"` -- but it is two decisions wearing one button. Approving
--- says both "yes, build it" and "and here is how much rope you have while you
--- do". Paseo's dialog only ever asked the first, and the daemon answered the
--- second on your behalf:
---
---     if (pending.request.kind === "plan") {
---         const targetMode = shouldResumePriorMode ? "bypassPermissions" : "acceptEdits";
---         await this.setMode(targetMode);
---
--- So every approved plan landed in `acceptEdits`, whether or not that is what
--- you wanted, and there was no way to say otherwise from here.
---
--- `AgentPermissionResponse` has no field for a target mode, so the second
--- decision cannot ride along with the first. It has to be a follow-up
--- `setAgentMode` AFTER the approval resolves -- before, and the daemon's own
--- call overwrites it. That sequencing lives in the sidecar; this module owns
--- the choice.
---
--- The plan text is the other half. For `kind == "plan"` the daemon sends no
--- `detail` at all and puts the markdown in `input.plan`, so a dialog that
--- renders `request.detail` -- which is what |paseo.ui.permission| does for
--- everything else -- shows an empty box and asks you to approve it.
---
--- No windows here. |paseo.ui.permission| owns the dialog and the keys; this
--- owns the RULES -- which buttons exist for this provider, and what each one
--- means -- which is why they can be tested without opening anything.

local M = {}

---@class paseo.PlanAction
---@field id string           The provider's own action id, for selectedActionId.
---@field label string
---@field behavior string     "allow" | "deny"
---@field variant string|nil
---@field mode string|nil     The mode to move to AFTER the approval lands.

---The modes an Implement button can hand you, in the order they are offered.
---
---Least rope first, which is the order Claude Code itself uses and the reason
---`y` -- which takes the first allow -- is the safe key rather than the bold
---one. Ids only: the labels are ours because the daemon's ("Accept File Edits",
---"Always Ask") do not read as the tail of a sentence beginning "Implement,".
local IMPLEMENT = {
  { mode = "acceptEdits", suffix = "accept edits" },
  { mode = "auto", suffix = "auto" },
  { mode = "default", suffix = "always ask" },
}

---@param value any
---@return string|nil
local function text(value)
  if type(value) ~= "string" or vim.trim(value) == "" then
    return nil
  end
  return value
end

---Is this request a plan waiting to be approved?
---
---`kind` rather than `name == "ExitPlanMode"`, because `kind` is the
---provider-neutral discriminant -- `AgentPermissionRequestKind` is
---`"tool" | "plan" | "question" | "mode" | "other"` -- and mapping the tool
---name onto it is the daemon's job, already done, for every provider rather
---than just for Claude.
---@param request table|nil
---@return boolean
function M.parse(request)
  return type(request) == "table" and request.kind == "plan"
end

---The plan itself, as markdown.
---
---`input.plan` is where the daemon puts it; `metadata.planText` is its own
---mirror of the same string, kept as the fallback in case a provider fills one
---and not the other. `description` is the last resort and is usually a summary
---line rather than the plan.
---
---Returns `""` rather than nil so the caller has no branch.
---@param request table
---@return string
function M.text(request)
  local input = type(request.input) == "table" and request.input or {}
  local metadata = type(request.metadata) == "table" and request.metadata or {}
  return text(input.plan) or text(metadata.planText) or text(request.description) or ""
end

---Find the request's own action matching a predicate.
---@param request table
---@param predicate fun(action: table): boolean
---@return table|nil
local function find(request, predicate)
  for _, action in ipairs(type(request.actions) == "table" and request.actions or {}) do
    if type(action) == "table" and predicate(action) then
      return action
    end
  end
end

---The buttons for a plan, or nil to use the request's own.
---
---Every Implement button carries the DAEMON'S action id, not one of ours: the
---daemon keys its own behaviour off `selectedActionId`, and an id it does not
---recognise is rejected outright. What differs between them is `mode`, which
---the sidecar applies afterwards. So these are not four different approvals;
---they are one approval and three different answers to "and then what".
---
---Modes are filtered against what the provider actually reports, so codex --
---which has `auto`/`auto-review`/`full-access` and no `acceptEdits` -- gets the
---one button that means something rather than three that do not. If nothing
---matches, or the daemon offered no allow action to build on, this returns nil
---and the dialog falls back to the request's own buttons untouched.
---@param request table
---@param available_modes table[]|nil  From `agent.config`; `{id, label, ...}`.
---@return paseo.PlanAction[]|nil
function M.actions(request, available_modes)
  local implement = find(request, function(action)
    return action.behavior == "allow" and action.intent ~= "implement_resume"
  end)
  if not implement then
    return nil
  end

  local known = {}
  for _, mode in ipairs(available_modes or {}) do
    if type(mode) == "table" and mode.id then
      known[mode.id] = mode
    end
  end

  local actions = {}
  for _, entry in ipairs(IMPLEMENT) do
    if known[entry.mode] then
      actions[#actions + 1] = {
        id = implement.id,
        label = ("Implement, %s"):format(entry.suffix),
        behavior = "allow",
        variant = #actions == 0 and "primary" or "secondary",
        mode = entry.mode,
      }
    end
  end
  if #actions == 0 then
    return nil
  end

  -- The daemon offers this one only when the session was in `bypassPermissions`
  -- before it entered plan mode, and it restores that mode server-side. It
  -- needs no `mode` from us, and inventing one would fight the daemon for a
  -- decision it is already making correctly.
  local resume = find(request, function(action)
    return action.intent == "implement_resume"
  end)
  if resume then
    actions[#actions + 1] = {
      id = resume.id,
      label = resume.label or "Implement, resume prior mode",
      behavior = "allow",
      variant = "secondary",
    }
  end

  local reject = find(request, function(action)
    return action.behavior == "deny"
  end)
  actions[#actions + 1] = {
    id = reject and reject.id or "__deny",
    label = "Reject, keep planning",
    behavior = "deny",
    variant = "danger",
  }

  return actions
end

---What was decided, for the transcript's resolution badge.
---
---The badge otherwise reads "allowed", which for a plan is true and useless:
---the whole point of the four buttons is that they differ, and a record that
---collapses them records nothing.
---@param action paseo.PlanAction
---@return string
function M.label(action)
  if action.behavior ~= "allow" then
    return "rejected, still planning"
  end
  if not action.mode then
    return "implemented"
  end
  for _, entry in ipairs(IMPLEMENT) do
    if entry.mode == action.mode then
      return ("implemented, %s"):format(entry.suffix)
    end
  end
  return "implemented"
end

---The plan as it goes into the transcript, capped.
---
---The picker is transient and the conversation is the record: which plan you
---approved should still be readable tomorrow, and `request.description` -- what
---the inline card showed before -- is a one-line summary of it at best.
---@param request table
---@param limit integer|nil  Lines to keep; default 12.
---@return string[]
function M.render(request, limit)
  limit = limit or 12
  local lines = vim.split(M.text(request), "\n", { plain = true })

  -- Trailing blanks would be spent from the budget and show as nothing.
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end

  if #lines <= limit then
    return lines
  end
  local kept = vim.list_slice(lines, 1, limit)
  kept[#kept + 1] = ("… %d more lines"):format(#lines - limit)
  return kept
end

return M
