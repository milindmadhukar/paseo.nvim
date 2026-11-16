# A folder Paseo has never seen is asked about before it becomes a project.
#
# The regression: the first session started anywhere registered that folder
# with the daemon, so `nvim ~`, `:Paseo` and a prompt made your home directory
# a project without a word.
#
#   plain folder   the rail says `new`; sending asks; Cancel starts nothing
#                  and keeps the words; "Add it" starts the session
#   git repo       starts unasked
#   $HOME          refused: nothing starts, nothing is added
source "$(dirname "$0")/../lib.sh"

# Is `$1` one of the daemon's projects?
project_has() {
  "$D" paseo project ls --json 2>/dev/null |
    python3 -I -c "import os,sys; r=os.path.realpath(sys.argv[1]); print(1 if ('\"' + r + '\"') in sys.stdin.read() else 0)" "$1"
}

sessions_in() {
  "$D" paseo workspace ls --json 2>/dev/null |
    python3 -I -c "import json,os,sys; r=os.path.realpath(sys.argv[1]); print(len([w for w in json.load(sys.stdin) if os.path.realpath(w.get('cwd') or '') == r]))" "$1"
}

wait_for() { # <shell expr> <seconds>
  for _ in $(seq 1 $(( $2 * 2 ))); do
    eval "$1" && return 0
    sleep 0.5
  done
  return 1
}

chat_fn='(function() _G.paseo_e2e.chat = function() return require("paseo.ui.native").chat() or require("paseo.ui.chat").current() end; return true end)()'
composer='table.concat(vim.api.nvim_buf_get_lines(_G.paseo_e2e.chat().composer, 0, -1, false), "\n")'
choosing='vim.bo.filetype == "paseo-choose"'
header='(function() local r = require("paseo.ui.rail").build(32).right[1]; return r and r[1][1] or "" end)()'

# ------------------------------------------------------------- plain folder
plain="$PASEO_E2E_ROOT/repos/new-folder-plain-$$-$RANDOM"
mkdir -p "$plain"
echo "notes" >"$plain/notes.txt"
plain="$(cd "$plain" && pwd -P)"

"$E" stop
"$E" start "$plain"
"$E" lua "$chat_fn" >/dev/null
"$E" keys ':Paseo' Enter
new_task_ready
"$E" wait "$header == \"new \"" 15 || fail "the rail does not mark a folder Paseo has never seen: '$("$E" lua "$header")'"
"$E" shot new-folder-rail >/dev/null

"$E" keys 'Read the notes' Escape Enter
"$E" wait "$choosing" 10 || fail "sending in a plain folder did not ask"
"$E" shot new-folder-confirm >/dev/null
"$E" keys 1  # Cancel
"$E" wait "not ($choosing)" 5 || fail "the question did not close"
sleep 1
[ "$(project_has "$plain")" = 0 ] || fail "Cancel still made $plain a project"
[ "$(sessions_in "$plain")" = 0 ] || fail "Cancel still started a session"
"$E" wait "($composer):find(\"Read the notes\", 1, true) ~= nil" 5 \
  || fail "Cancel lost the prompt: '$("$E" lua "$composer")'"

"$E" keys Escape Enter
"$E" wait "$choosing" 10 || fail "sending again did not ask again"
"$E" keys 2  # Add it
wait_for '[ "$(sessions_in "$plain")" = 1 ]' 30 || fail "Add it did not start the session"
wait_for '[ "$(project_has "$plain")" = 1 ]' 10 || fail "Add it did not make $plain a project"

# ----------------------------------------------------------------- git repo
repo="$(fresh_repo)"
"$E" stop
"$E" start "$repo"
"$E" lua "$chat_fn" >/dev/null
"$E" keys ':Paseo' Enter
new_task_ready
"$E" keys 'Read the README' Escape Enter
wait_for '[ "$(sessions_in "$repo")" = 1 ]' 30 || fail "a git repo should start unasked"
[ "$("$E" lua "$choosing and 1 or 0")" = 0 ] || fail "a git repo was asked about"

# -------------------------------------------------------------------- $HOME
home="$PASEO_E2E_ROOT/repos/new-folder-home-$$-$RANDOM"
mkdir -p "$home"
home="$(cd "$home" && pwd -P)"
"$E" stop
"$E" start "$home"
"$E" lua "$chat_fn" >/dev/null
"$E" lua "(function() vim.env.HOME = \"$home\"; return true end)()" >/dev/null
"$E" keys ':Paseo' Enter
new_task_ready
"$E" keys 'Tidy my home' Escape Enter
"$E" wait "($composer):find(\"Tidy my home\", 1, true) ~= nil" 10 || fail "a refused start lost the prompt"
sleep 1
[ "$("$E" lua "$choosing and 1 or 0")" = 0 ] || fail "\$HOME was asked about instead of refused"
[ "$(sessions_in "$home")" = 0 ] || fail "a session started in \$HOME"
[ "$(project_has "$home")" = 0 ] || fail "\$HOME became a project"
"$E" shot new-folder-home >/dev/null

echo "ok new-folder"
