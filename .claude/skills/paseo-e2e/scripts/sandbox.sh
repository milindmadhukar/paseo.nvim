#!/usr/bin/env bash
# sandbox.sh : make sure the sandbox project exists. Idempotent.
source "$(dirname "$0")/env.sh"
if [ ! -d "$E2E_SANDBOX/.git" ]; then
  mkdir -p "$E2E_SANDBOX"
  git -C "$E2E_SANDBOX" init -q
  printf '# paseo.nvim e2e sandbox\n\nThrowaway project for driving paseo.nvim against real agents. Safe to delete.\n' > "$E2E_SANDBOX/README.md"
  git -C "$E2E_SANDBOX" add README.md
  git -C "$E2E_SANDBOX" commit -q -m "chore: sandbox"
fi
echo "$E2E_SANDBOX"
