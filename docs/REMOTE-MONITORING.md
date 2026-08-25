# Monitoring from another network

Agent mode is for when Grafana does not live on the PiNodeXMR: a node at home
watched from a VPS, a node at a friend's house, several nodes on one dashboard,
or a device behind CGNAT with no way to open a port.

## Which transport?

| | **push** (remote_write) | **pull** (scrape) |
|---|---|---|
| Direction | Device → your stack | Your stack → device |
| Works behind NAT/CGNAT | ✅ | ❌ without a tunnel |
| Inbound ports needed | none | one |
| Needs a remote_write receiver | ✅ | ❌ any Prometheus |
| Survives changing home IP | ✅ | ❌ needs dynamic DNS |
| Extra service on the device | Prometheus Agent | none |

**If in doubt, choose push.** It is the one that works from anywhere, and it is
the default the installer offers.

Choose `both` if you want a remote dashboard *and* the ability to scrape
locally.

---

## Push mode

The device runs Prometheus in Agent mode: it scrapes node_exporter on loopback,
buffers briefly, and forwards over `remote_write`. No local time-series
database, so it is easy on an SD card.

### What you need

A `remote_write`-capable receiver. Any of:

- **Prometheus** with `--web.enable-remote-write-receiver`
- **Grafana Cloud** (free tier is enough for one node)
- **Grafana Mimir**, **VictoriaMetrics**, **Thanos Receive**, **InfluxDB v2**

### Grafana Cloud

1. In Grafana Cloud, open **Connections → Add new connection → Hosted
   Prometheus metrics**, then **Send metrics from a single Prometheus instance**.
2. Note the **Remote Write Endpoint**, your numeric **Username / Instance ID**,
   and a generated **API token**.
3. Run the installer, choose `agent` → `push`, and enter:

   | Prompt | Value |
   |---|---|
   | Remote write URL | `https://prometheus-<region>.grafana.net/api/prom/push` |
   | Auth | `basic` |
   | Username | your numeric instance ID |
   | Password | the API token |

4. Import `dashboards/pinodexmr-dashboard.json` into your Grafana Cloud
   instance and select the hosted Prometheus datasource.

### Your own Prometheus

Start the receiving Prometheus with the receiver endpoint enabled:

```bash
prometheus --config.file=/etc/prometheus/prometheus.yml \
           --web.enable-remote-write-receiver
```

Then use `http://your-prometheus:9090/api/v1/write` as the URL. Put it behind
TLS and basic auth if it crosses the public internet — see
[SECURITY.md](SECURITY.md).

### Verifying push

```bash
sudo systemctl status prometheus-agent
sudo journalctl -u prometheus-agent -f

# Samples actually accepted by the receiver:
curl -s http://127.0.0.1:9091/metrics | grep prometheus_remote_storage_samples_total

# Failures (wrong credentials, bad URL):
curl -s http://127.0.0.1:9091/metrics | grep prometheus_remote_storage_samples_failed_total
```

The installer runs this check for you and warns if samples are failing.

Then query `monerod_up` in your remote Grafana. It should appear within a
minute or two.

### Common push failures

| Symptom in the journal | Cause |
|---|---|
| `401 Unauthorized` | Wrong username/token. For Grafana Cloud the username is the numeric instance ID, not your email |
| `404 Not Found` | Endpoint path wrong — Grafana Cloud ends `/api/prom/push`, plain Prometheus ends `/api/v1/write` |
| `x509: certificate signed by unknown authority` | Self-signed cert on the receiver. Install the CA, or set `PNX_REMOTE_WRITE_INSECURE=true` knowing the risk |
| `context deadline exceeded` | Receiver unreachable — firewall or DNS |
| `out of order sample` | Two devices sending the same `instance` label. Give each a distinct `PNX_INSTANCE_NAME` |

---

## Pull mode

node_exporter binds `0.0.0.0` and your Prometheus scrapes it.

The installer writes a ready-to-paste scrape config to:

```
/var/lib/pinodexmr-monitoring/remote-scrape-config.yml
```

It looks like this:

```yaml
scrape_configs:
  - job_name: 'pinodexmr'
    scrape_interval: 30s
    static_configs:
      - targets: ['192.168.1.50:9100']
        labels:
          role: 'crypto-node'
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'pinodexmr'
```

Merge it into your Prometheus config and reload:

```bash
sudo systemctl reload prometheus     # or: docker kill -s HUP prometheus
```

Check the target is `UP` at `http://your-prometheus:9090/targets`.

### Reaching the device safely

node_exporter has **no authentication**. Anyone who can reach that port can
read your host and node metrics. Do not port-forward it to the internet
unprotected. Instead:

- **Same LAN** — fine as-is, ideally with `PNX_ALLOW_CIDR` set to your subnet
- **WireGuard / Tailscale** — the cleanest option across networks; scrape the
  VPN address
- **SSH tunnel** — from the monitoring host:
  ```bash
  ssh -N -L 9100:127.0.0.1:9100 pinodexmr@your-node
  ```
  then scrape `127.0.0.1:9100`
- **Reverse proxy with TLS + basic auth** in front of node_exporter

PiNodeXMR can install WireGuard for you: *setup → Extra Network Tools →
Install PiVPN*.

---

## Several nodes, one dashboard

1. Install on each device with a **distinct** `PNX_INSTANCE_NAME`.
2. Point them all at the same Prometheus (push), or add a scrape job per device
   (pull).
3. Import the dashboard once.

The `instance` dropdown at the top lists every device, and the dashboard is
built to filter cleanly by it.

For push, the `instance` label is set from `PNX_INSTANCE_NAME` in the agent's
`external_labels`, so nodes never collide even on identical hardware.

## Hybrid: local dashboard *and* remote reporting

Install in `local` mode, then add a `remote_write` block to
`/etc/prometheus/prometheus.yml`:

```yaml
remote_write:
  - url: 'https://prometheus-prod-x.grafana.net/api/prom/push'
    basic_auth:
      username: '123456'
      password: 'your-api-token'
```

```bash
sudo promtool check config /etc/prometheus/prometheus.yml
sudo systemctl reload prometheus
```

You keep the on-device dashboard and get a copy in the cloud. Note that the
installer regenerates `prometheus.yml` on re-run — it backs up the old file
first, so re-apply the block afterwards.
