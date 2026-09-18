--- Asking about a hunk.
---
--- The branch you take when a hunk is opaque, one keystroke from the hunk you
--- are standing on. If it costs more than that, it does not get taken -- which
--- is the whole reason this lives in the same plugin as the review surfaces
--- rather than in a separate agent-chat plugin.

local bridge = require "paseo.bridge"
local config = require "paseo.config"
local ref = require "paseo.ref"
local answer = require "paseo.answer"

local M = {}

---Per-directory agent ids, so a second question reuses the first one's session
---rather than starting a cold agent that has to re-read the repo.
---@type table<string, string>
local agents = {}

---The rubric.
---
---The last line is the load-bearing one. "Explain this" invites a summary you
---nod along to; asking what to push back on forces a posture where you argue
---with the answer. That is what actually addresses not being able to explain
---your own code.
local RUBRIC = table.concat({
  "Explain this change. Be specific and brief.",
  "",
  "1. What changed, in one or two sentences.",
  "2. What invariant or assumption it altered — what was true before that is not true now.",
  "3. The call sites or callers affected. Name files and lines.",
  "4. What I should push back on: what is unproven, riskier than it looks, or worth arguing about.",
}, "\n")

---@param callback fun(err: string|nil, agent_id: string|nil)
local function agent_for(repo, callback)
  local existing = agents[repo.worktree]
  if existing then
    return callback(nil, existing)
  end

  bridge.request("agent.ensure", {
    cwd = repo.worktree,
    provider = config.get().paseo.provider,
    title = "paseo.nvim · " .. repo.name,
  }, function(err, result)
    if err then
      return callback(err, nil)
    end
    agents[repo.worktree] = result.id
    callback(nil, result.id)
  end)
end

---@param agent_id string
---@param header string
local function stream_into_answer(agent_id, header)
  answer.begin(header)
  bridge.request("timeline.subscribe", { agentId = agent_id }, function(err)
    if err then
      answer.append("\n\n_could not stream the reply: " .. err .. "_")
    end
  end)
end

---Send `prompt`, with `location` as context, and stream the reply into a split.
---@param location paseo.Ref
---@param prompt string
---@param header string
local function ask_with(location, prompt, header)
  bridge.ensure(function(err)
    if err then
      vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      return
    end

    agent_for(location.repo, function(agent_err, agent_id)
      if agent_err then
        vim.notify("paseo: " .. agent_err, vim.log.levels.ERROR)
        return
      end

      stream_into_answer(agent_id, header)
      bridge.request("agent.send", {
        -- `agentId`, not `id`: `id` is the request-correlation field, which
        -- `bridge.request` sets LAST and therefore wins. Passed as `id` the
        -- agent became the request number and the daemon prefix-matched it
        -- against three different agents.
        agentId = agent_id,
        prompt = table.concat({ prompt, "", ref.render(location) }, "\n"),
      }, function(send_err)
        if send_err then
          answer.append("\n\n_send failed: " .. send_err .. "_")
        end
      end)
    end)
  end)
end

---Explain the hunk, selection or line under the cursor.
---@param kind? "cursor"|"visual"|"hunk"|"file"
function M.explain(kind)
  local location = ref.get(kind)
  if not location then
    vim.notify("paseo: nothing to explain here", vim.log.levels.WARN)
    return
  end
  ask_with(location, RUBRIC, "Explain " .. ref.format(location))
end

---Ask a free-form question about the same thing.
---@param kind? "cursor"|"visual"|"hunk"|"file"
function M.ask(kind)
  local location = ref.get(kind)
  if not location then
    vim.notify("paseo: nothing to ask about here", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Ask about " .. ref.format(location) .. ": " }, function(question)
    if not question or question == "" then
      return
    end
    ask_with(location, question, question)
  end)
end

---@type boolean
local attached = false

---Wire the sidecar's streaming events into the answer window.
---
---IDEMPOTENT, and it has to be: `setup()` calls it, and anything else that
---calls it again doubles every listener. Streamed text then appends twice and
---a reply delivered as "READ" + "Y" renders as "READREADYY" -- which reads
---like a corrupt stream rather than a duplicated handler.
function M.attach()
  if attached then
    return
  end
  attached = true

  bridge.on("text", function(payload)
    answer.append(payload.text or "")
  end)

  -- Turn completion comes from `turn_*`, never from a status transition to
  -- idle -- the SDK is explicit about that, and idle is reached for reasons
  -- other than "this turn finished".
  bridge.on("turn", function(payload)
    answer.finish(payload.outcome == "turn_completed" and "done" or tostring(payload.outcome))
  end)

  bridge.on("stream_error", function(payload)
    answer.append("\n\n_stream error: " .. tostring(payload.error) .. "_")
  end)

  -- Reconnected, and nothing is replayed. Say so rather than letting the window
  -- look like the agent simply stopped talking.
  bridge.on("restored", function()
    answer.append "\n\n_(reconnected — any output during the gap was not replayed)_\n"
  end)
end

return M
