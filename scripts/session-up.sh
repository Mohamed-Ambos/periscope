#!/usr/bin/env bash
# Starts one session for one customer. This is what the session manager will call.
#
#   ./scripts/session-up.sh customer2
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[ -f .env ] && . ./.env

SESSION_ID="${1:?usage: session-up.sh <customer-id>}"

# Bind-mount sources are resolved by the Docker daemon on the HOST. When the
# session manager calls this script it runs inside a container where the project is at
# /project — passing that path would mount something that does not exist.
HOST_DIR="${HOST_PROJECT_DIR:-$(pwd)}"
SRC_CONF="lab/wg-config/peer_${SESSION_ID}/peer_${SESSION_ID}.conf"
[ -f "$SRC_CONF" ] || { echo "✗ no peer config for '${SESSION_ID}' — add it to PEERS in docker-compose.lab.yml, then: docker compose -f docker-compose.lab.yml up -d --force-recreate wg-server" >&2; exit 1; }

# In production this is fetched from Infisical at start and never written to
# disk. Here it is a file, so the mechanism is visible.
mkdir -p "session/conf"
CONF="session/conf/${SESSION_ID}.conf"
# The session manager runs as root and writes this file through the Docker
# socket, so a leftover from a previous session is root-owned and a human
# running this script by hand cannot overwrite it. Removing first works
# either way: deletion needs write permission on the directory, not the file.
rm -f "$CONF"
sed "s/^Endpoint = .*/Endpoint = sb-wg-server:${WG_SERVER_PORT:-51820}/" "$SRC_CONF" > "$CONF"

# Render this customer's device names from the registry. Static IPs, one JSON
# file per customer — this is what replaces editing hosts files by hand.
DEV_JSON="session-manager/devices/${SESSION_ID}.json"
HOSTS_FILE="session/conf/${SESSION_ID}.hosts"
RESOLV_FILE="session/conf/${SESSION_ID}.resolv.conf"
if [ -f "$DEV_JSON" ]; then
  python3 - "$DEV_JSON" > "$HOSTS_FILE" <<'PYEOF'
import json, sys
reg = json.load(open(sys.argv[1]))
dom = reg.get("domain", "internal")
print(f"# generated for {reg['customer']} — {len(reg['devices'])} devices")
for d in reg["devices"]:
    print(f"{d['ip']}\t{d['name']}.{dom}\t{d['name']}")
PYEOF
  echo "  rendered $(grep -vc '^#' "$HOSTS_FILE") device names from ${DEV_JSON}"
else
  echo "# no device registry for ${SESSION_ID}" > "$HOSTS_FILE"
fi
printf 'nameserver 127.0.0.1\noptions ndots:1\n' > "$RESOLV_FILE"

echo "▶ starting session '${SESSION_ID}'"
SESSION_ID="$SESSION_ID" \
WG_CONF="${HOST_DIR}/${CONF}" \
DEV_HOSTS="${HOST_DIR}/${HOSTS_FILE}" \
RESOLV_CONF="${HOST_DIR}/${RESOLV_FILE}" \
LAB_DOMAIN="${LAB_DOMAIN:-localhost}" \
docker compose -f session/docker-compose.session.yml -p "sb-session-${SESSION_ID}" up -d --build

echo
echo "✓ session '${SESSION_ID}' is live"
echo "  open  http://${SESSION_ID}.${LAB_DOMAIN:-localhost}:${TRAEFIK_HTTP_PORT:-8088}/"
echo "  inside it, browse to a NAME, not an IP:"
grep -v '^#' "$HOSTS_FILE" | awk '{print "    https://" $2 "/"}' | head -5
