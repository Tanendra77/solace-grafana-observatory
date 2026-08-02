#!/usr/bin/env bash
# Checks the pipeline hop by hop — "up" isn't the same as "working".
# Run directly: ./scripts/verify.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; RST=''
fi

[ -f .env ] || { echo "no .env found — copy .env.example to .env first"; exit 1; }

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# Every hop in this stack serves TLS with a self-signed cert — -k
# (insecure) is deliberate throughout this script, not an oversight.
curl() { command curl -k "$@"; }

PASS=0; FAIL=0

pass() { printf '  %s[ok]%s   %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS+1)); }
fail() {
  printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$1"
  [ -n "${2:-}" ] && printf '         %s-> %s%s\n' "$YLW" "$2" "$RST"
  FAIL=$((FAIL+1))
}
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

printf '%sVerifying Solace Broker Metrics stack%s\n' "$BOLD" "$RST"

section "1. Containers"
# Broker isn't checked here — it may be its own compose file or your own broker.
for svc in solace-exporter prometheus grafana; do
  cname=$(docker ps --filter "label=com.docker.compose.service=$svc" \
                    --filter "label=com.docker.compose.project=solace-metrics-observatory" \
                    --format '{{.Names}}' | head -1)
  if [ -n "$cname" ]; then
    pass "$svc running ($cname)"
  else
    fail "$svc is not running" "docker compose up -d   (then docker compose logs $svc)"
  fi
done

# -----------------------------------------------------------------------------
section "2. Broker"
# -----------------------------------------------------------------------------
if curl -s -o /dev/null -w '%{http_code}' -m 10 "${SOLACE_SEMP_URL%/}/SEMP/v2/config/about/api" 2>/dev/null | grep -qE '^(200|401)$'; then
  pass "broker SEMP reachable at ${SOLACE_SEMP_URL}"
else
  fail "broker SEMP not reachable at ${SOLACE_SEMP_URL}" \
       "if using docker-compose.broker.yaml: docker compose -f docker-compose.broker.yaml up -d, give it 60-90s on first boot; then ./scripts/setup-broker-tls.sh if this is the TLS port"
fi

if curl -s -o /dev/null -w '%{http_code}' -m 10 -u "monitor:${SOLACE_MONITOR_PASSWORD}" \
   "${SOLACE_SEMP_URL%/}/SEMP/v2/config/msgVpns" 2>/dev/null | grep -q '^200$'; then
  pass "monitor SEMP user can authenticate"
else
  fail "monitor SEMP user cannot authenticate" \
       "check SOLACE_MONITOR_PASSWORD in .env matches what the broker booted with, or that your own broker has a 'monitor' user with read-only access"
fi

# -----------------------------------------------------------------------------
section "3. Exporter"
# -----------------------------------------------------------------------------
std=$(curl -s -m 10 "https://localhost:${PORT_EXPORTER}/solace-std" 2>/dev/null)
n=$(printf '%s' "$std" | grep -c '^solace_')
if [ "$n" -gt 50 ] 2>/dev/null; then
  pass "exporter serving /solace-std (${n} solace_* series)"
else
  fail "exporter /solace-std returned too few series (${n})" "docker compose logs solace-exporter"
fi

if curl -s -m 15 "https://localhost:${PORT_EXPORTER}/solace-det" 2>/dev/null | grep -q '^solace_'; then
  pass "exporter serving /solace-det (queue/client detail)"
else
  fail "exporter /solace-det returned no series" "docker compose logs solace-exporter"
fi

# -----------------------------------------------------------------------------
section "4. Prometheus"
# -----------------------------------------------------------------------------
targets=$(curl -s -m 10 "https://localhost:${PORT_PROMETHEUS}/api/v1/targets" 2>/dev/null)
for job in solace-std solace-vpn-stats solace-det; do
  if printf '%s' "$targets" | grep -o "\"job\":\"$job\"[^{]*\"health\":\"up\"" >/dev/null 2>&1; then
    pass "target '$job' is up"
  else
    fail "target '$job' is not up" "https://localhost:${PORT_PROMETHEUS}/targets shows why"
  fi
done

q=$(curl -s -m 10 "https://localhost:${PORT_PROMETHEUS}/api/v1/query?query=solace_up" 2>/dev/null)
if printf '%s' "$q" | grep -q '"resultType":"vector"' && printf '%s' "$q" | grep -q '"value"'; then
  pass "Prometheus has ingested solace_up"
else
  fail "Prometheus query for solace_up returned no data" "docker compose logs prometheus"
fi

# -----------------------------------------------------------------------------
section "5. Grafana"
# -----------------------------------------------------------------------------
ds=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
      "https://localhost:${PORT_GRAFANA}/api/datasources" 2>/dev/null)
if printf '%s' "$ds" | grep -q '"type"[[:space:]]*:[[:space:]]*"prometheus"'; then
  pass "Prometheus datasource present in Grafana"
  health=$(curl -s -m 15 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
            "https://localhost:${PORT_GRAFANA}/api/datasources/uid/prometheus-solace/health" 2>/dev/null)
  if printf '%s' "$health" | grep -q '"status"[[:space:]]*:[[:space:]]*"OK"'; then
    pass "Grafana can query Prometheus"
  else
    fail "Grafana has the datasource but cannot query Prometheus" \
         "$(printf '%s' "$health" | sed 's/.*"message":"\([^"]*\)".*/\1/')"
  fi
elif printf '%s' "$ds" | grep -qi "invalid.*credential\|unauthorized"; then
  fail "Grafana rejected the credentials" \
       "with a persistent volume the password is fixed at first boot; remove the grafana-data volume to change it"
else
  fail "Prometheus datasource missing from Grafana" "check docker compose logs grafana for provisioning errors"
fi

for uid in solace-vpn-overview solace-queue-monitor solace-home; do
  dash=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
          "https://localhost:${PORT_GRAFANA}/api/dashboards/uid/$uid" 2>/dev/null)
  if printf '%s' "$dash" | grep -q "\"uid\":\"$uid\""; then
    pass "dashboard '$uid' provisioned"
  else
    fail "dashboard '$uid' not found" "check docker compose logs grafana for provisioning errors"
  fi
done

# -----------------------------------------------------------------------------
printf '\n%s%d passed, %d failed%s\n' "$BOLD" "$PASS" "$FAIL" "$RST"

if [ "$FAIL" -gt 0 ]; then
  printf '%sPipeline is not fully working — fix the first failure above and re-run.%s\n' "$RED" "$RST"
  exit 1
fi

printf '%sEverything checks out. Start here: https://localhost:%s%s\n' \
  "$GRN" "${PORT_GRAFANA}" "$RST"
