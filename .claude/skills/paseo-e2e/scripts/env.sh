# Sourced by every script. One place for the paths.
E2E_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
E2E_TREE=${PASEO_NVIM_TREE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
# NAMED FOR THE CHECKOUT. Other sessions run e2e harnesses of their own at the
# same time -- one used `paseo-e2e` for its tmux session and run directory,
# and a fixed name here killed its Neovim and would have deleted its daemon's
# home on cleanup. A short hash of the tree keeps every checkout's apart.
E2E_ID=pne-$(printf '%s' "$E2E_TREE" | sha1sum | cut -c1-8)
E2E_RUN=${TMPDIR:-$HOME/.cache/claude/tmp}/$E2E_ID          # never /tmp
E2E_SANDBOX=$HOME/.local/share/paseo-nvim/e2e/sandbox
E2E_SESSION=$E2E_ID
mkdir -p "$E2E_RUN"
# The CLI run from inside a Paseo agent is AGENT-SCOPED: it would make every
# test agent YOUR subagent, in YOUR workspace. Strip that.
paseo_cli() { env -u PASEO_AGENT_ID -u PASEO_AGENT_CWD -u PASEO_WORKSPACE_ID paseo "$@"; }
