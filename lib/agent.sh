#!/bin/bash
# lib/agent.sh — report metrics to a Grafana/Prometheus stack living elsewhere.
#
# Two transports, which can be combined:
#
#   pull — node_exporter listens on the LAN and a remote Prometheus scrapes it.
#          Simplest, but the remote side must be able to open a connection to
#          this device (port forward, VPN, or same LAN).
#
#   push — a local Prometheus in Agent mode scrapes node_exporter on loopback
#          and forwards samples over remote_write. Only outbound connections
#          are made, so it works from behind NAT/CGNAT and needs no inbound
#          firewall rules. This is the option for "monitoring on another
#          network".

[ -n "${PNX_AGENT_SOURCED:-}" ] && return 0
PNX_AGENT_SOURCED=1

PNX_AGENT_UNIT="prometheus-agent.service"

# --- Pull transport ------------------------------------------------------
pnx_agent_setup_pull() {
    # node_exporter must be reachable off-box. The install flow already set
    # PNX_NODE_EXPORTER_BIND, but guard against a stale loopback binding.
    if [ "${PNX_NODE_EXPORTER_BIND}" = "127.0.0.1" ]; then
        pnx_warn "Pull transport selected but node_exporter is bound to 127.0.0.1."
        pnx_warn "A remote Prometheus will not be able to reach it."
    fi
    pnx_firewall_allow "${PNX_NODE_EXPORTER_PORT}" "pinodexmr-node-exporter"

    pnx_info "Pull transport ready on ${PNX_NODE_EXPORTER_BIND}:${PNX_NODE_EXPORTER_PORT}"
    return 0
}

# The scrape_config snippet the user must paste into their remote Prometheus.
pnx_agent_pull_snippet() {
    local ip
    ip="$(pnx_primary_ip)"
    cat <<EOF
scrape_configs:
  - job_name: '${PNX_INSTANCE_NAME}'
    scrape_interval: ${PNX_PROM_SCRAPE_INTERVAL}
    static_configs:
      - targets: ['${ip}:${PNX_NODE_EXPORTER_PORT}']
        labels:
          role: 'crypto-node'
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: '${PNX_INSTANCE_NAME}'
EOF
}

# --- Push transport ------------------------------------------------------
# Build the YAML block carrying remote_write credentials, indented to sit
# under the remote_write list item.
#
# Built with real newlines rather than \n escapes: credentials are user data
# and must never be run through a backslash-interpreting printf, or a password
# containing something like \t would be silently corrupted into a tab.
pnx_agent_auth_block() {
    local block=""
    case "${PNX_REMOTE_WRITE_AUTH}" in
        basic)
            block="$(cat <<EOF
    basic_auth:
      username: $(pnx_yaml_squote "${PNX_REMOTE_WRITE_USER}")
      password: $(pnx_yaml_squote "${PNX_REMOTE_WRITE_PASS}")
EOF
)"
            ;;
        bearer)
            block="$(cat <<EOF
    authorization:
      type: Bearer
      credentials: $(pnx_yaml_squote "${PNX_REMOTE_WRITE_TOKEN}")
EOF
)"
            ;;
        *)
            block="    # No authentication configured for this endpoint."
            ;;
    esac

    if [ "${PNX_REMOTE_WRITE_INSECURE}" = "true" ]; then
        block="${block}
    tls_config:
      insecure_skip_verify: true"
    fi

    printf '%s' "${block}"
}

pnx_agent_setup_push() {
    if ! pnx_is_url "${PNX_REMOTE_WRITE_URL}"; then
        pnx_error "Invalid remote_write URL: '${PNX_REMOTE_WRITE_URL}'"
        return 1
    fi

    pnx_ensure_user prometheus
    # Agent mode is the same binary with --agent, so reuse the native installer.
    pnx_prometheus_install_binary || return 1

    mkdir -p /etc/prometheus "${PNX_AGENT_DATA_DIR}"
    chown -R prometheus:prometheus "${PNX_AGENT_DATA_DIR}"
    chmod 0750 "${PNX_AGENT_DATA_DIR}"

    local auth_block
    auth_block="$(pnx_agent_auth_block)"

    pnx_backup_file /etc/prometheus/prometheus-agent.yml
    pnx_render "${PNX_SRC_DIR}/templates/prometheus-agent.yml.tmpl" /etc/prometheus/prometheus-agent.yml \
        "SCRAPE_INTERVAL=${PNX_PROM_SCRAPE_INTERVAL}" \
        "NODE_EXPORTER_TARGET=127.0.0.1:${PNX_NODE_EXPORTER_PORT}" \
        "INSTANCE_NAME=${PNX_INSTANCE_NAME}" \
        "REMOTE_WRITE_URL=${PNX_REMOTE_WRITE_URL}" \
        "REMOTE_WRITE_AUTH_BLOCK=${auth_block}"

    # Credentials live in this file, so keep it off world-readable paths.
    chown root:prometheus /etc/prometheus/prometheus-agent.yml
    chmod 0640 /etc/prometheus/prometheus-agent.yml

    if command -v promtool >/dev/null 2>&1; then
        if ! promtool check config /etc/prometheus/prometheus-agent.yml >/dev/null 2>&1; then
            pnx_error "Generated prometheus-agent.yml failed validation:"
            promtool check config /etc/prometheus/prometheus-agent.yml >&2 || true
            return 1
        fi
        pnx_info "prometheus-agent.yml passed promtool validation"
    fi

    pnx_render "${PNX_SRC_DIR}/templates/prometheus-agent.service.tmpl" \
        "/etc/systemd/system/${PNX_AGENT_UNIT}" \
        "DATA_DIR=${PNX_AGENT_DATA_DIR}" \
        "PORT=${PNX_AGENT_PORT}"

    pnx_service_enable_start "${PNX_AGENT_UNIT}" || return 1
    pnx_info "Prometheus Agent is forwarding to ${PNX_REMOTE_WRITE_URL}"
    return 0
}

# Confirm samples are actually leaving the device. prometheus_remote_storage_*
# counters are the authoritative signal that the receiver accepted them.
pnx_agent_verify_push() {
    local url="http://127.0.0.1:${PNX_AGENT_PORT}/metrics"
    local out failed succeeded
    for _ in $(seq 1 15); do
        out=$(curl -sf --max-time 5 "${url}" 2>/dev/null) || { sleep 2; continue; }
        succeeded=$(printf '%s' "${out}" | awk '/^prometheus_remote_storage_samples_total/{s+=$2} END{print s+0}')
        failed=$(printf '%s' "${out}" | awk '/^prometheus_remote_storage_samples_failed_total/{s+=$2} END{print s+0}')
        if [ "${succeeded%.*}" -gt 0 ] 2>/dev/null; then
            if [ "${failed%.*}" -gt 0 ] 2>/dev/null; then
                pnx_warn "remote_write is sending but ${failed} samples failed — check credentials and the endpoint URL"
                return 2
            fi
            pnx_info "remote_write is delivering samples (${succeeded} sent)"
            return 0
        fi
        sleep 2
    done
    pnx_warn "No samples have been forwarded yet. Check: journalctl -u ${PNX_AGENT_UNIT} -n 50"
    return 1
}

# --- Entry point ---------------------------------------------------------
pnx_agent_install() {
    case "${PNX_AGENT_TRANSPORT}" in
        pull) pnx_agent_setup_pull ;;
        push) pnx_agent_setup_push ;;
        both) pnx_agent_setup_pull && pnx_agent_setup_push ;;
        *)    pnx_error "Unknown agent transport: ${PNX_AGENT_TRANSPORT}"; return 1 ;;
    esac
}
