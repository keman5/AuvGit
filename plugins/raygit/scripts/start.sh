#!/bin/sh
set -eu
RAYGIT_PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -n "${CODEX_MCP_NODE_PATH:-}" ] && [ -x "$CODEX_MCP_NODE_PATH" ]; then
  exec "$CODEX_MCP_NODE_PATH" "$RAYGIT_PLUGIN_DIR/dist/server.cjs"
elif [ -x "$RAYGIT_PLUGIN_DIR/runtime/node" ]; then
  exec "$RAYGIT_PLUGIN_DIR/runtime/node" "$RAYGIT_PLUGIN_DIR/dist/server.cjs"
elif command -v node >/dev/null 2>&1; then
  exec node "$RAYGIT_PLUGIN_DIR/dist/server.cjs"
else
  echo 'RayGit: no compatible Node runtime. Install the packaged build for this platform.' >&2
  exit 1
fi
