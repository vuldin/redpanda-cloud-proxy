#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source ./.env

BROKER="${PROXY_HOST}:9192"
COMMON=(
  -X "brokers=${BROKER}"
  -X "user=${RPK_USER}"
  -X "pass=${RPK_PASS}"
  -X "sasl.mechanism=${RPK_SASL_MECHANISM}"
  -X "tls.enabled=false"
)

echo "=== metadata via proxy ==="
rpk "${COMMON[@]}" cluster metadata

echo
echo "=== create + produce + consume ==="
rpk "${COMMON[@]}" topic create poc-test --if-not-exists
echo "hello-from-proxy" | rpk "${COMMON[@]}" topic produce poc-test
rpk "${COMMON[@]}" topic consume poc-test -n 1
