# Troubleshooting

Start here:

```bash
sudo /path/to/PiNodeXMR_Grafana_Dashboard/install.sh --status
```

or from the PiNodeXMR menu: **7) Grafana Monitoring → 2) Show Monitoring
Status**. It reports every service, whether metrics are being produced, how
stale they are, and whether node_exporter is actually serving them.

The installer also logs everything to
`/var/log/pinodexmr-monitoring-install.log`.

---

## Dashboard shows "No data"

Work the pipeline from the node outwards. The first step that fails is your
problem.

### 1. Is the exporter producing metrics?

```bash
cat /var/lib/node_exporter/textfile_collector/monerod.prom | head -20
```

- **`monerod_up 1`** → good, go to step 2.
- **`monerod_up 0`** → the exporter cannot reach monerod. See
  [monerod_up is 0](#monerod_up-is-0).
- **File missing** → the exporter is not running. See
  [exporter not running](#exporter-service-is-not-running).

### 2. Is node_exporter serving them?

```bash
curl -s http://127.0.0.1:9100/metrics | grep monerod_height
```

Nothing back? node_exporter is not reading the textfile directory:

```bash
systemctl cat node_exporter | grep textfile
# expect: --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

If the flag is missing, re-run the installer. If it points somewhere else, that
directory is what the exporter should write to — check `PNX_TEXTFILE_DIR` in
`/etc/pinodexmr-monitoring/config.env`.

### 3. Is Prometheus scraping?

Open `http://<device>:9090/targets` (local mode) and confirm the `node` job is
**UP**. Or:

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=monerod_up' | jq .
```

`"result":[]` means Prometheus has nothing — check the target's error on the
`/targets` page.

### 4. Is Grafana asking the right Prometheus?

**Connections → Data sources → Prometheus (PiNodeXMR) → Test**. It should say
"Successfully queried the Prometheus API".

### 5. Are the dropdowns set?

The dashboard filters by `instance`. If the dropdown at the top is empty or
shows a stale name, pick your device. The value comes from
`PNX_INSTANCE_NAME`.

If only the **Blockchain Storage** or **System Resources** panels are empty
while everything else works, it is the `Blockchain volume`, `Network interface`
or `Disk device` dropdown — the selected value does not exist on this hardware.
Pick the right one; see
[CONFIGURATION.md](CONFIGURATION.md#dashboard-variables).

---

## `monerod_up` is 0

The exporter is running but cannot reach monerod's RPC.

```bash
# Is monerod running at all?
systemctl status moneroStatus.service
pgrep -a monerod
```

Test the RPC by hand with the same settings the exporter uses:

```bash
# PiNodeXMR (credentials from the variable files)
source /home/pinodexmr/variables/RPCu.sh
source /home/pinodexmr/variables/RPCp.sh
source /home/pinodexmr/variables/monero-port.sh
IP=$(hostname -I | awk '{print $1}')
curl -sf -u "${RPCu}:${RPCp}" --digest -X POST "http://${IP}:${MONERO_PORT}/json_rpc" \
  -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' \
  -H 'Content-Type: application/json' | jq .result.height
```

| Result | Meaning |
|---|---|
| A height | RPC is fine — check the exporter's own logs below |
| `401` | Wrong username/password, or wrong auth type. Check `PNX_RPC_AUTH` |
| Connection refused | monerod is not listening on that address/port |
| Empty / hangs | monerod is still starting, or busy syncing |

**monerod binds the LAN address on PiNodeXMR, not loopback.** If you set
`PNX_RPC_HOST=127.0.0.1` manually on a PiNodeXMR device, it will fail — use the
device IP, or leave `PNX_RPC_FROM_PINODEXMR=true` and let the exporter work it
out.

A freshly restarted monerod returns partial JSON for a while. The exporter
treats that as a failure and retries; it clears on its own.

---

## Exporter service is not running

```bash
systemctl status monerod-exporter
journalctl -u monerod-exporter -n 50 --no-pager
```

| Log line | Fix |
|---|---|
| `jq is required` | `sudo apt install jq` |
| `curl is required` | `sudo apt install curl` |
| `Permission denied` writing the `.prom` file | `sudo chown pinodexmr:pinodexmr /var/lib/node_exporter/textfile_collector` |
| Cannot read `config.env` | `sudo chown root:pinodexmr /etc/pinodexmr-monitoring/config.env && sudo chmod 640 …` |
| Exits every ~30s | Expected while monerod is unreachable: it exits after 3 failures so systemd restarts it cleanly |

---

## Grafana will not start

```bash
systemctl status grafana-server
journalctl -u grafana-server -n 50 --no-pager
```

**Port already in use** — something else holds 3000:

```bash
sudo ss -ltnp | grep :3000
```

Re-run the installer and choose a different port.

**Provisioning errors** — Grafana logs the offending file. Validate the
dashboard JSON:

```bash
jq -e . /var/lib/grafana/dashboards/pinodexmr/pinodexmr-dashboard.json >/dev/null && echo valid
```

**Forgotten admin password:**

```bash
sudo grafana-cli --homepath /usr/share/grafana admin reset-admin-password 'newpassword'
```

---

## Grafana loads but panels error

**"Datasource pinodexmr-prometheus was not found"** — the datasource
provisioning did not load. Check the file exists and restart:

```bash
cat /etc/grafana/provisioning/datasources/pinodexmr.yml
sudo systemctl restart grafana-server
```

If you imported the dashboard by hand instead of letting the installer
provision it, use the portable copy in `dashboards/pinodexmr-dashboard.json` —
it prompts for a datasource. The provisioned copy under `/var/lib/grafana` is
hard-wired to the fixed UID.

---

## Prometheus will not start

```bash
journalctl -u prometheus -n 50 --no-pager
sudo promtool check config /etc/prometheus/prometheus.yml
```

**`opening storage failed: ... no space left`** — the disk is full. Lower
`PNX_PROM_RETENTION_SIZE`, or move `PNX_PROM_DATA_DIR` to your USB disk (see
[CONFIGURATION.md](CONFIGURATION.md#retention-on-an-sd-card)).

**`permission denied` on the data directory:**

```bash
sudo chown -R prometheus:prometheus /var/lib/prometheus
```

---

## Push mode: nothing arrives remotely

```bash
journalctl -u prometheus-agent -n 50 --no-pager
curl -s http://127.0.0.1:9091/metrics | grep prometheus_remote_storage_samples_failed_total
```

See the failure table in
[REMOTE-MONITORING.md](REMOTE-MONITORING.md#common-push-failures) — it covers
401s, wrong endpoint paths, TLS errors and out-of-order samples.

---

## Docker flavour

```bash
cd /opt/pinodexmr-monitoring
docker compose ps
docker compose logs --tail 50
```

**Prometheus cannot reach node_exporter** — the containers reach the host
through `host.docker.internal`, which needs Docker Engine 20.10+. Check:

```bash
docker exec pinodexmr-prometheus wget -qO- http://host.docker.internal:9100/metrics | head -3
```

If that fails, make sure node_exporter is bound somewhere the container can
reach it (not strictly `127.0.0.1` inside a different namespace) and that the
`extra_hosts` entry is present in `docker-compose.yml`.

---

## CPU temperature reads 0

The device exposes no thermal zone the exporter recognises. Check:

```bash
for z in /sys/class/thermal/thermal_zone*; do echo "$z: $(cat $z/type) = $(cat $z/temp)"; done
```

Everything else keeps working; only that one panel is affected. Virtual
machines and some SBCs genuinely have no sensor.

---

## Architecture is unsupported

If node_exporter or Prometheus has no upstream build for your platform, the
installer says so. Fall back to distro packages:

```bash
sudo apt install prometheus-node-exporter prometheus
```

then re-run the installer — it detects the APT node_exporter and configures it
in place.

For Grafana, if the APT repo has no build for your architecture, use the Docker
flavour or run Grafana elsewhere and use agent mode.

---

## Starting over

```bash
sudo ./uninstall.sh     # answer yes to removing the config
sudo ./install.sh
```

Your Monero node is never touched by either.

## Getting help

Open an issue with:

- `sudo ./install.sh --status` output
- the relevant `journalctl -u <service> -n 50` output
- your device model and `uname -m`
- whether you used local or agent mode

Redact credentials before pasting.
