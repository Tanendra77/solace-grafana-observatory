# Solace Broker Metrics — local stack

Prometheus metrics for a Solace PubSub+ broker, collected via the community
`solace-prometheus-exporter`, stored 7 days in Prometheus, and visualized in
Grafana. Everything runs in Docker on one machine, every hop over TLS.

This is the metrics pillar of the same effort as `grafana-dt` (distributed
tracing) — reproducing the OpenShift build documented in
`doc/solace-observability-readme.md`, without OpenShift, using the community
exporter in place of the certified operator's bundled one. Same broker
metrics, same endpoint paths (`/solace-std`, `/solace-vpn-stats`,
`/solace-det`), plain containers instead of CRs and operators.

The broker is not part of this stack — it's started separately
(`docker-compose.broker.yaml`) or is one you already have. Every observability
pillar points at the same broker instead of bundling its own copy of it.

```
sdkperf / your clients ──SMF──> Solace broker (SEMP :8080 / :1943 TLS)
                                     │  monitor user (read-only)
                                     v  HTTPS
                        solace-prometheus-exporter (:9628, HTTPS)
                          /solace-std  /solace-vpn-stats  /solace-det
                                     │  HTTPS
                                Prometheus (7d / 2GB retention, :9090, HTTPS)
                                     │  HTTPS
                                  Grafana (:3000, HTTPS)
```

---

## Quick start

```bash
cp .env.example .env         # then review it — at minimum the credentials
./scripts/generate-certs.sh  # self-signed cert used by every hop below
```

**1. Start a broker**, if you don't already have one running:

```bash
docker compose -f docker-compose.broker.yaml up -d
```

Give it 60-90 seconds on first boot — it's building its config database.
Then load the TLS cert onto it (prompts for the admin password):

```bash
./scripts/setup-broker-tls.sh
```

Already have a broker (your own, or one shared with another pillar)? Skip
both steps and point `SOLACE_SEMP_URL` in `.env` at it instead.

**2. Start the metrics stack:**

```bash
docker compose up -d
```

**3. Check it's actually working, not just running:**

```bash
./scripts/verify.sh
```

Start here: **https://localhost:3000** (self-signed cert — your browser will
warn once, that's expected). Dashboards guide:
[`config/grafana/provisioning/dashboards/README.md`](config/grafana/provisioning/dashboards/README.md).

Nothing needs redoing after a restart — `docker compose down` (on either or
both files) and back `up` preserves broker config, metrics history and
Grafana's state. Add `-v` to a `down` to discard a given stack's volumes and
start that piece over; nothing does this automatically.

---

## Common commands

| Command | What it does |
|---|---|
| `docker compose -f docker-compose.broker.yaml up -d` | Start the broker. |
| `docker compose -f docker-compose.broker.yaml down` | Stop the broker. Data kept. |
| `docker compose up -d` | Start the metrics stack (exporter, Prometheus, Grafana). |
| `docker compose down` | Stop the metrics stack. Data kept. |
| `docker compose logs -f [service]` | Follow logs. |
| `docker compose ps` | Show container status. |
| `./scripts/verify.sh` | Check every hop; prints the fix for whatever failed. |

Run these from Git Bash or WSL on Windows. The two compose files are
independent — `docker compose` commands without `-f` operate on
`docker-compose.yaml` (the metrics stack); add `-f docker-compose.broker.yaml`
to target the broker instead.

---

## Sending traffic

Nothing here generates messages — bring your own client, publishing to
whatever VPN/queue you've set up on the broker. Any client works and none
need instrumenting: the exporter reports whatever the broker is doing.

```bash
sdkperf_java.sh -cip=localhost:55555 -cu=<user>@<vpn> -cp=<password> \
                -ptl=<topic> -mn=1000 -mr=50
```

Or use the broker's own Try Me! at http://localhost:8080 → your VPN → Try
Me! → Connect → Publish.

Queue-level dashboard panels populate once a queue exists and has data;
they're empty and correct on a stock broker with no queues yet.

---

## Using your own broker

Skip `docker-compose.broker.yaml` entirely and set in `.env`:

```env
SOLACE_SEMP_URL=https://your-broker.example.com:1943
```

(Plain `http://your-broker:8080` works too if you don't want TLS on that
specific hop — the exporter doesn't require it.)

Then create the read-only `monitor` user the exporter authenticates as:

```bash
./scripts/create-monitor-user.sh
```

It opens an SSH session to the broker's CLI and creates the user (prompts
for the admin password). Set `SOLACE_MONITOR_PASSWORD` in `.env` first. If
you want the TLS hop too, `./scripts/setup-broker-tls.sh` does the same over
SSH for the certificate — your broker needs its own cert if you don't want
to reuse the self-signed one `generate-certs.sh` makes.

---

## Security

- **TLS everywhere.** Broker SEMP, the exporter's own listener, Prometheus,
  and Grafana all serve HTTPS with a self-signed cert from
  `./scripts/generate-certs.sh` (`certs/`, gitignored — never commit it).
  Fine for local dev; swap in a CA-signed cert for anything real by pointing
  `GF_SERVER_CERT_FILE`/`SOLACE_SERVER_CERT`/etc. at your own files and
  re-running `setup-broker-tls.sh` with your own PEM.
- **Read-only monitor user.** The exporter authenticates as `monitor`
  (global access level `read-only`), never the broker admin account.
- **Grafana auth.** Anonymous access is disabled; there's one admin account
  by default (`GF_ADMIN_USER`/`GF_ADMIN_PASSWORD` in `.env`) — create a
  viewer-only account in Grafana itself for anyone who just needs to look.
