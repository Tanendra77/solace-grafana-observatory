#!/usr/bin/env bash
# =============================================================================
# verify.sh — prove the metrics pipeline actually works, hop by hop
#
# Every component here can look healthy while doing nothing: a container can
# be Running with the exporter unable to auth to SEMP, Prometheus can be up
# with every target down, Grafana can serve fine with no datasource. These
# checks target the difference between "up" and "working".
#
# Invoked by ./stack.sh verify. No jq required — only curl, grep and sed.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; RST=''
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

PASS=0; FAIL=0

pass() { printf '  %s[ok]%s   %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS+1)); }
fail() {
  printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$1"
  [ -n "${2:-}" ] && printf '         %s-> %s%s\n' "$YLW" "$2" "$RST"
  FAIL=$((FAIL+1))
}
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

field() {
  printf '%s' "$1" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" \
    | head -1 \
    | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//'
}

printf '%sVerifying Solace Broker Metrics stack%s  %s(broker mode: %s)%s\n' \
  "$BOLD" "$RST" "$DIM" "$BROKER_MODE" "$RST"

# -----------------------------------------------------------------------------
section "1. Containers"
# -----------------------------------------------------------------------------
expected="solace-exporter prometheus grafana"
[ "$BROKER_MODE" = "local" ] && expected="solbroker $expected"
for svc in $expected; do
  cname=$(docker ps --filter "label=com.docker.compose.service=$svc" \
                    --filter "label=com.docker.compose.project=solace-metrics-observatory" \
                    --format '{{.Names}}' | head -1)
  if [ -n "$cname" ]; then
    pass "$svc running ($cname)"
  else
    fail "$svc is not running" "./stack.sh up   (then ./stack.sh logs $svc)"
  fi
done

# -----------------------------------------------------------------------------
section "2. Broker"
# -----------------------------------------------------------------------------
if [ "$BROKER_MODE" = "local" ]; then
  if curl -sf -m 10 "http://localhost:${PORT_BROKER_HEALTH}/health-check/guaranteed-active" >/dev/null 2>&1; then
    pass "broker healthy (guaranteed messaging active)"
  else
    fail "broker health check failed" "still booting? give it 60-90s, then ./stack.sh logs solbroker"
  fi
else
  printf '  %s[skip]%s health check — external broker, endpoint unknown\n' "$DIM" "$RST"
fi

vpn_json=$(curl -s -m 10 -u "${SOLACE_ADMIN_USER}:${SOLACE_ADMIN_PASSWORD}" \
  "${SOLACE_SEMP_HOST_URL%/}/SEMP/v2/config/msgVpns/${SOLACE_MSG_VPN}" 2>/dev/null)
if [ "$(field "$vpn_json" enabled)" = "true" ]; then
  pass "message VPN '${SOLACE_MSG_VPN}' exists and is enabled"
else
  fail "message VPN '${SOLACE_MSG_VPN}' not found or disabled" "./stack.sh setup"
fi

if curl -s -o /dev/null -w '%{http_code}' -m 10 -u "monitor:${SOLACE_MONITOR_PASSWORD}" \
   "${SOLACE_SEMP_HOST_URL%/}/SEMP/v2/config/msgVpns" 2>/dev/null | grep -q '^200$'; then
  pass "monitor SEMP user can authenticate"
else
  fail "monitor SEMP user cannot authenticate" \
       "check SOLACE_MONITOR_PASSWORD in .env matches what solbroker booted with; ./stack.sh reset if it was changed after first boot"
fi

# -----------------------------------------------------------------------------
section "3. Exporter"
# -----------------------------------------------------------------------------
std=$(curl -s -m 10 "http://localhost:${PORT_EXPORTER}/solace-std" 2>/dev/null)
n=$(printf '%s' "$std" | grep -c '^solace_')
if [ "$n" -gt 50 ] 2>/dev/null; then
  pass "exporter serving /solace-std (${n} solace_* series)"
else
  fail "exporter /solace-std returned too few series (${n})" "./stack.sh logs solace-exporter"
fi

det=$(curl -s -m 15 "http://localhost:${PORT_EXPORTER}/solace-det" 2>/dev/null)
if printf '%s' "$det" | grep -q "solace_queue_spool_usage_msgs{queue_name=\"${SOLACE_DEMO_QUEUE}\""; then
  pass "exporter serving queue-level detail for '${SOLACE_DEMO_QUEUE}'"
else
  fail "no queue-level metrics for '${SOLACE_DEMO_QUEUE}' on /solace-det" "./stack.sh setup, then ./stack.sh logs solace-exporter"
fi

# -----------------------------------------------------------------------------
section "4. Prometheus"
# -----------------------------------------------------------------------------
targets=$(curl -s -m 10 "http://localhost:${PORT_PROMETHEUS}/api/v1/targets" 2>/dev/null)
for job in solace-std solace-vpn-stats solace-det; do
  if printf '%s' "$targets" | grep -o "\"job\":\"$job\".*\"health\":\"up\"" >/dev/null 2>&1; then
    pass "target '$job' is up"
  else
    fail "target '$job' is not up" "http://localhost:${PORT_PROMETHEUS}/targets shows why"
  fi
done

q=$(curl -s -m 10 "http://localhost:${PORT_PROMETHEUS}/api/v1/query?query=solace_system_redundancy_up" 2>/dev/null)
if printf '%s' "$q" | grep -q '"resultType":"vector"' && printf '%s' "$q" | grep -q '"value"'; then
  pass "Prometheus has ingested solace_system_redundancy_up"
else
  fail "Prometheus query for solace_system_redundancy_up returned no data" "./stack.sh logs prometheus"
fi

# -----------------------------------------------------------------------------
section "5. Grafana"
# -----------------------------------------------------------------------------
ds=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
      "http://localhost:${PORT_GRAFANA}/api/datasources" 2>/dev/null)
