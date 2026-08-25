# Configuration reference

Every setting lives in one file:

```
/etc/pinodexmr-monitoring/config.env
```

It is written `0640 root:<exporter group>` because it can hold RPC and
remote-write credentials. Edit it directly and re-run the installer to apply:

```bash
sudo nano /etc/pinodexmr-monitoring/config.env
sudo /path/to/PiNodeXMR_Grafana_Dashboard/install.sh --unattended
```

Changes to exporter-only settings take effect within one poll interval with no
restart at all, because the exporter re-reads this file every cycle.

## Deployment

| Variable | Default | Meaning |
|---|---|---|
| `PNX_MODE` | `local` | `local` (stack on this device) or `agent` (report elsewhere) |
| `PNX_LOCAL_STACK` | `native` | `native` or `docker`. Local mode only |
| `PNX_AGENT_TRANSPORT` | `pull` | `pull`, `push` or `both`. Agent mode only |
| `PNX_INSTANCE_NAME` | `pinodexmr` | Label for this node; what the dashboard's `instance` dropdown shows |

## monerod RPC

| Variable | Default | Meaning |
|---|---|---|
| `PNX_RPC_FROM_PINODEXMR` | `true` | Read port and credentials from PiNodeXMR's variable files on every poll |
| `PNX_PINODEXMR_VAR_DIR` | `/home/pinodexmr/variables` | Where those files live |
| `PNX_RPC_HOST` | `127.0.0.1` | Used when `PNX_RPC_FROM_PINODEXMR=false` |
| `PNX_RPC_PORT` | `18081` | ” |
| `PNX_RPC_USER` | *(empty)* | ” |
| `PNX_RPC_PASS` | *(empty)* | ” |
| `PNX_RPC_AUTH` | `digest` | `digest`, `basic` or `none` |

### Changing your RPC credentials

**If `PNX_RPC_FROM_PINODEXMR=true`, do nothing.** Change them through the
PiNodeXMR menu (*System Settings → Monero RPC Username and Password setup*) and
the exporter picks the new values up on its next poll. No restart, no edit here.

If you set credentials manually, update `PNX_RPC_USER` / `PNX_RPC_PASS` here and
the next poll uses them.

## Exporter

| Variable | Default | Meaning |
|---|---|---|
| `PNX_EXPORTER_INTERVAL` | `30` | Seconds between polls. Minimum sensible value ~15 |
| `PNX_EXPORTER_USER` | `pinodexmr` | Unprivileged user the exporter runs as |
| `PNX_EXPORTER_PATH` | `/usr/local/bin/monerod-exporter.sh` | Installed script |
| `PNX_TEXTFILE_DIR` | `/var/lib/node_exporter/textfile_collector` | Where the `.prom` file is written |

> If node_exporter was already serving a *different* textfile directory before
> you installed this, the installer adopts that directory rather than breaking
> whatever else writes there, and records it here.

## node_exporter

| Variable | Default | Meaning |
|---|---|---|
| `PNX_NODE_EXPORTER_PORT` | `9100` | Listen port |
| `PNX_NODE_EXPORTER_BIND` | `127.0.0.1` | `127.0.0.1` private, `0.0.0.0` scrapable from the network |
| `PNX_NODE_EXPORTER_VERSION` | `1.9.1` | Version installed when we install it |
| `PNX_NODE_EXPORTER_MANAGED` | `false` | `true` if this installer installed it — governs whether uninstall may remove it |

## Prometheus (local mode)

| Variable | Default | Meaning |
|---|---|---|
| `PNX_PROM_PORT` | `9090` | Listen port |
| `PNX_PROM_BIND` | `127.0.0.1` | Grafana reaches it on loopback; exposing it is optional |
| `PNX_PROM_RETENTION` | `15d` | How long history is kept |
| `PNX_PROM_RETENTION_SIZE` | `2GB` | Maximum on-disk size. Whichever limit hits first wins |
| `PNX_PROM_SCRAPE_INTERVAL` | `30s` | Scrape frequency |
| `PNX_PROM_VERSION` | `3.6.0` | Version installed |
| `PNX_PROM_DATA_DIR` | `/var/lib/prometheus` | TSDB location |

### Retention on an SD card

Prometheus writes continuously. On an SD card, keep `PNX_PROM_RETENTION_SIZE`
modest (the `2GB` default is deliberate) or move `PNX_PROM_DATA_DIR` onto the
USB disk you already use for the blockchain:

```bash
PNX_PROM_DATA_DIR="/media/usb/prometheus"
```

Then re-run the installer.

## Grafana (local mode)

