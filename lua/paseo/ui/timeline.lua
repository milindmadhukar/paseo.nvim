--- One timeline item in, one card out.
---
--- PURE. No buffers, no windows, no bridge -- an item table and a width go in,
--- a list of `{text, hl}` lines comes out. That is what makes it testable
--- headlessly, and it is why the permission dialog can show the exact command
--- you are approving: it calls the same `tool` builder the transcript does.
---
--- The items themselves come from the sidecar's `describeItem`, which is the
--- single place an `AgentTimelineItem` is flattened -- so live events and
--- history render through this file identically, by construction.

local icons = require "paseo.ui.icons"
local plan = require "paseo.ui.plan"
local questions = require "paseo.ui.questions"
local render = require "paseo.ui.render"

local M = {}

---Status glyphs for a tool call. A running card is visibly unfinished.
---
---From the registry rather than written out here, because the Agents & terminals panel
---and the Terminals panel say the same four things about their own rows and
---had each spelled them differently.
local GLYPH = {
  running = icons.status.running,
  completed = icons.status.completed,
  failed = icons.status.failed,
  canceled = icons.status.canceled,
}

local STATUS_HL = {
  running = "PaseoToolRunning",
  completed = "PaseoToolOk",
  failed = "PaseoToolFail",
  canceled = "PaseoDim",
}

---What the card's EDGE is drawn in -- the accent bar on an unframed style,
---the box on a framed one.
---
---Loudness tracks how much you need to look. A failure gets the accent at full
---strength; a command that is still running gets amber, because it is the
---other thing worth glancing at; and a call that SUCCEEDED -- which is most of
---a transcript -- gets a muted stop off the ramp. A long run of full-strength
---green edges is a wall of colour saying "everything is fine", which is the
---one message that does not need saying loudly.
local EDGE_HL = {
  running = "PaseoToolRunning",
  completed = "PaseoGreen2",
  failed = "PaseoToolFail",
  canceled = "PaseoTextFaint",
}

---The accent plate a card wears for the moment it settles.
---
---A tinted background rather than a brighter foreground: the card is already
---drawn in its status colour, so turning that colour up says nothing. A plate
---appearing and going is a change of SHAPE, which is what the eye catches in
---peripheral vision -- and catching it there is the whole point, because you
---are usually reading something else when a command finishes.
local FLASH_HL = {
  completed = "PaseoGreenTile",
  failed = "PaseoRedTile",
  canceled = "PaseoYellowTile",
}

---A stable key for one tool call's flash.
---@param item table
---@return string
function M.flash_key(item)
  return "tool." .. tostring(item.callId or item.id or item.name or "")
end

---Paths are shown relative to cwd where possible. An agent working in a
---worktree emits absolute paths, and a column of `/home/milind/.paseo/
---worktrees/29oge70y/ws-ui-change/lua/…` is all prefix and no information.
---@param path string|nil
---@return string
local function short_path(path)
  if not path or path == "" then
    return "?"
  end
  return vim.fn.fnamemodify(path, ":~:.")
end

---A value out of a tool's raw input or output, as ONE string.
---
---JSON, not `vim.inspect`: inspect renders Lua, and the decoder hands us
---`vim.empty_dict()` for a JSON `{}` -- so an argument-less call rendered as
---the literal text `vim.empty_dict()`, which is a sentinel from the transport
---and says nothing about the call.
---@param value any
---@return string
local function as_text(value)
  if type(value) == "string" then
    return value
  end
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or tostring(value)
end

---Nothing worth drawing: absent, or an empty table however it was decoded.
---@param value any
---@return boolean
local function blank(value)
  return value == nil or (type(value) == "table" and vim.tbl_isempty(value))
end

---Cut to `limit` CHARACTERS, not bytes -- `sub` on a byte offset lands inside
---a multibyte sequence and writes a broken one into the buffer, and a tool's
---arguments are exactly where a path with an accent in it turns up.
---@param text string
---@param limit integer
---@return string
local function clip(text, limit)
  if vim.fn.strchars(text) <= limit then
    return text
  end
  return vim.fn.strcharpart(text, 0, limit) .. "…"
