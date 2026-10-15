#!/bin/sh
set -eu
AUVGIT_PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export AUVGIT_PLUGIN_ROOT="$AUVGIT_PLUGIN_DIR"
if [ -x "$AUVGIT_PLUGIN_DIR/runtime/node" ]; then
  exec "$AUVGIT_PLUGIN_DIR/runtime/node" "$AUVGIT_PLUGIN_DIR/dist/server.cjs"
elif command -v node >/dev/null 2>&1; then
  exec node "$AUVGIT_PLUGIN_DIR/dist/server.cjs"
else
  echo 'AuvGit: no compatible Node runtime. Install the packaged build for this platform.' >&2
  exit 1
fi
