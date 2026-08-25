# Installation

## The easy way — from the PiNodeXMR menu

If you are running PiNodeXMR, this add-on is available from the settings menu.
No downloads, no SSH gymnastics.

1. SSH into your device (or use the web terminal) and run:

   ```bash
   setup
   ```

2. Choose **7) Grafana Monitoring**
3. Choose **1) Install / Reconfigure Monitoring**

The installer downloads this repository, then walks you through the questions
below. When it finishes it prints the URL to open.

That menu also gives you **Show Monitoring Status**, **Update Monitoring
Add-on** and **Uninstall Monitoring**.

## The manual way — any Debian/Ubuntu host

Works on PiNodeXMR and on a plain monerod machine alike.

```bash
git clone https://github.com/ChiefGyk3D/PiNodeXMR_Grafana_Dashboard.git
cd PiNodeXMR_Grafana_Dashboard
sudo ./install.sh
```

### Command-line options

| Option | Effect |
|---|---|
| *(none)* | Interactive install |
| `--unattended`, `-y` | No prompts; use the saved config, or defaults |
| `--status` | Report what is installed and whether it is healthy |
| `--uninstall` | Run the uninstaller |
| `--help`, `-h` | Usage |

## What you will be asked

### 1. Deployment mode

| Choice | Use it when |
|---|---|
| **local** | You want to open a browser at your PiNodeXMR and see the dashboard. Grafana and Prometheus are installed on the device. |
| **agent** | You already have Grafana somewhere, or you want to watch several nodes from one place. |

### 2. Node name

The label the dashboard's `instance` dropdown shows. Give each device a
distinct name if you monitor more than one (`pinodexmr-loft`, `pinodexmr-shed`).

### 3. monerod RPC

On PiNodeXMR the installer offers to read the RPC port and credentials from
PiNodeXMR's own variable files. **Say yes.** The exporter then re-reads them on
every poll, so if you later change your RPC username or password through the
PiNodeXMR menus, monitoring keeps working with no reconfiguration.

On a non-PiNodeXMR host you are asked for host, port, auth type (digest, basic
or none) and credentials. The installer tests the connection immediately and
shows your blockchain height, so a wrong password surfaces right away.

### 4. Poll interval

Default 30 seconds. Below 15 adds load for little benefit.

### 5a. Local mode questions

- **Native or Docker.** Native is lighter and matches how PiNodeXMR does
  everything else. Docker is more isolated and removes cleanly, at the cost of
  installing Docker and a few hundred MB.
- **Grafana port.** Default `3000`. It does not clash with PiNodeXMR's ports
  (80, 18081, 18083, 18089). The installer checks the port is free.
- **Who can reach Grafana.** `0.0.0.0` for your LAN, or `127.0.0.1` to keep it
  private and reach it over an SSH tunnel.
- **Admin password.** Required, minimum 8 characters. There is no way to end up
  on Grafana's `admin`/`admin` default.
- **Retention.** How long and how large the metrics history may grow — both
  limits apply, whichever is hit first. Defaults `15d` / `2GB`, chosen to be
  gentle on an SD card.
- **Expose Prometheus?** Default no. Grafana talks to it over loopback anyway.

### 5b. Agent mode questions

- **Transport** — `push`, `pull`, or `both`. See
  [REMOTE-MONITORING.md](REMOTE-MONITORING.md).
- **push**: the remote write URL and its authentication (basic, bearer, or
  none).
- **pull**: which port node_exporter should listen on.

### 6. Firewall

If `ufw` is active, the installer offers to open the ports it needs, optionally
restricted to one CIDR such as `192.168.1.0/24`.

## After installation

**Local mode** prints a URL like `http://192.168.1.50:3000`. Log in with
`admin` and your password. The dashboard is already there under the
**PiNodeXMR** folder — no import step.

**Agent mode** writes a ready-to-paste `scrape_config` to
`/var/lib/pinodexmr-monitoring/remote-scrape-config.yml` (pull), and/or starts
forwarding immediately (push). Import `dashboards/pinodexmr-dashboard.json`
into your remote Grafana and pick the Prometheus receiving the metrics.

### Verify

```bash
sudo ./install.sh --status
```

You should see the services active, `monerod_up: 1`, and a recent height.

## Requirements

- Debian or Ubuntu based OS with **systemd** (PiNodeXMR qualifies)
- Root access
- `armv7`, `arm64`, `amd64`, `armv6`, `386` or `riscv64` for node_exporter and
  Prometheus; Grafana's APT repo covers `arm64`, `armhf` and `amd64`
- Outbound internet during installation
- Roughly **250 MB** free for the native stack, or **700 MB** with Docker

`jq` and `curl` are installed automatically if missing.

## Upgrading

From the PiNodeXMR menu: **7) Grafana Monitoring → 3) Update Monitoring
Add-on**. Your settings are preserved.

Manually:

```bash
cd PiNodeXMR_Grafana_Dashboard
git pull
sudo ./install.sh --unattended
```

`--unattended` reuses the saved configuration, so nothing is re-asked.

## Uninstalling

See [UNINSTALL.md](UNINSTALL.md).
