#!/usr/bin/env bash
# =============================================================================
# verify.sh — prove the pipeline actually works, hop by hop
#
# The source readme's Stage 10, automated. Checks run in pipeline order so a
# failure localises to one hop instead of leaving you to bisect the stack.
#
# Every component here can look healthy while doing nothing: the collector
# stays Running through an auth failure, Grafana serves fine with no datasource,
# Tempo answers /ready with an empty store. These checks target the difference
# between "up" and "working".
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

CHECK_PERSISTENCE=false
[ "${1:-}" = "--persistence" ] && CHECK_PERSISTENCE=true

PASS=0; FAIL=0; SKIP=0; PENDING=0

pass() { printf '  %s[ok]%s   %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS+1)); }
skip() { printf '  %s[skip]%s %s\n' "$DIM" "$RST" "$1"; SKIP=$((SKIP+1)); }

# A correctly built stack that has simply never seen a message is not broken.
# Reporting that as a failure sends people debugging a healthy pipeline, so it
# gets its own state. Only ever used once every upstream config check has
# passed — at that point "no spans" can only mean "no traffic yet".
pending() {
  printf '  %s[wait]%s %s\n' "$YLW" "$RST" "$1"
  [ -n "${2:-}" ] && printf '         %s-> %s%s\n' "$DIM" "$2" "$RST"
  PENDING=$((PENDING+1))
}
fail() {
  printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$1"
  [ -n "${2:-}" ] && printf '         %s-> %s%s\n' "$YLW" "$2" "$RST"
  FAIL=$((FAIL+1))
}
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

# Extract a flat JSON field without jq. SEMP field names are unique enough
# within a single object response that this is reliable here.
field() {
  printf '%s' "$1" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" \
    | head -1 \
    | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//'
}

SEMP="${SOLACE_SEMP_HOST_URL%/}/SEMP/v2/config"
# Telemetry queues are broker-internal and appear only in the monitor API.
SEMP_MON="${SOLACE_SEMP_HOST_URL%/}/SEMP/v2/monitor"
AUTH="${SOLACE_ADMIN_USER}:${SOLACE_ADMIN_PASSWORD}"
VPN="${SOLACE_MSG_VPN}"
PROFILE="${TELEMETRY_PROFILE_NAME}"
TELEMETRY_QUEUE="#telemetry-${PROFILE}"

semp_get()     { curl -s -m 10 -u "$AUTH" "$SEMP$1" 2>/dev/null; }
semp_mon_get() { curl -s -m 10 -u "$AUTH" "$SEMP_MON$1" 2>/dev/null; }

printf '%sVerifying Solace DT Observatory%s  %s(broker mode: %s)%s\n' \
  "$BOLD" "$RST" "$DIM" "$BROKER_MODE" "$RST"

# -----------------------------------------------------------------------------
section "1. Containers"
# -----------------------------------------------------------------------------
expected="otel-collector tempo grafana"
[ "$BROKER_MODE" = "local" ] && expected="solbroker $expected"
for svc in $expected; do
  cname=$(docker ps --filter "label=com.docker.compose.service=$svc" \
                    --filter "label=com.docker.compose.project=solace-dt-observatory" \
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
  skip "health check — external broker, endpoint unknown"
fi

vpn_json=$(semp_get "/msgVpns/${VPN}")
if printf '%s' "$vpn_json" | grep -q "\"msgVpnName\"[[:space:]]*:[[:space:]]*\"${VPN}\""; then
  if [ "$(field "$vpn_json" enabled)" = "true" ]; then
    pass "message VPN '${VPN}' exists and is enabled"
  else
    fail "message VPN '${VPN}' exists but is disabled" "./stack.sh setup"
  fi
else
  fail "message VPN '${VPN}' not found" "./stack.sh setup   (or check SEMP credentials in .env)"
fi

# The single most common failure in this stack. A broker binds AMQP to exactly
# one VPN; if it is still on 'default' the collector connects and consumes
# nothing, with no error anywhere.
amqp_enabled=$(field "$vpn_json" serviceAmqpPlainTextEnabled)
amqp_port=$(field "$vpn_json" serviceAmqpPlainTextListenPort)
if [ "$amqp_enabled" = "true" ] && [ "$amqp_port" = "${SOLACE_BROKER_AMQP_PORT}" ]; then
  pass "AMQP enabled on '${VPN}' at port ${amqp_port}"
else
  fail "AMQP is not listening on '${VPN}' (enabled=${amqp_enabled:-?} port=${amqp_port:-?})" \
       "AMQP is probably still bound to the 'default' VPN. ./stack.sh setup"
fi

# -----------------------------------------------------------------------------
section "3. Telemetry profile"
# -----------------------------------------------------------------------------
tp_json=$(semp_get "/msgVpns/${VPN}/telemetryProfiles/${PROFILE}")
if printf '%s' "$tp_json" | grep -q "\"telemetryProfileName\""; then
  pass "telemetry profile '${PROFILE}' exists"
  [ "$(field "$tp_json" receiverEnabled)" = "true" ] \
    && pass "receiver enabled (collector may bind)" \
    || fail "receiver is disabled" "./stack.sh setup"
  [ "$(field "$tp_json" traceEnabled)" = "true" ] \
    && pass "trace enabled (broker is generating spans)" \
    || fail "trace is disabled — no spans are being produced" "./stack.sh setup"
else
  fail "telemetry profile '${PROFILE}' not found" "./stack.sh setup"
fi

filters_json=$(semp_get "/msgVpns/${VPN}/telemetryProfiles/${PROFILE}/traceFilters")
if printf '%s' "$filters_json" | grep -q '"traceFilterName"'; then
  if printf '%s' "$filters_json" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true'; then
    pass "trace filter present and enabled"
  else
    fail "trace filter exists but is disabled" "the filter itself needs enabling: ./stack.sh setup"
  fi
else
  fail "no trace filter configured — nothing matches, so no spans" "./stack.sh setup"
fi

q_json=$(semp_mon_get "/msgVpns/${VPN}/queues/$(printf '%s' "$TELEMETRY_QUEUE" | sed 's/#/%23/g')")
if printf '%s' "$q_json" | grep -q '"queueName"'; then
  pass "telemetry queue '${TELEMETRY_QUEUE}' exists"

  # These two together separate "the broker isn't producing spans" from
  # "the collector isn't draining them" — the two halves of a dead pipeline
  # that otherwise look identical from the outside.
  spooled=$(field "$q_json" lastSpooledMsgId)
  if [ "${spooled:-0}" -gt 0 ] 2>/dev/null; then
    pass "broker has written spans to the queue (${spooled} so far)"
    TRAFFIC_SEEN=true
  else
    pending "broker has not written any spans yet" \
            "nothing has been published — this is expected on a fresh stack"
  fi

  usage=$(field "$q_json" msgSpoolUsage)
  if [ "${usage:-0}" -eq 0 ] 2>/dev/null; then
    pass "queue is fully drained — the collector is keeping up"
  else
    fail "spans are backing up in the queue (${usage} MB spooled)" \
         "the broker is producing but the collector is not consuming — ./stack.sh logs otel-collector"
  fi
else
  fail "telemetry queue '${TELEMETRY_QUEUE}' missing" "the profile creates it; ./stack.sh setup"
fi

cu_json=$(semp_get "/msgVpns/${VPN}/clientUsernames/${SOLACE_TRACE_USER}")
if printf '%s' "$cu_json" | grep -q '"clientUsername"'; then
  acl=$(field "$cu_json" aclProfileName)
  if [ "$acl" = "$TELEMETRY_QUEUE" ]; then
    pass "'${SOLACE_TRACE_USER}' bound to ACL profile '${acl}'"
  else
    fail "'${SOLACE_TRACE_USER}' has ACL profile '${acl}', expected '${TELEMETRY_QUEUE}'" \
         "the ACL profile name must match the telemetry queue name: ./stack.sh setup"
  fi
else
  fail "client username '${SOLACE_TRACE_USER}' not found" "./stack.sh setup"
fi

# -----------------------------------------------------------------------------
section "4. Collector"
# -----------------------------------------------------------------------------
# The check that matters most, and the one worth getting right.
#
# An auth or ACL failure does NOT crash the collector — it retries silently and
# stays Running forever, so container status proves nothing. The obvious test is
# to grep the collector log for "Creating new AMQP Receive Link", but that line
# is emitted at DEBUG level, so the check would silently stop working for anyone
# who sets OTEL_LOG_LEVEL=info. Ask the broker instead: a transmit flow on the
# telemetry queue is the broker's own record of who is consuming it, and it is
# true regardless of how the collector is configured to log.
flows=$(semp_mon_get "/msgVpns/${VPN}/queues/$(printf '%s' "$TELEMETRY_QUEUE" | sed 's/#/%23/g')/txFlows")
if printf '%s' "$flows" | grep -q '"clientName"'; then
  flow_client=$(field "$flows" clientName)
  case "$flow_client" in
    *amqp*) pass "collector is consuming the telemetry queue (AMQP flow bound)" ;;
    *)      pass "a consumer is bound to the telemetry queue ($flow_client)" ;;
  esac
