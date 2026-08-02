#!/usr/bin/env bash
# Generates a self-signed TLS cert for local dev, covering every hostname
# used inside this stack's docker network plus host.docker.internal and
# localhost. Outputs to certs/ (gitignored — never commit these).
#
#   certs/server.crt / server.key   — Prometheus, Grafana, the exporter
#   certs/broker-combined.pem       — the broker (needs key+cert in one PEM)
#
# Re-run any time to regenerate (overwrites what's there).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p certs

MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout certs/server.key -out certs/server.crt \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:host.docker.internal,DNS:solbroker,DNS:solace-exporter,DNS:prometheus,DNS:grafana,IP:127.0.0.1"

# Broker's `server-certificate` CLI command wants one PEM file with the
# private key followed by the certificate, CRLF stripped.
sed 's/\r$//' certs/server.key > certs/broker-combined.pem
sed 's/\r$//' certs/server.crt >> certs/broker-combined.pem

chmod 600 certs/server.key certs/broker-combined.pem 2>/dev/null || true

echo "Generated certs/server.crt, certs/server.key, certs/broker-combined.pem"
echo "Valid 825 days. Re-run this script to regenerate."