if printf '%s' "$ds" | grep -q '"type"[[:space:]]*:[[:space:]]*"prometheus"'; then
  pass "Prometheus datasource present in Grafana"
  health=$(curl -s -m 15 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
            "http://localhost:${PORT_GRAFANA}/api/datasources/uid/prometheus-solace/health" 2>/dev/null)
  if printf '%s' "$health" | grep -q '"status"[[:space:]]*:[[:space:]]*"OK"'; then
    pass "Grafana can query Prometheus"
  else
    fail "Grafana has the datasource but cannot query Prometheus" \
         "$(printf '%s' "$health" | sed 's/.*"message":"\([^"]*\)".*/\1/')"
  fi
elif printf '%s' "$ds" | grep -qi "invalid.*credential\|unauthorized"; then
  fail "Grafana rejected the credentials" \
       "with a persistent volume the password is fixed at first boot; ./stack.sh reset to change it"
else
  fail "Prometheus datasource missing from Grafana" "check ./stack.sh logs grafana for provisioning errors"
fi

dash=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
        "http://localhost:${PORT_GRAFANA}/api/dashboards/uid/solace-broker-metrics" 2>/dev/null)
if printf '%s' "$dash" | grep -q '"uid":"solace-broker-metrics"'; then
  pass "dashboard 'Solace Broker — Metrics' provisioned"
else
  fail "dashboard not found" "check ./stack.sh logs grafana for provisioning errors"
fi

# -----------------------------------------------------------------------------
printf '\n%s%d passed, %d failed%s\n' "$BOLD" "$PASS" "$FAIL" "$RST"

if [ "$FAIL" -gt 0 ]; then
  printf '%sPipeline is not fully working — fix the first failure above and re-run.%s\n' "$RED" "$RST"
  exit 1
fi

printf '%sEverything checks out. Dashboard at http://localhost:%s -> Dashboards -> Solace Broker — Metrics.%s\n' \
  "$GRN" "${PORT_GRAFANA}" "$RST"
