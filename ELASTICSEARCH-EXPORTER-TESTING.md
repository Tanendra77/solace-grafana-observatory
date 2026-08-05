# Testing the Elasticsearch exporter

A walkthrough of what happens when you change `traces_index` / `logs_index` in
`config/otel/collector.yaml`, how to spot the problem it causes, and how to fix
it. This is the exact sequence we went through on this stack.

---

## Step 1 — Start the stack

```bash
docker compose -f docker-compose.broker.yaml up -d
./scripts/setup-broker-tracing.sh
docker compose up -d
```

Check it works before changing anything:

```bash
./scripts/verify.sh
```

Out of the box, traces go to a data stream Elasticsearch names and creates by
itself: `traces-generic.otel-default`.

---

## Step 2 — Change the setting and test

Add the custom index names to the exporter in `config/otel/collector.yaml`:

```yaml
elasticsearch:
  endpoints: ["http://elasticsearch:9200"]
  traces_index: "solace_trace"
  logs_index: "solace_traces"
  mapping:
    mode: otel
```

Restart, and send some messages:

```bash
docker compose restart otel-collector
```

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

You get `200 200 200`. Everything looks fine.

---

## Step 3 — But nothing arrives

Count the documents:

```bash
curl -s "http://localhost:9200/solace_trace/_count"
```

```
{"error":{"root_cause":[{"type":"index_not_found_exception",...
```

Nothing. And here is the confusing part:

- The publishes returned `200`
- `./scripts/verify.sh` still says **20/20 passed**
- No container crashed

**Why `verify.sh` lies here:** it only checks that traces *exist* in the last
week. Old documents from before your change satisfy that. A pipeline dropping
every single span still shows all green.

### Where the real error is

In the collector's log:

```bash
docker logs dtobs-otelcol --since 5m 2>&1 | grep "failed to index"
```

```
error  failed to index document  index: solace_trace  error.type: index_not_found_exception
```

**That is the whole problem.** The exporter tried to write to `solace_trace`,
Elasticsearch said "no such thing", and the spans were **thrown away** — not
redirected, not queued, not bounced. Gone.

> Always check this log after changing exporter settings. It is the only place
> the failure shows up.

---

## Step 4 — Why it happened

`mapping: mode: otel` normally lets Elasticsearch name and **create** the target
by itself. That auto-creation only works for its own naming scheme
(`traces-*`, `logs-*`).

The moment you write your own name, you are on your own: **nothing creates
`solace_trace` for you.** It has to exist before the first span arrives.

---

## Step 5 — The fix

Three commands, then a restart.

**1. Tell Elasticsearch these names should be data streams** (a plain index will
not work — the exporter rejects it):

```bash
curl -X PUT "http://localhost:9200/_index_template/solace_custom_tpl" \
  -H 'Content-Type: application/json' \
  -d '{"index_patterns":["solace_trace","solace_traces"],"data_stream":{},"priority":500}'
```

**2. Create them:**

```bash
curl -X PUT "http://localhost:9200/_data_stream/solace_trace"
curl -X PUT "http://localhost:9200/_data_stream/solace_traces"
```

**3. Restart the collector — this step is easy to miss:**

```bash
docker compose restart otel-collector
```

The collector looks up its target **once at startup**. If you create the data
stream while it is running, it keeps saying "no such index" forever. This alone
cost us a debugging round.

---

## Step 6 — Confirm the fix

Send messages again (Step 2), then:

```bash
curl -s -X POST "http://localhost:9200/solace_trace/_refresh" >/dev/null
curl -s "http://localhost:9200/solace_trace/_count"
```

```
{"count":6,...}
```

And confirm nothing is being dropped:

```bash
docker logs dtobs-otelcol --since 5m 2>&1 | grep -c "failed to index"
```

`0` — working.

> **Why 6 and not 3?** Each message makes two spans — one `receive`, one
> `q.test send` — sharing a trace ID. 3 messages = 6 spans.

**To see them in Kibana**, you need a data view matching the new name (the
default `traces-*` view will not match `solace_trace`):

```bash
curl -X POST "http://localhost:5601/api/data_views/data_view" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"data_view":{"title":"solace_trace*","name":"Solace Custom Index","timeFieldName":"@timestamp"}}'
```

Then http://localhost:5601 → ☰ → **Discover** → pick **Solace Custom Index**.
Widen the time picker — it defaults to 15 minutes and will look empty.

---

## Going back

```bash
git checkout -- config/otel/collector.yaml
docker compose restart otel-collector
```

Remove the custom data streams too, if you want them gone:

```bash
curl -X DELETE "http://localhost:9200/_data_stream/solace_trace"
curl -X DELETE "http://localhost:9200/_data_stream/solace_traces"
curl -X DELETE "http://localhost:9200/_index_template/solace_custom_tpl"
```

---

## Things worth knowing before you experiment

**⚠️ `docker compose down -v` deletes everything you created by hand.** The data
streams, the index template, the Kibana data view — all of it lives in the
Elasticsearch volume. After a `down -v`, if your config still points at custom
names, you are silently dropping spans again with no obvious cause.

**Not every config key exists in every collector version.** This branch pins
`otel/opentelemetry-collector-contrib:0.144.0`, where:

| Key | Works? |
|---|---|
| `traces_index`, `logs_index` | yes |
| `logs_dynamic_id`, `logs_dynamic_index` | yes |
| `traces_dynamic_id` | **no — collector refuses to start** |

Test any new key like this — if it prints something, the key is not supported:

```bash
docker compose restart otel-collector && sleep 4
docker logs dtobs-otelcol --tail 20 | grep "invalid keys"
```

**Custom names lose Elastic's field types.** In `solace_trace`, `trace_id` gets
auto-guessed as `text` instead of `keyword`, so exact filters and aggregations
need `trace_id.keyword`. The built-in `traces-*` stream gets the right types for
free.

---

## Error messages you will see

| Message | Meaning | Fix |
|---|---|---|
| `index_not_found_exception` | Target does not exist | Create it as a data stream, then **restart the collector** |
| `resource_not_found_exception` | Target exists but is a plain index | Delete it, recreate as a data stream, restart |
| `invalid keys: X` | Key not supported in this version | Remove it, or upgrade the collector |
| `must not specify both ...` | Two conflicting settings | Remove one |
| `version_conflict_engine_exception` | Duplicate document ID rejected | **Not a fault** — this is deduplication working |

**Count did not change but there are no errors?** Elasticsearch refreshes about
once a second. Run `POST /<name>/_refresh` and count again.
