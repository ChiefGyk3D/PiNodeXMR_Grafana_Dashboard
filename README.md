# PiNodeXMR Grafana Dashboard

Grafana monitoring for [PiNodeXMR](https://github.com/shermand100/PiNodeXMR)
Monero full nodes. One command installs everything — exporter, Prometheus,
Grafana and a 28-panel dashboard — either **on the node itself** or as an
**agent reporting to monitoring elsewhere**.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

## Screenshots

![Grafana Dashboard - Overview](media/Grafana-1.png)

![Grafana Dashboard - Details](media/Grafana-2.png)

## Quick start

### On PiNodeXMR

It is a menu option. SSH in (or use the web terminal) and run:

```bash
setup
```

Choose **7) Grafana Monitoring → 1) Install / Reconfigure Monitoring**, answer
a handful of questions, and open the URL it prints. The dashboard is already
there — no import, no datasource picking.

### Anywhere else

```bash
git clone https://github.com/ChiefGyk3D/PiNodeXMR_Grafana_Dashboard.git
cd PiNodeXMR_Grafana_Dashboard
sudo ./install.sh
```

Works on any Debian/Ubuntu host with systemd, against PiNodeXMR or a plain
monerod.

## Four ways to run it

Not every lab looks the same, so Grafana (the dashboard) and Prometheus (the
database) are chosen **independently** — each runs on the device or lives
elsewhere. Metrics collection always runs on the device.

| Topology | On this device | You already have |
|---|---|---|
| **Full** | Grafana + Prometheus | nothing — all-in-one, browse to port 3000 |
| **Backend** | Prometheus only | Grafana elsewhere → add this device as a datasource |
| **Viewer** | Grafana only | a Prometheus-compatible database elsewhere |
| **Agent** | neither | a complete stack elsewhere — this device just reports |

- **Full** — everything installed here, served on a port you choose (default
  `3000`). Native packages or Docker, picked at install time.
- **Backend** — for "I have Grafana in my lab but no database for this node."
  Prometheus runs here; the installer prints (and saves) the exact datasource
  URL and import steps for your existing Grafana.
- **Viewer** — for "I already have Prometheus / VictoriaMetrics / Mimir."
  Grafana runs here, provisioned against your existing database (URL, optional
  basic auth, self-signed TLS supported), while the metrics flow to that
  database by push or pull.
- **Agent** — nothing but collection here. Two transports, usable together:
  - **push** — a Prometheus Agent forwards over `remote_write`. Only outbound
    connections, so it works from behind NAT/CGNAT with **no inbound ports
    opened**. Works with your own Prometheus, Grafana Cloud, Mimir or
    VictoriaMetrics.
  - **pull** — node_exporter is exposed for your Prometheus to scrape. The
    installer writes a ready-to-paste `scrape_config`.

Cross-network setups (a node at home, monitoring in the cloud, several nodes
on one dashboard): [docs/REMOTE-MONITORING.md](docs/REMOTE-MONITORING.md).

## What you get

39 metrics, charted across six dashboard sections:

| Section | Panels |
|---|---|
| ⚡ **Monero Node Status** | Node up, sync status, height, difficulty, version, uptime, total transactions, hard fork version |
| 🌐 **Network & Connections** | P2P connections, peerlist sizes, RPC connections |
| 📦 **Mempool & Transactions** | Mempool count, size in bytes, fees in XMR, fee per byte |
| 🗓️ **Last Block** | Reward in XMR, block size, transactions per block, difficulty |
| 💾 **Blockchain Storage** | Database size, free disk space, blockchain volume usage |
| 🖥️ **System Resources** | SoC temperature, CPU, memory, load, network traffic, disk I/O |

The System Resources section is drawn from standard `node_exporter` host
metrics, which arrive on the same endpoint with the same labels as the
`monerod_*` series — so host and node data share a timeline.

No two devices are wired the same, so the storage and network panels do not
assume a layout: dropdowns at the top of the dashboard list the filesystems,
network interfaces and disks that actually exist on the selected device, and
the panels follow whatever you pick. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#dashboard-variables).

Full list: [docs/METRICS.md](docs/METRICS.md).

## How it works

```
monerod ──JSON-RPC──> monerod-exporter ──.prom file──> node_exporter ──> Prometheus ──> Grafana
```

The exporter polls monerod's RPC and writes Prometheus metrics to a file that
node_exporter serves through its textfile collector. That design is deliberate:

- **Your RPC credentials never reach Grafana.** They stay on the device; Grafana
  only ever sees numbers.
