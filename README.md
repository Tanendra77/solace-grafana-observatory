# Solace Broker Metrics — local stack

Prometheus metrics for a Solace PubSub+ broker, collected via the community
`solace-prometheus-exporter`, stored 7 days in Prometheus, and visualized in
Grafana. Everything runs in Docker on one machine.

This is the metrics pillar of the same effort as `grafana-dt` (distributed
tracing) — reproducing the OpenShift build documented in
`doc/solace-observability-readme.md`, without OpenShift, using the community
exporter in place of the certified operator's bundled one. Same broker
metrics, same endpoint paths (`/solace-std`, `/solace-vpn-stats`,
`/solace-det`), plain containers instead of CRs and operators.

```
sdkperf / your clients ──SMF──> Solace broker (SEMP :8080)
                                     │  monitor user (read-only)
                                     v
                        solace-prometheus-exporter (:9628)
                          /solace-std  /solace-vpn-stats  /solace-det
                                     │
                                Prometheus (7d / 2GB retention, :9090)
                                     │
                                  Grafana (:3000)
```

---

## Quick start

```bash
./stack.sh up
```

First run copies `.env.example` to `.env` and stops so you can review it. Run
`up` again and the stack comes up with the broker fully configured — VPN, a
read-only monitor user for the exporter, an app user, and a demo queue are all
applied automatically.

```bash
./stack.sh urls      # endpoints, credentials, and a ready-made sdkperf command
./stack.sh verify    # checks every hop and tells you exactly what is broken
```

Dashboard: **http://localhost:3000** → Dashboards → **Solace Broker — Metrics**.

Nothing needs redoing after a restart. `./stack.sh down` and `./stack.sh up`
preserve the broker config, metrics history and Grafana's state. Only
`./stack.sh reset` discards them, and it asks first.

---

## Commands

| Command | What it does |
|---|---|
| `./stack.sh up` | Start everything. Applies broker config automatically. |
| `./stack.sh down` | Stop and remove containers. **Data is kept.** |
| `./stack.sh stop` / `start` | Pause and resume without removing containers. |
| `./stack.sh setup` | Re-apply broker configuration over SEMP. Idempotent. |
| `./stack.sh verify` | Check every hop; prints the fix for whatever failed. |
| `./stack.sh logs [service]` | Follow logs. |
| `./stack.sh urls` | Endpoints, credentials, sdkperf command line. |
| `./stack.sh ps` | Show container status. |
| `./stack.sh reset` | **Destructive.** Delete all volumes and start over. |

Run these from Git Bash or WSL on Windows.

---

## Sending traffic

The demo queue subscribes to `metrics/demo/>`. Anything published there shows
up in the queue-depth panels:

```bash
sdkperf_java.sh -cip=localhost:55555 -cu=appuser@test -cp=appuser_pw \
                -ptl=metrics/demo/load -mn=1000 -mr=50
```

Or use the broker's own Try Me! at http://localhost:8080 → VPN `test` → Try
Me! → Connect → Publish to `metrics/demo/anything`.

---

## Using your own broker

Set in `.env`:

```env
BROKER_MODE=external
SOLACE_SEMP_URL=http://your-broker.example.com:8080
SOLACE_SEMP_HOST_URL=http://your-broker.example.com:8080
```

No broker container is created; the exporter, Prometheus and Grafana talk to
yours instead. If you don't have admin, set `BOOTSTRAP_ENABLED=false` and
create the VPN/queue and the read-only monitor user yourself —
`scripts/broker-setup.sh` is readable as a specification of what it expects to
exist for the VPN side; the monitor user itself is broker-level, not something
this script can create over SEMP (see the comment at the top of that file).

---

## Configuration

Everything lives in `.env`. Things worth knowing:

- **`METRICS_RETENTION_TIME` / `METRICS_RETENTION_SIZE`** bound Prometheus's
  local TSDB both ways — 7 days, 2GB by default. Whichever limit is hit first
  wins.
- Prometheus scrape intervals live in `config/prometheus/prometheus.yml`
  directly, not `.env` — Prometheus's config format has no env-substitution
  support, unlike Tempo's on the tracing branch.
- **Image tags are pinned deliberately.** Never `:latest`.

---

## Troubleshooting

`./stack.sh verify` diagnoses all of the below and prints the fix.

| Symptom | Cause | Fix |
|---|---|---|
| Exporter up, `/solace-std` has few/no `solace_*` lines | monitor user auth failing | check `SOLACE_MONITOR_PASSWORD` in `.env` matches what the broker booted with |
| Queue panels empty | no demo queue, or nothing published yet | `./stack.sh setup`, then send traffic (see above) |
| Grafana "No data" on traffic panels | nothing published recently | send traffic; `rate()` panels need recent activity |
| Grafana password change has no effect | written to SQLite on first boot, ignored afterwards | `./stack.sh reset`, or change it inside Grafana |
| Prometheus target down for one job | exporter unreachable or that endpoint erroring | `./stack.sh logs solace-exporter` |

---

## Layout

```
docker-compose.yaml            the stack
.env.example                   every setting, documented
stack.sh                       lifecycle wrapper
config/
  prometheus/prometheus.yml    scrape config — 3 jobs against the exporter
  grafana/provisioning/        Prometheus datasource + the dashboard
scripts/
  broker-setup.sh              idempotent SEMP bootstrap (VPN, app user, demo queue)
  verify.sh                    hop-by-hop checks
```

---

## What is deliberately not here

- **TLS.** Every hop is plaintext, matching the tracing branch and the
  OpenShift first build.
- **Alerting rules.** Dashboards only for this pass — can follow once the
  dashboard itself is verified working.
- **Long-term retention beyond 7 days.** Thanos/remote-write is out of scope
  at this size, same call the OpenShift doc made for its cluster Prometheus.
- **Traces and logs.** Metrics only — they live on their own branches
  (`grafana-dt` for tracing).
- **HA.** One broker, one exporter, one Prometheus.
