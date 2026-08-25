#!/bin/bash
# uninstall.sh — remove the PiNodeXMR monitoring add-on.
#
# Removes what the installer added, and is deliberately conservative about
# anything it did not add: a node_exporter that was already on the device
# before installation is left running, and Grafana/Prometheus removal is opt-in
# because other dashboards may depend on them.

set -uo pipefail

PNX_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PNX_SRC_DIR

. "${PNX_SRC_DIR}/lib/common.sh"
. "${PNX_SRC_DIR}/lib/config.sh"
. "${PNX_SRC_DIR}/lib/stack-docker.sh"

PNX_TITLE="PiNodeXMR Monitoring — Uninstall"

pnx_stop_disable() {
    local unit="$1"
    pnx_service_exists "${unit}" || return 0
    pnx_info "Stopping and disabling ${unit}"
    systemctl stop "${unit}" >/dev/null 2>&1 || true
    systemctl disable "${unit}" >/dev/null 2>&1 || true
}

main() {
    pnx_require_root
    pnx_config_load

    pnx_yesno "${PNX_TITLE}" \
        "This will remove the monerod exporter and the monitoring services this add-on installed.\n\nYour Monero node, blockchain data and PiNodeXMR itself are not touched.\n\nContinue?" 0 || {
        pnx_info "Uninstall cancelled"
        exit 0
    }

    # --- monerod exporter (always ours) ---
    pnx_stop_disable monerod-exporter.service
    rm -f /etc/systemd/system/monerod-exporter.service
    rm -f "${PNX_EXPORTER_PATH}"
    rm -f "${PNX_TEXTFILE_DIR}/monerod.prom"
    pnx_info "Removed the monerod exporter"

    # --- Prometheus Agent (only exists if we set up push mode) ---
    if pnx_service_exists prometheus-agent.service; then
        pnx_stop_disable prometheus-agent.service
        rm -f /etc/systemd/system/prometheus-agent.service
        rm -f /etc/prometheus/prometheus-agent.yml
        rm -rf "${PNX_AGENT_DATA_DIR}"
        pnx_info "Removed the Prometheus Agent"
    fi

    # --- Docker stack ---
    if [ "${PNX_MODE}" = "local" ] && [ "${PNX_LOCAL_STACK}" = "docker" ]; then
        pnx_stack_docker_remove
        if pnx_yesno "${PNX_TITLE}" "Also delete the compose project directory at ${PNX_DOCKER_DIR}?\n\nThis removes the generated configuration and the Grafana admin password secret." 0; then
            rm -rf "${PNX_DOCKER_DIR}"
            pnx_info "Removed ${PNX_DOCKER_DIR}"
        fi
    fi

    # --- node_exporter: only if this installer put it there ---
    if [ "${PNX_NODE_EXPORTER_MANAGED}" = "true" ]; then
        if pnx_yesno "${PNX_TITLE}" \
            "node_exporter was installed by this add-on.\n\nRemove it too?\n\nSay No if you use it for other host monitoring." 1; then
            pnx_stop_disable node_exporter.service
            rm -f /etc/systemd/system/node_exporter.service
            rm -f /usr/local/bin/node_exporter
            pnx_info "Removed node_exporter"
        fi
    else
        pnx_info "Leaving node_exporter in place (it predates this add-on)"
        pnx_msgbox "${PNX_TITLE}" \
            "node_exporter was already installed before this add-on and has been left running.\n\nIf you want to stop it serving monerod metrics, remove the\n--collector.textfile.directory flag from its unit file."
    fi

    # --- Native Prometheus / Grafana: opt-in, they may serve other things ---
    if pnx_service_exists prometheus.service; then
        if pnx_yesno "${PNX_TITLE}" "Remove Prometheus (service, binaries and stored metrics history)?" 0; then
            pnx_stop_disable prometheus.service
            rm -f /etc/systemd/system/prometheus.service
            rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
            rm -f /etc/prometheus/prometheus.yml
            rm -rf "${PNX_PROM_DATA_DIR}"
            pnx_info "Removed Prometheus"
        fi
    fi

    if dpkg -s grafana >/dev/null 2>&1; then
        if pnx_yesno "${PNX_TITLE}" "Remove Grafana as well?\n\nThis uninstalls the Grafana package and deletes any other dashboards stored on this device." 0; then
            pnx_stop_disable grafana-server.service
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq grafana >/dev/null 2>&1 || pnx_warn "Grafana package removal reported errors"
            rm -rf /var/lib/grafana/dashboards/pinodexmr
            pnx_info "Removed Grafana"
        else
            # Keep Grafana but drop only what we provisioned.
            rm -f /etc/grafana/provisioning/datasources/pinodexmr.yml
            rm -f /etc/grafana/provisioning/dashboards/pinodexmr.yml
            rm -rf /var/lib/grafana/dashboards/pinodexmr
            systemctl restart grafana-server >/dev/null 2>&1 || true
            pnx_info "Left Grafana installed; removed only the PiNodeXMR provisioning"
        fi
    fi

    # --- Firewall rules we may have added ---
    if [ "${PNX_MANAGE_FIREWALL}" = "true" ]; then
        pnx_firewall_delete "${PNX_GRAFANA_PORT}"
        pnx_firewall_delete "${PNX_PROM_PORT}"
        pnx_firewall_delete "${PNX_NODE_EXPORTER_PORT}"
        pnx_info "Removed the firewall rules added by this add-on"
    fi

    systemctl daemon-reload

    if pnx_yesno "${PNX_TITLE}" "Delete the saved configuration at ${PNX_CONF_FILE}?\n\nKeep it if you plan to reinstall with the same settings." 0; then
        rm -rf "${PNX_CONF_DIR}" "${PNX_STATE_DIR}"
        pnx_info "Removed the saved configuration"
    fi

    pnx_msgbox "${PNX_TITLE}" "Uninstall complete.\n\nYour Monero node and PiNodeXMR installation were not modified."
    printf '\nUninstall complete.\n'
}

main "$@"
