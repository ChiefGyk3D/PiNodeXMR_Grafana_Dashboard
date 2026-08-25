# Architecture

How metrics get from monerod to a Grafana panel, and why the pieces are
arranged the way they are.

## The data path

```
monerod ──JSON-RPC──> monerod-exporter ──writes .prom──> node_exporter ──HTTP──> Prometheus ──query──> Grafana
```

1. **monerod** exposes a JSON-RPC API (`get_info`, `get_fee_estimate`,
   `hard_fork_info`, `get_last_block_header`, `get_transaction_pool_stats`).
2. **monerod-exporter** — a small bash service — polls that API on an interval
   and writes Prometheus-formatted metrics to a `.prom` file.
3. **node_exporter** picks that file up through its *textfile collector* and
   serves it alongside the usual host metrics (CPU, memory, disk, network) on
   one HTTP endpoint.
4. **Prometheus** scrapes that endpoint and stores the samples.
5. **Grafana** queries Prometheus and draws the dashboard.

## Why the textfile collector?

The obvious design would be a Grafana datasource plugin pointed straight at
monerod's RPC. That does not work well in practice:

- monerod's RPC uses **HTTP digest authentication**. Most Grafana datasource
  plugins — including Infinity — only speak basic auth.
- It would put your **RPC credentials inside Grafana**, which is exactly where
  you do not want node credentials if Grafana is exposed to a LAN.
- monerod's RPC returns deeply nested JSON that Grafana cannot turn into time
  series without a lot of transformation.

Writing a `.prom` file that node_exporter already knows how to serve avoids all
three problems:

- **No extra port.** Metrics ride the node_exporter endpoint you already have.
- **Credentials never leave the device.** The exporter reads them locally and
  Grafana only ever sees numbers.
- **Host and node metrics share one scrape**, so CPU temperature and blockchain
  height arrive with the same timestamps and the same `instance` label.
- **Two dependencies only**: `curl` and `jq`.

## What the "database" actually is

This trips people up, so to be explicit: **the dashboard's datasource is
Prometheus.** There is no SQL database, and no direct connection from Grafana to
your Monero node.

The installer provisions a Prometheus datasource with the fixed UID
`pinodexmr-prometheus`, and rewrites the dashboard JSON so all of its panel
queries reference that exact UID. That pairing is what makes the dashboard work
the moment Grafana starts — no "select your datasource" import step, and no UID
drift between one install and the next.

