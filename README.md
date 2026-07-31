# Solace Grafana Observatory

Observability for Solace PubSub+ brokers, built as local Docker Compose stacks and
mirrored from working OpenShift deployments.

Three pillars, built one at a time:

| Pillar | Stack | Branch | Status |
|---|---|---|---|
| **Traces** | broker → OTel Collector → Tempo → Grafana | `grafana-dt` | done |
| **Metrics** | broker → Prometheus exporter → Prometheus → Grafana | `grafana-metrics` | planned |
| **Logs** | broker syslog → OTel Collector → Loki → Grafana | `grafana-logs` | planned |

---

## How this repository is organised

**`main`** holds the combined setup — every pillar, integrated, in one stack. It is the
end state, not the workbench.

**Feature branches hold one pillar each.** All work happens on them. A branch contains
only the stack for its pillar plus the shared foundation, so it can be brought up on its
own and understood without reading around the other two.

```
main ──┬── grafana-dt          traces:  Tempo
       ├── grafana-metrics     metrics: Prometheus
       └── grafana-logs        logs:    Loki
```

Each branch carries its **own README**, written for that pillar: what it builds, how to
start it, and how to verify it. Read the README on the branch you check out, not this
one.

### Working here

```bash
git checkout grafana-dt     # or another pillar branch
cat README.md               # branch-specific quick start
```

Start new work by branching from `main`, never from another pillar branch. Pillars merge
into `main` when they are complete and verified.

---

## Shared foundation

`main` carries what every pillar branch inherits: this overview and a `.gitignore`
covering secrets, certificates, kubeconfigs and runtime output.

The stacks are derived from working OpenShift deployments. Those deployment notes are
kept outside this repository — they describe live infrastructure and are not published
here. What matters from them is folded into each branch's own README and design
document.

---

## Conventions

**Never commit secrets.** Every stack keeps its configuration in a gitignored `.env`,
with a committed `.env.example` template carrying placeholder values only. Certificates,
keys and kubeconfigs are excluded by `.gitignore`.

**Pin image tags.** No `:latest` anywhere. Collector config schemas change between
releases, and a silent upgrade breaks a working pipeline at the worst possible time.

**Every stack must be verifiable in one command.** These pipelines fail silently —
components report healthy while doing nothing. A stack you cannot verify is a stack you
cannot trust.
