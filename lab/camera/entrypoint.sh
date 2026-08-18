#!/bin/sh
# A real camera ships a self-signed certificate for its own serial/hostname,
# which never matches the address you reach it on. Reproduce that exactly:
# the point of the lab is that the session must cope with an untrusted cert.
set -eu
CERT=/etc/nginx/cert.pem
KEY=/etc/nginx/key.pem

if [ ! -f "$CERT" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=${CAMERA_SERIAL:-ACCC8E1234AB}" \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
fi

cat > /etc/nginx/conf.d/default.conf <<NGINX
server {
    listen 443 ssl;
    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
    root /usr/share/nginx/html;
    add_header X-Camera-Serial "${CAMERA_SERIAL:-ACCC8E1234AB}";
}
server {
    listen 80;
    return 301 https://\$host\$request_uri;
}
NGINX

echo "[camera] ${CAMERA_NAME:-camera} serial=${CAMERA_SERIAL:-ACCC8E1234AB} up on :443 (self-signed)"
exec nginx -g 'daemon off;'
