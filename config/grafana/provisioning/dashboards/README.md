# Dashboards

Three dashboards, split by what they're for — one VPN at a time doesn't scale
to "is anything backed up right now" across hundreds of queues, so that's its
own dashboard with tables instead of graphs.

## Solace Observability — Start Here

The landing page — set as Grafana's actual default home dashboard (visiting
Grafana takes you here first), not just a link on some other page. Links to
both dashboards below, plus a system-wide pulse (broker up, redundancy,
VPN/queue/consumer counts across every VPN, not scoped to one).

## Solace VPN Overview

Pick a VPN from the `VPN` dropdown at the top; everything on the page scopes
to it. Rows, top to bottom:

- **Broker Health** — is the broker/HA pair actually working (redundancy,
  config-sync, disk/compute/mate-link latency).
- **VPN Connections** — who's connected, by protocol, and how close to the
  connection quota you are.
- **Message Traffic** — in/out rate, and discard rate (non-zero discards
  means backpressure — look here first if something feels slow).
- **Producers & Consumers** — queue count, total active consumer binds,
  total connected clients. Solace doesn't label a client as "producer" or
  "consumer" in its metrics, so "Connected Clients" is everyone, not a
  role breakdown — binds-per-queue is the accurate consumer count.
- **Client Detail** — per-client RX/TX throughput (table, sortable,
  paginated), and a **Slow Subscribers** panel: a slow subscriber can't keep
  up with its delivery rate, which is a common root cause of queue pile-up.
  Empty is good; anything listed there is worth investigating first.
- **Replication & HA** — redundancy and replication state. The "Internal/
  System Queue Pile-up" panel is a best-effort guess (Solace's internal
  queues conventionally start with `#`) — it was **not verified against a
  real HA-paired broker**. Check the queue names it shows against what you
  actually expect before trusting it for replication monitoring.
- **Spool** — system and VPN spool usage vs quota.

## Solace Queue Monitor

Built for scale — hundreds or thousands of queues render as unreadable
noise on a graph, so this is three tables instead:

- **All Queues** — every queue, sorted by message depth, highest first —
  the queues most worth looking at are at the top.
- **Active Consumers** — same table, filtered to queues with at least one
  bound consumer.
- **Idle Queues** — filtered to queues with zero consumers. A growing idle
  queue usually means a stuck or missing consumer — worth checking first
  when something's piling up.

Use the `VPN` dropdown and the `Queue Search` box to narrow further — type
part of a queue name and all three tables filter live as you type (leave it
empty to show everything). It's a substring match, not exact — searching
`test` matches `q.test`, `q.test.1`, `q.test.orders`, anything containing
"test". It's implemented as a regex under the hood, so the usual regex
characters (`.` `*` `+` `(` `)`) behave as regex rather than literal text.
Internal/system queues (names starting with `#` — replication, telemetry)
are filtered out everywhere on this dashboard; they're not real application
queues and would just be noise at the top of a pile-up-sorted table.

**Sorting is interactive, not fixed.** Tables open sorted by `Depth (msgs)`
descending (biggest pile-up first), but every column header is clickable —
click once for ascending, again for descending, again to reset. Sort by
`Consumers` to find over- or under-subscribed queues, by `Spool Usage %` to
find queues closest to their quota, or by `Queue` to find one by name. This
is a native table feature, not something specific to one column.

**Scale — 1000+ queues.** Prometheus and Grafana both handle a query
returning 1000-1200 series without strain; that's small by Prometheus
standards. The tables paginate (page controls at the bottom) instead of
rendering one giant scroll, so sorting/browsing stays usable at that size.
If it ever gets sluggish in your environment, narrow with the `Queue Search`
box rather than browsing all rows — it filters at query time, not just in
the rendered table.

### Alerting

Not set up yet — these are dashboards, not alerts. When you're ready to add
a "queue depth exceeded" alert, `solace_queue_spool_usage_msgs` and
`solace_queue_spool_usage_bytes` (both per `queue_name`) are what you'd
threshold on; Grafana's alert rules or a Prometheus `PrometheusRule`-style
recording rule both work off the same metric.

## If a panel shows "No data"

Check `../prometheus/prometheus.yml` — the four scrape jobs need to be up.
`../../scripts/verify.sh` (repo root) checks this along with everything
else in the pipeline, including that all three dashboards here are actually
provisioned.

## References

- [Grafana table transformations](https://grafana.com/docs/grafana/latest/panels-visualizations/query-transform-data/transform-data/) — `joinByField`, `organize`, `filterByValue`, `calculateField`: the mechanics behind the Queue Monitor tables.
- [Grafana template variables](https://grafana.com/docs/grafana/latest/dashboards/variables/) — how `$vpn` and `$queue` work, including the `textbox` type used for the search box.
- [PromQL basics](https://prometheus.io/docs/prometheus/latest/querying/basics/) — for editing or adding panel queries.
