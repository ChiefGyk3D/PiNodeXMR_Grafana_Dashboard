#!/bin/bash
# lib/config.sh — Configuration model for the PiNodeXMR monitoring add-on.
#
# Every tunable lives in one file (/etc/pinodexmr-monitoring/config.env) that is
# sourced by the installer, the exporter and the uninstaller. Defaults below are
# applied first, then the file overrides them, so a config written by an older
# version keeps working after an upgrade.

[ -n "${PNX_CONFIG_SOURCED:-}" ] && return 0
PNX_CONFIG_SOURCED=1

# --- Defaults ------------------------------------------------------------
pnx_config_defaults() {
    # Which stack components run on THIS device. Independent switches, so all
    # four topologies work:
    #   both true            — all-in-one (Grafana + Prometheus here)
    #   prometheus only      — database here, dashboard in an existing Grafana
    #   grafana only         — dashboard here, database in an existing lab
    #   both false           — pure agent, everything lives elsewhere
    PNX_INSTALL_PROMETHEUS="${PNX_INSTALL_PROMETHEUS:-true}"
    PNX_INSTALL_GRAFANA="${PNX_INSTALL_GRAFANA:-true}"

    # Local component flavour: native | docker
    PNX_LOCAL_STACK="${PNX_LOCAL_STACK:-native}"

    # How metrics leave the device when Prometheus is NOT local: pull | push | both
    PNX_AGENT_TRANSPORT="${PNX_AGENT_TRANSPORT:-pull}"

    # --- monerod RPC ---
    # When true the exporter sources PiNodeXMR's own variable files on every
    # poll, so RPC credential/port changes made through the PiNodeXMR menus are
    # picked up automatically with no reconfiguration here.
    PNX_RPC_FROM_PINODEXMR="${PNX_RPC_FROM_PINODEXMR:-true}"
    PNX_PINODEXMR_VAR_DIR="${PNX_PINODEXMR_VAR_DIR:-/home/pinodexmr/variables}"

    # Used when PNX_RPC_FROM_PINODEXMR=false (generic monerod hosts).
    PNX_RPC_HOST="${PNX_RPC_HOST:-127.0.0.1}"
    PNX_RPC_PORT="${PNX_RPC_PORT:-18081}"
    PNX_RPC_USER="${PNX_RPC_USER:-}"
    PNX_RPC_PASS="${PNX_RPC_PASS:-}"
    # digest | basic | none
    PNX_RPC_AUTH="${PNX_RPC_AUTH:-digest}"

    # --- monerod exporter ---
    PNX_EXPORTER_INTERVAL="${PNX_EXPORTER_INTERVAL:-30}"
    PNX_EXPORTER_USER="${PNX_EXPORTER_USER:-pinodexmr}"
    PNX_TEXTFILE_DIR="${PNX_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    PNX_EXPORTER_PATH="${PNX_EXPORTER_PATH:-/usr/local/bin/monerod-exporter.sh}"

    # --- node_exporter ---
    PNX_NODE_EXPORTER_PORT="${PNX_NODE_EXPORTER_PORT:-9100}"
    # 127.0.0.1 keeps it private; 0.0.0.0 lets a remote Prometheus scrape it.
    PNX_NODE_EXPORTER_BIND="${PNX_NODE_EXPORTER_BIND:-127.0.0.1}"
    PNX_NODE_EXPORTER_VERSION="${PNX_NODE_EXPORTER_VERSION:-1.9.1}"
    # true when this installer installed it (governs uninstall behaviour).
    PNX_NODE_EXPORTER_MANAGED="${PNX_NODE_EXPORTER_MANAGED:-false}"

    # --- Local stack: Prometheus ---
    PNX_PROM_PORT="${PNX_PROM_PORT:-9090}"
    PNX_PROM_BIND="${PNX_PROM_BIND:-127.0.0.1}"
    PNX_PROM_RETENTION="${PNX_PROM_RETENTION:-15d}"
    # Cap on-disk TSDB size — important on SD-card installs.
    PNX_PROM_RETENTION_SIZE="${PNX_PROM_RETENTION_SIZE:-2GB}"
    PNX_PROM_SCRAPE_INTERVAL="${PNX_PROM_SCRAPE_INTERVAL:-30s}"
    PNX_PROM_VERSION="${PNX_PROM_VERSION:-3.6.0}"
    PNX_PROM_DATA_DIR="${PNX_PROM_DATA_DIR:-/var/lib/prometheus}"

    # --- Local stack: Grafana ---
    PNX_GRAFANA_PORT="${PNX_GRAFANA_PORT:-3000}"
    PNX_GRAFANA_BIND="${PNX_GRAFANA_BIND:-0.0.0.0}"
    PNX_GRAFANA_ADMIN_USER="${PNX_GRAFANA_ADMIN_USER:-admin}"
    # Stored only long enough to seed Grafana; blanked after first provisioning.
    PNX_GRAFANA_ADMIN_PASS="${PNX_GRAFANA_ADMIN_PASS:-}"
    PNX_GRAFANA_DOMAIN="${PNX_GRAFANA_DOMAIN:-}"

    # --- Grafana datasource ---
    # Where the local Grafana reads its data from. Empty means "the Prometheus
    # this installer manages" (local native or the compose service). Set a URL
    # to point at an existing Prometheus-compatible database instead —
    # Prometheus, Mimir, VictoriaMetrics, Thanos Query all work.
    PNX_GRAFANA_DS_URL="${PNX_GRAFANA_DS_URL:-}"
    # none | basic
    PNX_GRAFANA_DS_AUTH="${PNX_GRAFANA_DS_AUTH:-none}"
    PNX_GRAFANA_DS_USER="${PNX_GRAFANA_DS_USER:-}"
    PNX_GRAFANA_DS_PASS="${PNX_GRAFANA_DS_PASS:-}"
    # Skip TLS verification for a self-signed database endpoint (discouraged).
    PNX_GRAFANA_DS_INSECURE="${PNX_GRAFANA_DS_INSECURE:-false}"

    # --- Labels ---
    # instance/label applied to this node's metrics; distinguishes devices when
    # several PiNodeXMRs report into one Prometheus.
    PNX_INSTANCE_NAME="${PNX_INSTANCE_NAME:-pinodexmr}"

    # --- Agent push (remote_write) ---
    PNX_REMOTE_WRITE_URL="${PNX_REMOTE_WRITE_URL:-}"
    # none | basic | bearer
    PNX_REMOTE_WRITE_AUTH="${PNX_REMOTE_WRITE_AUTH:-none}"
    PNX_REMOTE_WRITE_USER="${PNX_REMOTE_WRITE_USER:-}"
    PNX_REMOTE_WRITE_PASS="${PNX_REMOTE_WRITE_PASS:-}"
    PNX_REMOTE_WRITE_TOKEN="${PNX_REMOTE_WRITE_TOKEN:-}"
    # Skip TLS verification for self-signed remote endpoints (discouraged).
    PNX_REMOTE_WRITE_INSECURE="${PNX_REMOTE_WRITE_INSECURE:-false}"
    PNX_AGENT_DATA_DIR="${PNX_AGENT_DATA_DIR:-/var/lib/prometheus-agent}"
    PNX_AGENT_PORT="${PNX_AGENT_PORT:-9091}"

    # --- Docker stack ---
    PNX_DOCKER_DIR="${PNX_DOCKER_DIR:-/opt/pinodexmr-monitoring}"
    PNX_DOCKER_GRAFANA_IMAGE="${PNX_DOCKER_GRAFANA_IMAGE:-grafana/grafana:11.6.0}"
    PNX_DOCKER_PROM_IMAGE="${PNX_DOCKER_PROM_IMAGE:-prom/prometheus:v3.6.0}"

    # --- Firewall ---
    # When true, the installer opens the ports it needs via ufw (if present).
    PNX_MANAGE_FIREWALL="${PNX_MANAGE_FIREWALL:-false}"
    # Optional CIDR that remote scrapes are restricted to, e.g. 192.168.1.0/24
    PNX_ALLOW_CIDR="${PNX_ALLOW_CIDR:-}"
}

