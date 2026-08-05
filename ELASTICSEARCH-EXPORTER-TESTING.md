# Testing the Elasticsearch exporter

A working guide for changing settings on the `elasticsearch` exporter in
`config/otel/collector.yaml` and finding out what actually happened.

Written from things that went wrong on this stack, not from the docs. Every
command here has been run against it.

---

## The one thing to understand first

Two separate programs, two separate jobs:

- **The exporter** (inside `otel-collector`) decides **where** each span should
  go and what its document ID is. It has no storage of its own — it just builds
  a Bulk API request and POSTs it.
- **Elasticsearch** decides **whether that destination can actually receive it**,
  and does the indexing.

`traces_index`, `logs_index`, `logs_dynamic_id` are all **exporter-side**
settings, evaluated before anything reaches Elasticsearch.

This matters because of the failure mode: when the exporter targets something
Elasticsearch won't accept, **documents are discarded, not redirected**. There
is no fallback and no bounce. The only evidence is a line in the collector log.

**Therefore: after any exporter change, check the collector log for
`failed to index`. A rising document count elsewhere does not prove your change
worked.**

---

## The check loop

Four steps. Do all four — skipping step 4 is how you convince yourself a broken
config works.

### 1. Apply the change and restart

```bash
docker compose restart otel-collector
```

Then confirm it actually started — a bad config key stops the collector dead:

```bash
docker logs dtobs-otelcol --tail 20 | grep -iE "invalid keys|error reading configuration"
```

Empty output = started fine. Any output = the collector is crash-looping and
nothing at all is being processed.

### 2. Send traffic

No `sdkperf` needed. This publishes 3 messages over the broker's REST service,
enabling it on port 9001 and switching it off again afterwards (port 9000 is
already taken by the `default` VPN, which is not traced):

```bash
curl -s -u admin:admin -X PATCH -H 'Content-Type: application/json' \
  -d '{"serviceRestIncomingPlainTextEnabled":true,"serviceRestIncomingPlainTextListenPort":9001}' \
  http://localhost:8080/SEMP/v2/config/msgVpns/test >/dev/null

for i in 1 2 3; do
  docker run --rm --network solace_dt_broker_net curlimages/curl -s -o /dev/null -w '%{http_code} ' \
    -u dtuser:dtuser_pw -X POST -H 'Content-Type: text/plain' -d "test $i" \
    http://solbroker:9001/test/trade/new
done; echo

curl -s -u admin:admin -X PATCH -H 'Content-Type: application/json' \
  -d '{"serviceRestIncomingPlainTextEnabled":false,"serviceRestIncomingPlainTextListenPort":0}' \
  http://localhost:8080/SEMP/v2/config/msgVpns/test >/dev/null
```

Expect `200 200 200`. Each message produces **two** spans (`... receive` and
`q.test send`) sharing one trace ID, so 3 publishes = 6 span documents.

### 3. Confirm the broker produced spans

Separates "the broker isn't tracing" from "the pipeline is losing them":

```bash
curl -s -u admin:admin "http://localhost:8080/SEMP/v2/monitor/msgVpns/test/queues/%23telemetry-trace" \
  | grep -o '"lastSpooledMsgId":[0-9]*\|"msgSpoolUsage":[0-9.]*'
```

- `lastSpooledMsgId` rising = broker is generating spans
- `msgSpoolUsage: 0` = collector is draining them

If `lastSpooledMsgId` doesn't move, the problem is on the broker, not the
exporter — run `./scripts/setup-broker-tracing.sh`.

### 4. Check for dropped documents — do not skip

```bash
docker logs dtobs-otelcol --since 5m 2>&1 | grep "failed to index"
```

Silence is the only acceptable result. Anything here means data is being lost.
The `error.type` field names the cause:

| `error.type` | Meaning |
|---|---|
| `index_not_found_exception` | Target doesn't exist. Nothing auto-creates a custom name. |
| `resource_not_found_exception` | Target exists but is a plain index; a data stream is required. |
| `version_conflict_engine_exception` | Duplicate document ID rejected — **this one is the dedup feature working**, not an error. |

### 5. Count the documents

Elasticsearch only refreshes about once a second, and counting too early gives a
misleadingly stale number — force it:

```bash
curl -s -X POST "http://localhost:9200/<target>/_refresh" >/dev/null
curl -s "http://localhost:9200/<target>/_count"
```

Not sure what the target ended up being? List everything:

```bash
curl -s "http://localhost:9200/_cat/indices?v&h=index,docs.count" | grep -viE "^\.internal|^\.kibana|alerts"
```

---

## Setting by setting

### Baseline — no overrides

```yaml
elasticsearch:
  endpoints: ["http://elasticsearch:9200"]
  mapping:
    mode: otel
```

Elasticsearch names and creates everything itself: `traces-generic.otel-default`
and `logs-generic.otel-default`. Correct field types, automatic rotation, Kibana
recognises it. This is what the branch ships and what `verify.sh` expects.

### `traces_index` / `logs_index`

```yaml
  traces_index: "solace_trace"
  logs_index: "solace_traces"
```

Forces everything into one named target. **Three conditions, all mandatory:**

1. The target must already exist — it is never auto-created
2. It must be a **data stream**, not a plain index
3. The collector must be **restarted after** creating it — it resolves its
   target once at startup and caches it

Miss any one and every document is silently dropped.

**Setup:**

