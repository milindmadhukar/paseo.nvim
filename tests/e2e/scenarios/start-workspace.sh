# "New agent in a new workspace" sends its first prompt WITH the workspace,
# so the daemon names it -- a worktree here, since the fixture is one repo.
#
# The regression: the workspace was created bare (titled with the slug typed
# for its directory) and the agent started in it afterwards, so its name was
# the slug for good. The slug still picks the branch; the title must not be it.
source "$(dirname "$0")/../lib.sh"

repo="$PASEO_E2E_ROOT/fresh-$$-$RANDOM"
mkdir -p "$repo"
git -C "$repo" init -q -b main
echo hi >"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false commit -qm init

"$E" stop
"$E" start "$repo"
"$E" keys ':Paseo chat' Enter
sleep 5 # the start menu is a vim.ui.select prompt, which nothing can wait on
"$E" keys 2 Enter
sleep 1
"$E" keys C-u 'billing-fix' Enter
"$E" wait 'vim.api.nvim_win_get_config(0).relative ~= ""' 10 || fail "no review"
sleep 2
"$E" keys c
"$E" wait 'vim.bo.buftype == "nofile" and vim.api.nvim_win_get_config(0).relative ~= ""' 10 || fail "no prompt box"
sleep 1
"$E" keys 'Fix the invoice rounding in billing' Escape Enter

"$E" wait 'require("paseo.ui.chat").current() and require("paseo.ui.chat").current().agent_id ~= nil' 60 \
  || fail "no agent was opened"

# One workspace that is not the repo: the worktree.
name=""
for _ in $(seq 1 60); do
  name="$("$D" paseo workspace ls --json 2>/dev/null | python3 -I -c '
import json, sys
ws = [w for w in json.load(sys.stdin) if w.get("cwd", "").find("billing-fix") >= 0 or w.get("name", "").find("billing") >= 0]
print(ws[0]["name"] if ws else "")')"
  [ -n "$name" ] && [ "$name" != "billing-fix" ] && [ "$name" != "ws/billing-fix" ] && break
  sleep 0.5
done
[ -n "$name" ] || fail "no workspace was created"
[ "$name" != "billing-fix" ] && [ "$name" != "ws/billing-fix" ] || fail "still named by its slug: $name"
echo "  titled: $name"
"$E" shot start-workspace >/dev/null