end

---@param text string|nil
---@param limit integer
---@return string[]
local function tail_lines(text, limit)
  local all = vim.split(text or "", "\n", { plain = true })
  -- Drop a trailing empty line so a command ending in a newline does not show
  -- a blank final row inside its card.
  if all[#all] == "" then
    table.remove(all)
  end
  if #all <= limit then
    return all
  end
  return vim.list_slice(all, #all - limit + 1, #all)
end

-- ------------------------------------------------------- tool detail bodies

---The body of a call nothing here has a schema for -- an MCP tool, mostly, and
---EVERY tool call for its first few frames.
---
---That second case is the one that matters. The daemon emits a `tool_call` the
---moment the model names the tool and fills `detail` in only once the arguments
---have finished streaming, so every call arrives as `{ type = "unknown", input
---= {} }` first. A running card draws open, so that frame is on screen -- and
---this arm used to draw it as `vim.inspect(detail.input)`, which for an empty
---table is the literal text `vim.empty_dict()`. A sub-agent, whose prompt is
---long enough to stream for seconds, sat there saying it.
---
---So: nothing at all until there is something, then the arguments by name, then
---what the tool answered -- which this never showed, leaving an expanded MCP
---card as a header and a blank.
---@param detail table
---@param inner integer
---@return table[][]
local function unknown_body(detail, inner)
  local lines = {}

  local input = detail.input
  if type(input) == "table" and not blank(input) then
    local keys = vim.tbl_keys(input)
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      -- A colon, not two spaces: `render.wrap` re-splits on whitespace, so any
      -- run of spaces inside the text collapses to one and the label stops
      -- reading as a label.
      local text = ("%s: %s"):format(key, clip(as_text(input[key]), inner * 3))
      vim.list_extend(lines, render.wrap(text, inner, "PaseoToolArg"))
    end
  elseif input ~= nil and type(input) ~= "table" then
    vim.list_extend(lines, render.wrap(as_text(input), inner, "PaseoToolArg"))
  end

  -- Unwrapped one level: the daemon returns an MCP result as `{ output = … }`,
  -- and the outer key is a word of noise in front of every one of them.
  local output = detail.output
  if type(output) == "table" and vim.tbl_count(output) == 1 and output.output ~= nil then
    output = output.output
  end
  if not blank(output) then
    vim.list_extend(lines, render.wrap(clip(as_text(output), inner * 12), inner, "PaseoDim"))
  end

  return lines
end

---The expanded body of a tool card, per detail type.
---
---Each arm answers "what did this actually do", which is the question the old
---UI could not answer at all because none of this reached Neovim.
---@param detail table|nil
---@param width integer
---@return table[][]
local function detail_body(detail, width, summary)
  if not detail then
    return {}
  end
  local inner = math.max(10, render.card_inner(width))
  local lines = {}

  if detail.type == "shell" then
    -- The command is already the card's SUMMARY, in the header. Repeating it
    -- as the body's first line spent a row of an expanded card saying what the
    -- row above it just said; `summary` is only elided when it was truncated,
    -- and then the full text is worth having.
    if detail.command and detail.command ~= summary then
      vim.list_extend(lines, render.wrap(detail.command, inner, "PaseoToolArg"))
    end
    for _, line in ipairs(tail_lines(detail.output, 20)) do
      lines[#lines + 1] = { { line, "PaseoDim" } }
    end
    if detail.exitCode ~= nil and detail.exitCode ~= 0 then
      lines[#lines + 1] = { { "exit " .. tostring(detail.exitCode), "PaseoToolFail" } }
    end
  elseif detail.type == "read" then
    local where = short_path(detail.filePath)
    if detail.offset then
      where = ("%s:%d"):format(where, detail.offset)
      if detail.limit then
        where = ("%s-%d"):format(where, detail.offset + detail.limit)
      end
    end
    -- Only when it says something the header does not. A read with a line
    -- range does; a plain read repeats the summary exactly.
    if where ~= short_path(summary) then
      lines[#lines + 1] = { { where, "PaseoPath" } }
    end
    for _, line in ipairs(vim.list_slice(vim.split(detail.content or "", "\n"), 1, 20)) do
      lines[#lines + 1] = { { line, "PaseoDim" } }
    end
  elseif detail.type == "edit" then
    if short_path(detail.filePath) ~= short_path(summary) then
      lines[#lines + 1] = { { short_path(detail.filePath), "PaseoPath" } }
    end
    -- A unified diff is the one thing worth showing in full colour: it is the
    -- change you are about to accept.
    for _, line in ipairs(vim.list_slice(vim.split(detail.unifiedDiff or "", "\n"), 1, 40)) do
      local hl = "PaseoDim"
      if line:match "^%+" then
        hl = "PaseoAdd"
      elseif line:match "^%-" then
        hl = "PaseoDel"
      elseif line:match "^@@" then
        hl = "PaseoHeader"
      end
      lines[#lines + 1] = { { line, hl } }
    end
  elseif detail.type == "write" then
    if short_path(detail.filePath) ~= short_path(summary) then
      lines[#lines + 1] = { { short_path(detail.filePath), "PaseoPath" } }
    end
    local content = detail.content or ""
    if content ~= "" then
      lines[#lines + 1] = {
        { ("%d bytes, %d lines"):format(#content, #vim.split(content, "\n")), "PaseoDim" },
      }
    end
  elseif detail.type == "search" then
    lines[#lines + 1] = { { detail.query or "", "PaseoToolArg" } }
    if detail.numMatches or detail.numFiles then
      lines[#lines + 1] = {
        {
          ("%s match(es) in %s file(s)"):format(
            tostring(detail.numMatches or "?"),
            tostring(detail.numFiles or "?")
          ),
          "PaseoDim",
        },
      }
    end
    for _, path in ipairs(vim.list_slice(detail.filePaths or {}, 1, 15)) do
      lines[#lines + 1] = { { short_path(path), "PaseoPath" } }
    end
  elseif detail.type == "fetch" then
    lines[#lines + 1] = { { detail.url or "", "PaseoPath" } }
    if detail.codeText or detail.code then
      lines[#lines + 1] = {
        { tostring(detail.codeText or detail.code), "PaseoDim" },
      }
    end
  elseif detail.type == "sub_agent" then
    -- A sub-agent's `description` IS its summary -- `buildToolCallDisplayModel`
    -- takes one straight from the other -- so drawing it here put the same
    -- sentence on the header line and on the line under it. Guarded the way the
    -- shell and read arms already guard theirs; what the header cannot say is
    -- the list of actions below.
    if detail.description and detail.description ~= summary then
      vim.list_extend(lines, render.wrap(detail.description, inner, "PaseoDim"))
    end
    for _, action in ipairs(detail.actions or {}) do
      lines[#lines + 1] = {
        { "· ", "PaseoDim" },
        { action.toolName or "?", "PaseoToolName" },
        { " " .. (action.summary or ""), "PaseoDim" },
      }
    end

    -- `actions` is empty for the whole of a Claude sub-agent's run -- measured,
    -- over two of them: 64 updates, `#actions == 0` in every one. `log` is
    -- where that provider puts the work, one `[Tool] summary` line per call,
    -- and without it an expanded sub-agent card was a header and a blank for
    -- the minute you most wanted to watch it.
    if #(detail.actions or {}) == 0 and detail.log and detail.log ~= "" then
      for _, line in ipairs(tail_lines(detail.log, 12)) do
        lines[#lines + 1] = render.truncate({ { "· ", "PaseoDim" }, { line, "PaseoDim" } }, inner)
      end
    end
  elseif detail.type == "worktree_setup" then
    -- The one detail type with no arm here, so an expanded worktree-setup card
    -- was a header and nothing else -- on exactly the operation you most want
    -- to watch, because it is the one that runs your own setup commands and
    -- the one whose failure leaves a worktree you cannot build in.
    lines[#lines + 1] = { { detail.worktreePath or "", "PaseoPath" } }
    if detail.branchName then
      lines[#lines + 1] = { { detail.branchName, "PaseoDim" } }
    end
    for _, command in ipairs(detail.commands or {}) do
      local glyph, group = icons.status.pending, "PaseoDim"
      if command.status == "completed" then
        glyph, group = icons.status.completed, "PaseoToolOk"
      elseif command.status == "failed" then
        glyph, group = icons.status.failed, "PaseoToolFail"
      end
      local line = {
        { glyph .. " ", group },
        { command.command or "", "PaseoToolName" },
      }
      if command.exitCode and command.exitCode ~= 0 then
        line[#line + 1] = { (" exit %d"):format(command.exitCode), "PaseoToolFail" }
      end
      lines[#lines + 1] = render.truncate(line, inner)
    end
    if detail.truncated then
      lines[#lines + 1] = { { "…truncated", "PaseoDim" } }
    end
  elseif detail.type == "plan" or detail.type == "plain_text" then
    vim.list_extend(lines, render.wrap(detail.text or "", inner, "PaseoDim"))
  elseif detail.type == "unknown" then
    vim.list_extend(lines, unknown_body(detail, inner))
  end

  return lines
end

---The body a permission dialog shows for a request's `detail`. Exposed so the
---dialog does not reimplement any of the above.
---@param detail table|nil
---@param width integer
---@return table[][]
function M.detail_body(detail, width, summary)
  return detail_body(detail, width, summary)
end

-- ------------------------------------------------------------------- cards

---@param item table
---@param opts { width: integer, expanded?: boolean }
---@return table[][]
local function tool_card(item, opts)
  local status = item.status or "running"
  local display = item.display or {}
  local name = display.displayName or item.name or "tool"

  -- Mid-settle, the status glyph wears its accent plate; the rest of the
  -- header is untouched, so the flash is a mark appearing beside the name
  -- rather than the whole line changing colour.
  local flashing = require("paseo.ui.animate").flash_stop(M.flash_key(item)) ~= nil
  local status_hl = (flashing and FLASH_HL[status]) or STATUS_HL[status] or "PaseoDim"

  local header = {
    { GLYPH[status] or icons.status.pending, status_hl },
    { " " .. name, "PaseoToolName" },
  }

  -- `summary` is the daemon's own one-line description of the call -- the
  -- command for a shell, the path for a read. Using it rather than picking
  -- fields out of `detail` ourselves is what keeps this correct across
  -- providers that name their tools differently.
  local summary = display.summary
  if summary and summary ~= "" then
    if
      item.detail
      and (item.detail.type == "read" or item.detail.type == "edit" or item.detail.type == "write")
    then
      summary = short_path(summary)
    end
    header[#header + 1] = { "  " .. summary, "PaseoToolArg" }
  end

  if not opts.expanded then
    -- Collapsed: one line. An error still shows, because a failure you have to
    -- expand to notice is a failure you will not notice.
    if display.errorText or item.error then
      header[#header + 1] = { "  " .. tostring(display.errorText or item.error), "PaseoToolFail" }
    end
    return render.card(header, {}, { width = opts.width, hl = EDGE_HL[status] })
  end

  local body = detail_body(item.detail, opts.width, display.summary)
  if display.errorText or item.error then
    body[#body + 1] = { { tostring(display.errorText or item.error), "PaseoToolFail" } }
  end
  return render.card(header, body, { width = opts.width, hl = EDGE_HL[status] })
end

---Build the lines for one item.
---
---Returns the lines plus whether the item can be expanded, so the transcript
---knows which blocks `<Tab>` should act on.
---@param item table
---@param opts { width: integer, expanded?: boolean }
---@return { lines: table[][], collapsible: boolean }
function M.card(item, opts)
  local width = opts.width
  local kind = item.kind

  if kind == "user" then
    local lines = { { { "", "PaseoDim" } }, { { "▌ you", "PaseoYou" } } }
    vim.list_extend(lines, render.wrap(item.text or "", width, nil, { { "▌ ", "PaseoYou" } }))
    return { lines = lines, collapsible = false }
  end

  if kind == "text" then
    local lines = { { { "", "PaseoDim" } } }
    vim.list_extend(lines, render.wrap(item.text or "", width, nil))
    return { lines = lines, collapsible = false }
  end

  if kind == "thinking" then
    local first = vim.split(vim.trim(item.text or ""), "\n", { plain = true })[1] or ""
    if not opts.expanded then
      return {
        lines = {
          {
            { icons.status.thinking .. " ", "PaseoThinking" },
            { render.width { { first } } > 0 and first or "thinking…", "PaseoThinking" },
          },
        },
        collapsible = true,
      }
    end
    local lines = { { { icons.status.thinking .. " thinking", "PaseoThinking" } } }
    vim.list_extend(
      lines,
      render.wrap(item.text or "", width, "PaseoThinking", { { "  ", "PaseoThinking" } })
    )
    return { lines = lines, collapsible = true }
  end

  if kind == "tool" then
    return { lines = tool_card(item, opts), collapsible = true }
  end

  if kind == "todo" then
    local lines = { { { icons.status.todo .. " plan", "PaseoHeader" } } }
    for _, task in ipairs(item.items or {}) do
      -- From the registry, like every other status marker. A plan item and a
      -- tool card say the same three things about the same three states, and
      -- these were the one place still spelling them out.
      local mark = task.status == "completed" and icons.status.completed
        or task.status == "in_progress" and icons.status.running
        or icons.status.pending
      local hl = task.status == "completed" and "PaseoToolOk"
        or task.status == "in_progress" and "PaseoToolRunning"
        or "PaseoDim"
      lines[#lines + 1] = { { "  " .. mark .. " ", hl }, { task.text or "", hl } }
    end
    return { lines = lines, collapsible = false }
  end

  if kind == "notice" then
    local hl = item.level == "error" and "PaseoToolFail"
      or item.level == "warning" and "PaseoToolRunning"
      or "PaseoDim"
    return {
      lines = render.wrap(item.message or "", width, hl, { { " ", hl } }),
      collapsible = false,
    }
  end

  if kind == "compaction" then
    local text = item.status == "completed" and "context compacted" or "compacting context…"
    if item.preTokens then
      text = ("%s (was %s tokens)"):format(text, tostring(item.preTokens))
    end
    return { lines = { { { " " .. text, "PaseoDim" } } }, collapsible = false }
  end

  -- A request rendered INLINE, so the permission is in the log and answerable
  -- even when the dialog was dismissed.
  if kind == "permission" then
    local request = item.request or {}
    -- A plan is not a danger, here for the same reason it is not one in the
    -- dialog: the agent is proposing, not reaching for the filesystem.
    local planned = plan.parse(request)
    local group = planned and "PaseoQuestion" or "PaseoDanger"
    local header = {
      { "", group },
      { " " .. (planned and "plan" or (request.title or request.name or "permission")), group },
    }
    if item.resolution then
      header[#header + 1] = { "  " .. item.resolution, "PaseoDim" }
    else
      header[#header + 1] = { "  awaiting", "PaseoBadge" }
    end
    local body = {}
    -- A question's `title` is its FIRST question and `description` its labels,
    -- so a request carrying four rendered here as one. Render the questions
    -- themselves when there are any.
    local asked = questions.parse(request)
    if asked then
      for _, line in ipairs(questions.render(asked)) do
        vim.list_extend(body, render.wrap(line, render.card_inner(width), "PaseoDim"))
      end
    elseif planned then
      -- The plan lives in `input.plan` and the request has no `detail` at all,
      -- so `description` -- a summary line, at best -- was the whole record of
      -- what was approved.
      for _, line in ipairs(plan.render(request)) do
        vim.list_extend(body, render.wrap(line, render.card_inner(width), "PaseoDim"))
      end
    elseif request.description and request.description ~= "" then
      vim.list_extend(body, render.wrap(request.description, render.card_inner(width), "PaseoDim"))
    end
    vim.list_extend(body, detail_body(request.detail, width))
    return { lines = render.card(header, body, { width = width, hl = group }), collapsible = false }
  end

  return { lines = {}, collapsible = false }
end

return M
