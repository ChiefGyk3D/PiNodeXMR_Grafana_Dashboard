# Security notes

Monitoring a Monero node means handling RPC credentials and exposing a web
interface. This page covers what is exposed, and how to keep it small.

## What the add-on exposes

| Service | Default bind | Authentication | Notes |
|---|---|---|---|
| Grafana | `0.0.0.0:3000` | password (you set it) | The only thing exposed by default in local mode |
| Prometheus | `127.0.0.1:9090` | none | Loopback unless you opt in |
| node_exporter | `127.0.0.1:9100` | none | `0.0.0.0` only in agent/pull mode |
| Prometheus Agent | `127.0.0.1:9091` | none | Its own metrics; never needs exposing |

The defaults are deliberately narrow: in local mode nothing but Grafana is
reachable from the network.

## Credentials

**monerod RPC credentials never reach Grafana.** The exporter reads them
locally and Grafana only ever sees numbers. This is the main reason for the
textfile-collector design — see
[ARCHITECTURE.md](ARCHITECTURE.md#why-the-textfile-collector).

Credentials live in `/etc/pinodexmr-monitoring/config.env`, mode `0640`, owned
`root:<exporter group>`. It is readable by the exporter's user and nobody else.

On PiNodeXMR, prefer `PNX_RPC_FROM_PINODEXMR=true`: the credentials are then
read from PiNodeXMR's own variable files at poll time and are never duplicated
into a second file.

**The Grafana admin password is not stored on disk by the add-on.** It is
applied to Grafana's own database during installation and then cleared from the
config file.

## node_exporter has no authentication

Anyone who can reach node_exporter's port can read your host metrics and every
`monerod_*` metric. That is not catastrophic — no keys or addresses are exposed
— but it does reveal uptime, disk size, peer counts and sync state.

**Never port-forward node_exporter to the internet.** In agent/pull mode, put
it behind one of:

- a VPN (WireGuard via PiNodeXMR's PiVPN option, or Tailscale)
- an SSH tunnel
- a reverse proxy with TLS and basic auth
- at minimum, `PNX_ALLOW_CIDR` restricting it to your LAN

Push mode avoids the problem entirely: node_exporter stays on loopback and
nothing inbound is opened.

## Grafana exposure

- The installer **requires** an admin password of at least 8 characters, so no
  device is left on Grafana's `admin`/`admin` default.
- Sign-up is disabled (`GF_USERS_ALLOW_SIGN_UP=false`).
- Anonymous access is off.
- Analytics and update checks are disabled — a monitoring box for a privacy
  coin should not phone home.

For anything beyond a trusted LAN, bind Grafana to `127.0.0.1` and reach it
over a tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 pinodexmr@your-node
```

Then browse `http://127.0.0.1:3000`.

### Grafana behind TLS

Grafana can terminate TLS itself:

```ini
# /etc/grafana/grafana.ini
[server]
protocol = https
cert_file = /etc/grafana/grafana.crt
cert_key = /etc/grafana/grafana.key
```

PiNodeXMR can generate a self-signed certificate for you: *setup → Node Tools →
Generate SSL self-signed certificates*.

## Tor

PiNodeXMR already runs Tor for many users. To reach Grafana as a hidden service
instead of exposing a LAN port, bind Grafana to localhost
(`PNX_GRAFANA_BIND=127.0.0.1`) and add to `/etc/tor/torrc`:

```
HiddenServiceDir /var/lib/tor/grafana/
HiddenServicePort 80 127.0.0.1:3000
```

```bash
sudo systemctl restart tor
sudo cat /var/lib/tor/grafana/hostname
```

You get an onion address, authenticated by Grafana's own login, with no inbound
port on your router.

## remote_write over the internet

When pushing metrics off-device:

- **Always use `https://`.** Basic auth over plain HTTP sends your token in
  clear text.
- Leave `PNX_REMOTE_WRITE_INSECURE=false` unless you genuinely have a
  self-signed receiver — skipping verification exposes the credentials to
  anyone able to intercept the connection.
- Prefer a scoped API token over a reusable account password. Grafana Cloud
  tokens can be revoked individually.

## Service hardening

Both the exporter and node_exporter run unprivileged with systemd hardening:

```
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
```

The exporter's only writable path is the textfile collector directory.

## What is not touched

The add-on does not modify monerod, its configuration, the blockchain, your
wallet, or any existing PiNodeXMR setting. Uninstalling leaves the node exactly
as it was.

## Privacy

The dashboard shows node-level statistics only — height, peers, mempool size,
difficulty, disk, temperature. It does not, and cannot, show transactions,
addresses, balances or anything that identifies wallet activity. Everything
comes from `get_info` and related public RPC calls.

If Grafana is reachable by others, be aware they can infer when your node is
online and how it is doing. That is usually harmless, but it is not nothing —
treat the dashboard as node-operational data, not as public information.
