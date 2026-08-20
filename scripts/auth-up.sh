#!/usr/bin/env bash
# Starts authentik and waits until it is actually ready. First boot runs
# database migrations and takes a few minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f docker-compose.auth.yml up -d
echo "▶ waiting for authentik (first boot migrates the database, be patient)"
until curl -s -o /dev/null -w '%{http_code}' -H 'Host: auth.psc.test' \
        http://127.0.0.1:"${TRAEFIK_HTTP_PORT:-8088}"/-/health/ready/ | grep -q 200; do
  sleep 10; printf '.'
done
echo
echo "✓ authentik ready — log in at http://console.localhost:8088/ as akadmin"
echo "  password: see AK_ADMIN_PASSWORD in .env"
