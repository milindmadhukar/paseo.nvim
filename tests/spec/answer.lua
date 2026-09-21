--- The overlay that answers a question or decides a plan.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

--- The overlay that answers a question or decides a plan.
---
--- Driven with stub handlers rather than a daemon, which is the whole reason
--- |paseo.ui.answer| takes them as an argument: every assertion here is about what
--- is on screen and what comes back out, and none of it needs a socket.
local function test_answer()
  local ask = require "paseo.ui.answer"
  local plan = require "paseo.ui.plan"
  local questions = require "paseo.ui.questions"

  ---A chat with a REAL conversation window, because the overlay anchors to one.
  ---@param width integer
  local function chat_with_window(width)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    vim.cmd "silent only"
    local buf = vim.api.nvim_create_buf(false, true)
    vim.cmd "vsplit"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, width)
    return { root = root, agent_id = "a1", conversation = buf, win_conversation = win }
  end

  ---Everything volt actually drew, as one string.
  ---@param buf integer
  local function drawn(buf)
    local parts = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      for _, cell in ipairs(mark[4].virt_text or {}) do
        parts[#parts + 1] = cell[1]
      end
    end
    return table.concat(parts, " ")
  end

  local function press(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
  end

  local request = {
    id = "ask-1",
    kind = "question",
    name = "AskUserQuestion",
    actions = { { id = "deny", label = "Deny", behavior = "deny" } },
    input = {
      questions = {
        {
          question = "How should I reconcile your local work?",
          header = "Reconcile",
          options = {
            { label = "Rebase", description = "Replay mine on top" },
            { label = "Merge" },
          },
        },
        {
          question = "Which checks should run?",
          header = "Checks",
          multiSelect = true,
          options = { { label = "tests" }, { label = "lint" } },
        },
        { question = "Anything else?", header = "Note", options = {}, allowEmpty = true },
      },
    },
  }

  local asked = questions.parse(request)
  local sent, sent_notes, declined
  local function handlers()
    return {
      submit = function(state)
        sent = questions.answers(state)
        sent_notes = state.notes
      end,
      choose = function() end,
      reject = function(interrupt)
        declined = interrupt and "interrupt" or "deny"
      end,
    }
  end

  local chat = chat_with_window(90)
  ask.open(chat, request, { actions = request.actions, state = questions.state(asked) }, handlers())

  local card = vim.api.nvim_get_current_buf()
  local card_win = vim.api.nvim_get_current_win()

  -- The overlay is volt's, and it is over the CHAT window rather than centred on
  -- the editor. Anchoring is what makes "takes over the chat window" true on
  -- both surfaces without a branch per surface.
  truthy("ask: the card is a volt buffer", require("volt.state")[card] ~= nil)

  -- A description says what an option MEANS, and the half of it that used to
  -- fall off the end of its single row was the half that told it apart from
  -- the option below. Wrapped, it is all there.
  truthy(
    "ask: an option's description is shown in full, not truncated",
    drawn(card):find("Replay mine on top", 1, true) ~= nil,
    drawn(card)
  )
  eq(
    "ask: and is anchored to the chat window",
    vim.api.nvim_win_get_config(card_win).relative,
    "win"
  )
  eq("ask: to THAT chat window", vim.api.nvim_win_get_config(card_win).win, chat.win_conversation)
  truthy(
    "ask: it fits inside it",
    vim.api.nvim_win_get_width(card_win) <= vim.api.nvim_win_get_width(chat.win_conversation)
      and vim.api.nvim_win_get_height(card_win)
        <= vim.api.nvim_win_get_height(chat.win_conversation)
  )

  -- Clickable, which is the half `volt.events.add` alone does not give you.
  local targets = 0
  for _, row in pairs(require("volt.state")[card].clickables) do
    targets = targets + #row
  end
  truthy("ask: the options carry click targets", targets > 0, targets)

  -- ONE question at a time, and the counter is what says so. Both halves matter:
  -- the second question being absent is the feature, and `2 of 3` is what stops
  -- that teaching you the first answer was the whole reply.
  local shown = drawn(card)
  truthy("ask: the first question is drawn", shown:find("reconcile", 1, true) ~= nil, shown)
  eq("ask: and the second is not", shown:find("Which checks", 1, true), nil)
  truthy("ask: the counter says how many there are", shown:find("1 of 3", 1, true) ~= nil, shown)
  truthy("ask: and the hint does not offer to send yet", shown:find "answer this one" ~= nil, shown)

  -- Volt lays a section out by row and never clears, so the window and the
  -- buffer have to agree after a step that changed the line count.
  local function consistent(label)
    local state = require("volt.state")[card]
    eq(
      "ask: " .. label .. " -- volt's height is the buffer's",
      state.h,
      vim.api.nvim_buf_line_count(card)
    )
    eq("ask: " .. label .. " -- and the window's", state.h, vim.api.nvim_win_get_height(card_win))
    local overflow = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(card, -1, 0, -1, {})) do
      if mark[2] >= vim.api.nvim_buf_line_count(card) then
        overflow = overflow + 1
      end
    end
    eq("ask: " .. label .. " -- nothing is drawn past the end", overflow, 0)
  end
  consistent "on open"

  -- Nothing answered yet, so <CR> cannot send. It jumps to the gap instead --
  -- which on the first question means it stays, and says so.
  press "<CR>"
  eq("ask: an incomplete set is not sent", sent, nil)

  -- Single-select replaces and advances, so one keypress moves the stepper on.
  press "1"
  shown = drawn(card)
  truthy("ask: picking advances to the next question", shown:find("2 of 3", 1, true) ~= nil, shown)
  consistent "after stepping"

  -- A picked option KEEPS its description. The focused one explains what you
  -- are deciding; the picked one explains what you are about to send, and an
  -- answer whose meaning vanished the moment you chose it cannot be checked.
  press "<S-Tab>"
  truthy(
    "ask: the option you picked keeps its description",
    drawn(card):find("Replay mine on top", 1, true) ~= nil,
    drawn(card)
  )

  -- `c` writes a note ABOUT that pick -- the caveat the options did not cover.
  press "c"
  local note_box = vim.api.nvim_get_current_buf()
  truthy("ask: `c` opens a box for a note", note_box ~= card and vim.bo[note_box].modifiable)
  vim.api.nvim_buf_set_lines(note_box, 0, -1, false, { "only for new workspaces" })
  press "<CR>"
  truthy(
    "ask: and the note is shown back on the card",
    drawn(card):find("only for new workspaces", 1, true) ~= nil,
    drawn(card)
  )
  press "<Tab>"

  -- Multi-select accumulates and stays put.
  press "1"
  press "2"
  truthy("ask: multi-select stays on its question", drawn(card):find("2 of 3", 1, true) ~= nil)

  -- The third question has no options at all, so the box is the only thing to
  -- do. A REAL buffer, and never volt's -- that is the difference between
  -- writing an answer and filling in a text field.
  press "<Tab>"
  press "i"
  local box = vim.api.nvim_get_current_buf()
  truthy("ask: the answer box is a real, typeable buffer", vim.bo[box].modifiable and box ~= card)
  eq("ask: and is never handed to volt", require("volt.state")[box], nil)

  vim.api.nvim_buf_set_lines(box, 0, -1, false, { "looks", "right" })
  press "<CR>"
  truthy(
    "ask: what was typed is shown back",
    drawn(card):find("looks right", 1, true) ~= nil,
    drawn(card)
  )

  -- Complete, so now it sends -- and the hint said so first.
  truthy(
    "ask: the hint offers to send once nothing is missing",
    drawn(card):find "send the answers" ~= nil
  )
  vim.api.nvim_set_current_win(card_win)
  press "<CR>"
  eq("ask: the whole set is sent at once", sent and #sent, 3)
  eq("ask: single-select, as its label", sent and sent[1], "Rebase")
  eq("ask: multi-select, joined", sent and sent[2], "tests, lint")
  eq("ask: and the typed answer, flattened onto one line", sent and sent[3], "looks right")
  -- The note travels with the set, attached to the answer it qualifies.
  eq(
    "ask: and the note rides along with it",
    sent_notes and sent_notes[1],
    "only for new workspaces"
  )

  ask.close()
  sent = nil

  -- Dismiss is not deny, and the picks survive it: that is the whole reason
  -- <Esc> does not answer.
  -- A REQUEST OF ITS OWN, because `request` has already been answered above and
  -- its picks are held on the chat -- reopening that one resumes onto its
  -- free-text question, where the box takes the focus and a keypress is text.
  local pair = {
    id = "ask-2",
    kind = "question",
    actions = { { id = "deny", label = "Deny", behavior = "deny" } },
    input = {
      questions = {
        { question = "First of two?", options = { { label = "A" }, { label = "B" } } },
        { question = "Second of two?", options = { { label = "C" }, { label = "D" } } },
      },
    },
  }
  local two = questions.parse(pair)

  ask.open(chat, pair, { actions = pair.actions, state = questions.state(two) }, handlers())
  -- `q`, not `<Esc>`: `nvim_feedkeys` eats a bare `<Esc>` in normal mode before
  -- any mapping sees it. They are bound to the same thing.
  press "2"
  press "q"
  eq("ask: dismissing closes the overlay", ask.showing(), nil)
  eq("ask: and does not answer it", sent, nil)

  ask.open(chat, pair, { actions = pair.actions, state = questions.state(two) }, handlers())
  -- Resumed, not restarted: a fresh `questions.state` went in and the held one
  -- came back out, so the stepper is still on the question you had reached.
  truthy(
    "ask: and reopening resumes rather than starting again",
    drawn(vim.api.nvim_get_current_buf()):find("2 of 2", 1, true) ~= nil,
    drawn(vim.api.nvim_get_current_buf())
  )
  press "n"
  eq("ask: `n` declines rather than allowing", declined, "deny")
  ask.close()

  -- More options than rows. The list is windowed around the focus rather than
  -- cut off, because a fifteenth option you cannot scroll to is unreachable
  -- however the keys are bound -- and the card must still fit the chat window.
  local many = {}
  for i = 1, 15 do
    many[i] = { label = "option " .. i }
  end
  local long_list = {
    id = "ask-many",
    kind = "question",
    actions = { { id = "deny", label = "Deny", behavior = "deny" } },
    input = { questions = { { question = "Pick one of many", options = many } } },
  }
  chat = chat_with_window(80)
  vim.api.nvim_win_set_height(chat.win_conversation, 14)
  ask.open(chat, long_list, {
    actions = long_list.actions,
    state = questions.parse(long_list) and questions.state(questions.parse(long_list)),
  }, handlers())
  for _ = 1, 9 do
    press "j"
  end
  card = vim.api.nvim_get_current_buf()
  shown = drawn(card)
  truthy(
    "ask: a long list keeps the focused option in view",
    shown:find("option 10", 1, true) ~= nil,
    shown
  )
  truthy("ask: and says how many are above it", shown:find("↑", 1, true) ~= nil, shown)
  truthy("ask: and below", shown:find("↓", 1, true) ~= nil, shown)
  truthy(
    "ask: while still fitting the chat window",
    vim.api.nvim_win_get_height(vim.fn.bufwinid(card))
      <= vim.api.nvim_win_get_height(chat.win_conversation),
    vim.api.nvim_win_get_height(vim.fn.bufwinid(card))
  )
  ask.close()

  -- A chat window too narrow to read an option in gets the SAME overlay,
  -- centred on the editor. Not a second, drifting one.
  chat = chat_with_window(30)
  ask.open(chat, request, { actions = request.actions, state = questions.state(asked) }, handlers())
  eq(
    "ask: a chat window too narrow falls back to the editor",
    vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative,
    "editor"
  )
  truthy(
    "ask: and it is the same card, not a lesser one",
    drawn(vim.api.nvim_get_current_buf()):find("reconcile", 1, true) ~= nil
  )
  ask.close()

  -- A win-relative float does NOT die with its parent. Without the WinClosed
  -- guard this is an orphan hanging over whatever replaces the chat window.
  chat = chat_with_window(90)
  ask.open(chat, request, { actions = request.actions, state = questions.state(asked) }, handlers())
  vim.api.nvim_win_close(chat.win_conversation, true)
  vim.wait(200, function()
    return ask.showing() == nil
  end)
  eq("ask: the overlay goes with the chat window it was anchored to", ask.showing(), nil)

  -- ------------------------------------------------------------------- plans
  local long = {}
  for i = 1, 120 do
    long[i] = "plan line " .. i
  end
  local plan_request = {
    id = "ask-plan",
    kind = "plan",
    actions = {
      { id = "impl", label = "Implement", behavior = "allow" },
      { id = "rej", label = "Reject", behavior = "deny" },
    },
    input = { plan = table.concat(long, "\n") },
  }
  chat = chat_with_window(90)
  local modes = { { id = "acceptEdits" }, { id = "auto" }, { id = "default" } }
  local picked
  ask.open(chat, plan_request, {
    actions = plan.actions(plan_request, modes),
    plan = true,
  }, {
    submit = function() end,
    choose = function(action)
      picked = action
    end,
    reject = function() end,
  })

  card = vim.api.nvim_get_current_buf()
  local body
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "markdown" and buf ~= chat.conversation then
      body = buf
    end
  end

  -- The whole point: a plan is READ, so it is real text in a window you scroll,
  -- and it is not budgeted against the screen and truncated the way the dialog
  -- it replaces did. You cannot approve what you were not shown.
  truthy("ask: a plan gets a real-text body", body ~= nil)
  eq("ask: carrying the plan in full", body and vim.api.nvim_buf_line_count(body), 120)
  eq("ask: which is not volt's either", body and require("volt.state")[body], nil)
  eq("ask: and nothing is elided", drawn(card):find "more lines", nil)
  truthy(
    "ask: one Implement per mode it could land in",
    drawn(card):find("accept edits", 1, true) ~= nil,
    drawn(card)
  )

  -- Focusable, or the WHEEL cannot reach it: an unfocusable float is one the
  -- mouse lands straight through, so the plan sat still while the conversation
  -- underneath it scrolled -- which is what "scrolling does not work" was.
  local body_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
    end
  end
  truthy(
    "ask: the plan's body can be focused, so the mouse can scroll it",
    body_win and vim.api.nvim_win_get_config(body_win).focusable,
    body_win and vim.inspect(vim.api.nvim_win_get_config(body_win))
  )
  -- And since you can now END UP in it, it answers the same keys the card does
  -- -- otherwise the mouse puts you somewhere with no way to accept or reject.
  truthy(
    "ask: and answers the same keys, so it is not a dead end",
    vim.fn.maparg("y", "n", false, true).buffer == 1 or #vim.api.nvim_buf_get_keymap(body, "n") > 0,
    vim.inspect(#vim.api.nvim_buf_get_keymap(body, "n"))
  )

  -- Scrolling actually moves it. `j` is proxied from the card into the body,
  -- and a plan you cannot move is a plan you approve half-read.
  local before = vim.api.nvim_win_call(body_win, function()
    return vim.fn.line "w0"
  end)
  press "<C-d>"
  local after = vim.api.nvim_win_call(body_win, function()
    return vim.fn.line "w0"
  end)
  truthy(
    "ask: and the scroll keys really move it",
    after > before,
    ("%d -> %d"):format(before, after)
  )

  press "1"
  eq("ask: a button sends the daemon's own action id", picked and picked.id, "impl")
  eq("ask: with the mode that button means", picked and picked.mode, "acceptEdits")

  ask.close()

  -- Volt keys its state by buffer and keeps the buffer on its key handler; both
  -- halves are ours to undo, for every window the overlay opened.
  eq("ask: closing clears the card's volt state", require("volt.state")[card], nil)
  local listed = false
  for _, buf in ipairs(require("volt.events").bufs) do
    listed = listed or buf == card
  end
  eq("ask: and takes it off volt's key handler", listed, false)
  -- The augroup is deleted outright, and `nvim_get_autocmds` raises on a group
  -- that does not exist -- so "it threw" IS the pass here.
  local kept = pcall(vim.api.nvim_get_autocmds, { group = "paseo.answer" })
  eq("ask: no autocmds are left behind", kept, false)
  vim.cmd "silent only"
  eq("ask: and no windows", #vim.api.nvim_list_wins(), 1)
end

return {
  { "ask", test_answer },
}