- **No extra port.** Metrics ride the node_exporter endpoint.
- **monerod's RPC uses digest auth**, which most Grafana datasource plugins
  cannot speak — this sidesteps the problem entirely.
- **Two dependencies**: `curl` and `jq`.

### The datasource ("how is the database set?")

**The dashboard reads from Prometheus.** There is no SQL database and no direct
Grafana → monerod connection.

The installer provisions a Prometheus datasource with the fixed UID
`pinodexmr-prometheus` and rewrites the dashboard so every panel references
that exact UID. That pairing is why the dashboard works the moment Grafana
starts, with no manual import step and no UID drift between installs.

Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#the-datasource).

## Configuration

Every setting lives in `/etc/pinodexmr-monitoring/config.env`. Re-run
`sudo ./install.sh --unattended` after editing to apply.

On PiNodeXMR the exporter reads the monerod RPC port and credentials from
PiNodeXMR's own variable files **on every poll** — so if you change your RPC
username or password through the PiNodeXMR menus, monitoring keeps working with
no reconfiguration at all.

Full reference: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Managing it

```bash
sudo ./install.sh              # interactive install or reconfigure
sudo ./install.sh --status     # what is installed, and is it healthy
sudo ./install.sh --unattended # re-apply saved settings, no prompts
sudo ./uninstall.sh            # remove it
```

The same actions are on the PiNodeXMR menu under **7) Grafana Monitoring**.

## Requirements

- Debian/Ubuntu-based OS with systemd (PiNodeXMR qualifies)
- Root access and outbound internet during installation
- `armv7`, `arm64`, `amd64`, `armv6`, `386` or `riscv64`
- ~250 MB free (native) or ~700 MB (Docker)

`jq`, `curl`, node_exporter, Prometheus and Grafana are installed as needed.

> **Note:** PiNodeXMR does **not** ship node_exporter. The installer installs
> it. If your device already has one — from APT or a manual install — it is
> detected and reconfigured in place rather than duplicated.

## Documentation

| Guide | What is in it |
|---|---|
| [INSTALL.md](docs/INSTALL.md) | Every install path and prompt, upgrading |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit, and why |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every setting, multi-node setups, retention on SD cards |
| [REMOTE-MONITORING.md](docs/REMOTE-MONITORING.md) | Agent mode, Grafana Cloud, VPN and tunnel options |
| [SECURITY.md](docs/SECURITY.md) | What is exposed, credential handling, Tor and TLS |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom-first fixes for the whole pipeline |
| [METRICS.md](docs/METRICS.md) | All 39 metrics, plus useful PromQL |
| [UNINSTALL.md](docs/UNINSTALL.md) | Clean removal, and what is deliberately left alone |

## Repository layout

```
install.sh                 interactive installer
uninstall.sh               removal
lib/                       installer modules
exporter/                  the monerod exporter and its unit
templates/                 systemd, Prometheus, Grafana and compose templates
dashboards/                the dashboard JSON (portable import form)
docs/                      documentation
```

## Using the dashboard on its own

If you only want the dashboard and already have Prometheus and node_exporter:

1. Deploy the exporter: copy `exporter/monerod-exporter.sh` to the node,
   configure `/etc/pinodexmr-monitoring/config.env`, and install
   `templates/monerod-exporter.service.tmpl` as a unit — or just run
   `sudo ./install.sh` and choose agent/pull, which does it for you.
2. Scrape the node's node_exporter from your Prometheus.
3. Import `dashboards/pinodexmr-dashboard.json` through the Grafana UI and pick
   your Prometheus datasource when asked.

That JSON is kept in Grafana's portable form precisely so a hand import works.

## Contributing

Contributions welcome — fork, branch, and open a pull request.

Ideas: P2Pool mining metrics, alerting rules, additional SBC temperature
sensors, non-PiNodeXMR monerod packaging.

## Related Projects

