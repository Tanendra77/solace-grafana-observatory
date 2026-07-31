# Solace Distributed Tracing Observatory — local stack

Distributed tracing for a Solace PubSub+ broker, stored in Grafana Tempo and explored in
Grafana. Everything runs in Docker on one machine.

This reproduces a working OpenShift deployment without OpenShift — no operators, no CRs,
no cloud object store. Same architecture, same failure modes, same lessons; plain
containers instead.

```
sdkperf / your clients ──SMF──> Solace broker
                                     │  telemetry profile "trace"
                                     │  → queue #telemetry-trace  (spool-backed)
                                     │
                            AMQP 5672, SASL PLAIN
                                     v
                              OTel Collector          → traces.jsonl (optional)
                                     │
                              OTLP gRPC 4317
                                     v
                                   Tempo  (local filesystem, named volume)
                                     │
                                  HTTP 3200
                                     v
                                  Grafana
```

---

## Quick start

```bash
./stack.sh up
```

First run copies `.env.example` to `.env` and stops so you can review it. Run `up` again
and the stack comes up with the broker fully configured — VPN, AMQP, telemetry profile,
trace filter and both client users are all applied automatically.

Then send some traffic and check it worked:

```bash
./stack.sh urls      # endpoints, credentials, and a ready-made sdkperf command
./stack.sh verify    # checks every hop and tells you exactly what is broken
```

Traces appear at **http://localhost:3000** → Explore → Tempo → Search → Run query.

Nothing needs redoing after a restart. `./stack.sh down` and `./stack.sh up` preserve
the broker config, the traces and Grafana's state. Only `./stack.sh reset` discards them,
and it asks first.

---

## Commands

| Command | What it does |
|---|---|
| `./stack.sh up` | Start everything. Applies broker config automatically. |
| `./stack.sh down` | Stop and remove containers. **Data is kept.** |
| `./stack.sh stop` / `start` | Pause and resume without removing containers. |
| `./stack.sh setup` | Re-apply broker configuration over SEMP. Idempotent. |
| `./stack.sh verify` | Check every hop; prints the fix for whatever failed. |
| `./stack.sh verify --persistence` | Also restart and confirm state survives. |
| `./stack.sh logs [service]` | Follow logs. |
| `./stack.sh urls` | Endpoints, credentials, sdkperf command line. |
| `./stack.sh reset` | **Destructive.** Delete all volumes and start over. |

Run these from Git Bash or WSL on Windows.

---

## Sending traffic

Nothing in this stack generates messages — bring your own client. Any of these work,
and none of them need instrumenting: the broker produces spans for every message
matching the trace filter, whatever published it.

**sdkperf**

```bash
sdkperf_java.sh -cip=localhost:55555 -cu=dtuser@test -cp=dtuser_pw \
                -ptl=test/trade/new -mn=100 -mr=10
```

**The broker's own Try Me!** — http://localhost:8080 → VPN `test` → Try Me! → Connect → Publish.

**Your own application** — connect to `localhost:55555`, VPN `test`, user `dtuser`.

Exact credentials come from `.env`; `./stack.sh urls` prints the current ones.

---

## Using your own broker

Set two things in `.env`:

```env
BROKER_MODE=external
SOLACE_BROKER_HOST=your-broker.example.com      # reachable from inside docker
SOLACE_SEMP_URL=http://your-broker.example.com:8080
SOLACE_SEMP_HOST_URL=http://your-broker.example.com:8080
```

No broker container is created; the collector, Tempo and Grafana talk to yours instead.

`SOLACE_BROKER_HOST` is resolved **from inside the Docker network**, so `localhost` will
not work — it would point at the container itself. Use a hostname, a routable IP, or
`host.docker.internal` for a broker running on your machine outside Docker.

The bootstrap script configures a remote broker exactly as it does a local one, provided
the admin credentials in `.env` are right. If you do not have admin, or the broker is
already set up, set `BOOTSTRAP_ENABLED=false` and configure it yourself. `broker-setup.sh`
is readable as a specification of exactly what needs to exist on the broker.

