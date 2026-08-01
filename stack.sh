#!/usr/bin/env bash
# =============================================================================
# stack.sh — lifecycle wrapper for the Solace Broker Metrics stack
#
# Owns the mapping from BROKER_MODE to COMPOSE_PROFILES, so the broker switch
# stays a single variable rather than two that must agree.
#
# Run from Git Bash / WSL on Windows, or any POSIX shell elsewhere.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; CYN=''; RST=''
fi
info()  { printf '%s==>%s %s\n' "$CYN" "$RST" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$YLW" "$RST" "$*"; }
die()   { printf '%s[error]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

load_env() {
  if [ ! -f .env ]; then
    warn ".env not found — creating it from .env.example"
    cp .env.example .env
    printf '\n'
    printf '%sEdit .env before continuing.%s At minimum review the credentials\n' "$BOLD" "$RST"
    printf 'and, if you are using your own broker, set BROKER_MODE=external plus\n'
    printf 'the SOLACE_BROKER_HOST / SOLACE_SEMP_URL values.\n\n'
    printf 'Then re-run: %s./stack.sh %s%s\n' "$DIM" "${1:-up}" "$RST"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a

  : "${BROKER_MODE:?BROKER_MODE must be set in .env}"
  case "$BROKER_MODE" in
    local|external) ;;
    *) die "BROKER_MODE must be 'local' or 'external', got '$BROKER_MODE'" ;;
  esac
}

compose() {
  local profiles=""
  if [ "$BROKER_MODE" = "local" ]; then
    profiles="local-broker"
  fi
  COMPOSE_PROFILES="$profiles" docker compose "$@"
}

cmd_up() {
  load_env up
  info "Bringing up the stack (BROKER_MODE=$BROKER_MODE)"
  if [ "$BROKER_MODE" = "external" ]; then
    info "External broker: $SOLACE_SEMP_URL — no broker container will be started"
  fi
  compose up -d
  printf '\n'
  info "Started. The exporter waits for broker-bootstrap to finish, so give it a few seconds."
  printf '\n'
  cmd_urls
  printf '\n'
  printf 'Then run: %s./stack.sh verify%s\n' "$BOLD" "$RST"
}

cmd_down() {
  load_env down
  info "Stopping the stack — volumes are kept, so all configuration and metrics history survive"
  compose down
  info "Done. './stack.sh up' brings it back with everything intact."
}

cmd_stop()  { load_env stop;  info "Pausing containers"; compose stop; }
cmd_start() { load_env start; info "Resuming containers"; compose start; }
cmd_ps()    { load_env ps;    compose ps; }

cmd_logs() {
  load_env logs
  shift || true
  if [ $# -gt 0 ]; then
    compose logs -f --tail=200 "$@"
  else
    compose logs -f --tail=100
  fi
}

cmd_setup() {
  load_env setup
  if [ "${BOOTSTRAP_ENABLED:-true}" != "true" ]; then
    warn "BOOTSTRAP_ENABLED=false in .env — nothing to do."
    warn "Set it to true if you want this stack to configure the broker."
    return 0
  fi
  info "Applying broker configuration over SEMP ($SOLACE_SEMP_URL)"
  compose run --rm --no-deps broker-bootstrap
}

cmd_verify() {
  load_env verify
  shift || true
  exec ./scripts/verify.sh "$@"
}

cmd_reset() {
  load_env reset
  printf '%sThis deletes all volumes:%s\n' "$BOLD$RED" "$RST"
  printf '  - broker configuration and message spool\n'
  printf '  - every metric stored in Prometheus\n'
  printf '  - Grafana users, dashboards and settings\n\n'
  printf 'The broker will be reconfigured from scratch on the next up.\n\n'
  read -r -p "Type 'reset' to confirm: " reply
  [ "$reply" = "reset" ] || { info "Cancelled."; return 0; }
  compose down -v
  info "Volumes removed. './stack.sh up' rebuilds from nothing."
}

cmd_urls() {
  load_env urls
  printf '%sEndpoints%s\n' "$BOLD" "$RST"
  printf '  Grafana            http://localhost:%s  (%s / %s)\n' \
    "${PORT_GRAFANA}" "${GF_ADMIN_USER}" "${GF_ADMIN_PASSWORD}"
  printf '  Prometheus         http://localhost:%s\n' "${PORT_PROMETHEUS}"
  printf '  Exporter           http://localhost:%s/solace-std\n' "${PORT_EXPORTER}"
  if [ "$BROKER_MODE" = "local" ]; then
    printf '  Broker manager     http://localhost:%s  (%s / %s)\n' \
      "${PORT_BROKER_SEMP}" "${SOLACE_ADMIN_USER}" "${SOLACE_ADMIN_PASSWORD}"
    printf '\n%sSend traffic with sdkperf%s\n' "$BOLD" "$RST"
    printf '  sdkperf_java.sh -cip=localhost:%s -cu=%s@%s -cp=%s \\\n' \
      "${PORT_BROKER_SMF}" "${SOLACE_APP_USER}" "${SOLACE_MSG_VPN}" "${SOLACE_APP_PASSWORD}"
    printf '                  -ptl=%s/load -mn=1000 -mr=50\n' "${SOLACE_DEMO_TOPIC}"
  else
    printf '  Broker (external)  %s\n' "${SOLACE_SEMP_HOST_URL}"
  fi
}

usage() {
  cat <<EOF
${BOLD}stack.sh${RST} — Solace Broker Metrics

  ${BOLD}up${RST}          Start everything. Creates .env from the example on first run.
  ${BOLD}down${RST}        Stop and remove containers. Volumes and data are kept.
  ${BOLD}stop${RST}        Pause containers without removing them.
  ${BOLD}start${RST}       Resume paused containers.
  ${BOLD}setup${RST}       Re-apply broker configuration over SEMP. Idempotent.
  ${BOLD}verify${RST}      Check every hop of the pipeline and report what is broken.
  ${BOLD}logs${RST} [svc]  Follow logs. Service names: solbroker, solace-exporter,
              prometheus, grafana, broker-bootstrap.
  ${BOLD}ps${RST}          Show container status.
  ${BOLD}urls${RST}        Print endpoints, credentials and an sdkperf command line.
  ${BOLD}reset${RST}       ${RED}Destructive.${RST} Delete all volumes and start over.

Typical first run:

  ./stack.sh up
  ./stack.sh verify
EOF
}

case "${1:-help}" in
  up)      cmd_up ;;
  down)    cmd_down ;;
  stop)    cmd_stop ;;
  start)   cmd_start ;;
  setup)   cmd_setup ;;
  verify)  cmd_verify "$@" ;;
  logs)    cmd_logs "$@" ;;
  ps)      cmd_ps ;;
  urls)    cmd_urls ;;
  reset)   cmd_reset ;;
  help|-h|--help) usage ;;
  *)       printf '%sUnknown command: %s%s\n\n' "$RED" "$1" "$RST"; usage; exit 1 ;;
esac
