#!/usr/bin/env bash
# probe.sh [lua-expression]
#
# No argument: the state summary -- mode, mount, held requests, the dialog or
# overlay showing. With one: evaluate it in the e2e Neovim and print the result
# (wrap tables in vim.inspect).
source "$(dirname "$0")/env.sh"
nvim --server "$(cat "$E2E_RUN/sock")" --remote-expr "luaeval('${1:-require(\"paseo.e2e_probe\").state()}')"
echo
