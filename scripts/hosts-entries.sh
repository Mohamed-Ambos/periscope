#!/usr/bin/env bash
# Prints the /etc/hosts line this lab needs. Run the sudo command it shows.
#
# Why not *.localhost? Browsers resolve it automatically, but they REJECT a
# cookie scoped to "localhost" (a single-label TLD), and authentik's outpost
# needs exactly that cookie. Every login failed with "invalid state" until the
# lab moved to sb.test.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
D="${LAB_DOMAIN:-sb.test}"
NAMES="console.$D auth.$D"
for f in broker/devices/*.json; do
  [ -e "$f" ] || continue
  NAMES="$NAMES $(basename "$f" .json).$D"
done
LINE="127.0.0.1 $NAMES"
if grep -qF "$LINE" /etc/hosts 2>/dev/null; then
  echo "✓ /etc/hosts already has:"; echo "    $LINE"; exit 0
fi
echo "Add this line to /etc/hosts:"; echo; echo "    $LINE"; echo
echo "One command:"; echo
echo "    echo '$LINE' | sudo tee -a /etc/hosts"
