#!/usr/bin/env bash
# Certbot --deploy-hook script. Triggered after a successful renewal.
# Copies new cert into the docker-compose certs dir and restarts kroxy.
set -euo pipefail

: "${RENEWED_DOMAINS:?certbot sets this; if running by hand, export RENEWED_DOMAINS=<your-hostname>}"
DOMAIN="$RENEWED_DOMAINS"
PROJECT_DIR="${PROJECT_DIR:-/opt/kroxy}"
LIVE="/etc/letsencrypt/live/$DOMAIN"
DEST="$PROJECT_DIR/certs"

cp "$LIVE/fullchain.pem" "$DEST/fullchain.pem"
cp "$LIVE/privkey.pem"   "$DEST/privkey.pem"
chmod 644 "$DEST"/*.pem

cd "$PROJECT_DIR" && docker compose restart
