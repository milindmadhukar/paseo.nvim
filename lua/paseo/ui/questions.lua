--- The questions an agent asks, and answers it can actually read.
---
--- A question arrives as a PERMISSION REQUEST like any other -- the daemon
--- gives it `kind == "question"` -- but answering one is not the same act as
--- allowing a tool call. Allowing only says "go ahead and ask". The answer
--- itself rides back in `updatedInput.answers`, keyed by the question, and an
--- allow that carries no answers is what produces the reply everyone has seen
--- in a transcript:
---
---     The user did not answer the questions.
---
--- The request was approved. Nothing was answered. So the allow/deny pair is
--- the wrong instrument for this kind, and this module is the right one: it
--- reads the questions out of the request, holds the answering as it goes,
--- and builds the input the provider reads back.
---
--- No windows here. |paseo.ui.permission| owns the dialog and the keys; this
--- owns the RULES -- what a tick does, when a set of answers is complete, and
--- the one serialisation the provider parses -- which is why they can be
--- tested without opening anything.

local M = {}

---@class paseo.QuestionOption
---@field label string
---@field description string|nil

---@class paseo.Question
---@field question string     The full text, which is also the answer's key.
---@field header string|nil   The short form; some providers key answers by it.
---@field options paseo.QuestionOption[]
---@field multi boolean       Several labels are an acceptable answer.
---@field free boolean        So is text that is none of the labels.
---@field optional boolean    So is nothing at all.

---@param value any
---@return string|nil
local function text(value)
  if type(value) ~= "string" or vim.trim(value) == "" then
    return nil
  end
  return value
end

