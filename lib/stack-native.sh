#!/bin/bash
# lib/stack-native.sh — install Prometheus + Grafana directly on the device.
#
# Prometheus comes from the upstream release tarball (the distro package lags
# badly and its flag set differs). Grafana comes from Grafana Labs' official
# APT repository, which publishes arm64 and armhf builds suitable for the SBCs
# PiNodeXMR runs on.

[ -n "${PNX_STACK_NATIVE_SOURCED:-}" ] && return 0
PNX_STACK_NATIVE_SOURCED=1

PNX_PROM_UNIT="prometheus.service"
PNX_GRAFANA_UNIT="grafana-server.service"

# --- Prometheus ----------------------------------------------------------
pnx_prometheus_install_binary() {
    # Skip the download if the requested version is already in place.
    if [ -x /usr/local/bin/prometheus ]; then
        local have
        have="$(/usr/local/bin/prometheus --version 2>&1 | awk '/prometheus, version/{print $3}' | head -1)"
        if [ "${have}" = "${PNX_PROM_VERSION}" ]; then
            pnx_info "Prometheus ${have} already installed"
            return 0
        fi
        pnx_info "Replacing Prometheus ${have:-unknown} with ${PNX_PROM_VERSION}"
    fi

    local arch ver tarball url tmpdir
    arch="$(pnx_arch)"
    ver="${PNX_PROM_VERSION}"
    tarball="prometheus-${ver}.linux-${arch}.tar.gz"
    url="https://github.com/prometheus/prometheus/releases/download/v${ver}/${tarball}"

    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    pnx_download "${url}" "${tmpdir}/${tarball}" || {
        pnx_error "Could not download Prometheus ${ver} for ${arch}"
        return 1
    }
    tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}" || return 1

    local src="${tmpdir}/prometheus-${ver}.linux-${arch}"
    install -m 0755 -o root -g root "${src}/prometheus" /usr/local/bin/prometheus || return 1
    install -m 0755 -o root -g root "${src}/promtool"   /usr/local/bin/promtool   || return 1

    pnx_info "Installed Prometheus ${ver} (${arch})"
}

pnx_prometheus_setup() {
    pnx_ensure_user prometheus
    pnx_prometheus_install_binary || return 1

    mkdir -p /etc/prometheus "${PNX_PROM_DATA_DIR}"
    chown -R prometheus:prometheus "${PNX_PROM_DATA_DIR}"
    chmod 0750 "${PNX_PROM_DATA_DIR}"

    # node_exporter always binds a concrete address; Prometheus reaches it on
    # loopback regardless of whether it also listens on the LAN.
    local ne_target="127.0.0.1:${PNX_NODE_EXPORTER_PORT}"

    pnx_backup_file /etc/prometheus/prometheus.yml
    pnx_render "${PNX_SRC_DIR}/templates/prometheus.yml.tmpl" /etc/prometheus/prometheus.yml \
        "SCRAPE_INTERVAL=${PNX_PROM_SCRAPE_INTERVAL}" \
        "NODE_EXPORTER_TARGET=${ne_target}" \
        "INSTANCE_NAME=${PNX_INSTANCE_NAME}" \
        "PROM_PORT=${PNX_PROM_PORT}"
    chown root:prometheus /etc/prometheus/prometheus.yml
    chmod 0640 /etc/prometheus/prometheus.yml

    # Catch a malformed config before systemd does.
    if command -v promtool >/dev/null 2>&1; then
        if ! promtool check config /etc/prometheus/prometheus.yml >/dev/null 2>&1; then
            pnx_error "Generated prometheus.yml failed validation:"
            promtool check config /etc/prometheus/prometheus.yml >&2 || true
            return 1
        fi
        pnx_info "prometheus.yml passed promtool validation"
    fi

    pnx_render "${PNX_SRC_DIR}/templates/prometheus.service.tmpl" \
        "/etc/systemd/system/${PNX_PROM_UNIT}" \
        "DATA_DIR=${PNX_PROM_DATA_DIR}" \
        "RETENTION=${PNX_PROM_RETENTION}" \
        "RETENTION_SIZE=${PNX_PROM_RETENTION_SIZE}" \
        "BIND=${PNX_PROM_BIND}" \
        "PORT=${PNX_PROM_PORT}"

    pnx_service_enable_start "${PNX_PROM_UNIT}" || return 1
    [ "${PNX_PROM_BIND}" != "127.0.0.1" ] && pnx_firewall_allow "${PNX_PROM_PORT}" "pinodexmr-prometheus"
    return 0
}

# --- Grafana -------------------------------------------------------------
pnx_grafana_add_repo() {
    # Already configured?
    if [ -f /etc/apt/sources.list.d/grafana.list ] && [ -f /etc/apt/keyrings/grafana.gpg ]; then
        pnx_info "Grafana APT repository already configured"
        return 0
    fi

    pnx_apt_install apt-transport-https software-properties-common ca-certificates gnupg || return 1

    mkdir -p /etc/apt/keyrings
    local tmpkey
    tmpkey="$(mktemp)"
    pnx_download "https://apt.grafana.com/gpg.key" "${tmpkey}" || {
        rm -f "${tmpkey}"
        return 1
    }
    gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg < "${tmpkey}" || {
        rm -f "${tmpkey}"
        pnx_error "Failed to import the Grafana signing key"
        return 1
    }
    rm -f "${tmpkey}"
    chmod 0644 /etc/apt/keyrings/grafana.gpg

    printf 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main\n' \
        > /etc/apt/sources.list.d/grafana.list

    # Force a refresh now that a new source exists.
    unset PNX_APT_UPDATED
    pnx_apt_update_once
    pnx_info "Grafana APT repository configured"
}