See [CONFIGURATION.md](CONFIGURATION.md#the-datasource) for how to point it at a
different Prometheus.

## Deployment modes

### Local mode

Everything runs on the PiNodeXMR device.

```
┌──────────────────── PiNodeXMR device ─────────────────────┐
│                                                            │
│  monerod ──> monerod-exporter ──> node_exporter :9100      │
│                                        │  (127.0.0.1)      │
│                                        ▼                   │
│                                   Prometheus :9090         │
│                                        │  (127.0.0.1)      │
│                                        ▼                   │
│                                    Grafana :3000 ──────────┼──> your browser
│                                                            │
└────────────────────────────────────────────────────────────┘
```

node_exporter and Prometheus bind to loopback by default; only Grafana is
exposed. That is the smallest surface that still gives you a dashboard on your
LAN.

### Agent mode — pull

The device only produces metrics. A Prometheus somewhere else scrapes it.

```
┌──── PiNodeXMR ────┐                    ┌──── your monitoring host ────┐
│                    │                    │                              │
│ monerod-exporter   │                    │   Prometheus ──> Grafana     │
│        │           │                    │        │                     │
│        ▼           │   scrape :9100     │        │                     │
│ node_exporter ◄────┼────────────────────┼────────┘                     │
│    (0.0.0.0)       │                    │                              │
└────────────────────┘                    └──────────────────────────────┘
```

Simple, but your monitoring host must be able to *open a connection to* the
PiNodeXMR — same LAN, a VPN, or a port forward.

### Agent mode — push

The device pushes to a remote endpoint. Only outbound connections are made.

```
┌──── PiNodeXMR ─────────────────┐        ┌──── remote (any network) ────┐
│                                 │        │                              │
│ monerod-exporter                │        │  Prometheus / Mimir /        │
│        │                        │        │  Grafana Cloud               │
│        ▼                        │        │        │                     │
│ node_exporter (127.0.0.1)       │        │        ▼                     │
│        │                        │        │     Grafana                  │
│        ▼                        │        │                              │
│ Prometheus Agent ───remote_write┼───────>│                              │
│                                 │        │                              │
└─────────────────────────────────┘        └──────────────────────────────┘
```

This is the mode for **monitoring a node on someone else's network**, behind
CGNAT, or anywhere you cannot open inbound ports. Prometheus Agent keeps no
local time-series database — it scrapes, buffers briefly, and forwards — so it
is easy on an SD card.

Both transports can be enabled together (`both`).

### Mixed topologies

Grafana and Prometheus are independent install switches, so two further
shapes exist for labs that already run half the stack:

- **Backend** — Prometheus on the device, dashboard in your existing Grafana.
  The device's Prometheus scrapes locally and serves the query API on the LAN;
  your Grafana adds `http://<device>:9090` as a datasource and imports the
  dashboard JSON.
- **Viewer** — Grafana on the device, database in your existing lab. The local
  Grafana is provisioned against any Prometheus-compatible endpoint
  (Prometheus, Mimir, VictoriaMetrics, Thanos Query — with optional basic
  auth), while the device's metrics reach that database over push or pull
  exactly as in agent mode.

## Components installed

| Component | Full | Backend | Viewer | Agent (pull) | Agent (push) | Installed from |
|---|:---:|:---:|:---:|:---:|:---:|---|
| `monerod-exporter` | ✅ | ✅ | ✅ | ✅ | ✅ | this repo |
| `node_exporter` | ✅ loopback | ✅ loopback | per transport | ✅ exposed | ✅ loopback | upstream release binary |
| `prometheus` | ✅ server | ✅ server, LAN-facing | agent mode if pushing | — | ✅ agent mode | upstream release binary |
| `grafana` | ✅ | — | ✅ | — | — | Grafana Labs APT repo |
| Docker + Compose | optional | optional | optional | — | — | get.docker.com |

> **PiNodeXMR does not ship node_exporter.** The installer installs it. If your
> device already has one — from APT or a manual install — the installer detects
> it and reconfigures it in place rather than installing a second copy.

## Files on disk

| Path | Purpose |
|---|---|
| `/etc/pinodexmr-monitoring/config.env` | every setting, `0640 root:<exporter group>` |
| `/usr/local/bin/monerod-exporter.sh` | the exporter |
| `/etc/systemd/system/monerod-exporter.service` | exporter unit |
| `/var/lib/node_exporter/textfile_collector/monerod.prom` | generated metrics |
| `/etc/prometheus/prometheus.yml` | Prometheus config (local mode) |
| `/etc/prometheus/prometheus-agent.yml` | Agent config (push mode) |
| `/etc/grafana/provisioning/datasources/pinodexmr.yml` | the datasource |
| `/etc/grafana/provisioning/dashboards/pinodexmr.yml` | dashboard provider |
| `/var/lib/grafana/dashboards/pinodexmr/` | the provisioned dashboard |
| `/opt/pinodexmr-monitoring/` | compose project (Docker flavour) |
| `/var/log/pinodexmr-monitoring-install.log` | installer log |

## Design notes

**The exporter re-reads its configuration every cycle.** On PiNodeXMR it also
re-sources `RPCu.sh`, `RPCp.sh` and `monero-port.sh` on every poll, so changing
your RPC username, password or port through the PiNodeXMR menus takes effect
within one interval with no restart and no duplicated configuration.

**Metrics are written atomically.** The exporter writes to a temp file and
`mv`s it into place, so node_exporter never serves a half-written file.

**The exporter exits after repeated failures** rather than spinning. systemd
restarts it with backoff, which recovers cleanly from a monerod restart while
still surfacing a genuine outage as `monerod_up 0`.

**node_exporter stays on the host in the Docker flavour.** It needs host
`/proc`, `/sys` and the textfile directory, and keeping it on the host means
both flavours expose byte-identical metrics.
