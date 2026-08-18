#!/usr/bin/env bash
# Destroys a session. Nothing survives it.
set -euo pipefail
cd "$(dirname "$0")/.."
SESSION_ID="${1:?usage: session-down.sh <customer-id>}"
SESSION_ID="$SESSION_ID" WG_CONF=/dev/null \
  docker compose -f session/docker-compose.session.yml -p "sb-session-${SESSION_ID}" down -v || true
rm -f "session/conf/${SESSION_ID}.conf"
echo "✓ session '${SESSION_ID}' destroyed"
