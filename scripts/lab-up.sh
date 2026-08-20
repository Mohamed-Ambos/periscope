#!/usr/bin/env bash
# Starts the simulated customer: VPN endpoint + a camera on an isolated LAN.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ starting console (traefik)"
docker compose -f docker-compose.console.yml up -d

echo "▶ starting simulated customer (wg-server + camera)"
docker compose -f docker-compose.lab.yml up -d --build

echo "▶ waiting for wireguard to generate a peer config"
for _ in $(seq 1 30); do
  [ -n "$(ls -d lab/wg-config/peer_* 2>/dev/null)" ] && break
  sleep 2
done

if [ -z "$(ls -d lab/wg-config/peer_* 2>/dev/null)" ]; then
  echo "✗ peer config never appeared — check: docker logs psc-wg-server" >&2
  exit 1
fi

echo "✓ lab up. Per-customer peer configs:"; ls -d lab/wg-config/peer_* | sed "s/^/    /"
