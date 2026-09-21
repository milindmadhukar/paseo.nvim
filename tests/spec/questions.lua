--- The agent's questions, and answering them.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_questions()
  local questions = require "paseo.ui.questions"
  local render = require "paseo.ui.render"
  local timeline = require "paseo.ui.timeline"

  truthy("questions: the module loads", (pcall(require, "paseo.ui.questions")))

  -- Claude's own AskUserQuestion, as the daemon forwards it.
  local claude = {
    id = "permission-1",
    kind = "question",
    name = "AskUserQuestion",
    title = "How should I reconcile your local work?",
    input = {
      questions = {
        {
          question = "How should I reconcile your local work?",
          header = "Reconcile",
          multiSelect = false,
          allowOther = true,
          options = {
            { label = "Rebase", description = "Replay my commits on top" },
            { label = "Merge" },
          },
        },
      },
    },
  }

  local one = questions.parse(claude)
  eq("questions: a question request parses", one and #one, 1)
  eq(
    "questions: options keep their descriptions",
    one[1].options[1].description,
    "Replay my commits on top"
  )
  truthy("questions: allowOther means free text is an answer", one[1].free)

  -- The whole bug: a request to ACT carries no questions and must stay on the
  -- allow/deny path rather than be answered as if it did.
  eq(
    "questions: a tool permission is not a question",
    questions.parse {
      kind = "tool",
      name = "Write",
      input = { file_path = "/tmp/x", content = "y" },
    },
    nil
  )

  -- Two questions in one request: the shape that rendered as one.
  local pair = {
    id = "permission-2",
    kind = "question",
    input = {
      questions = {
        {
          question = "Which ones apply?",
          header = "Applies",
          multiSelect = true,
          options = { { label = "A" }, { label = "B" } },
        },
        { question = "Optional comment", header = "Comment", options = {}, allowEmpty = true },
      },
    },
  }

  local both = questions.parse(pair)
  eq("questions: every question in the request is parsed", #both, 2)
  truthy("questions: no options at all is a free-text question", both[2].free)
  truthy("questions: allowEmpty may be skipped", both[2].optional)

  eq(
    "questions: a label containing the separator is quoted",
    questions.join { "Rebase, then push", "B" },
    '"Rebase, then push", B'
  )

  local input = questions.input(pair, both, { [1] = questions.join { "A", "B" }, [2] = "" })
  eq(
    "questions: answers are keyed by the question text",
    input.answers["Which ones apply?"],
    "A, B"
  )
  eq("questions: and by the header other providers read", input.answers["Applies"], "A, B")
  eq("questions: a skipped answer is sent as no answer", input.answers["Comment"], nil)
  eq("questions: the questions go back with them", #input.questions, 2)

  -- `answers = {}` encodes as `[]`, which is not an answers object: a set
  -- skipped whole still has to arrive as a dict.
  eq(
    "questions: answered nothing still sends an object",
    vim.json.encode(questions.input(pair, both, {}).answers),
    "{}"
  )

  -- ----------------------------------------------------------------- state

  local state = questions.state(both)
  eq("questions: the first question is the one the keys act on", state.current, 1)

  questions.choose(state, 1)
  questions.choose(state, 2)
  eq("questions: multi-select accumulates", questions.answers(state)[1], "A, B")
  questions.choose(state, 1)
  eq("questions: and a second press takes it back off", questions.answers(state)[1], "B")
  eq("questions: multi-select does not move on by itself", state.current, 1)

  -- Unanswered means UNSENDABLE while the question is not optional.
  local blocked = questions.state(both)
  eq("questions: an unanswered question blocks the send", questions.missing(blocked), 1)
  questions.choose(blocked, 1)
  eq("questions: and stops blocking once answered", questions.missing(blocked), nil)

  -- The optional second question is free text, and typing moves nothing on
  -- because there is nothing after it.
  questions.move(state, 1)
  eq("questions: <Tab> moves to the next question", state.current, 2)
  questions.write(state, "  looks right  ")
  eq("questions: a typed answer is trimmed", questions.answers(state)[2], "looks right")

  -- `typed` is what tells a picked LABEL apart from typed text, which the
  -- overlay needs to know to draw them in different places.
  eq("questions: a picked label is not a typed answer", #questions.typed(both[1], { "A" }), 0)
  eq(
    "questions: and anything that is not a label is",
    questions.typed(both[1], { "A", "something else" })[1],
    "something else"
  )

  -- Skipping. Only where the question says nothing is an acceptable answer, and
  -- it CLEARS rather than leaving a half-answer behind.
  local skipping = questions.state(both)
  questions.choose(skipping, 1)
  eq("questions: a required question cannot be skipped", questions.skip(skipping), false)
  eq("questions: and skipping it changes nothing", #skipping.picked[1], 1)
  questions.move(skipping, 1)
  questions.write(skipping, "never mind")
  eq("questions: an optional one can be", questions.skip(skipping), true)
  eq("questions: and the skip clears what was there", #skipping.picked[2], 0)

  -- Answering out of ORDER still reports the first gap, which is what the
  -- overlay's <CR> jumps to.
  local gapped = questions.state(both)
  questions.move(gapped, 1)
  questions.write(gapped, "later one")
  eq("questions: the first gap is what is missing, not the last", questions.missing(gapped), 1)

  -- Single-select replaces and moves on: there is nothing else to say.
  local single = questions.state(one)
  questions.choose(single, 2)
  questions.choose(single, 1)
  eq(
    "questions: single-select replaces rather than accumulating",
    questions.answers(single)[1],
    "Rebase"
  )

  eq(
    "questions: the badge says what was answered, not just `allowed`",
    questions.label(both, questions.answers(state)),
    "Applies: B · Comment: looks right"
  )

  -- The transcript card showed `title`, which is the FIRST question and its
  -- labels, so a request carrying two was recorded as one.
  local card = timeline.card({ kind = "permission", request = pair }, { width = 60 })
  local text = {}
  for _, line in ipairs(card.lines) do
    text[#text + 1] = render.concat(line)
  end
  text = table.concat(text, "\n")
  truthy(
    "questions: the inline card shows the second question too",
    text:find("Optional comment", 1, true) ~= nil,
    text
  )
  truthy("questions: and the options under it", text:find("A", 1, true) ~= nil, text)
end

return {
  { "questions", test_questions },
}
