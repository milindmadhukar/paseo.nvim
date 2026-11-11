# The session tree down the right: the workspace's agents, the one on screen
# marked -- and `<C-n>` starts another one beside it as a draft, which lands
# on the tree once its first message has made it.
source "$(dirname "$0")/../lib.sh"

repo="$(repo_with_agent)"
open_chat

tree='require("paseo.ui.tree")'
"$E" wait "$tree.win() ~= nil" 15 || fail "no session tree"
"$E" wait "#$tree.nodes(require(\"paseo.ui.float\").chat()) == 1" 15 || fail "the tree does not list the agent"
"$E" shot session-tree >/dev/null

# The Sessions tab is gone.
[ "$("$E" lua 'vim.tbl_contains(require("paseo.ui.float").TABS, "Sessions") and 1 or 0')" = "0" ] \
  || fail "there is still a Sessions tab"

# <C-n> from the composer's normal mode, then "new agent" (here).
"$E" keys Escape C-n
sleep 2 # vim.ui.select, which nothing can wait on
"$E" keys 1 Enter
create_from_review 'require("paseo.ui.chat").current() and require("paseo.ui.chat").current().draft ~= nil'
first="$("$E" lua '#require("paseo.ui.tree").nodes(require("paseo.ui.float").chat())')"
[ "$first" = "1" ] || fail "the draft is not an agent yet, but the tree has $first"

users_before=0
"$E" keys 'echo second agent' Escape Enter
wait_idle 40
"$E" wait "#$tree.nodes(require(\"paseo.ui.float\").chat()) == 2" 20 \
  || fail "the second agent is not on the tree: $("$E" lua "#$tree.nodes(require(\"paseo.ui.float\").chat())")"

# Into the tree and back to the first agent with <CR>.
# The agent on screen is the one marked, and <C-s> lands on it.
"$E" keys C-s
"$E" wait "vim.bo.filetype == \"paseo-sessions\"" 5 || fail "<C-s> did not land in the tree"
"$E" wait "$tree.current() and $tree.current().item.id == require(\"paseo.ui.float\").chat().agent_id" 5 \
  || fail "the tree is not seated on the agent on screen"
"$E" shot session-tree-two >/dev/null

# k, <CR>: back to the first agent.
"$E" keys k Enter
"$E" wait "require(\"paseo.ui.float\").chat().agent_id == $tree.nodes(require(\"paseo.ui.float\").chat())[1].item.id" 15 \
  || fail "<CR> on the first agent did not open it"
