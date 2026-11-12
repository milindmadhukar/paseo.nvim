---
name: paseo-e2e
description: Drive paseo.nvim end to end against REAL agents — spawn cheap throwaway test agents in a sandbox project, open this checkout's plugin on them in a tmux Neovim, make them ask for permissions, start subagents or run tools, and read what the user would actually see. Use when a paseo.nvim bug only shows with a live daemon (a permission that never appears, a subagent status that is wrong, a surface that jumps), when asked to "test it for real", "spawn a test agent", "reproduce against the daemon", or before claiming a fix to anything event-driven is done. Not for the unit suite (tests/run.sh), which never touches a daemon.
---

# paseo.nvim end to end, with test agents

The unit suite stubs the bridge and can only check what you thought to stub.
The bugs that matter — a permission request that never reaches the screen, a
subagent drawn as done while it works, a dashboard that turns into a float —
live in the order real events arrive from a real daemon. This skill gets you
that order, safely, in about a minute.

A DEVELOPMENT skill, for working ON this repository. It lives in
`.claude/skills/` itself rather than `.agents/skills/` on purpose: everything in
`.agents/skills/` is what `:Paseo skills install` ships to users.

All scripts are in `scripts/` next to this file. Run them from the checkout you
are testing (they load THAT tree's plugin, not the installed one).

## The rules

1. **Only agents you spawned here.** Every test agent carries the label
   `paseo-nvim-e2e=1` and a title starting `e2e: `. Never open a chat on, prompt,
   answer for, or archive any other agent — the daemon on 6767 is Milind's live
   one, with his real sessions on it.
2. **Only the sandbox project.** `~/.local/share/paseo-nvim/e2e/sandbox` — a git
   repo with a README, created on first use and reused. Never point a test agent
   at a real repo: "Always Ask" still runs whatever you approve.
3. **Cheap.** Haiku 5.5, thinking `low`. A scenario is a one-line prompt
   ("Use the Bash tool to run exactly: date > now.txt"), not a task.
4. **Not agent-scoped.** Inside a Paseo agent the CLI defaults to *your*
   workspace and makes every agent it starts *your* subagent. `env.sh`'s
   `paseo_cli` strips `PASEO_AGENT_ID`/`PASEO_AGENT_CWD`; always go through it
   (or the scripts), never bare `paseo run`.
5. **Clean up.** `cleanup.sh` when done: archives by label, stops the tmux
   session, deletes the run directory. It never touches anything unlabelled.
6. **Never `/tmp`.** Run files live in `$TMPDIR/pne-<hash>`, one per checkout.
7. **Your own names only.** The tmux session and run directory are
   `pne-<hash of the checkout>` (`source scripts/env.sh` sets `$E2E_SESSION`
   and `$E2E_RUN`). Other sessions run e2e harnesses of their own at the same
   time — one uses `paseo-e2e` for both, with an isolated daemon on 6797 — and
   a fixed shared name once killed its Neovim and would have deleted its
   daemon's home. Never touch a tmux session or `$TMPDIR` directory you did
   not create. No `pkill`, no pattern matches — see the
   no-broad-process-kills memory.

## The loop

```bash
S=.claude/skills/paseo-e2e/scripts
source $S/env.sh                     # $E2E_SESSION, $E2E_RUN, $E2E_SANDBOX, paseo_cli

# 1. A parent agent. --wait lets its first turn finish before you watch it.
A=$($S/spawn.sh parent "Reply with just READY. Use no tools." --wait)

# 2. Neovim on it, on a surface: float (default), buffer or sidebar.
$S/start.sh "$A" float

# 3. Make something happen, and wait for the daemon to hold a request.
$S/send.sh "$A" "Use the Bash tool to run exactly: date > now.txt" --until-permission

# 4. Look: the state summary, and the screen as text.
$S/probe.sh            # mode, mount, held requests, dialog/overlay showing
$S/screen.sh           # the tmux pane, empty `~` rows dropped
cat "$E2E_RUN/notify.log"            # every vim.notify, timestamped

# 5. Act as the user would.
tmux send-keys -t $E2E_SESSION y     # allow (n deny, Escape dismiss, i type…)

# 6. When finished.
$S/cleanup.sh
```

`probe.sh '<lua>'` evaluates anything in the running Neovim, for example
`$S/probe.sh 'vim.inspect(require("paseo.subagents").list(require("paseo.ui.chat").current().agent_id))'`.

## Scenarios that have found real bugs

| Scenario | How |
|---|---|
| Request while you type | `tmux send-keys -t $E2E_SESSION i 'half a thought'`, then `send.sh … --until-permission`. Expect: held, card inline, `needs you (gp)`, a notification; `Escape` then opens it. |
| Request with no chat open | `probe.sh 'require("paseo.ui.chat").close()'`, send, then `start.sh "$A"` again. Expect the dialog on open. |
| Provider subagent (Task tool) | `send.sh "$A" "Use the Task tool to launch ONE general-purpose subagent whose only job is to run the Bash command: uname -a > kernel.txt"`. Then `gs`, and the rail's `󱙺 n/m` badge. |
| **Paseo subagent** | `C=$($S/spawn.sh child "Use the Bash tool to run exactly: pwd > where.txt" --parent "$A")`. Its request must appear in the PARENT's chat, marked `asked by subagent`. This was the stuck permission. |
| Surfaces | `start.sh "$A" buffer` / `sidebar`, then switch workspace from the rail (`<C-h>`, `j`, `<CR>`) and check `probe.sh`'s `mount` did not change. |

## Reading the screen

`screen.sh` drops colour. To see colour — whether a highlight is right, whether
something is drawn but invisible — use `screen.sh --color > x.ansi`, convert it
to HTML (spans per SGR code) and screenshot it with
`google-chrome-stable --headless --screenshot=... --user-data-dir=$TMPDIR/chrome`.
Look at a light theme too: `E2E_SCHEME=morning start.sh "$A"`.

Tests never assert how something looks. If the fix is visual, look at it.

## When it goes wrong

- `connection refused` on the socket: an old Neovim's exit unlinked it. Every
  `start.sh` uses a new socket and records it in `$E2E_RUN/sock`; use
  `probe.sh` rather than a hardcoded path.
- The Neovim died: the pane stays up after it exits and its last line says
  `[nvim exited: N]` — `screen.sh` shows it.
- `gp` is bound in the CONVERSATION buffer, and the cursor is usually in the
  composer. `probe.sh 'require("paseo.ui.permission").reopen(require("paseo.ui.chat").current()) and "" or ""'`
  does what `gp` does.
- A second `main` workspace row on the rail: an agent was spawned without
  `--workspace`. `spawn.sh` remembers the sandbox's workspace id in
  `<sandbox>/.git/paseo-workspace` and passes it every time; delete that file
  if the workspace was archived, and the next spawn records a fresh one.
- The CLI answered but nothing reached Neovim: the sidecar only follows a
  timeline for an agent with an initialised chat. That gap is real behaviour,
  not a harness bug — it is exactly how the Paseo-subagent permission got stuck.

## After

Turn what you found into a unit test in `tests/spec/` (stubbed bridge, same
event order), so the suite holds the fix without a daemon. The e2e run is the
reproduction; the spec is the guard.
