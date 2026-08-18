#!/bin/sh
# Serves this customer's device names inside the session's network namespace,
# so an engineer types a name instead of an IP — and nobody edits a hosts file
# on any laptop, ever.
#
# The name list is generated from the customer's device registry at session
# start. It lives only here, only for this session, only for this customer.
set -eu

HOSTS=/etc/devices.hosts
[ -f "$HOSTS" ] || { echo "[resolver] no device file mounted"; exit 1; }

echo "[resolver] serving $(grep -vc '^#' "$HOSTS" 2>/dev/null || echo 0) names for ${SESSION_ID:-?}:"
grep -v '^#' "$HOSTS" | sed 's/^/[resolver]   /'

# 127.0.0.11 is Docker's own resolver inside this namespace: anything that is
# not one of the customer's devices still resolves normally.
exec dnsmasq \
  --keep-in-foreground \
  --log-facility=- \
  --listen-address=127.0.0.1 \
  --bind-interfaces \
  --no-resolv \
  --no-hosts \
  --addn-hosts="$HOSTS" \
  --server=127.0.0.11
