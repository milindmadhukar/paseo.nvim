--- A finished plan, and what to do about it.
---
--- A plan arrives as a PERMISSION REQUEST like any other -- the daemon gives it
--- `kind == "plan"` -- and the daemon decides its buttons, the same ones the
--- Paseo app shows:
---
---     Reject                          deny,  intent "dismiss"
---     Implement                       allow, intent "implement"
---     Implement with Bypass ...       allow, intent "implement_resume"
---
--- The third is offered only when the agent was in `bypassPermissions` or
--- `auto` before it entered plan mode. The daemon also applies the mode that
--- follows: `implement_resume` restores the prior mode, anything else lands in
--- `acceptEdits`. The app renders `request.actions` as sent and answers with
--- the chosen action's id, and so does this plugin -- an invented list of modes
--- here is exactly how a button the app gained went missing in Neovim.
---
--- The plan text is the other half. For `kind == "plan"` the daemon sends no
--- `detail` at all and puts the markdown in `input.plan`, so a dialog that
--- renders `request.detail` -- which is what |paseo.ui.permission| does for
--- everything else -- shows an empty box and asks you to approve it.
---
--- No windows here. |paseo.ui.permission| owns the dialog and the keys; this
--- owns what a plan IS and how its decision is recorded, which is why it can
--- be tested without opening anything.

local M = {}

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

---What was decided, for the transcript's resolution badge.
---
---The badge otherwise reads "allowed", which for a plan is true and useless.
---A plain Implement is "implemented"; the daemon's resume button says which
---mode it went back to, in the daemon's own words rather than a mode name of
---ours.
---@param action table  One of `request.actions`.
---@return string
function M.label(action)
  if action.behavior ~= "allow" then
    return "rejected, still planning"
  end
  if action.intent ~= "implement_resume" or not text(action.label) then
    return "implemented"
  end
  return ("implemented (%s)"):format(action.label)
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