# --- Load ----------------------------------------------------------------
pnx_config_load() {
    if [ -f "${PNX_CONF_FILE}" ]; then
        # shellcheck disable=SC1090
        set -a; . "${PNX_CONF_FILE}"; set +a
    fi
    # Migrate configs written before the component switches existed, where
    # PNX_MODE=local|agent was the whole story.
    if [ -z "${PNX_INSTALL_PROMETHEUS:-}" ] && [ -n "${PNX_MODE:-}" ]; then
        case "${PNX_MODE}" in
            local) PNX_INSTALL_PROMETHEUS="true";  PNX_INSTALL_GRAFANA="true"  ;;
            agent) PNX_INSTALL_PROMETHEUS="false"; PNX_INSTALL_GRAFANA="false" ;;
        esac
    fi
    pnx_config_defaults
}

# Human-readable name for the current component combination.
pnx_mode_name() {
    if [ "${PNX_INSTALL_PROMETHEUS}" = "true" ]; then
        if [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
            printf 'full (Grafana + Prometheus on this device)'
        else
            printf 'backend (Prometheus here, Grafana elsewhere)'
        fi
    else
        if [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
            printf 'viewer (Grafana here, database elsewhere)'
        else
            printf 'agent (metrics only, everything elsewhere)'
        fi
    fi
}

# --- Save ----------------------------------------------------------------
# Emit one NAME='value' line, single-quote-escaped so any credential — quotes,
# dollars, backslashes, spaces — survives a round-trip through `source`.
pnx_conf_line() {
    local name="$1" value="${!1}"
    value="${value//\'/\'\\\'\'}"
    printf "%s='%s'\n" "${name}" "${value}"
}

# Written 0640 root:<exporter group> because it can hold RPC and remote-write
# credentials, and the unprivileged exporter must be able to read it.
pnx_config_save() {
    mkdir -p "${PNX_CONF_DIR}"
    chmod 0750 "${PNX_CONF_DIR}"
    local tmp
    tmp="$(mktemp)"
    {
        printf '# PiNodeXMR monitoring configuration\n'
        printf '# Generated by install.sh on %s\n' "$(date -Iseconds)"
        printf '#\n# Edit and re-run install.sh (or restart monerod-exporter) to apply.\n'
        printf '# This file may contain credentials — keep it non-world-readable.\n\n'

        printf '# --- Deployment ---\n'
        printf '# Which components run on this device (see docs/CONFIGURATION.md#deployment).\n'
        pnx_conf_line PNX_INSTALL_PROMETHEUS
        pnx_conf_line PNX_INSTALL_GRAFANA
        pnx_conf_line PNX_LOCAL_STACK
        pnx_conf_line PNX_AGENT_TRANSPORT
        pnx_conf_line PNX_INSTANCE_NAME

        printf '\n# --- monerod RPC ---\n'
        pnx_conf_line PNX_RPC_FROM_PINODEXMR
        pnx_conf_line PNX_PINODEXMR_VAR_DIR
        pnx_conf_line PNX_RPC_HOST
        pnx_conf_line PNX_RPC_PORT
        pnx_conf_line PNX_RPC_USER
        pnx_conf_line PNX_RPC_PASS
        pnx_conf_line PNX_RPC_AUTH

        printf '\n# --- monerod exporter ---\n'
        pnx_conf_line PNX_EXPORTER_INTERVAL
        pnx_conf_line PNX_EXPORTER_USER
        pnx_conf_line PNX_EXPORTER_PATH
        pnx_conf_line PNX_TEXTFILE_DIR

        printf '\n# --- node_exporter ---\n'
        pnx_conf_line PNX_NODE_EXPORTER_PORT
        pnx_conf_line PNX_NODE_EXPORTER_BIND
        pnx_conf_line PNX_NODE_EXPORTER_VERSION
        pnx_conf_line PNX_NODE_EXPORTER_MANAGED

        printf '\n# --- Prometheus (when installed on this device) ---\n'
        pnx_conf_line PNX_PROM_PORT
        pnx_conf_line PNX_PROM_BIND
        pnx_conf_line PNX_PROM_RETENTION
        pnx_conf_line PNX_PROM_RETENTION_SIZE
        pnx_conf_line PNX_PROM_SCRAPE_INTERVAL
        pnx_conf_line PNX_PROM_VERSION
        pnx_conf_line PNX_PROM_DATA_DIR

        printf '\n# --- Grafana (when installed on this device) ---\n'
        pnx_conf_line PNX_GRAFANA_PORT
        pnx_conf_line PNX_GRAFANA_BIND
        pnx_conf_line PNX_GRAFANA_ADMIN_USER
        pnx_conf_line PNX_GRAFANA_ADMIN_PASS
        pnx_conf_line PNX_GRAFANA_DOMAIN

        printf '\n# --- Grafana datasource (empty URL = the locally managed Prometheus) ---\n'
        pnx_conf_line PNX_GRAFANA_DS_URL
        pnx_conf_line PNX_GRAFANA_DS_AUTH
        pnx_conf_line PNX_GRAFANA_DS_USER
        pnx_conf_line PNX_GRAFANA_DS_PASS
        pnx_conf_line PNX_GRAFANA_DS_INSECURE

        printf '\n# --- Agent push (remote_write) ---\n'
        pnx_conf_line PNX_REMOTE_WRITE_URL
        pnx_conf_line PNX_REMOTE_WRITE_AUTH
        pnx_conf_line PNX_REMOTE_WRITE_USER
        pnx_conf_line PNX_REMOTE_WRITE_PASS
        pnx_conf_line PNX_REMOTE_WRITE_TOKEN
        pnx_conf_line PNX_REMOTE_WRITE_INSECURE
        pnx_conf_line PNX_AGENT_DATA_DIR
        pnx_conf_line PNX_AGENT_PORT

        printf '\n# --- Docker stack ---\n'
        pnx_conf_line PNX_DOCKER_DIR
        pnx_conf_line PNX_DOCKER_GRAFANA_IMAGE
        pnx_conf_line PNX_DOCKER_PROM_IMAGE

        printf '\n# --- Firewall ---\n'
        pnx_conf_line PNX_MANAGE_FIREWALL
        pnx_conf_line PNX_ALLOW_CIDR
    } > "${tmp}"

    # The exporter runs as PNX_EXPORTER_USER and must be able to read this
    # file, so it is group-readable by that user's primary group rather than
    # root-only. It stays unreadable to everyone else.
    local grp="root"
    if id -u "${PNX_EXPORTER_USER}" >/dev/null 2>&1; then
        grp="$(id -gn "${PNX_EXPORTER_USER}" 2>/dev/null || echo root)"
    fi
    install -m 0640 -o root -g "${grp}" "${tmp}" "${PNX_CONF_FILE}"
    chgrp "${grp}" "${PNX_CONF_DIR}" 2>/dev/null || true
    chmod 0750 "${PNX_CONF_DIR}"
    rm -f "${tmp}"
    pnx_info "Configuration written to ${PNX_CONF_FILE} (root:${grp} 0640)"
}

# --- Summary for confirmation screens ------------------------------------
pnx_config_summary() {
    local s=""
    s+="Setup:           $(pnx_mode_name)\n"
    if [ "${PNX_INSTALL_PROMETHEUS}" = "true" ] || [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
        s+="Flavour:         ${PNX_LOCAL_STACK}\n"
    fi
    if [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
        s+="Grafana:         http://${PNX_GRAFANA_BIND}:${PNX_GRAFANA_PORT}\n"
        if [ -n "${PNX_GRAFANA_DS_URL}" ]; then
            s+="Datasource:      ${PNX_GRAFANA_DS_URL} (auth: ${PNX_GRAFANA_DS_AUTH})\n"
        else
            s+="Datasource:      local Prometheus\n"
        fi
    fi
    if [ "${PNX_INSTALL_PROMETHEUS}" = "true" ]; then
        s+="Prometheus:      ${PNX_PROM_BIND}:${PNX_PROM_PORT} (retain ${PNX_PROM_RETENTION}/${PNX_PROM_RETENTION_SIZE})\n"
    else
        s+="Transport:       ${PNX_AGENT_TRANSPORT}\n"
        case "${PNX_AGENT_TRANSPORT}" in
            pull|both) s+="Scrape endpoint: ${PNX_NODE_EXPORTER_BIND}:${PNX_NODE_EXPORTER_PORT}\n" ;;
        esac
        case "${PNX_AGENT_TRANSPORT}" in
            push|both) s+="Remote write:    ${PNX_REMOTE_WRITE_URL} (auth: ${PNX_REMOTE_WRITE_AUTH})\n" ;;
        esac
    fi
    s+="Instance label:  ${PNX_INSTANCE_NAME}\n"
    s+="Poll interval:   ${PNX_EXPORTER_INTERVAL}s\n"
    if [ "${PNX_RPC_FROM_PINODEXMR}" = "true" ]; then
        s+="monerod RPC:     auto (PiNodeXMR variable files)\n"
    else
        s+="monerod RPC:     ${PNX_RPC_HOST}:${PNX_RPC_PORT} (auth: ${PNX_RPC_AUTH})\n"
    fi
    printf '%s' "${s}"
}
