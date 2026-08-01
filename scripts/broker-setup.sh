#!/bin/sh
# =============================================================================
# broker-setup.sh — configure a Solace broker for metrics collection
#
# Idempotent throughout: every object is created, and if it already exists it
# is updated instead. Safe on every `up`, safe to run by hand any time. POSIX
# sh + curl only — no bash, no jq. Runs inside curlimages/curl.
#
# Creates: Message VPN, app-user ACL/client profiles, an app client username,
# a demo queue with a topic subscription. Does NOT create the `monitor` SEMP
# user — that is a broker-level identity created via docker environment
# variables on solbroker itself (see docker-compose.yaml), not a VPN-scoped
# object this script can reach over SEMP.
#
# Run standalone:
#   SOLACE_SEMP_URL=http://localhost:8080 ... sh scripts/broker-setup.sh
# or through the stack:
#   ./stack.sh setup
# =============================================================================
set -eu

BOOTSTRAP_ENABLED="${BOOTSTRAP_ENABLED:-true}"
SEMP_URL="${SOLACE_SEMP_URL:-http://solbroker:8080}"
ADMIN_USER="${SOLACE_ADMIN_USER:-admin}"
ADMIN_PASS="${SOLACE_ADMIN_PASSWORD:-admin}"
VPN="${SOLACE_MSG_VPN:-test}"
VPN_SPOOL_MB="${SOLACE_VPN_SPOOL_MB:-1500}"
APP_USER="${SOLACE_APP_USER:-appuser}"
APP_PASS="${SOLACE_APP_PASSWORD:-appuser_pw}"
DEMO_QUEUE="${SOLACE_DEMO_QUEUE:-demo-queue}"
DEMO_TOPIC="${SOLACE_DEMO_TOPIC:-metrics/demo}"
DEMO_QUEUE_SPOOL_MB="${SOLACE_DEMO_QUEUE_SPOOL_MB:-500}"

SEMP="${SEMP_URL%/}/SEMP/v2/config"
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
printf ' Solace metrics bootstrap\n'
printf '   broker : %s\n' "$SEMP_URL"
printf '   vpn    : %s\n' "$VPN"
printf '   queue  : %s  (topic %s/>)\n' "$DEMO_QUEUE" "$DEMO_TOPIC"
printf '=========================================================\n'

step "Waiting for SEMP to answer"
n=0
until curl -s -f -m 5 -u "$AUTH" -o /dev/null "$SEMP/about/api"; do
  n=$((n + 1))
  if [ "$n" -ge 60 ]; then
    die "broker did not answer at $SEMP after 5 minutes.
       - local mode:    check 'docker logs mobs-solbroker'
       - external mode: check SOLACE_SEMP_URL is reachable from inside the
                        docker network, and that the admin credentials are right"
  fi
  [ $((n % 6)) -eq 0 ] && say "still waiting... (${n}0s)"
  sleep 10
done
say "broker is up"

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
    say "created  $_label"; CREATED=$((CREATED + 1)); return 0
  fi
  if grep -q 'ALREADY_EXISTS' "$BODY_FILE" 2>/dev/null; then
    _code=$(http PATCH "$_obj" "$_json")
    if [ "$_code" = "200" ]; then
      say "updated  $_label (already existed)"; UPDATED=$((UPDATED + 1)); return 0
    fi
    failed "could not update $_label (HTTP $_code)"
  fi
  failed "could not create $_label (HTTP $_code)"
}

ensure() { # ensure LABEL COLLECTION_PATH JSON — for objects with no mutable
           # attributes (identity IS the content), e.g. a subscription.
  _label="$1"; _coll="$2"; _json="$3"
  _code=$(http POST "$_coll" "$_json")
  if [ "$_code" = "200" ]; then
    say "created  $_label"; CREATED=$((CREATED + 1)); return 0
  fi
  if grep -q 'ALREADY_EXISTS' "$BODY_FILE" 2>/dev/null; then
    say "ok       $_label (already correct)"; UNCHANGED=$((UNCHANGED + 1)); return 0
  fi
  failed "could not create $_label (HTTP $_code)"
}

patch() { # patch LABEL OBJECT_PATH JSON — for objects the broker auto-creates
  _label="$1"; _obj="$2"; _json="$3"
  _code=$(http PATCH "$_obj" "$_json")
  if [ "$_code" = "200" ]; then
    say "updated  $_label"; UPDATED=$((UPDATED + 1)); return 0
  fi
  failed "could not update $_label (HTTP $_code)"
}

# -----------------------------------------------------------------------------
step "Message VPN '$VPN'"
# -----------------------------------------------------------------------------
upsert "message VPN '$VPN'" \
  "/msgVpns" "/msgVpns/$VPN" \
  "{\"msgVpnName\":\"$VPN\",\"enabled\":true,\"authenticationBasicType\":\"internal\",\"maxMsgSpoolUsage\":$VPN_SPOOL_MB}"

# -----------------------------------------------------------------------------
step "Application access"
# -----------------------------------------------------------------------------
# A new VPN's auto-created 'default' profiles deny everything, which looks
# like a broken broker when a publisher is refused.
patch "ACL profile 'default' on '$VPN'" "/msgVpns/$VPN/aclProfiles/default" \
  '{"clientConnectDefaultAction":"allow","publishTopicDefaultAction":"allow","subscribeTopicDefaultAction":"allow"}'

patch "client profile 'default' on '$VPN'" "/msgVpns/$VPN/clientProfiles/default" \
  '{"allowGuaranteedMsgSendEnabled":true,"allowGuaranteedMsgReceiveEnabled":true,"allowGuaranteedEndpointCreateEnabled":true}'

upsert "client username '$APP_USER'" \
  "/msgVpns/$VPN/clientUsernames" "/msgVpns/$VPN/clientUsernames/$APP_USER" \
  "{\"clientUsername\":\"$APP_USER\",\"password\":\"$APP_PASS\",\"enabled\":true,\"aclProfileName\":\"default\",\"clientProfileName\":\"default\"}"

# -----------------------------------------------------------------------------
step "Demo queue '$DEMO_QUEUE'"
# -----------------------------------------------------------------------------
# Exists so queue-level dashboard panels (depth, spool usage, binds) have real
# data without the user creating one by hand first.
upsert "queue '$DEMO_QUEUE'" \
  "/msgVpns/$VPN/queues" "/msgVpns/$VPN/queues/$DEMO_QUEUE" \
  "{\"queueName\":\"$DEMO_QUEUE\",\"egressEnabled\":true,\"ingressEnabled\":true,\"permission\":\"consume\",\"maxMsgSpoolUsage\":$DEMO_QUEUE_SPOOL_MB}"

# A subscription has no mutable attributes — its identity is the composite key
# "<subscription>,<syntax>" — so SEMP rejects PATCH on it. Create-or-accept is
# the only correct shape here.
ensure "topic subscription '$DEMO_TOPIC/>' on '$DEMO_QUEUE'" \
  "/msgVpns/$VPN/queues/$DEMO_QUEUE/subscriptions" \
  "{\"subscriptionTopic\":\"$DEMO_TOPIC/>\"}"

printf '\n=========================================================\n'
printf ' Bootstrap complete — %d created, %d updated, %d already correct\n' \
  "$CREATED" "$UPDATED" "$UNCHANGED"
printf '\n'
printf ' VPN "%s" is ready. Publish to "%s/..." and it lands in queue "%s".\n' \
  "$VPN" "$DEMO_TOPIC" "$DEMO_QUEUE"
printf '=========================================================\n'
