#!/usr/bin/env bash
# =============================================================================
# verify.sh — prove the pipeline actually works, hop by hop
#
# The source readme's Stage 10, automated. Checks run in pipeline order so a
# failure localises to one hop instead of leaving you to bisect the stack.
#
# Every component here can look healthy while doing nothing: the collector
# stays Running through an auth failure, Kibana serves fine with an empty
# cluster, Elasticsearch answers /_cluster/health green with zero docs. These
# checks target the difference between "up" and "working".
#
# Run directly: ./scripts/verify.sh. No jq required — only curl, grep and sed.
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

# Same ENV_FILE selection as setup-broker-tracing.sh — verify the second traced
# VPN with:  ENV_FILE=.env.vpn2 ./scripts/verify.sh
ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE found — copy .env.example to .env first"; exit 1; }
set -a
# shellcheck disable=SC1091
. "./$ENV_FILE"
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

SEMP="${SOLACE_SEMP_URL%/}/SEMP/v2/config"
# Telemetry queues are broker-internal and appear only in the monitor API.
SEMP_MON="${SOLACE_SEMP_URL%/}/SEMP/v2/monitor"
AUTH="${SOLACE_ADMIN_USER}:${SOLACE_ADMIN_PASSWORD}"
VPN="${SOLACE_MSG_VPN}"
PROFILE="${TELEMETRY_PROFILE_NAME}"
TELEMETRY_QUEUE="#telemetry-${PROFILE}"

semp_get()     { curl -s -m 10 -u "$AUTH" "$SEMP$1" 2>/dev/null; }
semp_mon_get() { curl -s -m 10 -u "$AUTH" "$SEMP_MON$1" 2>/dev/null; }

printf '%sVerifying Solace DT Observatory%s\n' "$BOLD" "$RST"

# -----------------------------------------------------------------------------
section "1. Containers"
# -----------------------------------------------------------------------------
for svc in otel-collector elasticsearch kibana; do
  cname=$(docker ps --filter "label=com.docker.compose.service=$svc" \
                    --filter "label=com.docker.compose.project=solace-dt-observatory" \
                    --format '{{.Names}}' | head -1)
  if [ -n "$cname" ]; then
    pass "$svc running ($cname)"
  else
    fail "$svc is not running" "docker compose up -d   (then docker compose logs $svc)"
  fi
done

broker_cname=$(docker ps --filter "label=com.docker.compose.service=solbroker" \
                  --filter "label=com.docker.compose.project=solace-dt-broker" \
                  --format '{{.Names}}' | head -1)
if [ -n "$broker_cname" ]; then
  pass "solbroker running ($broker_cname)"
  BROKER_LOCAL=true
else
  skip "solbroker container not found — assuming an external broker"
  BROKER_LOCAL=false
fi

# -----------------------------------------------------------------------------
section "2. Broker"
# -----------------------------------------------------------------------------
if [ "$BROKER_LOCAL" = "true" ]; then
  if curl -sf -m 10 "http://localhost:${PORT_BROKER_HEALTH}/health-check/guaranteed-active" >/dev/null 2>&1; then
    pass "broker healthy (guaranteed messaging active)"
  else
    fail "broker health check failed" "still booting? give it 60-90s, then docker compose -f docker-compose.broker.yaml logs solbroker"
  fi
else
  skip "health check — external broker, endpoint unknown"
fi

vpn_json=$(semp_get "/msgVpns/${VPN}")
if printf '%s' "$vpn_json" | grep -q "\"msgVpnName\"[[:space:]]*:[[:space:]]*\"${VPN}\""; then
  if [ "$(field "$vpn_json" enabled)" = "true" ]; then
    pass "message VPN '${VPN}' exists and is enabled"
  else
    fail "message VPN '${VPN}' exists but is disabled" "./scripts/setup-broker-tracing.sh"
  fi
