#!/usr/bin/env bash
# Destroys a session. Nothing survives it.
set -euo pipefail
cd "$(dirname "$0")/.."
SESSION_ID="${1:?usage: session-down.sh <customer-id>}"

# Every ${VAR} the session compose file interpolates must be set here too, even
# though nothing is mounted on the way down: an unset one renders an empty
# mount source (":/etc/devices.hosts:ro"), compose refuses to parse the file,
# and `down` never runs. That failure used to be swallowed by `|| true`, so the
# script printed "destroyed" while all three containers were still there.
if SESSION_ID="$SESSION_ID" \
   WG_CONF=/dev/null DEV_HOSTS=/dev/null RESOLV_CONF=/dev/null \
   docker compose -f session/docker-compose.session.yml \
     -p "sb-session-${SESSION_ID}" down -v --remove-orphans; then
  ok=1
else
  ok=0
fi

rm -f "session/conf/${SESSION_ID}.conf" \
      "session/conf/${SESSION_ID}.hosts" \
      "session/conf/${SESSION_ID}.resolv.conf"

# Say what actually happened. A session that outlives its own teardown is the
# one failure this design cannot tolerate quietly.
left=$(docker ps -aq --filter "name=sb-${SESSION_ID}-" | wc -l)
if [ "$ok" = 1 ] && [ "$left" -eq 0 ]; then
  echo "✓ session '${SESSION_ID}' destroyed"
else
  echo "✗ session '${SESSION_ID}' NOT fully destroyed — ${left} container(s) remain" >&2
  docker ps -a --filter "name=sb-${SESSION_ID}-" --format '    {{.Names}}  {{.Status}}' >&2
  exit 1
fi
