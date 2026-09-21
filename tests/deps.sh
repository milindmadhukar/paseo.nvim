#!/usr/bin/env bash
# Fetch the plugins the suite runs against, into a directory of its own.
#
# The suite used to load them out of ~/.local/share/nvim/lazy, which made a
# green run a statement about one laptop's plugin manager. These are cloned
# shallow and reused, so this is a no-op after the first run.
set -euo pipefail

dir="${1:?usage: deps.sh <dir>}"
mkdir -p "$dir"

# Floating on the default branch on purpose: volt is a hard dependency that
# moves, and a pinned SHA would turn "upstream broke us" into a surprise at
# release time instead of a red run.
repos=(
  nvzone/volt                     # the chat UI; not optional
  lewis6991/gitsigns.nvim         # the hunk under the cursor
  nvim-telescope/telescope.nvim   # the pickers
  nvim-lua/plenary.nvim           # telescope's own dependency
)

for repo in "${repos[@]}"; do
  name="${repo##*/}"
  if [ -d "$dir/$name/.git" ]; then
    git -C "$dir/$name" fetch -q --depth 1 origin HEAD
    git -C "$dir/$name" checkout -q --force FETCH_HEAD
  else
    git clone -q --depth 1 "https://github.com/$repo" "$dir/$name"
  fi
done

echo "$dir"