else
  col_logs=$(docker logs dtobs-otelcol 2>&1 | grep -iv "memorylimiter\|grpc_log" | tail -200)
  if printf '%s' "$col_logs" | grep -qi "unauthorized\|authentication failed\|SASL"; then
    fail "the broker is rejecting the collector's credentials" \
         "check SOLACE_TRACE_USER / SOLACE_TRACE_PASSWORD in .env, then ./stack.sh setup"
  else
    fail "nothing is consuming the telemetry queue" \
         "the collector stays Running through auth and ACL failures — ./stack.sh logs otel-collector"
  fi
fi

if curl -sf -m 10 "http://localhost:${PORT_OTEL_HEALTH}/" >/dev/null 2>&1; then
  pass "collector health endpoint responding"
else
  fail "collector health endpoint not responding" "./stack.sh logs otel-collector"
fi

# -----------------------------------------------------------------------------
section "5. Tempo"
# -----------------------------------------------------------------------------
# Tempo answers /ready with 503 while it replays its WAL and joins its internal
# rings — up to ~90s on a cold start. Retry rather than calling a booting Tempo
# broken.
tempo_ready=false
n=0
while [ $n -lt 10 ]; do
  if curl -sf -m 5 "http://localhost:${PORT_TEMPO}/ready" >/dev/null 2>&1; then
    tempo_ready=true; break
  fi
  n=$((n+1)); sleep 5