```bash
curl -X PUT "http://localhost:9200/_index_template/solace_custom_tpl" \
  -H 'Content-Type: application/json' \
  -d '{"index_patterns":["solace_trace","solace_traces"],"data_stream":{},"priority":500}'

curl -X PUT "http://localhost:9200/_data_stream/solace_trace"
curl -X PUT "http://localhost:9200/_data_stream/solace_traces"

docker compose restart otel-collector      # required
```

**Known cost:** without Elastic's OTel component templates attached, field types
are auto-guessed. `trace_id` becomes `text` (tokenised) instead of `keyword`, so
exact filters and aggregations need `trace_id.keyword`. Check with:

```bash
curl -s "http://localhost:9200/solace_trace/_mapping" | grep -o '"trace_id":{[^}]*}'
```

### `logs_dynamic_id` / `traces_dynamic_id`

```yaml
  logs_dynamic_id:
    enabled: true
```

Lets the `elasticsearch.document_id` attribute set the document's `_id`. Its
purpose is **deduplication** — Elasticsearch rejects a second document with an
existing ID, so a collector retry can't create a duplicate.

**The flag alone does nothing.** Something must set the attribute. Add a
processor and put it in the pipeline:

```yaml
processors:
  transform/es-doc-id:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          - set(attributes["elasticsearch.document_id"], Concat([trace_id.string, span_id.string], "-"))

service:
  pipelines:
    logs:
      processors: [memory_limiter, transform/es-doc-id, batch]
```

**Verify the attribute is actually being set** (it's stripped from the final
document, so its absence there proves nothing — read the debug exporter output
instead):

```bash
docker logs dtobs-otelcol --since 2m 2>&1 | grep -o "elasticsearch.document_id=[^ ]*" | tail -1
```

**Verify dedup works** — send the same record twice and confirm the count only
goes up by one, with `version_conflict_engine_exception` in the log for the
second.

**Version matters.** On `otel/opentelemetry-collector-contrib:0.144.0` (what
this branch pins):

| Key | Status |
|---|---|
| `logs_dynamic_id` | accepted |
| `logs_dynamic_index` | accepted |
| `traces_dynamic_id` | **rejected — invalid key, collector won't start** |

The traces variant is newer than this collector. Test any key before trusting
it:

```bash
docker compose restart otel-collector && sleep 4
docker logs dtobs-otelcol --tail 20 | grep "invalid keys"
```

### Mutually exclusive settings

`traces_index` and `traces_dynamic_index` cannot both be set — the collector
refuses to start:

```
must not specify both traces_index and traces_dynamic_index
```

---

## Fixes

| Symptom | Cause | Fix |
|---|---|---|
| Collector won't start, `invalid keys: X` | Key not in this exporter version | Remove it, or upgrade the collector |
| Collector won't start, `must not specify both` | Conflicting settings | Remove one |
| `index_not_found_exception` | Custom target doesn't exist | Create it as a data stream, then **restart the collector** |
| `resource_not_found_exception` | Target is a plain index | Delete it, recreate as a data stream, restart |
| Created the data stream, still `index_not_found` | Collector cached the old resolution | `docker compose restart otel-collector` |
| Published OK, count unchanged, no errors | Refresh timing | `POST /<target>/_refresh` then count again |
| `version_conflict_engine_exception` | Duplicate document ID | Not a fault — dedup working as intended |
| Everything green but no new data | See the trap below | |

### The trap: `verify.sh` can pass on a broken pipeline

`./scripts/verify.sh` checks that traces *exist* within `VERIFY_LOOKBACK_HOURS`
(a week by default). Old documents satisfy that. A pipeline that has been
dropping every span for hours still reports **20/20 passed**.

To prove ingestion is live, compare a count before and after publishing —
or just check step 4. Don't trust a green `verify.sh` alone after an exporter
change.

---

## Reset

**Wipe trace data, keep the stack running** (data streams auto-recreate on the
next span; no restart needed for the default `traces-*` targets):

```bash
curl -X DELETE "http://localhost:9200/_data_stream/traces-generic.otel-default"
curl -X DELETE "http://localhost:9200/_data_stream/logs-generic.otel-default"
```

**Remove custom targets:**

```bash
curl -X DELETE "http://localhost:9200/_data_stream/solace_trace"
curl -X DELETE "http://localhost:9200/_data_stream/solace_traces"
curl -X DELETE "http://localhost:9200/_index_template/solace_custom_tpl"
```

**Back to the shipped config:**

```bash
git checkout -- config/otel/collector.yaml
docker compose restart otel-collector
```

**Full clean slate:**

```bash
docker compose down -v
docker compose -f docker-compose.broker.yaml down -v
```

⚠️ Everything created here by hand — data streams, index templates, Kibana data
views — lives only in the Elasticsearch volume. `down -v` destroys all of it. If
your config still points at custom names afterwards, you are silently dropping
spans again with no obvious cause. Re-run the setup, or revert the config.

---

## Viewing in Kibana

http://localhost:5601 → ☰ → **Analytics** → **Discover**

A data view must match your target's name. `traces-*` will not match
`solace_trace`. Create one per naming scheme:

```bash
curl -X POST "http://localhost:5601/api/data_views/data_view" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"data_view":{"title":"solace_trace*","name":"Solace Custom Index","timeFieldName":"@timestamp"}}'
```

Two things that make a working stack look empty:

- **The time picker.** Defaults to 15 minutes. Widen it.
- **Refresh lag.** ~1s before a new span is searchable. Hit refresh.

**Observability → APM → Traces** gives waterfalls and service maps, but only
recognises the standard `traces-*` data streams — custom index names won't
appear there.
