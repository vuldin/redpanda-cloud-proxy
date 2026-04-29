#!/usr/bin/env bash
# Run on the VM. Issues an LE cert via HTTP-01 and copies it into ./certs/
# so the Kroxylicious container can read it.
set -euo pipefail

: "${DOMAIN:?set DOMAIN to the public hostname for the proxy (matches LE cert)}"
: "${EMAIL:?set EMAIL to the LE registration email}"
PROJECT_DIR="${PROJECT_DIR:-/opt/kroxy}"

echo "[*] Issuing LE cert for $DOMAIN (HTTP-01, port 80)"
sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN" \
  --preferred-challenges http

LIVE="/etc/letsencrypt/live/$DOMAIN"
DEST="$PROJECT_DIR/certs"

echo "[*] Copying cert + key into $DEST (container-readable)"
sudo mkdir -p "$DEST"
sudo cp "$LIVE/fullchain.pem" "$DEST/fullchain.pem"
sudo cp "$LIVE/privkey.pem"   "$DEST/privkey.pem"
sudo chmod 644 "$DEST/fullchain.pem"
sudo chmod 644 "$DEST/privkey.pem"

echo "[*] Done. Cert files at $DEST"
ls -la "$DEST"