---The questions in a permission request, or nil if it is not asking any.
---
---Shape rather than `kind` is the test. Every provider that asks something
---puts a `questions` array in the input -- Claude's own `AskUserQuestion`
---tool, and the extension-UI providers that wrap their `ask_user` in the same
---envelope -- and a request whose questions cannot be read is better handled
---by the ordinary allow/deny path than by a guess.
---@param request table|nil
---@return paseo.Question[]|nil
function M.parse(request)
  local input = request and request.input
  local raw = type(input) == "table" and input.questions or nil
  if type(raw) ~= "table" or #raw == 0 then
    return nil
  end

  local questions = {}
  for _, item in ipairs(raw) do
    local asked = type(item) == "table" and text(item.question)
    if not asked then
      return nil
    end

    local options = {}
    for _, option in ipairs(type(item.options) == "table" and item.options or {}) do
      if type(option) == "string" and text(option) then
        options[#options + 1] = { label = option }
      elseif type(option) == "table" and text(option.label) then
        options[#options + 1] = { label = option.label, description = text(option.description) }
      end
    end

    questions[#questions + 1] = {
      question = asked,
      header = text(item.header),
      options = options,
      multi = item.multiSelect == true,
      -- A question with no options at all IS free text -- that is how the
      -- "optional comment" half of an `ask_user` pair arrives. `allowOther` is
      -- the other half of it: options, or something else entirely.
      free = #options == 0 or item.allowOther == true,
      optional = item.allowEmpty == true,
    }
  end
  return questions
end

---Several answers to ONE question, in the single form the provider parses.
---
---The separator is `", "`, and a label containing the separator or a quote is
---JSON-quoted. The reader splits on unquoted `", "` and JSON-parses whatever
---began with a quote, so a label like `Rebase, then push` sent raw comes back
---as two answers that match no option and the whole set is rejected.
---@param labels string[]
---@return string
function M.join(labels)
  local parts = {}
  for _, label in ipairs(labels) do
    if label:find(", ", 1, true) or label:find('"', 1, true) then
      parts[#parts + 1] = vim.json.encode(label)
    else
      parts[#parts + 1] = label
    end
  end
  return table.concat(parts, ", ")
end

---The tool input to allow with: the request's own, plus the answers.
---
---Answers are keyed BOTH ways on purpose. Claude's tool wants the full
---question text; the extension-UI providers read their own `header`. Sending
---both means each reader finds the key it knows, and the one that does not
---recognise a key ignores it -- which is cheaper than deciding which provider
---this is.
---@param request table
---@param questions paseo.Question[]
---@param answers table<integer, string>  Keyed by question index; "" is a skip.
---@param notes table<integer, string>|nil  Remarks about the answers, same keying.
---@return table
function M.input(request, questions, answers, notes)
  local input = vim.deepcopy(type(request.input) == "table" and request.input or {})
  -- An empty Lua table encodes as `[]`, and an `answers` ARRAY is not an
  -- answers object -- the provider would ignore it and the agent would be told
  -- nothing was answered. `vim.empty_dict()` keeps it an object when every
  -- question was skipped.
  local map = vim.empty_dict()
  for index, question in ipairs(questions) do
    local answer = answers[index]
    if answer and answer ~= "" then
      map[question.question] = answer
      if question.header and question.header ~= question.question then
        map[question.header] = answer
      end
    end
  end
  input.answers = map
  if notes and next(notes) then
    -- Keyed by question text the way `answers` is, and an OBJECT per question
    -- rather than a bare string: the schema puts the remark under `notes`, and
    -- leaving room beside it is what lets a note travel with whatever else a
    -- future answer carries without moving this key again.
    local annotated = vim.empty_dict()
    for index, question in ipairs(questions) do
      local note = notes[index]
      if note and note ~= "" and answers[index] and answers[index] ~= "" then
        annotated[question.question] = { notes = note }
        if question.header and question.header ~= question.question then
          annotated[question.header] = { notes = note }
        end
      end
    end
    if next(annotated) then
      input.annotations = annotated
    end
  end
  return input
end

---Which of a question's options were actually chosen.
---
---Two sources, because a question can be answered somewhere else entirely. The
---structured `answers` map is the exact one and is what the dialog in this
---Neovim hands back; a question answered in the Paseo app arrives as a
---resolution STRING and nothing else, so the labels are looked for in it. That
---second path is a guess, and it is allowed to find nothing -- an option that
---cannot be proved chosen is simply drawn as an option.
---@param question paseo.Question
---@param answers table<string, string>|nil  Keyed by question text or header.
---@param resolution string|nil              The one-line badge, as a fallback.
---@return table<string, boolean>
function M.chosen(question, answers, resolution)
  local said = answers
    and (answers[question.question] or (question.header and answers[question.header]))
  local picked = {}
  for _, option in ipairs(question.options) do
    if said then
      -- `M.join`'s separator, and the quoting it uses for a label containing
      -- one. Matching the whole string against each label would miss every
      -- answer to a multi-select.
      picked[option.label] = said == option.label or said:find(option.label, 1, true) ~= nil
    elseif resolution and resolution ~= "" then
      picked[option.label] = resolution:find(option.label, 1, true) ~= nil
    end
  end
  return picked
end

---The question as it goes into the transcript, as ROWS rather than text.
---
---The picker is transient and the conversation is the record: what was asked,
---and what could have been said, should still be readable tomorrow. But it was
---readable as one flat block of dim prose -- the question, then every option
---with its description run onto the same line behind an em dash -- which on a
---question with three explained options is a dozen wrapped lines of identical
---grey that says nothing about which one you picked.
---
---So it comes out structured and the drawing is |paseo.ui.timeline|'s: a row
---knows whether it is the question, an option, that option's description, or
---the note under a question, and whether the option was the one taken.
---@class paseo.QuestionRow
---@field kind "question"|"option"|"description"|"note"|"gap"
---@field text string
---@field chosen boolean|nil  Only on an option, and only when it is known.
---@param questions paseo.Question[]
---@param answers table<string, string>|nil
---@param resolution string|nil
---@return paseo.QuestionRow[]
function M.rows(questions, answers, resolution)
  local rows = {}
  for index, question in ipairs(questions) do
    if #rows > 0 then
      rows[#rows + 1] = { kind = "gap", text = "" }
    end
    rows[#rows + 1] = {
      kind = "question",
      text = #questions > 1 and ("%d. %s"):format(index, question.question) or question.question,
    }

    local picked = M.chosen(question, answers, resolution)
    for _, option in ipairs(question.options) do
      rows[#rows + 1] = { kind = "option", text = option.label, chosen = picked[option.label] }
      if option.description then
        rows[#rows + 1] = { kind = "description", text = option.description }
      end
    end

    local note = question.multi and "choose as many as apply"
      or (#question.options == 0 and "type an answer" or nil)
    if note then
      rows[#rows + 1] = { kind = "note", text = note }
    end
  end
  return rows
end

---What was answered, in one line, for the transcript's resolution badge.
---
---The badge otherwise reads "allowed", which for a question is true and
---useless: the record of a five-option question would be the word "allow".
---@param questions paseo.Question[]
---@param answers table<integer, string>
---@param notes table<integer, string>|nil
---@return string
function M.label(questions, answers, notes)
  local parts = {}
  for index, question in ipairs(questions) do
    local answer = answers[index]
    if answer and answer ~= "" then
      local note = notes and notes[index]
      -- The note goes in the badge too, in parentheses: a caveat that only
      -- exists in the request the agent read is one nobody can find later.
      local said = note and note ~= "" and ("%s (%s)"):format(answer, note) or answer
      parts[#parts + 1] = #questions > 1
          and question.header
          and ("%s: %s"):format(question.header, said)
        or said
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or "answered"
end

-- ------------------------------------------------------------------- state

---The answering in progress.
---
---Kept as data rather than in the dialog's closures so the rules -- what a
---tick does, when a set is complete, what it serialises to -- can be tested
---without opening a window.
---@class paseo.QuestionState
---@field questions paseo.Question[]
---@field current integer                        The question the keys act on.
---@field picked table<integer, string[]>        Chosen labels, in the order chosen.
---@field notes table<integer, string>           What was said ABOUT the pick.

---@param questions paseo.Question[]
---@return paseo.QuestionState
function M.state(questions)
  local picked = {}
  for index = 1, #questions do
    picked[index] = {}
  end
  return { questions = questions, current = 1, picked = picked, notes = {} }
end

---@param state paseo.QuestionState
---@param delta integer
function M.move(state, delta)
  state.current = math.max(1, math.min(#state.questions, state.current + delta))
end

---Take, or untake, one of the current question's options.
---
---Single-select REPLACES and moves on, because there is nothing else to say
---about that question; multi-select toggles and stays, because there is.
---@param state paseo.QuestionState
---@param option integer  Index into the current question's options.
function M.choose(state, option)
  local index = state.current
  local question = state.questions[index]
  local label = question.options[option] and question.options[option].label
  if not label then
    return
  end

  if not question.multi then
    state.picked[index] = { label }
    return M.move(state, 1)
  end

  for at, chosen in ipairs(state.picked[index]) do
    if chosen == label then
      table.remove(state.picked[index], at)
      return
    end
  end
  table.insert(state.picked[index], label)
end

---The answers to this question that were TYPED rather than picked.
---
---The picked list holds labels and free text side by side, because to the
---provider they are the same thing -- an answer. The dialog has to tell them
---apart to draw them: a label belongs on its own option row, and typed text
---belongs in the box you typed it into.
---@param question paseo.Question
---@param picked string[]
---@return string[]
function M.typed(question, picked)
  local labels = {}
  for _, option in ipairs(question.options) do
    labels[option.label] = true
  end
  local out = {}
  for _, chosen in ipairs(picked or {}) do
    if not labels[chosen] then
      out[#out + 1] = chosen
    end
  end
  return out
end

---Say nothing about the current question, and move on.
---
---Only where the question says nothing is an acceptable answer. A skip on a
---required question is not a smaller answer, it is the same wrong one
---`M.missing` exists to refuse -- so this reports that it did nothing rather
---than silently clearing what was there.
---@param state paseo.QuestionState
---@return boolean skipped
function M.skip(state)
  local index = state.current
  if not state.questions[index].optional then
    return false
  end
  state.picked[index] = {}
  M.move(state, 1)
  return true
end

---An answer in the human's own words, for a question that allows one.
---@param state paseo.QuestionState
---@param typed string
function M.write(state, typed)
  local index = state.current
  typed = vim.trim(typed or "")
  if typed == "" then
    return
  end
  if state.questions[index].multi then
    table.insert(state.picked[index], typed)
  else
    state.picked[index] = { typed }
    M.move(state, 1)
  end
end

---A remark ABOUT an answer, rather than an answer.
---
---A picked option says which; a note says why, or what is different about the
---case at hand -- "the second one, but only for new workspaces". It never
---replaces the pick, so unlike `M.write` it is kept apart from `picked` and
---travels in `annotations` rather than in `answers`: a reader that only knows
---about answers still gets a clean label, and one that knows about both gets
---the caveat attached to it.
---@param state paseo.QuestionState
---@param typed string|nil  Empty or nil clears it.
function M.annotate(state, typed)
  typed = vim.trim(typed or "")
  state.notes[state.current] = typed ~= "" and typed or nil
end

---@param state paseo.QuestionState
---@return table<integer, string>  By question index; "" is a skip.
function M.answers(state)
  local answers = {}
  for index in ipairs(state.questions) do
    answers[index] = M.join(state.picked[index])
  end
  return answers
end

---The first question that still needs an answer, if any.
---
---What makes the dialog refuse to send half a reply: there is ONE response
---for the set, so an unanswered question is not a smaller answer, it is a
---wrong one.
---@param state paseo.QuestionState
---@return integer|nil index
function M.missing(state)
  for index, question in ipairs(state.questions) do
    if not question.optional and #state.picked[index] == 0 then
      return index
    end
  end
end

return M