---

## Configuration

Everything lives in `.env`, which is documented inline and gitignored. The YAML files
read from it; don't hardcode values in them.

Things worth knowing:

- **`TRACE_FILTER_SUBSCRIPTION`** defaults to `>`, meaning every topic is traced. Narrow
  it for anything resembling production — tracing everything is expensive at volume.
- **`TRACE_FILE_ENABLED`** turns on a second sink writing every span to
  `trace-data/traces.jsonl`, alongside Tempo. Off by default. Useful for raw dumps and
  offline inspection.
- **`OTEL_LOG_LEVEL`** is `info`. Spans still print to the collector log at that level
  (the debug *exporter* logs at info). Raise it to `debug` only to diagnose the AMQP
  connection itself.
- **Image tags are pinned deliberately.** The collector's config schema changes between
  releases, and `grafana/tempo:latest` is currently a v3.0.0 development build with no
  matching release tag.

### Adding instrumented applications later

The collector's OTLP ports are published on the host (`4317` gRPC, `4318` HTTP). Point an
instrumented app at either and its spans land in the same Tempo alongside the broker's.
Tempo's own OTLP port is deliberately not published, so there is exactly one endpoint to
aim at.

---

## Troubleshooting

`./stack.sh verify` diagnoses all of the below and prints the fix. This table is for
understanding *why*.

| Symptom | Cause | Fix |
|---|---|---|
| Collector running, no spans anywhere | AMQP bound to the wrong Message VPN | `./stack.sh setup` |
| Collector running, no spans anywhere | auth or ACL failure — the collector retries silently and never crashes | `./stack.sh verify`, then check the trace credentials |
| Broker produces spans, queue keeps growing | collector not consuming | `./stack.sh logs otel-collector` |
| Tempo returns no traces, but spans reached it | search with no time range covers only a narrow recent window | pass `start` / `end`, as `verify` does |
| Tempo `503` right after start | normal WAL replay and ring join | wait ~90s |
| Grafana password change has no effect | written to SQLite on first boot, ignored afterwards | `./stack.sh reset`, or change it inside Grafana |
| Broker container restarting in a loop | an invalid `username_admin_globalaccesslevel` value | must be `admin`, not `global/admin` |

Two traps deserve emphasis, because both present as a perfectly healthy stack:

**AMQP binds to exactly one Message VPN.** Out of the box that is `default`. If it stays
there while your traffic and telemetry profile are on `test`, the collector connects
successfully, binds nothing, and reports itself healthy indefinitely. `broker-setup.sh`
moves it; don't undo that by hand.

**The telemetry queue is not in the config API.** It is broker-internal and appears only
under `/SEMP/v2/monitor`. Querying `/SEMP/v2/config/.../queues` makes a perfectly good
queue look missing.

---

## Layout

```
docker-compose.yaml            the stack
docker-compose.jsonl.yaml      overlay adding the JSONL sink
.env.example                   every setting, documented
stack.sh                       lifecycle wrapper
config/
  otel/collector.yaml          collector pipeline
  otel/jsonl-overlay.yaml      merged in when the JSONL sink is on
  tempo/tempo.yaml             Tempo, local filesystem backend
  grafana/provisioning/        Tempo datasource (replaces the GrafanaDatasource CR)
scripts/
  broker-setup.sh              idempotent SEMP v2 bootstrap
  verify.sh                    hop-by-hop checks
trace-data/                    JSONL output when the file sink is enabled
```

---

## What is deliberately not here

Recorded so they aren't mistaken for oversights:

- **TLS.** Every hop is plaintext, matching the OpenShift first build.
- **Metrics and logs.** Traces only — they live on their own branches.
- **A traffic generator.** By design — bring your own client.
- **Application instrumentation.** The OTLP seam is open for it; no instrumented app ships here.
- **HA.** One broker, one collector. The telemetry queue is a single consumption point;
  scaling the collector past one replica partitions consumption rather than sharing it.
