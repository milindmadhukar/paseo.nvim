# The e2e harness (`tests/e2e/`)

A real daemon, a real Neovim, a provider with no model behind it.

| File | What |
|---|---|
| `daemon.sh start\|stop\|env\|paseo …` | The installed `paseo` with `PASEO_HOME=$TMPDIR/paseo-e2e/.paseo`, port **6797**, relay and web UI off. Writes `config.json` registering the `fake` provider, makes a fixture repo, and waits until `fake` lists its model. `stop` signals only the process group it started. `paseo …` runs the CLI against it. |
| `fake-acp.mjs` | A scripted ACP agent (`fake/scripted`). Words in the prompt pick the script: `think` (many reasoning chunks), `tool`, `slow` (40ms gaps), `long` (~20s turn), `echo` (answer repeats the prompt), `fail` (error reply plus stderr). It journals each session under `FAKE_ACP_STATE` and replays it on `session/load`, so agents survive a daemon restart. |
| `nvim.sh start [cwd]\|keys\|lua\|state\|wait\|shot\|stop` | Neovim in tmux (`paseo-e2e` session, 140×42), with its own XDG state and data, listening on `$PASEO_E2E_ROOT/nvim.sock`. `state` dumps the mount, windows and transcript blocks as JSON. `wait '<lua expr>' [s]` polls. `shot <name>` writes `shots/<name>.png` (ANSI → HTML → headless Chrome). |
| `init.lua` | `paseo.setup` pointed at the e2e daemon (`autostart = false`; refuses 6767). Defines `_G.paseo_e2e.state/users/turn_done`. |
| `lib.sh` | Sourced by scenarios: `fail`, `q '<python expr over s>'`, `open_chat`, `settle`, `send_prompt`, `wait_idle`, `fresh_repo`, `repo_with_agent`, `create_from_review`. |
| `run.sh [filter]` | Starts the daemon if needed, then runs each `scenarios/*.sh` in a fresh Neovim. |

## Writing a scenario

```bash
source "$(dirname "$0")/../lib.sh"
repo_with_agent >/dev/null      # own repo, one finished agent, Neovim open there
open_chat                       # :Paseo chat, then wait for history to settle
send_prompt "think slow"
wait_idle 30                    # waits for THIS turn, not the idle before it
[ "$(q 'len(s["blocks"])')" -gt 3 ] || fail "…"
"$E" shot my-scenario >/dev/null
```

## Traps, all of them hit once

- **Wait for the thing, not for "a float".** The dashboard is floats. A key
  meant for the new-agent screen landed in the composer as the change
  operator, and `cc` then satisfied a wait for an insert-mode float.
- **Settle before sending.** Sending before the history fetch lands makes
  the test read the previous turn.
- **A turn's end is a newer user block plus an answer plus not streaming**
  (`turn_done`), not "not streaming": the chat is idle before the turn starts.
- **Every scenario gets its own repo.** A shared fixture means opening
  whatever agent the last scenario left.
- **A `vim.ui.select` prompt cannot be waited on.** `sleep` before answering
  it is the one sleep that stays.
- **Agent-to-agent sends:** `PASEO_AGENT_ID=<sender> daemon.sh paseo send <receiver> "…"`.
  `paseo ls` hides closed agents, so take ids from `paseo run --json`.
- **Paseo's own dev `mock` provider is not in the packaged daemon.** That is
  why `fake-acp.mjs` exists.
- Workspace **title generation** calls a real small model. The scenarios
  accept the provisional first-line title; the generated one appears on this
  machine because real providers are configured.