- **Not covered:** client-certificate auth, secrets management beyond plain
  `.env` (fine for local dev, not for anything shared), and rotating the
  self-signed cert automatically (it's valid 825 days; re-run
  `generate-certs.sh` + `setup-broker-tls.sh` before it expires).

---

## Configuration

Everything lives in `.env`. Things worth knowing:

- **`SOLACE_SEMP_URL`** is how the exporter (running in a container) reaches
  the broker. Default points at `host.docker.internal`, which resolves to
  whatever machine is running Docker — right for a broker started via
  `docker-compose.broker.yaml` on the same machine. Point it elsewhere for a
  remote or shared broker.
- **`METRICS_RETENTION_TIME` / `METRICS_RETENTION_SIZE`** bound Prometheus's
  local TSDB both ways — 7 days, 2GB by default. Whichever limit is hit first
  wins.
- Prometheus scrape intervals live in `config/prometheus/prometheus.yml`
  directly, not `.env` — Prometheus's config format has no env-substitution
  support, unlike Tempo's on the tracing branch. `solace-std`/`solace-vpn-stats`
  poll every 10s; `solace-det` (queue enumeration, heavier on SEMP at scale)
  every 15s.
- **Image tags are pinned deliberately.** Never `:latest`.

---

## Troubleshooting

`./scripts/verify.sh` diagnoses all of the below and prints the fix.

| Symptom | Cause | Fix |
|---|---|---|
| Exporter up, `/solace-std` has few/no `solace_*` lines | monitor user auth failing, or broker unreachable | check `SOLACE_MONITOR_PASSWORD` and `SOLACE_SEMP_URL` in `.env` |
| Queue panels empty | no queue exists yet, or nothing published | create a queue and send traffic (see above) |
| Grafana "No data" on traffic panels | nothing published recently | send traffic; `rate()` panels need recent activity |
| Grafana password change has no effect | written to SQLite on first boot, ignored afterwards | remove the `grafana-data` volume, or change it inside Grafana |
| Prometheus target down for one job | exporter unreachable or that endpoint erroring | `docker compose logs solace-exporter` |
| Exporter can't reach the broker | `host.docker.internal` not resolving | Docker Desktop provides it by default; on Linux Docker Engine the compose file already adds `host-gateway` — confirm your Docker version supports it |
| Browser warns about the certificate | self-signed, expected | click through / add an exception — or use your own CA-signed cert |
| `curl` fails with a cert error | self-signed cert isn't trusted by curl | add `-k`, or `--cacert certs/server.crt` |
| Broker SEMP TLS port (1943) not reachable | cert never loaded | `./scripts/setup-broker-tls.sh` |

---

## Layout

```
docker-compose.broker.yaml     standalone broker — start this first (or use your own)
docker-compose.yaml            the metrics stack: exporter, Prometheus, Grafana
.env.example                   every setting, documented
certs/                         generated by generate-certs.sh — gitignored
config/
  prometheus/prometheus.yml    scrape config — 3 jobs against the exporter, HTTPS
  prometheus/web-config.yml    Prometheus's own HTTPS listener
  grafana/provisioning/        datasource + the three dashboards + their README
scripts/
  generate-certs.sh            self-signed TLS cert for every hop
  setup-broker-tls.sh          loads the cert onto the broker over SSH
  verify.sh                    hop-by-hop checks
  create-monitor-user.sh       creates the read-only user on your own broker
```

---

## References

- [solacecommunity/solace-prometheus-exporter](https://github.com/solacecommunity/solace-prometheus-exporter) — the exporter this stack runs. Its `configs/solace_prometheus_exporter.ini` documents every endpoint alias and env var; `examples/grafana/` has the stock broker/VPN/bridge dashboards this build's custom ones supersede for queue-level detail.
- [Solace SEMP v2 API](https://docs.solace.com/API-Tools/SEMP/SEMP-API.htm) — the API the exporter scrapes and `scripts/broker-setup.sh`'s successor scripts talk to.
- [Solace PubSub+ CLI reference](https://docs.solace.com/Software-Broker/Configuring-and-Managing.htm) — background for `scripts/setup-broker-tls.sh` and `create-monitor-user.sh`: broker-level TLS certificates and SEMP admin users are CLI-only, not exposed over SEMP's REST API.
- [Prometheus documentation](https://prometheus.io/docs/) — scrape config, retention flags, `--web.config.file` for TLS.
- [Grafana documentation](https://grafana.com/docs/grafana/latest/) — dashboard provisioning, datasource provisioning, and the [table transformations reference](https://grafana.com/docs/grafana/latest/panels-visualizations/query-transform-data/transform-data/) (`joinByField`, `organize`, `filterByValue`, `calculateField`) the Queue Monitor dashboard is built on.
- `doc/solace-observability-readme.md` — the OpenShift build this stack reproduces locally. Gitignored (internal reference material) — present only if you already have it locally, not part of this repo.

---

## What is deliberately not here

- **Broker bootstrap.** No VPN, queue, or application user is created for
  you — bring your own broker configuration, or configure a fresh one by
  hand. Only the read-only `monitor` user (needed by the exporter) is
  created automatically, and only when using `docker-compose.broker.yaml`.
- **Alerting rules.** Dashboards only for this pass — can follow once the
  dashboard itself is verified working.
- **Long-term retention beyond 7 days.** Thanos/remote-write is out of scope
  at this size, same call the OpenShift doc made for its cluster Prometheus.
- **Traces and logs.** Metrics only — they live on their own branches
  (`grafana-dt` for tracing).
- **HA.** One broker, one exporter, one Prometheus.
- **Automated cert rotation / a real CA.** Self-signed, manually regenerated.
