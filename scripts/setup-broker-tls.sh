#!/usr/bin/env bash
# Loads certs/broker-combined.pem onto the broker as its TLS server
# certificate, over the CLI (SSH) — Solace has no SEMP REST endpoint for
# this, same situation as the monitor user in create-monitor-user.sh.
#
# Run ./scripts/generate-certs.sh first. SSH will prompt for the admin
# password interactively.
#
# Usage: ./scripts/setup-broker-tls.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] || { echo "no .env found — copy .env.example to .env first"; exit 1; }
set -a; . ./.env; set +a

CERT_FILE="certs/broker-combined.pem"
[ -f "$CERT_FILE" ] || { echo "$CERT_FILE not found — run ./scripts/generate-certs.sh first"; exit 1; }

SSH_HOST=$(printf '%s' "$SOLACE_SEMP_URL" | sed -E 's#^https?://##; s#:.*##')
SSH_PORT="${PORT_BROKER_SSH:-2222}"

# The CLI's file-contents parameter takes the whole PEM as one line, with
# real newlines encoded as the two-character sequence \n. Built with a plain
# bash read loop (not awk/sed printf) because printf-style tools re-interpret
# \n as an actual newline in their own format string, undoing the escaping.
pem_escaped=""
while IFS= read -r line; do
  pem_escaped="${pem_escaped}${line}\\n"
done < <(sed 's/\r$//' "$CERT_FILE")

ssh -p "$SSH_PORT" "${SOLACE_ADMIN_USER}@${SSH_HOST}" <<EOF
enable
configure
ssl
server-certificate broker-combined.pem file-contents "${pem_escaped}"
exit
exit
EOF

echo "TLS server certificate loaded. SEMP is now also reachable over HTTPS on port ${PORT_BROKER_SEMP_TLS:-1943}."
