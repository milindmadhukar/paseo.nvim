--- Drawing: cards, the timeline, the transcript.
---
--- All pure, so all of it runs headlessly.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local render = require "paseo.ui.render"
local timeline = require "paseo.ui.timeline"
local transcript = require "paseo.ui.transcript"

local function test_render()
  require("paseo.ui.hl").setup()

  -- Every module has to at least load, same reason as the bridge suite.
  for _, name in ipairs {
    "paseo.ui.hl",
    "paseo.ui.render",
    "paseo.ui.timeline",
    "paseo.ui.transcript",
    "paseo.ui.permission",
  } do
    truthy("ui: " .. name .. " loads", (pcall(require, name)))
  end

  -- ---------------------------------------------------------------- render

  -- A card whose lines are not all exactly the requested width draws a ragged
  -- right edge, which is what every box-drawing bug looks like.
  --
  -- Pinned to a FRAMED style. The width invariant is a property of having a
  -- right-hand border to line up: an unframed card has no right edge, and
  -- padding one to full width would put trailing whitespace on every line of a
  -- buffer the user yanks out of. That is asserted separately below.
  local card = render.card(
    { { "Shell", "PaseoToolOk" } },
    { { { "ls -la" } }, { { "a.txt" } } },
    { width = 40, kind = "rounded" }
  )
  local ragged
  for _, line in ipairs(card) do
    if render.width(line) ~= 40 then
      ragged = render.concat(line)
    end
  end
  eq("ui: every framed card line is exactly the requested width", ragged, nil)

  -- Found by real agent history, not by a fixture: a multi-line shell command
  -- comes back with newlines in `display.summary`, and nvim_buf_set_lines
  -- rejects a line containing one ("'replacement string' item contains
  -- newlines"). A single heredoc in a transcript was enough to hit it.
  local newline_card = render.card(
    { { "Shell", "PaseoToolName" }, { "cat <<EOF\nhello\nEOF", "PaseoToolArg" } },
    {},
    { width = 50, kind = "rounded" }
  )
  eq(
    "ui: a cell containing a newline is flattened, not passed through",
    render.concat(newline_card[1]):find("\n", 1, true),
    nil
  )
  eq("ui: and the card is still exactly its width", render.width(newline_card[1]), 50)

  -- Also from real data: a header long enough to be truncated used the body's
  -- width budget, which does not account for the opening "╭─ " and the closing
  -- corner, so every truncated card came out one column too wide.
  local long = render.card(
    { { string.rep("x", 400), "PaseoToolArg" } },
    { { { string.rep("y", 400) } } },
    { width = 60, kind = "rounded" }
  )
  local widths = {}
  for _, line in ipairs(long) do
    widths[#widths + 1] = render.width(line)
  end
  eq("ui: a truncated header does not overflow the card", widths, { 60, 60, 60 })

  -- Every style has to hold two invariants, whatever it does in between: a
  -- collapsed card is one line, and nothing overflows the width it was given.
  -- Those are the two that break the transcript rather than merely looking
  -- wrong -- an over-wide line soft-wraps and a multi-line "collapsed" card
  -- makes a fold of one fact.
  for _, kind in ipairs { "plate", "rule", "rounded", "square" } do
    eq(
      "ui: a card with no body is a single line -- " .. kind,
      #render.card({ { "x" } }, {}, { width = 40, kind = kind }),
      1
    )

    local over
    for _, line in
      ipairs(
        render.card(
          { { string.rep("x", 400) } },
          { { { string.rep("y", 400) } }, { { "short" } } },
          { width = 40, kind = kind }
        )
      )
    do
      if render.width(line) > 40 then
        over = render.width(line)
      end
    end
    eq("ui: no card line overflows its width -- " .. kind, over, nil)
  end

  -- An unframed card must NOT pad: these lines are real buffer text, and
  -- trailing whitespace on every row of a tool card is whitespace in whatever
  -- the reader yanks out of the transcript.
  local unpadded
  for _, line in
    ipairs(render.card({ { "Shell" } }, { { { "ls -la" } } }, { width = 40, kind = "plate" }))
  do
    if render.concat(line):match "%s$" then
      unpadded = render.concat(line)
    end
  end
  eq("ui: an unframed card does not pad to width", unpadded, nil)

  -- Extmark columns are BYTES; widths are display columns. Box-drawing and the
  -- status glyphs make the two differ on literally every card line.
  local buf = vim.api.nvim_create_buf(false, true)
  render.to_buffer(buf, require("paseo.ui.hl").ns, 0, -1, {
    { { "│ ", "PaseoBorder" }, { "ok", "PaseoToolOk" } },
  })
  local marks =
    vim.api.nvim_buf_get_extmarks(buf, require("paseo.ui.hl").ns, 0, -1, { details = true })
  local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  local second = marks[2]
  eq(
    "ui: extmark columns are byte offsets, not display columns",
    second and text:sub(second[3] + 1, second[4].end_col),
    "ok"
  )

  -- Highlights must outrank treesitter: the transcript is a markdown buffer and
  -- markdown's captures sit at the default priority of 100.
  truthy("ui: transcript highlights outrank treesitter", marks[1] and marks[1][4].priority == 200)
end

local function test_timeline()
  -- ------------------------------------------------------------- timeline

  -- The whole complaint: the agent reading a file and running commands was
  -- invisible. Each of these must produce something.
  for _, case in ipairs {
    { "shell", { type = "shell", command = "ls -la", output = "a\nb", exitCode = 0 } },
    { "read", { type = "read", filePath = "/tmp/a.lua", offset = 1, limit = 20 } },
    { "edit", { type = "edit", filePath = "/tmp/a.lua", unifiedDiff = "@@ -1 +1 @@\n-a\n+b" } },
    { "write", { type = "write", filePath = "/tmp/a.lua", content = "x\ny" } },
    { "search", { type = "search", query = "foo", numFiles = 2, numMatches = 7 } },
    { "fetch", { type = "fetch", url = "https://example.com", code = 200 } },
    { "sub_agent", { type = "sub_agent", description = "explore", log = "", actions = {} } },
    { "plan", { type = "plan", text = "do the thing" } },
    { "plain_text", { type = "plain_text", text = "note" } },
    { "unknown", { type = "unknown", input = { a = 1 }, output = nil } },
  } do
    local built = timeline.card({
      kind = "tool",
      callId = "c",
      name = "T",
      status = "completed",
      display = { displayName = "T", summary = "s" },
      detail = case[2],
    }, { width = 60, expanded = true })
    truthy("ui: a " .. case[1] .. " tool call renders", #built.lines > 0)
  end

  -- The state EVERY tool call passes through: the daemon emits the call as soon
  -- as the model names it and fills `detail` in once the arguments have finished
  -- streaming. A running card draws open, so this frame is on screen -- and it
  -- used to draw `vim.inspect(detail.input)`, which for an empty table is the
  -- literal text `vim.empty_dict()`. That is what the Paseo app showed as a bare
  -- header and Neovim showed as a Lua sentinel, side by side in one screenshot.
  ---@param lines table[][]
  ---@return string
  local function flat(lines)
    return table.concat(vim.tbl_map(render.concat, lines), "\n")
  end

  local streaming =
    flat(timeline.detail_body({ type = "unknown", input = vim.empty_dict(), output = nil }, 60))
  eq("ui: a tool call whose arguments have not arrived has no body", streaming, "")

  local mcp = flat(timeline.detail_body({
    type = "unknown",
    input = { limit = 30, cwd = "/tmp" },
    -- The daemon wraps an MCP result in one `output` key; the outer key is a
    -- word of noise in front of every one of them.
    output = { output = { agents = { "a", "b" } } },
  }, 60))
  truthy("ui: an unknown tool names its arguments", mcp:find("limit: 30", 1, true) ~= nil, mcp)
  truthy("ui: and shows what it answered", mcp:find("agents", 1, true) ~= nil, mcp)
  truthy("ui: and never leaks a Lua sentinel", mcp:find("empty_dict", 1, true) == nil, mcp)

  -- `buildToolCallDisplayModel` takes a sub-agent's summary straight from its
  -- description, so rendering the description in the body put the same sentence
  -- on the header line and on the line under it.
  local delegated = flat(timeline.detail_body({
    type = "sub_agent",
    subAgentType = "Explore",
    description = "Explore workspace.toml in paseo.nvim",
    log = "",
    actions = { { index = 1, toolName = "Grep", summary = "workspace.toml" } },
  }, 60, "Explore workspace.toml in paseo.nvim"))
  eq(
    "ui: a sub-agent does not repeat its summary in its body",
    select(2, delegated:gsub("Explore workspace%.toml", "")),
    0
  )
  truthy("ui: but does list what it did", delegated:find("Grep", 1, true) ~= nil, delegated)

  -- Reasoning is the "thinking steps" half of the complaint.
  local thought = timeline.card({ kind = "thinking", text = "line one\nline two" }, { width = 60 })
  truthy("ui: reasoning renders", #thought.lines > 0)
  truthy("ui: reasoning is collapsible", thought.collapsible)
  -- Two, not one: every card leads with the blank line that separates it from
  -- whatever is above it -- `timeline.card` owns that gap now rather than the
  -- two arms that used to hand-roll it. The collapsed thought is still ONE
  -- line of content.
  eq("ui: reasoning collapses to one line", #thought.lines, 2)

  -- A failure you have to expand to notice is a failure you will not notice.
  local failed = timeline.card({
    kind = "tool",
    callId = "c",
    name = "T",
    status = "failed",
    error = "boom",
    display = { displayName = "T", errorText = "exit 1" },
    detail = { type = "shell", command = "false" },
  }, { width = 60 })
  truthy(
    "ui: a failed tool call shows its error while collapsed",
    render.concat(failed.lines[2]):find("exit 1", 1, true) ~= nil
  )

  -- The one detail type with no arm, on exactly the operation you most want to
  -- watch: an expanded worktree-setup card used to be a header and nothing
  -- else, so a setup command that failed left a worktree you cannot build in
  -- and no way to see which command did it.
  local setup = table.concat(
    vim.tbl_map(
      render.concat,
      timeline.detail_body({
        type = "worktree_setup",
        worktreePath = "/tmp/wt",
        branchName = "ws/thing",
        commands = {
          { index = 1, command = "bun install", status = "completed", exitCode = 0 },
          { index = 2, command = "bun run build", status = "failed", exitCode = 2 },
        },
      }, 60)
    ),
    "\n"
  )
  truthy("ui: a worktree setup names its branch", setup:find("ws/thing", 1, true) ~= nil)
  truthy("ui: and each command it ran", setup:find("bun run build", 1, true) ~= nil)
  truthy("ui: and how the failing one failed", setup:find("exit 2", 1, true) ~= nil)
end

local function test_transcript()
  -- ----------------------------------------------------------- transcript

  local chat = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(chat)

  transcript.upsert(chat, { kind = "user", text = "run ls" })
  transcript.upsert(chat, {
    kind = "tool",
    callId = "call-1",
    name = "Bash",
    status = "running",
    display = { displayName = "Shell", summary = "ls -la" },
    detail = { type = "shell", command = "ls -la" },
  })
  -- Content arriving BELOW the running card is what makes its line number go
  -- stale, which is why blocks are anchored by extmark rather than by row.
  transcript.upsert(chat, { kind = "thinking", text = "waiting" })
  transcript.stream(chat, "Run")
  transcript.stream(chat, "ning.")

  -- A command is open WHILE it runs, under the default `ui.expand = "running"`.
  -- Watching the output arrive is the whole reason to have this window open;
  -- a card that hides it until you press <Tab> is a card that tells you the
  -- agent is busy and nothing else.
  truthy(
    "ui: a running command shows its output as it arrives",
    chat.blocks[chat.by_call["call-1"]].expanded
  )

  local before = vim.api.nvim_buf_line_count(chat.conversation)
  transcript.upsert(chat, {
    kind = "tool",
    callId = "call-1",
    name = "Bash",
    status = "completed",
    display = { displayName = "Shell", summary = "ls -la" },
    detail = { type = "shell", command = "ls -la", output = "a.txt", exitCode = 0 },
  })

  -- The regression this guards: a tool call arrives TWICE, running then
  -- completed. Appending the second one prints every command in the
  -- transcript twice, so the transcript must never get LONGER here.
  --
  -- It used to assert "shorter", which was a proxy: the running card spent a
  -- body row repeating its own command, so folding always removed at least
  -- that row. The card no longer repeats it -- the command is already the
  -- header's summary -- so a command that has produced no output yet is the
  -- same height open or folded, which is correct rather than a regression.
  -- The block count below is the assertion that actually catches a duplicate.
  truthy(
    "ui: a completing tool call replaces its card rather than appending",
    vim.api.nvim_buf_line_count(chat.conversation) <= before,
    ("%d -> %d"):format(before, vim.api.nvim_buf_line_count(chat.conversation))
  )
  truthy("ui: and folds once it has succeeded", not chat.blocks[chat.by_call["call-1"]].expanded)
  local blocks = 0
  for _ in pairs(chat.blocks) do
    blocks = blocks + 1
  end
  eq("ui: and does not create a second block", blocks, 4)

  -- THE LIVE STREAM IS NOT THE PROJECTED ONE, and a sub-agent is where the two
  -- part company. Captured off a real daemon, one `callId` goes:
  --
  --     Agent  unknown    input={}          x4   while the input streams
  --     Task   sub_agent  subAgentType=…    x32  for the whole of its run
  --     Agent  unknown    input={prompt…}   x1   its terminal event
  --
  -- The last one knows LESS than the 32 before it. Taking each event whole made
  -- the card read `Explore  Find RSS feed fetching` for a minute and then fall
  -- back, at the instant the sub-agent SUCCEEDED, to `Agent` over a dump of the
  -- prompt -- while `timeline.history`, which asks for the projected view, drew
  -- the same call correctly. That is the pair of screenshots this came from.
  local delegate = {
    kind = "tool",
    callId = "call-sub",
    name = "Task",
    status = "running",
    display = { displayName = "Explore", summary = "Find RSS feed fetching" },
    detail = {
      type = "sub_agent",
      subAgentType = "Explore",
      description = "Find RSS feed fetching",
      log = "[Bash] ls",
      actions = {},
    },
  }
  local sub_chat = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(sub_chat)
  transcript.upsert(sub_chat, delegate)
  transcript.upsert(sub_chat, {
    kind = "tool",
    callId = "call-sub",
    name = "Agent",
    status = "completed",
    display = { displayName = "Agent" },
    detail = { type = "unknown", input = { description = "Find RSS feed fetching" } },
  })
  local settled = sub_chat.blocks[sub_chat.by_call["call-sub"]].item
  eq("ui: a finished sub-agent keeps the name it ran under", settled.display.displayName, "Explore")
  eq("ui: and its detail", settled.detail.type, "sub_agent")
  eq("ui: while still settling to its terminal status", settled.status, "completed")

  -- An error only exists on the terminal event, so that much must still cross.
  transcript.upsert(sub_chat, {
    kind = "tool",
    callId = "call-sub",
    name = "Agent",
    status = "failed",
    display = { displayName = "Agent", errorText = "sub-agent failed" },
    detail = { type = "unknown", input = {} },
  })
  local broke = sub_chat.blocks[sub_chat.by_call["call-sub"]].item
  eq(
    "ui: a failure carries its error across the merge",
    broke.display.errorText,
    "sub-agent failed"
  )
  eq("ui: and still says who failed", broke.display.displayName, "Explore")

  -- And with output to fold away, it does shrink -- which is the visible half
  -- of "the card folds on success". Asserted against `timeline.card`, which is
  -- the pure function that decides a card's height, rather than by pushing
  -- another block through the shared transcript this section goes on to make
  -- assertions about.
  local card = require "paseo.ui.timeline"
  local ran = card.card({
    kind = "tool",
    callId = "c",
    name = "Bash",
    status = "running",
    display = { displayName = "Shell", summary = "wc -l" },
    detail = { type = "shell", command = "wc -l", output = "1\n2\n3" },
  }, { width = 60, expanded = true })
  local folded = card.card({
    kind = "tool",
    callId = "c",
    name = "Bash",
    status = "completed",
    display = { displayName = "Shell", summary = "wc -l" },
    detail = { type = "shell", command = "wc -l", output = "1\n2\n3", exitCode = 0 },
  }, { width = 60, expanded = false })
  truthy(
    "ui: a card with output folds smaller than it ran",
    #(folded.lines or folded) < #(ran.lines or ran),
    ("%d open, %d folded"):format(#(ran.lines or ran), #(folded.lines or folded))
  )

  -- The command is the header's summary; repeating it as the body's first line
  -- spent a row saying what the row above it had just said.
  local body = ""
  for _, line in ipairs(ran.lines or ran) do
    for _, cell in ipairs(line) do
      body = body .. cell[1]
    end
  end
  local occurrences = select(2, body:gsub("wc %-l", ""))
  eq("ui: and does not print its command twice", occurrences, 1)

  local joined = table.concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
  -- Named through the registry, not pasted in. A literal glyph in a test is
  -- the same fragile thing as a literal glyph in the source -- and when the
  -- source one went missing, a test holding its own copy would have gone on
  -- passing while the card drew nothing.
  local glyphs = require "paseo.ui.icons"
  truthy(
    "ui: the completed card shows its terminal status",
    joined:find(glyphs.status.completed, 1, true) ~= nil
  )
  truthy(
    "ui: and no longer shows the running one",
    joined:find(glyphs.status.running, 1, true) == nil
  )

  -- Streamed chunks must join: a reply delivered as "Run" + "ning." renders
  -- "Running.", not two lines.
  truthy("ui: streamed chunks join into one block", joined:find("Running.", 1, true) ~= nil)

  -- Expanding grows the card and pushes everything below it down; the anchors
  -- must survive that, or the next replace lands in the wrong place.
  local tool = chat.blocks[chat.by_call["call-1"]]
  tool.expanded = true
  transcript.rerender(chat, tool)
  truthy(
    "ui: expanding a card reveals its output",
    table
      .concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("a.txt", 1, true) ~= nil
  )
  eq(
    "ui: anchors survive a block changing height",
    #vim.api.nvim_buf_get_extmarks(chat.conversation, require("paseo.ui.hl").ns_anchor, 0, -1, {}),
    4
  )

  -- A CARD THAT SHRINKS MUST NOT TAKE THE ONE BELOW IT WITH IT.
  --
  -- `nvim_buf_set_lines(row, row + height)` spans `(row,0)`-`(row+height,0)`,
  -- and every anchor used to be left-gravity -- so the NEXT block's anchor,
  -- sitting exactly on that far boundary, collapsed onto `row` the moment a
  -- card got shorter. The next redraw then wrote over the card above it. A tool
  -- card shrinks when it folds on success, so two calls launched together left
  -- one card and a wreck: watched live, a finished sub-agent was overwritten by
  -- its sibling.
  local pair = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(pair)
  -- A message first, as a real transcript has. It matters: a scratch buffer
  -- starts with one empty line that the first block inserts ABOVE rather than
  -- replacing, and that stray row puts a gap between the first card's end and
  -- the second card's anchor -- so the boundary the bug needs never lines up.
  transcript.upsert(pair, { kind = "user", text = "go" })
  transcript.upsert(pair, {
    kind = "tool",
    callId = "a",
    name = "Bash",
    status = "running",
    display = { displayName = "Shell", summary = "first" },
    detail = { type = "shell", command = "first", output = "1\n2\n3\n4\n5" },
  })
  transcript.upsert(pair, {
    kind = "tool",
    callId = "b",
    name = "Bash",
    status = "running",
    display = { displayName = "Shell", summary = "second" },
    detail = { type = "shell", command = "second" },
  })
  -- `a` folds: five body rows go away under `b`'s anchor.
  transcript.upsert(pair, {
    kind = "tool",
    callId = "a",
    name = "Bash",
    status = "completed",
    display = { displayName = "Shell", summary = "first" },
    detail = { type = "shell", command = "first", output = "1\n2\n3\n4\n5", exitCode = 0 },
  })
  local both = table.concat(vim.api.nvim_buf_get_lines(pair.conversation, 0, -1, false), "\n")
  truthy("ui: a card that folds keeps its own summary", both:find("first", 1, true) ~= nil, both)
  truthy("ui: and does not overwrite the card below it", both:find("second", 1, true) ~= nil, both)
  local function anchor_of(call)
    local block = pair.blocks[pair.by_call[call]]
    return vim.api.nvim_buf_get_extmark_by_id(
      pair.conversation,
      require("paseo.ui.hl").ns_anchor,
      block.mark,
      {}
    )[1]
  end
  truthy(
    "ui: and the card below still anchors beneath it, not onto it",
    anchor_of "b" > anchor_of "a",
    ("a@%s b@%s"):format(tostring(anchor_of "a"), tostring(anchor_of "b"))
  )

  -- THE BUG THAT MADE EVERY TOOL CARD INVISIBLE, at the only place it was
  -- observable: the shape of the line the sidecar actually writes.
  --
  -- Every other assertion in this file hand-builds an item with `kind` set,
  -- which is exactly why the suite stayed green while the live transcript
  -- rendered nothing at all -- the sidecar used `kind` as the event NAME and
  -- destructured it off the payload, and the renderer dispatches on
  -- `item.kind`. So this one asserts against the wire and not against a
  -- convenient fixture.
  local wire = vim.json.decode(
    '{"event":"tool","agentId":"a","kind":"tool","callId":"wire-1","name":"Bash",'
      .. '"status":"completed","display":{"displayName":"Shell","summary":"echo hi"},'
      .. '"detail":{"type":"shell","command":"echo hi","output":"hi","exitCode":0}}'
  )
  local wire_before = vim.api.nvim_buf_line_count(chat.conversation)
  transcript.upsert(chat, wire)
  truthy(
    "ui: an item in the sidecar's own wire shape renders",
    vim.api.nvim_buf_line_count(chat.conversation) > wire_before
  )

  -- A card you opened by hand is yours. It must not snap shut under you the
  -- moment the command finishes, which is precisely when you are reading it.
  local pinned = chat.blocks[chat.by_call["wire-1"]]
  pinned.expanded = true
  pinned.pinned = true
  transcript.rerender(chat, pinned, vim.tbl_extend("force", wire, { status = "completed" }))
  truthy("ui: a card you opened by hand stays open", pinned.expanded)

  -- `replaced` invalidates the epoch. It was emitted by the sidecar and
  -- listened to by nobody, so a replacement left stale messages on screen.
  chat.permissions = { { id = "req-1" } }
  chat.permission_blocks = { ["req-1"] = 99 }
  transcript.reset(chat)
  eq("ui: reset empties the transcript", vim.api.nvim_buf_line_count(chat.conversation), 1)
  eq("ui: and drops the callId map", next(chat.by_call), nil)
  -- The permission bookkeeping points at blocks that just went away. Left
  -- behind, it named block ids that no longer exist -- so the resolution badge
  -- could never be written -- and made the re-offer that follows a reset hit
  -- the de-duplicate and drop the inline card for good.
  eq("ui: reset drops the held permissions", next(chat.permissions), nil)
  eq("ui: and the blocks they pointed at", next(chat.permission_blocks), nil)
end

--- The transcript's two redraw economies: the width guard and the card memo.
---
--- Both are invisible when they work and silently wrong when they do not, so
--- they are asserted on `changedtick` -- the only thing that answers "did this
--- write to the buffer" without caring what it wrote.
local function test_transcript_cache()
  require("paseo.ui.hl").setup()

  local chat = { conversation = vim.api.nvim_create_buf(false, true) }
  transcript.reset(chat)
  transcript.upsert(chat, { kind = "user", text = "go" })
  transcript.upsert(chat, {
    kind = "tool",
    callId = "c1",
    name = "Bash",
    status = "completed",
    display = { displayName = "Shell", summary = "ls" },
    detail = { type = "shell", command = "ls", output = "a.txt", exitCode = 0 },
  })
  transcript.stream(chat, "done")

  -- A redraw at a width nothing has changed at is a redraw that writes
  -- nothing. This is the whole of the resize fix: a drag fires per column, and
  -- every one of them used to rebuild and rewrite every block.
  local tick = vim.api.nvim_buf_get_changedtick(chat.conversation)
  transcript.redraw(chat)
  eq(
    "ui: the first redraw is already free",
    vim.api.nvim_buf_get_changedtick(chat.conversation),
    tick
  )
  transcript.redraw(chat)
  eq("ui: and so is the second", vim.api.nvim_buf_get_changedtick(chat.conversation), tick)
  eq("ui: redraw records the width it drew at", chat.rendered_width, 72)

  -- `force` is for what the width cannot see -- `ui.style` or `ui.expand`
  -- changing under a live session. It must reach past BOTH economies, so it
  -- invalidates the memo rather than merely skipping the width guard.
  transcript.redraw(chat, { force = true })
  truthy("ui: force redraws anyway", vim.api.nvim_buf_get_changedtick(chat.conversation) > tick)

  -- THE MEMO MUST NOT OUTLIVE AN IN-PLACE MUTATION. `stream` appends onto
  -- `block.item.text` rather than replacing the item, so a cache keyed on the
  -- item alone would show the first chunk forever -- a reply that arrives as
  -- "READ" + "Y" would render as READ.
  transcript.stream(chat, "!!")
  truthy(
    "ui: a streamed chunk survives the card cache",
    table
      .concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("done!!", 1, true) ~= nil
  )

  -- Expansion is in the key, so `<Tab>` needs no invalidation of its own.
  local tool = chat.blocks[chat.by_call["c1"]]
  tool.expanded = true
  tool.pinned = true
  transcript.rerender(chat, tool)
  truthy(
    "ui: expanding through the cache reveals the output",
    table
      .concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("a.txt", 1, true) ~= nil
  )
  tool.expanded = false
  transcript.rerender(chat, tool)
  truthy(
    "ui: and collapsing hides it again",
    table
      .concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("a.txt", 1, true) == nil
  )

  -- A cache that outlived its blocks would guard the refetched history out of
  -- ever being drawn -- `replaced` resets and refetches at the SAME width.
  transcript.reset(chat)
  eq("ui: reset forgets the width it drew at", chat.rendered_width, nil)
  transcript.upsert(chat, { kind = "user", text = "again" })
  truthy(
    "ui: and the new history draws",
    table
      .concat(vim.api.nvim_buf_get_lines(chat.conversation, 0, -1, false), "\n")
      :find("again", 1, true) ~= nil
  )
end

return {
  { "ui.render", test_render },
  { "ui.timeline", test_timeline },
  { "ui.transcript", test_transcript },
  { "ui.transcript.cache", test_transcript_cache },
}
