# Contributing to paseo.nvim

## Tests

```sh
tests/run.sh          # everything: the Lua suite, the sidecar typecheck and tests
tests/run.sh git      # only the suites whose name matches `git`
```

Install the sidecar's dependencies first (`cd sidecar && bun install`, or
`npm install`). Neovim runs with `-u tests/minimal_init.lua` and nothing else,
so none of your own configuration is loaded, and no other plugin: the plugin
depends on none. CI runs the same command against Neovim 0.11, stable and nightly.

```
tests/
  run.sh              fixtures, then Neovim, then the sidecar's own tests
  fixtures.sh         the git repositories assertions are made against
  minimal_init.lua    the Neovim the suite runs in
  spec.lua            the runner: the suite files, in the order they run
  spec/               one file per area; helpers.lua has eq/truthy
  orphan.sh           does the sidecar die when Neovim does?
  e2e/                a real daemon and a real Neovim, in tmux
  bench/              timings
```

`tests/spec.lua` lists the suites in order. A file on disk that is not
listed fails the run, so it can't quietly never run.

### End to end, against a real daemon

The headless suite stubs the daemon. `tests/e2e/` drives the whole stack:

```sh
tests/e2e/run.sh              # every scenario
tests/e2e/run.sh paste        # only scenarios whose name matches
tests/e2e/daemon.sh stop      # take the throwaway daemon down
```

- `daemon.sh` runs your installed `paseo` with its own `PASEO_HOME` under
  `$TMPDIR/paseo-e2e`, on port 6797, with the relay off. It never touches the
  daemon on 6767.
- `fake-acp.mjs` is a scripted ACP agent registered as the `fake` provider.
  It is free, offline and the same every run. Words in the prompt pick the
  script: `think`, `tool`, `slow`, `long`, `echo`.
- `nvim.sh` opens Neovim against that daemon in tmux and sends it keys.
  Scenarios assert on `nvim.sh state` and the daemon's own CLI.
- `nvim.sh shot <name>` renders the pane to a PNG under
  `$TMPDIR/paseo-e2e/shots`.

It needs `tmux`, `python3`, `node` and a Chromium-family browser for the
PNGs. It is opt-in and not part of CI.

### Benchmarks

```sh
tests/bench/run.sh micro [out.json]   # main-loop work, stubbed daemon
tests/e2e/bench.sh [label]            # real windows against a throwaway daemon
python3 -I tests/bench/compare.py before.json after.json
```

In your own editor, `PASEO_PERF=1 nvim` records the same spans, and
`:lua require("paseo.perf").show()` prints them.

## Layout

```
lua/paseo/
  init.lua          setup(), the :Paseo command, the public API
  native.lua        the full-screen surface's public actions
  bridge.lua        the sidecar process and its requests
  daemon.lua        finding (and starting) the daemon
  repos.lua git.lua ref.lua   the data layer: repos, hunks, references
  explain.lua       :Paseo ask / explain
  image.lua         clipboard and pasted-path images
  workspace/        assembling N worktrees into one workspace
  pickers/          the workspace, agent and subagent lists
  ui/
    choose.lua      the one chooser every list uses
    popup.lua       the frame choosers and settings cards are drawn in
    chat.lua        a chat: buffers, sending, events
    native.lua      the full-screen surface
    sidebar.lua     the pane beside your code
    rail.lua tree.lua   the workspace rail
    panels/         Settings, Changes, Usage
    theme.lua hl.lua style.lua   colours, groups and frames
    render.lua widgets.lua       cells, lines, cards, chips
sidecar/            paseo-bridge.ts and its bridge-*.ts modules
.agents/skills/     the bundled agent skills
doc/paseo.txt       :help paseo
```

## Architecture

```
┌ paseo.nvim (Lua) ─────────────────────────┐
│  repos · git · ref · chat · surfaces      │
└──────────────┬────────────────────────────┘
               │ stdio, newline-delimited JSON (push)
┌──────────────▼────────────────────────────┐
│  sidecar (Bun or Node 22+)                │
│  @getpaseo/client                         │
└──────────────┬────────────────────────────┘
               │ ws://127.0.0.1:6767/ws
┌──────────────▼────────────────────────────┐
│  Paseo daemon: agents, workspaces, PTYs   │
└───────────────────────────────────────────┘
```

**Why a sidecar.** The `paseo` CLI costs about a second per call to start
Node, while the WebSocket answers in 1–10 ms. A raw WebSocket in Lua would
also mean reimplementing the client's subscriptions, snapshot ordering,
timeline cursors and reconnects. So one small process per Neovim holds the
socket and pushes events to Lua over stdio. It starts on the first request
(or just after startup, if a daemon is already up) and dies with Neovim.

**Finding the daemon.** The candidates, in order, are `paseo.url`,
`$PASEO_ENDPOINT`, `daemon.listen` from `$PASEO_HOME/config.json`, then
`127.0.0.1:6767`. Each is probed with `GET /api/status`, and a `401` counts
as reachable. If nothing answers and `paseo.autostart` is on, the plugin runs
`paseo daemon start`.

**Multi-repo workspaces.** `workspace/` builds the composite directory (a
worktree per repo, the shared siblings linked in) and registers it with Paseo
as an ordinary local workspace. Paseo sees a directory with agents in it.

## Style

- Every surface is a real buffer. Prefer the cursor and Vim's own keys to a
  bespoke focus model.
- Every pick-one list goes through `paseo.ui.choose`.
- Format with the repo's `stylua.toml`, but only the lines you changed:
  reformatting whole files produces noisy diffs.
- Docs change in the same commit as the code: `README.md` and
  `doc/paseo.txt`, then `nvim --headless -c 'helptags doc' -c 'qa!'`
  (`doc/tags` is gitignored).
