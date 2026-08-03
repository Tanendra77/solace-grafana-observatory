#!/usr/bin/env bash
# =============================================================================
# setup-broker-tracing.sh — configure a Solace broker for distributed tracing
#
# Idempotent throughout: every object is created, and if it already exists it is
# updated instead. Safe to run any time, including repeatedly. Works against
# the broker started by docker-compose.broker.yaml or any broker you already
# have — it only ever talks SEMP v2 over HTTP, from your host.
#
# Run from Git Bash / WSL on Windows, or any bash elsewhere:
#   ./scripts/setup-broker-tracing.sh
# =============================================================================
set -eu

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env found — copy .env.example to .env first"; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# --- configuration, all from the environment ---------------------------------
BOOTSTRAP_ENABLED="${BOOTSTRAP_ENABLED:-true}"
SEMP_URL="${SOLACE_SEMP_URL:-http://localhost:8080}"
ADMIN_USER="${SOLACE_ADMIN_USER:-admin}"
ADMIN_PASS="${SOLACE_ADMIN_PASSWORD:-admin}"
VPN="${SOLACE_MSG_VPN:-test}"
VPN_SPOOL_MB="${SOLACE_VPN_SPOOL_MB:-1500}"
AMQP_PORT="${SOLACE_BROKER_AMQP_PORT:-5672}"
TRACE_USER="${SOLACE_TRACE_USER:-trace_user}"
TRACE_PASS="${SOLACE_TRACE_PASSWORD:-trace_user_pw}"
APP_USER="${SOLACE_APP_USER:-dtuser}"
APP_PASS="${SOLACE_APP_PASSWORD:-dtuser_pw}"
PROFILE="${TELEMETRY_PROFILE_NAME:-trace}"
FILTER_SUB="${TRACE_FILTER_SUBSCRIPTION:->}"
QUEUE_SPOOL_MB="${TELEMETRY_QUEUE_SPOOL_MB:-500}"

FILTER_NAME="allmsgs"
# The broker derives this from the profile name and it cannot be chosen. The
# collector's ACL profile and client profile must both carry the same name.
TELEMETRY_QUEUE="#telemetry-${PROFILE}"
TELEMETRY_QUEUE_ENC="%23telemetry-${PROFILE}"

SEMP="${SEMP_URL%/}/SEMP/v2/config"
# Telemetry queues are broker-internal: they are NOT listed in the config API's
# queues collection, only in the monitor API. Querying the wrong one makes a
# perfectly good queue look missing.
SEMP_MON="${SEMP_URL%/}/SEMP/v2/monitor"
AUTH="${ADMIN_USER}:${ADMIN_PASS}"
BODY_FILE="/tmp/semp-response.$$"

CREATED=0; UPDATED=0; UNCHANGED=0

cleanup() { rm -f "$BODY_FILE"; }
trap cleanup EXIT

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [ "$BOOTSTRAP_ENABLED" != "true" ]; then
  printf 'BOOTSTRAP_ENABLED=%s — skipping broker configuration.\n' "$BOOTSTRAP_ENABLED"
  printf 'The broker is assumed to be configured already.\n'
  exit 0
fi

printf '=========================================================\n'
printf ' Solace DT bootstrap\n'
printf '   broker : %s\n' "$SEMP_URL"
printf '   vpn    : %s\n' "$VPN"
printf '   profile: %s  (queue %s)\n' "$PROFILE" "$TELEMETRY_QUEUE"
printf '=========================================================\n'

# -----------------------------------------------------------------------------
# Wait for the broker. Done here rather than with depends_on because in external
# mode there is no broker container for compose to wait on.
# -----------------------------------------------------------------------------
step "Waiting for SEMP to answer"
n=0
until curl -s -f -m 5 -u "$AUTH" -o /dev/null "$SEMP/about/api"; do
  n=$((n + 1))
  if [ "$n" -ge 60 ]; then
    die "broker did not answer at $SEMP after 5 minutes.
       - local mode:    check 'docker logs dtobs-solbroker'
       - external mode: check SOLACE_SEMP_URL is reachable from this machine,
                        and that the admin credentials are right"
  fi
  [ $((n % 6)) -eq 0 ] && say "still waiting... (${n}0s)"
  sleep 10
done
say "broker is up"

