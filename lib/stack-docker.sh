#!/bin/bash
# lib/stack-docker.sh — run Prometheus + Grafana as containers on the device.
#
# node_exporter and the monerod exporter still run on the host: node_exporter
# needs host /proc, /sys and the textfile directory, and keeping it on the host
# means both stack flavours expose exactly the same metrics.

[ -n "${PNX_STACK_DOCKER_SOURCED:-}" ] && return 0
PNX_STACK_DOCKER_SOURCED=1

# Resolve the compose entrypoint: `docker compose` (v2 plugin) or the older
# standalone `docker-compose`.
pnx_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        return 127
    fi
}

pnx_docker_install() {
    if command -v docker >/dev/null 2>&1 && (docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1); then
        pnx_info "Docker and Compose are already installed"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        pnx_info "Installing Docker Engine via get.docker.com (this takes a while on an SBC)"
        local script
        script="$(mktemp)"
        pnx_download "https://get.docker.com" "${script}" || { rm -f "${script}"; return 1; }
        sh "${script}" || { rm -f "${script}"; pnx_error "Docker installation failed"; return 1; }
        rm -f "${script}"
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        pnx_apt_install docker-compose-plugin || {
            pnx_error "Could not install the Docker Compose plugin"
            return 1
        }
    fi

    command -v docker >/dev/null 2>&1 || { pnx_error "Docker is still not available"; return 1; }
    return 0
}

pnx_stack_docker_install() {
    pnx_docker_install || return 1

    local dir="${PNX_DOCKER_DIR}"
    mkdir -p "${dir}/prometheus" "${dir}/grafana/provisioning" "${dir}/grafana/dashboards" "${dir}/secrets"

    # Containers run as a dedicated unprivileged user so the bind-mounted
    # provisioning files are never owned by root inside the container.
    pnx_ensure_user pinodexmr-mon
    local puid pgid
    puid="$(id -u pinodexmr-mon)"
    pgid="$(id -g pinodexmr-mon)"

    # --- Prometheus config ---
    # Containers reach the host's node_exporter through the host-gateway alias
    # declared in the compose file.
    pnx_render "${PNX_SRC_DIR}/templates/prometheus.yml.tmpl" "${dir}/prometheus/prometheus.yml" \
        "SCRAPE_INTERVAL=${PNX_PROM_SCRAPE_INTERVAL}" \
        "NODE_EXPORTER_TARGET=host.docker.internal:${PNX_NODE_EXPORTER_PORT}" \
        "INSTANCE_NAME=${PNX_INSTANCE_NAME}" \
        "PROM_PORT=9090"

    # --- Grafana provisioning ---
    # Host paths are where we write; the container sees the dashboards at a
    # fixed mount point, which is what the provider file must reference.
    # Consumed by pnx_provision_grafana in lib/provision.sh.
    # shellcheck disable=SC2034
    PNX_DASHBOARD_DIR_INTERNAL="/var/lib/grafana/dashboards"
    pnx_provision_grafana \
        "${dir}/grafana/provisioning" \
        "${dir}/grafana/dashboards" \
        "http://prometheus:9090" || return 1

    # --- Admin password secret ---
    printf '%s' "${PNX_GRAFANA_ADMIN_PASS}" > "${dir}/secrets/grafana_admin_password"
    chmod 0600 "${dir}/secrets/grafana_admin_password"

    # --- Compose file ---
    pnx_render "${PNX_SRC_DIR}/templates/docker-compose.yml.tmpl" "${dir}/docker-compose.yml" \
        "DOCKER_DIR=${dir}" \
        "PROM_IMAGE=${PNX_DOCKER_PROM_IMAGE}" \
        "GRAFANA_IMAGE=${PNX_DOCKER_GRAFANA_IMAGE}" \
        "RETENTION=${PNX_PROM_RETENTION}" \
        "RETENTION_SIZE=${PNX_PROM_RETENTION_SIZE}" \
        "PROM_BIND=${PNX_PROM_BIND}" \
        "PROM_PORT=${PNX_PROM_PORT}" \
        "GRAFANA_BIND=${PNX_GRAFANA_BIND}" \
        "GRAFANA_PORT=${PNX_GRAFANA_PORT}" \
        "GRAFANA_ADMIN_USER=${PNX_GRAFANA_ADMIN_USER}" \
        "PUID=${puid}" \
        "PGID=${pgid}"

    chown -R "${puid}:${pgid}" "${dir}/grafana" "${dir}/prometheus" "${dir}/secrets"
    chmod 0750 "${dir}/secrets"

    pnx_info "Starting the monitoring containers (first run pulls images)"
    ( cd "${dir}" && pnx_compose up -d ) || {
        pnx_error "docker compose up failed. Inspect with: cd ${dir} && docker compose logs"
        return 1
    }

    pnx_grafana_wait "${PNX_GRAFANA_BIND}" "${PNX_GRAFANA_PORT}" || true

    [ "${PNX_GRAFANA_BIND}" != "127.0.0.1" ] && pnx_firewall_allow "${PNX_GRAFANA_PORT}" "pinodexmr-grafana"
    [ "${PNX_PROM_BIND}" != "127.0.0.1" ] && pnx_firewall_allow "${PNX_PROM_PORT}" "pinodexmr-prometheus"
    return 0
}

pnx_stack_docker_remove() {
    local dir="${PNX_DOCKER_DIR}"
    [ -f "${dir}/docker-compose.yml" ] || return 0
    pnx_info "Stopping and removing the monitoring containers"
    ( cd "${dir}" && pnx_compose down -v ) || pnx_warn "docker compose down reported errors"
}
