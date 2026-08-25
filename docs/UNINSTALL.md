# Uninstalling

## From the PiNodeXMR menu

```bash
setup
```

**7) Grafana Monitoring → 4) Uninstall Monitoring**

## Manually

```bash
cd PiNodeXMR_Grafana_Dashboard
sudo ./uninstall.sh
```

## What it does

The uninstaller is deliberately careful about things it did not install.

**Always removed** (these are unambiguously ours):

- `monerod-exporter` service, script and generated `.prom` file
- Prometheus Agent, if push mode was configured
- Any `ufw` rules the installer added

**Removed after asking:**

| Component | Default | Why it asks |
|---|---|---|
| node_exporter | remove — *only if this add-on installed it* | You may rely on it for other host monitoring |
| Prometheus | keep | It may serve other dashboards, and removal deletes your metrics history |
| Grafana | keep | Removing it deletes every other dashboard on the device |
| Docker compose project | keep | Holds your generated config and the admin password secret |
| Saved configuration | keep | Handy if you plan to reinstall with the same settings |

**Never touched:**

- monerod, its configuration, and the blockchain
- Any PiNodeXMR setting, including your RPC credentials
- Docker itself, if it was installed

If node_exporter was already on the device before you installed this add-on,
the uninstaller leaves it running and tells you so. To stop it serving monerod
metrics, remove the `--collector.textfile.directory` flag from its unit file.

If you keep Grafana, only the PiNodeXMR provisioning is removed — the
datasource file, the dashboard provider and the dashboard itself — and Grafana
is restarted. Your other dashboards are untouched.

## Verifying

```bash
systemctl status monerod-exporter     # should report "not-found"
ls /var/lib/node_exporter/textfile_collector/    # monerod.prom gone
```

## Removing leftovers by hand

If you answered "keep" to something and change your mind:

```bash
# Prometheus (native)
sudo systemctl disable --now prometheus
sudo rm -f /etc/systemd/system/prometheus.service
sudo rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
sudo rm -rf /etc/prometheus /var/lib/prometheus

# Grafana
sudo systemctl disable --now grafana-server
sudo apt purge -y grafana
sudo rm -rf /var/lib/grafana /etc/grafana
sudo rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg

# node_exporter
sudo systemctl disable --now node_exporter
sudo rm -f /etc/systemd/system/node_exporter.service /usr/local/bin/node_exporter
sudo rm -rf /var/lib/node_exporter
sudo userdel node_exporter

# Docker flavour
cd /opt/pinodexmr-monitoring && sudo docker compose down -v
sudo rm -rf /opt/pinodexmr-monitoring

# Config, state and log
sudo rm -rf /etc/pinodexmr-monitoring /var/lib/pinodexmr-monitoring
sudo rm -f /var/log/pinodexmr-monitoring-install.log

sudo systemctl daemon-reload
```

## Removing the dashboard from a remote Grafana

If you used agent mode, the dashboard lives on your monitoring host. Delete it
there: open it, **Dashboard settings → Delete Dashboard**. Then drop the
PiNodeXMR scrape job (or remote_write receiver config) from that Prometheus and
reload it.
