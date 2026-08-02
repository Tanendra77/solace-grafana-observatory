#!/usr/bin/env bash
# Creates the read-only "monitor" SEMP user the exporter needs, on a broker
# you already have running (docker-compose.broker.yaml creates it for you
# automatically — this script is only for bringing your own broker).
#
# Broker-level users aren't manageable over SEMP's REST API, only via CLI —
# this opens an SSH session and feeds it the CLI commands. SSH will prompt
# for the admin password interactively.
#
# Usage: ./scripts/create-monitor-user.sh
# Reads SOLACE_SEMP_URL, PORT_BROKER_SSH, SOLACE_ADMIN_USER, and
# SOLACE_MONITOR_PASSWORD from .env.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] || { echo "no .env found — copy .env.example to .env first"; exit 1; }
set -a; . ./.env; set +a

SSH_HOST=$(printf '%s' "$SOLACE_SEMP_URL" | sed -E 's#^https?://##; s#:.*##')

ssh -p "${PORT_BROKER_SSH:-2222}" "${SOLACE_ADMIN_USER}@${SSH_HOST}" <<EOF
enable
configure
create username monitor
password ${SOLACE_MONITOR_PASSWORD}
global-access-level read-only
no shutdown
exit
exit
EOF