else
  fail "message VPN '${VPN}' not found" "./scripts/setup-broker-tracing.sh   (or check SEMP credentials in .env)"
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
       "AMQP is probably still bound to the 'default' VPN. ./scripts/setup-broker-tracing.sh"
fi

# -----------------------------------------------------------------------------
section "3. Telemetry profile"
# -----------------------------------------------------------------------------
tp_json=$(semp_get "/msgVpns/${VPN}/telemetryProfiles/${PROFILE}")
if printf '%s' "$tp_json" | grep -q "\"telemetryProfileName\""; then
  pass "telemetry profile '${PROFILE}' exists"
  [ "$(field "$tp_json" receiverEnabled)" = "true" ] \
    && pass "receiver enabled (collector may bind)" \
    || fail "receiver is disabled" "./scripts/setup-broker-tracing.sh"
  [ "$(field "$tp_json" traceEnabled)" = "true" ] \
    && pass "trace enabled (broker is generating spans)" \
    || fail "trace is disabled — no spans are being produced" "./scripts/setup-broker-tracing.sh"
else
  fail "telemetry profile '${PROFILE}' not found" "./scripts/setup-broker-tracing.sh"
fi

filters_json=$(semp_get "/msgVpns/${VPN}/telemetryProfiles/${PROFILE}/traceFilters")
if printf '%s' "$filters_json" | grep -q '"traceFilterName"'; then
  if printf '%s' "$filters_json" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true'; then
    pass "trace filter present and enabled"
  else
    fail "trace filter exists but is disabled" "the filter itself needs enabling: ./scripts/setup-broker-tracing.sh"
  fi
else
  fail "no trace filter configured — nothing matches, so no spans" "./scripts/setup-broker-tracing.sh"
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
         "the broker is producing but the collector is not consuming — docker compose logs otel-collector"
  fi
else
  fail "telemetry queue '${TELEMETRY_QUEUE}' missing" "the profile creates it; ./scripts/setup-broker-tracing.sh"
fi

cu_json=$(semp_get "/msgVpns/${VPN}/clientUsernames/${SOLACE_TRACE_USER}")
if printf '%s' "$cu_json" | grep -q '"clientUsername"'; then
  acl=$(field "$cu_json" aclProfileName)
  if [ "$acl" = "$TELEMETRY_QUEUE" ]; then
    pass "'${SOLACE_TRACE_USER}' bound to ACL profile '${acl}'"
  else
    fail "'${SOLACE_TRACE_USER}' has ACL profile '${acl}', expected '${TELEMETRY_QUEUE}'" \
         "the ACL profile name must match the telemetry queue name: ./scripts/setup-broker-tracing.sh"
  fi
else
  fail "client username '${SOLACE_TRACE_USER}' not found" "./scripts/setup-broker-tracing.sh"
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
         "check SOLACE_TRACE_USER / SOLACE_TRACE_PASSWORD in .env, then ./scripts/setup-broker-tracing.sh"
  else
    fail "nothing is consuming the telemetry queue" \
         "the collector stays Running through auth and ACL failures — docker compose logs otel-collector"
  fi
fi

if curl -sf -m 10 "http://localhost:${PORT_OTEL_HEALTH}/" >/dev/null 2>&1; then
  pass "collector health endpoint responding"
else
  fail "collector health endpoint not responding" "docker compose logs otel-collector"
fi

# -----------------------------------------------------------------------------
section "5. Elasticsearch"
# -----------------------------------------------------------------------------
# A single-node cluster can never assign its replica shards, so "yellow" is
# its normal healthy state — treating it as a failure would flag every
# working stack this compose file can ever produce.
es_ready=false
n=0
while [ $n -lt 10 ]; do
  health=$(curl -s -m 5 "http://localhost:${PORT_ELASTICSEARCH}/_cluster/health" 2>/dev/null)
  status=$(field "$health" status)
  if [ "$status" = "green" ] || [ "$status" = "yellow" ]; then
    es_ready=true; break
  fi
  n=$((n+1)); sleep 5
