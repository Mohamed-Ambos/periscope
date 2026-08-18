#!/usr/bin/env bash
# Starts one session for one customer. This is what the broker will call.
#
#   ./scripts/session-up.sh customer2
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[ -f .env ] && . ./.env

SESSION_ID="${1:?usage: session-up.sh <customer-id>}"
SRC_CONF="lab/wg-config/peer_${SESSION_ID}/peer_${SESSION_ID}.conf"
[ -f "$SRC_CONF" ] || { echo "✗ no peer config for '${SESSION_ID}' — add it to PEERS in docker-compose.lab.yml, then: docker compose -f docker-compose.lab.yml up -d --force-recreate wg-server" >&2; exit 1; }

# In production this is fetched from Infisical at start and never written to
# disk. Here it is a file, so the mechanism is visible.
mkdir -p "session/conf"
CONF="session/conf/${SESSION_ID}.conf"
sed "s/^Endpoint = .*/Endpoint = sb-wg-server:${WG_SERVER_PORT:-51820}/" "$SRC_CONF" > "$CONF"

echo "▶ starting session '${SESSION_ID}'"
SESSION_ID="$SESSION_ID" \
WG_CONF="$(pwd)/${CONF}" \
LAB_DOMAIN="${LAB_DOMAIN:-localhost}" \
docker compose -f session/docker-compose.session.yml -p "sb-session-${SESSION_ID}" up -d --build

echo
echo "✓ session '${SESSION_ID}' is live"
echo "  open  http://${SESSION_ID}.${LAB_DOMAIN:-localhost}:${TRAEFIK_HTTP_PORT:-8088}/"
echo "  then browse to  https://${CAMERA_IP:-172.31.90.10}/  inside it"
