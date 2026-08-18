#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for p in $(docker compose ls --format json | grep -o 'sb-session-[a-z0-9-]*' | sort -u); do
  docker compose -p "$p" down -v 2>/dev/null || true
done
docker compose -f docker-compose.lab.yml down -v
docker compose -f docker-compose.console.yml down
echo "✓ everything down"