done
if [ "$es_ready" = true ]; then
  pass "Elasticsearch cluster healthy (status: ${status})"
else
  fail "Elasticsearch not healthy after 50s" "check docker compose logs elasticsearch"
fi

# The traces-* data stream does not exist until the first span is indexed, so
# "index_not_found" on a fresh stack means "no traffic yet", not "broken".
LOOKBACK_H="${VERIFY_LOOKBACK_HOURS:-168}"
query="{\"query\":{\"range\":{\"@timestamp\":{\"gte\":\"now-${LOOKBACK_H}h\"}}},\"size\":0,\"track_total_hits\":true}"
search=$(curl -s -m 15 -H 'Content-Type: application/json' -d "$query" \
          "http://localhost:${PORT_ELASTICSEARCH}/traces-*/_search" 2>/dev/null)
if printf '%s' "$search" | grep -q 'index_not_found_exception'; then
  if [ "${TRAFFIC_SEEN:-false}" = "true" ]; then
    fail "the broker produced spans but no traces index exists in Elasticsearch" \
         "the collector is not exporting — docker compose logs otel-collector"
  else
    pending "no traces index in Elasticsearch yet" \
            "expected until traffic is sent — see README Sending traffic for an sdkperf command"
  fi
else
  n=$(field "$search" value)
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    pass "Elasticsearch has ingested traces (${n} in the last ${LOOKBACK_H}h)"
  elif [ "${TRAFFIC_SEEN:-false}" = "true" ]; then
    fail "the broker produced spans but Elasticsearch has none in range" \
         "the collector is not exporting, or VERIFY_LOOKBACK_HOURS is too narrow — docker compose logs otel-collector"
  else
    pending "Elasticsearch holds no traces yet" \
            "expected until traffic is sent — see README Sending traffic for an sdkperf command"
  fi
fi

# -----------------------------------------------------------------------------
section "6. Kibana"
# -----------------------------------------------------------------------------
# Kibana has no separate datasource object to provision — it always talks to
# the one Elasticsearch it's pointed at (ELASTICSEARCH_HOSTS), and its own
# overall status already reflects whether that connection is working.
kb=$(curl -s -m 10 "http://localhost:${PORT_KIBANA}/api/status" 2>/dev/null)
level=$(field "$kb" level)
if [ "$level" = "available" ]; then
  pass "Kibana available"
else
  fail "Kibana not available (status: ${level:-unreachable})" "docker compose logs kibana"
fi

# -----------------------------------------------------------------------------
if [ "$CHECK_PERSISTENCE" = "true" ]; then
section "7. Persistence"
  before=$(field "$(curl -s -m 10 "http://localhost:${PORT_ELASTICSEARCH}/traces-*/_count" 2>/dev/null)" count)
  printf '  %srestarting the stack...%s\n' "$DIM" "$RST"
  docker compose down    >/dev/null 2>&1
  docker compose up -d   >/dev/null 2>&1
  n=0
  while [ $n -lt 30 ]; do
    curl -sf -m 5 "http://localhost:${PORT_ELASTICSEARCH}/_cluster/health" >/dev/null 2>&1 && break
    sleep 5; n=$((n+1))
  done
  after=$(field "$(curl -s -m 10 "http://localhost:${PORT_ELASTICSEARCH}/traces-*/_count" 2>/dev/null)" count)
  if [ -n "$after" ] && [ "${after:-0}" -ge "${before:-0}" ] 2>/dev/null; then
    pass "trace data survived a full restart (${before:-0} -> ${after} docs)"
  else
    fail "trace data did not survive the restart (before='${before:-0}' after='${after:-0}')" \
         "check the es-data volume is mounted"
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
  printf 'then re-run this. See README Sending traffic for a ready-made sdkperf command.\n'
  exit 0
fi

printf '%sEverything checks out. Explore traces at http://localhost:%s -> Discover -> traces-*.%s\n' \
  "$GRN" "${PORT_KIBANA}" "$RST"
