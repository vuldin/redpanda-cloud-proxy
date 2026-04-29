#!/usr/bin/env bash
# Run from your laptop. Exercises the proxy over real TLS via the public hostname.
set -euo pipefail

# shellcheck disable=SC1091
source ./.env

BROKER="${PROXY_HOST}:9192"
COMMON=(
  -X "brokers=${BROKER}"
  -X "user=${RPK_USER}"
  -X "pass=${RPK_PASS}"
  -X "sasl.mechanism=${RPK_SASL_MECHANISM}"
  -X "tls.enabled=true"
)

echo "=== metadata via proxy (TLS) ==="
rpk "${COMMON[@]}" cluster metadata

echo
echo "=== produce + consume (TLS) ==="
rpk "${COMMON[@]}" topic create poc-tls --if-not-exists
echo "hello-from-proxy-tls" | rpk "${COMMON[@]}" topic produce poc-tls
rpk "${COMMON[@]}" topic consume poc-tls -n 1