| Variable | Default | Meaning |
|---|---|---|
| `PNX_GRAFANA_PORT` | `3000` | Listen port |
| `PNX_GRAFANA_BIND` | `0.0.0.0` | `0.0.0.0` LAN-reachable, `127.0.0.1` local only |
| `PNX_GRAFANA_ADMIN_USER` | `admin` | Admin username |
| `PNX_GRAFANA_ADMIN_PASS` | *(blank after install)* | Applied to Grafana's database, then cleared from this file |
| `PNX_GRAFANA_DOMAIN` | *(empty)* | Set if you front Grafana with a hostname or reverse proxy |

Grafana settings are applied through `/etc/default/grafana-server` rather than
by rewriting `grafana.ini`, so your own `grafana.ini` edits survive upgrades.

To change the admin password later:

```bash
sudo grafana-cli --homepath /usr/share/grafana admin reset-admin-password 'newpassword'
```

## Agent push (remote_write)

| Variable | Default | Meaning |
|---|---|---|
| `PNX_REMOTE_WRITE_URL` | *(empty)* | Receiver endpoint |
| `PNX_REMOTE_WRITE_AUTH` | `none` | `none`, `basic` or `bearer` |
| `PNX_REMOTE_WRITE_USER` | *(empty)* | Basic auth username (Grafana Cloud: numeric instance ID) |
| `PNX_REMOTE_WRITE_PASS` | *(empty)* | Basic auth password or API token |
| `PNX_REMOTE_WRITE_TOKEN` | *(empty)* | Bearer token |
| `PNX_REMOTE_WRITE_INSECURE` | `false` | Skip TLS verification. Only for self-signed endpoints — it exposes credentials to interception |
| `PNX_AGENT_DATA_DIR` | `/var/lib/prometheus-agent` | Agent WAL buffer |
| `PNX_AGENT_PORT` | `9091` | Agent's own metrics, loopback only |

## Docker flavour

| Variable | Default | Meaning |
|---|---|---|
| `PNX_DOCKER_DIR` | `/opt/pinodexmr-monitoring` | Compose project directory |
| `PNX_DOCKER_GRAFANA_IMAGE` | `grafana/grafana:11.6.0` | Pin a different tag if you want |
| `PNX_DOCKER_PROM_IMAGE` | `prom/prometheus:v3.6.0` | ” |

## Firewall

| Variable | Default | Meaning |
|---|---|---|
| `PNX_MANAGE_FIREWALL` | `false` | Let the installer add `ufw` rules |
| `PNX_ALLOW_CIDR` | *(empty)* | Restrict those rules to one network, e.g. `192.168.1.0/24` |

## The datasource

The installer provisions a Prometheus datasource with the fixed UID
**`pinodexmr-prometheus`**, and rewrites the dashboard so every panel query
references that UID. This is why the dashboard works immediately with no
"choose your datasource" step.

The generated file:

```
/etc/grafana/provisioning/datasources/pinodexmr.yml
```

### Pointing the dashboard at a different Prometheus

Edit the `url:` in that file and restart Grafana:

```bash
sudo nano /etc/grafana/provisioning/datasources/pinodexmr.yml
sudo systemctl restart grafana-server
```

### Using the dashboard with your own existing datasource

The copy in `dashboards/pinodexmr-dashboard.json` is the **portable** form — it
asks which datasource to use when imported through the Grafana UI. Use that one
for a hand import; the installer converts it to the fixed-UID form only for
automatic provisioning.

## Dashboard variables

The dashboard has four dropdowns at the top. Three of them exist so the host
panels work on any hardware layout, not just a stock PiNodeXMR — they are
populated by querying Prometheus for what actually exists on your device.

| Variable | Label | What it selects |
|---|---|---|
| `$instance` | Instance | Which device to show. Lists every node reporting `monerod_up` |
| `$blockchain_mount` | Blockchain volume | Filesystem holding the blockchain. `/mnt/xmrblockchain` on a stock USB install, `/` when it is on the root volume |
| `$net_device` | Network interface | Interface for the traffic panel — `eth0`, `wlan0`, `enp3s0`, `enP8p1s0` … |
| `$disk_device` | Disk device | Block device for the I/O panel — `sda`, `nvme0n1`, `mmcblk0` … |

Pseudo-filesystems, loopback, container interfaces and partitions are filtered
out, so the dropdowns list only real candidates.

If the **Blockchain Storage** or **System Resources** panels show "No data",
the selected value simply does not exist on that device — open the dropdown and
pick the right one. Grafana remembers the choice per user.

To make a choice the permanent default, open the dashboard with the values you
want selected, then **Dashboard settings → Save dashboard → Save current
variable values as dashboard default**.

## Monitoring several nodes on one dashboard

Give each device a distinct `PNX_INSTANCE_NAME`, point them all at the same
Prometheus, and the dashboard's `instance` dropdown lists all of them. To add a
second device to a local-mode Prometheus, add a job to
`/etc/prometheus/prometheus.yml` — the generated file has a commented example
at the bottom — then:

```bash
sudo systemctl reload prometheus
```