pnx_grafana_setup() {
    if ! dpkg -s grafana >/dev/null 2>&1; then
        pnx_grafana_add_repo || return 1
        pnx_info "Installing Grafana (this can take a few minutes on an SBC)"
        pnx_apt_install grafana || {
            pnx_error "Grafana installation failed. No Grafana build for architecture: $(pnx_deb_arch)"
            pnx_error "On unsupported architectures, use the Docker flavour or a remote Grafana (agent mode)."
            return 1
        }
    else
        pnx_info "Grafana is already installed"
    fi

    # Port and bind address go through the environment file rather than
    # rewriting grafana.ini, so user edits to grafana.ini survive upgrades.
    local envfile="/etc/default/grafana-server"
    pnx_backup_file "${envfile}"
    touch "${envfile}"
    pnx_grafana_set_env "${envfile}" GF_SERVER_HTTP_PORT "${PNX_GRAFANA_PORT}"
    pnx_grafana_set_env "${envfile}" GF_SERVER_HTTP_ADDR "${PNX_GRAFANA_BIND}"
    pnx_grafana_set_env "${envfile}" GF_ANALYTICS_REPORTING_ENABLED "false"
    pnx_grafana_set_env "${envfile}" GF_ANALYTICS_CHECK_FOR_UPDATES "false"
    pnx_grafana_set_env "${envfile}" GF_USERS_ALLOW_SIGN_UP "false"
    if [ -n "${PNX_GRAFANA_DOMAIN}" ]; then
        pnx_grafana_set_env "${envfile}" GF_SERVER_DOMAIN "${PNX_GRAFANA_DOMAIN}"
        pnx_grafana_set_env "${envfile}" GF_SERVER_ROOT_URL "http://${PNX_GRAFANA_DOMAIN}:${PNX_GRAFANA_PORT}/"
    fi

    # Provision the datasource + dashboard before first start so Grafana comes
    # up already wired to its database. That database is the locally managed
    # Prometheus by default, or an existing Prometheus-compatible endpoint
    # elsewhere when PNX_GRAFANA_DS_URL is set (viewer topology).
    local ds_url="${PNX_GRAFANA_DS_URL}"
    [ -z "${ds_url}" ] && ds_url="http://127.0.0.1:${PNX_PROM_PORT}"
    # Consumed by pnx_provision_grafana in lib/provision.sh.
    # shellcheck disable=SC2034
    PNX_DASHBOARD_DIR_INTERNAL="/var/lib/grafana/dashboards/pinodexmr"
    pnx_provision_grafana \
        "/etc/grafana/provisioning" \
        "/var/lib/grafana/dashboards/pinodexmr" \
        "${ds_url}" || return 1

    chown -R root:grafana /etc/grafana/provisioning 2>/dev/null || true
    chown -R grafana:grafana /var/lib/grafana/dashboards 2>/dev/null || true

    pnx_service_enable_start "${PNX_GRAFANA_UNIT}" || return 1
    pnx_grafana_wait "${PNX_GRAFANA_BIND}" "${PNX_GRAFANA_PORT}" || true

    # Set the admin password after startup: grafana-cli writes the hash into
    # Grafana's own database, so it works on a fresh install and on a re-run,
    # and the plaintext never persists in a config file.
    if [ -n "${PNX_GRAFANA_ADMIN_PASS}" ]; then
        # Prefer --password-from-stdin (Grafana 9.1+) so the password never
        # touches argv, which is world-readable via /proc. Fall back to the
        # positional form only on older grafana-cli that lacks the flag.
        if printf '%s' "${PNX_GRAFANA_ADMIN_PASS}" | \
            grafana-cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin >/dev/null 2>&1; then
            pnx_info "Grafana admin password set for user '${PNX_GRAFANA_ADMIN_USER}'"
        elif grafana-cli --homepath /usr/share/grafana admin reset-admin-password "${PNX_GRAFANA_ADMIN_PASS}" >/dev/null 2>&1; then
            pnx_info "Grafana admin password set for user '${PNX_GRAFANA_ADMIN_USER}'"
        else
            pnx_warn "Could not set the Grafana admin password automatically."
            pnx_warn "Set it manually: sudo grafana-cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin"
        fi
    fi

    [ "${PNX_GRAFANA_BIND}" != "127.0.0.1" ] && pnx_firewall_allow "${PNX_GRAFANA_PORT}" "pinodexmr-grafana"
    return 0
}

# Set KEY=VALUE in an environment file, replacing any existing definition.
pnx_grafana_set_env() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^[#[:space:]]*${key}=" "${file}" 2>/dev/null; then
        sed -i "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "${file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

# --- Entry point ---------------------------------------------------------
# Installs only the components selected for this device.
pnx_stack_native_install() {
    if [ "${PNX_INSTALL_PROMETHEUS}" = "true" ]; then
        pnx_prometheus_setup || return 1
    fi
    if [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
        pnx_grafana_setup || return 1
    fi
    return 0
}
