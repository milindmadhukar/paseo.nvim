---
name: explain-change
description: Explain a specific code change — a hunk, a diff, a commit, a selected range — to the person who is reviewing it, in a form they can argue with. Use when asked to explain, walk through, or review a diff or hunk; when handed a `path:line` reference and asked what it does; or when someone says they cannot explain code they shipped. Not for explaining unchanged code, which is ordinary code reading.
---

# Explain a change

Someone is reviewing a diff and has stopped on a hunk they cannot account for.
They are not asking for a summary. They are trying to get to the point where
they could defend this change to somebody else.

## Answer in five parts, in this order

**1. What changed.** One or two sentences. Say it in terms of behaviour, not
syntax: "retries are now capped at three" rather than "added a `max_retries`
constant". If the change is purely mechanical — a rename, a move, a formatting
pass — say so plainly and stop; the remaining sections are noise for a change
with no semantics.

**2. What invariant it altered.** Name something that was true before and is
not true now, or the reverse. This is the section that does the work. Most
changes that are hard to explain are hard because the person never articulated
what the old code guaranteed. Examples of the shape: "before, `render()` could
assume the cache was warm"; "the function was previously safe to call twice;
it is not now"; "this was the only place that validated the token, and it no
longer does".

If you genuinely cannot find an altered invariant, say that — "this changes no
invariant I can identify" is a real and useful answer.

**3. Who is affected.** The call sites, the callers of those, the tests that
cover it. **Name files and lines.** If you have not looked, say you have not
looked rather than guessing — a plausible-sounding wrong file name costs the
reviewer more time than an admission.

**4. Who made it.** If the prompt lists sibling Paseo agents, they are the
agents that have been working in this tree, and you can ask what they did:
call `get_agent_activity` on an id before you answer. Report which one made
this change and what it was asked to do — the task it was given is usually the
missing half of "why is this here". If no agents are listed, or none of them
touched this code, say so and move on; do not guess from the diff.

**5. What to push back on.** Not optional, and not a formality.

This is the part that turns reading into reviewing. List the things a careful
reviewer should refuse to accept on trust:

- assumptions the change makes that nothing enforces;
- error paths that are now unreachable, or newly reachable and unhandled;
- the cases the change does not cover but looks like it does;
- anything riskier than it appears — a lock held longer, a loop that can now
  run unbounded, an ordering that only holds by accident;
- places where a simpler change would have done.

If the change is genuinely clean, say what you checked in order to conclude
that. "Nothing to push back on" with no reasoning is worth nothing.

## How to write it

- **Brief.** Five short sections, and the attribution one is a line unless it
  found something. This is read next to the diff, not instead of it.
- **Concrete.** Names, paths, line numbers. Never "the relevant function".
- **Do not narrate the diff.** They can see the `+` and `-` lines. Tell them
  what those lines mean.
- **Do not praise the change.** You are not reviewing the author, and a change
  the reviewer wrote themselves does not need encouragement.
- **Say when you are unsure.** Mark inference as inference. The reviewer is
  going to act on this.
