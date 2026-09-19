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
---@return table
function M.input(request, questions, answers)
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
  return input
end

---The question as it goes into the transcript.
---
---The picker is transient and the conversation is the record: what was asked,
---and what could have been said, should still be readable tomorrow.
---@param questions paseo.Question[]
---@return string[]
function M.render(questions)
  local lines = {}
  for index, question in ipairs(questions) do
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = #questions > 1 and ("%d. %s"):format(index, question.question)
      or question.question
    for _, option in ipairs(question.options) do
      lines[#lines + 1] = ("   - %s%s"):format(
        option.label,
        option.description and (" — " .. option.description) or ""
      )
    end
    local note = question.multi and "choose as many as apply"
      or (#question.options == 0 and "type an answer" or nil)
    if note then
      lines[#lines + 1] = ("   _(%s)_"):format(note)
    end
  end
  return lines
end

---What was answered, in one line, for the transcript's resolution badge.
---
---The badge otherwise reads "allowed", which for a question is true and
---useless: the record of a five-option question would be the word "allow".
---@param questions paseo.Question[]
---@param answers table<integer, string>
---@return string
function M.label(questions, answers)
  local parts = {}
  for index, question in ipairs(questions) do
    local answer = answers[index]
    if answer and answer ~= "" then
      parts[#parts + 1] = #questions > 1 and question.header
          and ("%s: %s"):format(question.header, answer)
        or answer
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

---@param questions paseo.Question[]
---@return paseo.QuestionState
function M.state(questions)
  local picked = {}
  for index = 1, #questions do
    picked[index] = {}
  end
  return { questions = questions, current = 1, picked = picked }
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