| Repository | Description |
|-----------|-------------|
| [siem-docker-stack](https://github.com/ChiefGyk3D/siem-docker-stack) | Dockerized SIEM/SOC stack with hot/warm tiering (OpenSearch, Wazuh, Grafana, Logstash, Prometheus) |
| [pfsense_siem_stack](https://github.com/ChiefGyk3D/pfsense_siem_stack) | pfSense-side SIEM integration (Suricata, Telegraf, pfBlockerNG, 30+ docs) |

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [PiNodeXMR](https://github.com/shermand100/PiNodeXMR) — The Monero node distribution this dashboard is designed for
- [Prometheus node_exporter](https://github.com/prometheus/node_exporter) — The textfile collector approach that makes this possible
- [Monero Project](https://www.getmonero.org/) — The monerod JSON-RPC API

## 💬 Support

- **Issues**: [GitHub Issues](https://github.com/ChiefGyk3D/PiNodeXMR_Grafana_Dashboard/issues)
- **Discussions**: [GitHub Discussions](https://github.com/ChiefGyk3D/PiNodeXMR_Grafana_Dashboard/discussions)

---

## 💝 Donations and Tips

If you find this PiNodeXMR Grafana Dashboard useful, consider supporting development:

### Recurring Support

<div align="center">
  <table>
    <tr>
      <td align="center"><a href="https://patreon.com/chiefgyk3d?utm_medium=unknown&utm_source=join_link&utm_campaign=creatorshare_creator&utm_content=copyLink" title="Patreon"><img src="media/icons/patreon.svg" width="32" height="32" alt="Patreon"/></a></td>
      <td align="center"><a href="https://streamelements.com/chiefgyk3d/tip" title="StreamElements"><img src="media/streamelements.png" width="32" height="32" alt="StreamElements"/></a></td>
    </tr>
    <tr>
      <td align="center">Patreon</td>
      <td align="center">StreamElements</td>
    </tr>
  </table>
</div>

### Cryptocurrency Tips

<div align="center">
  <table style="border:none;">
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="media/icons/bitcoin.svg" width="28" height="28" alt="Bitcoin"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Bitcoin</b><br/>
        <code style="font-size:12px;">bc1qztdzcy2wyavj2tsuandu4p0tcklzttvdnzalla</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="media/icons/monero.svg" width="28" height="28" alt="Monero"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Monero</b><br/>
        <code style="font-size:12px;">84Y34QubRwQYK2HNviezeH9r6aRcPvgWmKtDkN3EwiuVbp6sNLhm9ffRgs6BA9X1n9jY7wEN16ZEpiEngZbecXseUrW8SeQ</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="media/icons/ethereum.svg" width="28" height="28" alt="Ethereum"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Ethereum</b><br/>
        <code style="font-size:12px;">0x554f18cfB684889c3A60219BDBE7b050C39335ED</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/solana.svg" width="28" height="28" alt="Solana"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Solana</b><br/>
        <code style="font-size:12px;">5T8h3HbyvHgLxwXgchRYbHSqRjZyAr8J7uwjLN9Fh8Jh</code>
      </td>
    </tr>
  </table>
</div>

---

<div align="center">

Made with ❤️ by [ChiefGyk3D](https://github.com/ChiefGyk3D)

## Author & Socials

<table>
  <tr>
    <td align="center"><a href="https://social.chiefgyk3d.com/@chiefgyk3d" title="Mastodon"><img src="media/icons/mastodon.svg" width="32" height="32" alt="Mastodon"/></a></td>
    <td align="center"><a href="https://bsky.app/profile/chiefgyk3d.com" title="Bluesky"><img src="media/icons/bluesky.svg" width="32" height="32" alt="Bluesky"/></a></td>
    <td align="center"><a href="http://twitch.tv/chiefgyk3d" title="Twitch"><img src="media/icons/twitch.svg" width="32" height="32" alt="Twitch"/></a></td>
    <td align="center"><a href="https://www.youtube.com/channel/UCvFY4KyqVBuYd7JAl3NRyiQ" title="YouTube"><img src="media/icons/youtube.svg" width="32" height="32" alt="YouTube"/></a></td>
    <td align="center"><a href="https://kick.com/chiefgyk3d" title="Kick"><img src="media/icons/kick.svg" width="32" height="32" alt="Kick"/></a></td>
    <td align="center"><a href="https://www.tiktok.com/@chiefgyk3d" title="TikTok"><img src="media/icons/tiktok.svg" width="32" height="32" alt="TikTok"/></a></td>
    <td align="center"><a href="https://discord.chiefgyk3d.com" title="Discord"><img src="media/icons/discord.svg" width="32" height="32" alt="Discord"/></a></td>
    <td align="center"><a href="https://matrix-invite.chiefgyk3d.com" title="Matrix"><img src="media/icons/matrix.svg" width="32" height="32" alt="Matrix"/></a></td>
  </tr>
  <tr>
    <td align="center">Mastodon</td>
    <td align="center">Bluesky</td>
    <td align="center">Twitch</td>
    <td align="center">YouTube</td>
    <td align="center">Kick</td>
    <td align="center">TikTok</td>
    <td align="center">Discord</td>
    <td align="center">Matrix</td>
  </tr>
</table>

</div>