# -----------------------------------------------------------------------------
# SEMP helpers
#
# upsert() is the workhorse: POST to create, and on ALREADY_EXISTS fall through
# to PATCH. That is what makes every run after the first a no-op in effect.
# -----------------------------------------------------------------------------
http() { # http METHOD PATH [BODY] -> echoes status code, body in $BODY_FILE
  _m="$1"; _p="$2"; _b="${3:-}"
  if [ -n "$_b" ]; then
    curl -s -o "$BODY_FILE" -w '%{http_code}' -u "$AUTH" \
         -X "$_m" -H 'Content-Type: application/json' -d "$_b" "$SEMP$_p"
  else
    curl -s -o "$BODY_FILE" -w '%{http_code}' -u "$AUTH" -X "$_m" "$SEMP$_p"
  fi
}

failed() { # failed DESCRIPTION
  printf '\nERROR: %s\n' "$1" >&2
  printf 'SEMP said:\n' >&2
  sed 's/^/  /' "$BODY_FILE" >&2
  printf '\nA half-configured broker fails silently later, so this is fatal.\n' >&2
  exit 1
}

upsert() { # upsert LABEL COLLECTION_PATH OBJECT_PATH JSON
  _label="$1"; _coll="$2"; _obj="$3"; _json="$4"

  _code=$(http POST "$_coll" "$_json")
  if [ "$_code" = "200" ]; then
    say "created  $_label"
    CREATED=$((CREATED + 1))
    return 0
  fi

  if grep -q 'ALREADY_EXISTS' "$BODY_FILE" 2>/dev/null; then
    _code=$(http PATCH "$_obj" "$_json")
    if [ "$_code" = "200" ]; then
      say "updated  $_label (already existed)"
      UPDATED=$((UPDATED + 1))
      return 0
    fi
    failed "could not update $_label (HTTP $_code)"
  fi

  failed "could not create $_label (HTTP $_code)"
}

ensure() { # ensure LABEL COLLECTION_PATH JSON
  # For objects with no mutable attributes — their identity IS their content, so
  # SEMP allows only GET and DELETE on them. Existing already means correct.
  _label="$1"; _coll="$2"; _json="$3"

  _code=$(http POST "$_coll" "$_json")
  if [ "$_code" = "200" ]; then
    say "created  $_label"
    CREATED=$((CREATED + 1))
    return 0
  fi

  if grep -q 'ALREADY_EXISTS' "$BODY_FILE" 2>/dev/null; then
    say "ok       $_label (already correct)"
    UNCHANGED=$((UNCHANGED + 1))
    return 0
  fi

  failed "could not create $_label (HTTP $_code)"
}

patch() { # patch LABEL OBJECT_PATH JSON  — for objects the broker auto-creates
  _label="$1"; _obj="$2"; _json="$3"
  _code=$(http PATCH "$_obj" "$_json")
  if [ "$_code" = "200" ]; then
    say "updated  $_label"
    UPDATED=$((UPDATED + 1))
    return 0
  fi
  failed "could not update $_label (HTTP $_code)"
}

# -----------------------------------------------------------------------------
step "Message VPN '$VPN'"
# -----------------------------------------------------------------------------
# maxMsgSpoolUsage must be > 0 or the telemetry queue cannot spool spans and
# guaranteed messaging does not work at all.
upsert "message VPN '$VPN'" \
  "/msgVpns" "/msgVpns/$VPN" \
  "{\"msgVpnName\":\"$VPN\",\"enabled\":true,\"authenticationBasicType\":\"internal\",\"maxMsgSpoolUsage\":$VPN_SPOOL_MB}"

# -----------------------------------------------------------------------------
step "AMQP service"
# -----------------------------------------------------------------------------
# THE trap this whole stack turns on. A broker binds AMQP to exactly one Message
# VPN. Out of the box that is 'default'. Leave it there and the collector
# connects successfully, binds nothing, and reports itself perfectly healthy
# forever. Port 5672 has to be released by 'default' before this VPN can take it.
if [ "$VPN" != "default" ]; then
  _code=$(http PATCH "/msgVpns/default" \
    "{\"serviceAmqpPlainTextEnabled\":false,\"serviceAmqpPlainTextListenPort\":0}")
  case "$_code" in
    200) say "released AMQP port from the 'default' VPN" ;;
    *)   say "note: could not change the 'default' VPN (HTTP $_code) — continuing" ;;
  esac
fi

patch "AMQP on '$VPN' port $AMQP_PORT" "/msgVpns/$VPN" \
  "{\"serviceAmqpPlainTextListenPort\":$AMQP_PORT,\"serviceAmqpPlainTextEnabled\":true}"

