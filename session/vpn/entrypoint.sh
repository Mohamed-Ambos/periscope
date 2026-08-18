#!/bin/sh
# Brings up the tunnel, then stays alive for as long as the session lives.
# Deliberately NOT a default route: only the customer's subnets go over wg0,
# so a session can reach that customer and nothing else.
set -eu

echo "[vpn] starting tunnel for session ${SESSION_ID:-?}"
wg-quick up wg0

echo "[vpn] interface up:"
wg show wg0 | sed 's/^/[vpn]   /'
ip route | sed 's/^/[vpn]   route: /'

# wg-quick returns immediately; hold the namespace open for the browser.
trap 'echo "[vpn] tearing down"; wg-quick down wg0 || true; exit 0' TERM INT
while :; do sleep 3600 & wait $!; done