done
if [ "$tempo_ready" = true ]; then
  pass "Tempo ready"
else
  fail "Tempo not ready after 50s" "check ./stack.sh logs tempo"
fi

# An explicit time range is required. /api/search with no start/end covers only
# a narrow recent window, so traces that are minutes old return an empty result
# and look like a broken pipeline.
#
# The window also has to be generous. Too narrow and a stack left idle
# overnight reports perfectly good traces as missing, which points the blame at
# the collector instead of at the clock.
LOOKBACK=$(( ${VERIFY_LOOKBACK_HOURS:-168} * 3600 ))
NOW=$(date +%s); SINCE=$((NOW - LOOKBACK))
search=$(curl -s -m 15 "http://localhost:${PORT_TEMPO}/api/search?limit=20&start=${SINCE}&end=${NOW}" 2>/dev/null)
if printf '%s' "$search" | grep -q '"traceID"'; then
  n=$(printf '%s' "$search" | grep -o '"traceID"' | wc -l | tr -d ' ')
  pass "Tempo has ingested traces (${n} in the last ${VERIFY_LOOKBACK_HOURS:-168}h)"
  root=$(field "$search" rootTraceName)
  [ -n "$root" ] && printf '         %smost recent: %s%s\n' "$DIM" "$root" "$RST"
elif [ "${TRAFFIC_SEEN:-false}" = "true" ]; then
  # The broker definitely produced spans, so an empty Tempo is a real fault
  # somewhere between the collector and storage.
  fail "the broker produced spans but Tempo has none" \
       "the collector is not exporting — ./stack.sh logs otel-collector"
else
  pending "Tempo holds no traces yet" \
          "expected until traffic is sent — ./stack.sh urls shows an sdkperf line"
fi