# -----------------------------------------------------------------------------
step "Application access"
# -----------------------------------------------------------------------------
# So sdkperf and your own clients can publish and subscribe on the traced VPN.
# A new VPN's auto-created 'default' profiles deny everything, which looks like
# a broken broker when a publisher is refused.
patch "ACL profile 'default' on '$VPN'" "/msgVpns/$VPN/aclProfiles/default" \
  '{"clientConnectDefaultAction":"allow","publishTopicDefaultAction":"allow","subscribeTopicDefaultAction":"allow"}'

patch "client profile 'default' on '$VPN'" "/msgVpns/$VPN/clientProfiles/default" \
  '{"allowGuaranteedMsgSendEnabled":true,"allowGuaranteedMsgReceiveEnabled":true,"allowGuaranteedEndpointCreateEnabled":true}'

upsert "client username '$APP_USER'" \
  "/msgVpns/$VPN/clientUsernames" "/msgVpns/$VPN/clientUsernames/$APP_USER" \
  "{\"clientUsername\":\"$APP_USER\",\"password\":\"$APP_PASS\",\"enabled\":true,\"aclProfileName\":\"default\",\"clientProfileName\":\"default\"}"

# -----------------------------------------------------------------------------
step "Telemetry profile '$PROFILE'"
# -----------------------------------------------------------------------------
# Creating the profile also creates the queue '#telemetry-<profile>'. Because
# that is a real spool-backed queue, spans survive a collector outage: the queue
# fills and drains on reconnect instead of dropping data.
#
# There can be only ONE telemetry profile per Message VPN.
upsert "telemetry profile '$PROFILE'" \
  "/msgVpns/$VPN/telemetryProfiles" "/msgVpns/$VPN/telemetryProfiles/$PROFILE" \
  "{\"telemetryProfileName\":\"$PROFILE\",\"receiverEnabled\":true,\"receiverAclConnectDefaultAction\":\"allow\",\"traceEnabled\":true,\"queueMaxMsgSpoolUsage\":$QUEUE_SPOOL_MB}"

upsert "trace filter '$FILTER_NAME'" \
  "/msgVpns/$VPN/telemetryProfiles/$PROFILE/traceFilters" \
  "/msgVpns/$VPN/telemetryProfiles/$PROFILE/traceFilters/$FILTER_NAME" \
  "{\"traceFilterName\":\"$FILTER_NAME\",\"enabled\":true}"

# The subscription decides which topics get traced. '>' is everything; narrow it
# in production, because tracing every topic is expensive at volume.
#
# A subscription has no mutable attributes — its identity is the composite key
# "<subscription>,<syntax>" — so SEMP rejects PATCH on it. Create-or-accept is
# the only correct shape here.
ensure "trace subscription '$FILTER_SUB'" \
  "/msgVpns/$VPN/telemetryProfiles/$PROFILE/traceFilters/$FILTER_NAME/subscriptions" \
  "{\"subscription\":\"$FILTER_SUB\",\"subscriptionSyntax\":\"smf\"}"

# -----------------------------------------------------------------------------
step "Collector identity '$TRACE_USER'"
# -----------------------------------------------------------------------------
# The ACL profile and client profile names MUST equal the telemetry queue name.
# The broker creates both automatically alongside the profile; this only binds
# the username to them.
upsert "client username '$TRACE_USER'" \
  "/msgVpns/$VPN/clientUsernames" "/msgVpns/$VPN/clientUsernames/$TRACE_USER" \
  "{\"clientUsername\":\"$TRACE_USER\",\"password\":\"$TRACE_PASS\",\"enabled\":true,\"aclProfileName\":\"$TELEMETRY_QUEUE\",\"clientProfileName\":\"$TELEMETRY_QUEUE\"}"

# -----------------------------------------------------------------------------
step "Confirming"
# -----------------------------------------------------------------------------
_code=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -u "$AUTH" \
          "$SEMP_MON/msgVpns/$VPN/queues/$TELEMETRY_QUEUE_ENC")
if [ "$_code" = "200" ]; then
  say "queue '$TELEMETRY_QUEUE' exists and is spool-backed"
else
  failed "telemetry queue '$TELEMETRY_QUEUE' was not created (HTTP $_code)"
fi

printf '\n=========================================================\n'
printf ' Bootstrap complete — %d created, %d updated, %d already correct\n' \
  "$CREATED" "$UPDATED" "$UNCHANGED"
printf '\n'
printf ' The broker now traces every topic matching "%s" on VPN "%s"\n' "$FILTER_SUB" "$VPN"
printf ' and writes spans to %s for the collector to consume.\n' "$TELEMETRY_QUEUE"
printf '=========================================================\n'
