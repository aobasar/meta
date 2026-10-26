#!/usr/bin/env bash
# Start the Nova local web prototype: http://127.0.0.1:9005
#
# The server reads MODEL_API_KEY from .env.local on each request and forwards
# calls to the Meta Model API, so the browser never sees the key.
set -euo pipefail

# Fixed port, claimed for Nova with ~/.claude/AOBClaudeCodeSync/scripts/port-claim.sh.
PORT="${NOVA_PORT:-9005}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Refuse to start rather than kill whatever already holds the port.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  exit 1
fi

# Loopback only: binding to the LAN would let other devices spend the API key.
echo "Nova prototype: http://127.0.0.1:$PORT (this Mac only)"
exec python3 "$ROOT/web-prototype/server.py" --port "$PORT"