# -----------------------------------------------------------------------------
section "6. Grafana"
# -----------------------------------------------------------------------------
ds=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
      "http://localhost:${PORT_GRAFANA}/api/datasources" 2>/dev/null)
if printf '%s' "$ds" | grep -q '"type"[[:space:]]*:[[:space:]]*"tempo"'; then
  pass "Tempo datasource present in Grafana"

  # Present is not the same as working. Ask Grafana to actually reach Tempo —
  # this is the equivalent of clicking "Save & test" in the UI.
  health=$(curl -s -m 15 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
            "http://localhost:${PORT_GRAFANA}/api/datasources/uid/tempo-solace/health" 2>/dev/null)
  if printf '%s' "$health" | grep -q '"status"[[:space:]]*:[[:space:]]*"OK"'; then
    pass "Grafana can query Tempo"
  else
    fail "Grafana has the datasource but cannot query Tempo" \
         "$(printf '%s' "$health" | sed 's/.*"message":"\([^"]*\)".*/\1/')"
  fi
elif printf '%s' "$ds" | grep -qi "invalid.*credential\|unauthorized"; then
  fail "Grafana rejected the credentials" \
       "with a persistent volume the password is fixed at first boot; ./stack.sh reset to change it"
else
  fail "Tempo datasource missing from Grafana" \
       "check ./stack.sh logs grafana for provisioning errors"
fi

# -----------------------------------------------------------------------------
if [ "$CHECK_PERSISTENCE" = "true" ]; then
section "7. Persistence"
  before=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
            "http://localhost:${PORT_GRAFANA}/api/datasources" 2>/dev/null | grep -o '"uid":"[^"]*"' | head -1)
  printf '  %srestarting the stack...%s\n' "$DIM" "$RST"
  ./stack.sh down >/dev/null 2>&1
  ./stack.sh up   >/dev/null 2>&1
  n=0
  while [ $n -lt 30 ]; do
    curl -sf -m 5 "http://localhost:${PORT_GRAFANA}/api/health" >/dev/null 2>&1 && break
    sleep 5; n=$((n+1))
  done
  after=$(curl -s -m 10 -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
           "http://localhost:${PORT_GRAFANA}/api/datasources" 2>/dev/null | grep -o '"uid":"[^"]*"' | head -1)
  if [ -n "$after" ] && [ "$before" = "$after" ]; then
    pass "datasource survived a full restart with the same uid"
  else
    fail "datasource did not survive the restart (before='$before' after='$after')" \
         "Grafana is probably not on its named volume"
  fi
  NOW=$(date +%s); SINCE=$((NOW - $(( ${VERIFY_LOOKBACK_HOURS:-168} * 3600 )) ))
  if curl -s -m 15 "http://localhost:${PORT_TEMPO}/api/search?limit=20&start=${SINCE}&end=${NOW}" \
       2>/dev/null | grep -q '"traceID"'; then
    pass "traces survived the restart"
  else
    fail "traces did not survive the restart" "check the tempo-data volume is mounted"
  fi
fi

# -----------------------------------------------------------------------------
printf '\n%s%d passed, %d failed' "$BOLD" "$PASS" "$FAIL"
[ "$PENDING" -gt 0 ] && printf ', %d waiting on traffic' "$PENDING"
[ "$SKIP" -gt 0 ] && printf ', %d skipped' "$SKIP"
printf '%s\n' "$RST"

if [ "$FAIL" -gt 0 ]; then
  printf '%sPipeline is not fully working — fix the first failure above and re-run.%s\n' "$RED" "$RST"
  exit 1
fi

if [ "$PENDING" -gt 0 ]; then
  printf '%sThe stack is correctly configured and nothing is broken.%s\n' "$GRN" "$RST"
  printf 'It just has not seen a message yet. Publish something on VPN '"'"'%s'"'"',\n' "${VPN}"
  printf 'then re-run this. %s./stack.sh urls%s prints a ready-made sdkperf command.\n' "$DIM" "$RST"
  exit 0
fi

printf '%sEverything checks out. Explore traces at http://localhost:%s -> Explore -> Tempo.%s\n' \
  "$GRN" "${PORT_GRAFANA}" "$RST"
