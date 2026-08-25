#!/bin/bash
# lib/node-exporter.sh — install/configure Prometheus node_exporter.
#
# PiNodeXMR does NOT ship node_exporter, so in the common case we install it
# from the upstream release binaries. We also handle two other situations a
# user may already be in:
#
#   * node_exporter installed from Debian/Ubuntu APT (prometheus-node-exporter),
#     configured through /etc/default/prometheus-node-exporter
#   * a hand-rolled /usr/local/bin/node_exporter with its own unit file
#
# In every case the goal is the same: node_exporter must serve the textfile
# collector directory that the monerod exporter writes into.

[ -n "${PNX_NODE_EXPORTER_SOURCED:-}" ] && return 0
PNX_NODE_EXPORTER_SOURCED=1

PNX_NE_APT_UNIT="prometheus-node-exporter.service"
PNX_NE_OWN_UNIT="node_exporter.service"

# Which flavour of node_exporter is present? Echoes: none | apt | custom
pnx_ne_detect() {
    if pnx_service_exists "${PNX_NE_APT_UNIT}"; then
        printf 'apt'
    elif pnx_service_exists "${PNX_NE_OWN_UNIT}" || [ -x /usr/local/bin/node_exporter ]; then
        printf 'custom'
    else
        printf 'none'
    fi
}

# Create the textfile collector directory, owned by the exporter user so the
# monerod exporter (running unprivileged) can write into it.
pnx_ne_prepare_textfile_dir() {
    mkdir -p "${PNX_TEXTFILE_DIR}"
    if id -u "${PNX_EXPORTER_USER}" >/dev/null 2>&1; then
        chown "${PNX_EXPORTER_USER}:$(id -gn "${PNX_EXPORTER_USER}")" "${PNX_TEXTFILE_DIR}"
    fi
    chmod 0755 "${PNX_TEXTFILE_DIR}"
    pnx_info "Textfile collector directory ready: ${PNX_TEXTFILE_DIR}"
}

# --- Install from upstream release binaries ------------------------------
pnx_ne_install_binary() {
    local arch ver tarball url tmpdir
    arch="$(pnx_arch)"
    ver="${PNX_NODE_EXPORTER_VERSION}"
    tarball="node_exporter-${ver}.linux-${arch}.tar.gz"
    url="https://github.com/prometheus/node_exporter/releases/download/v${ver}/${tarball}"

    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    if ! pnx_download "${url}" "${tmpdir}/${tarball}"; then
        pnx_error "Could not download node_exporter ${ver} for ${arch}."
        pnx_error "If this architecture has no upstream build, install the distro package instead:"
        pnx_error "  sudo apt install prometheus-node-exporter"
        return 1
    fi

    tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}" || {
        pnx_error "Failed to extract ${tarball}"
        return 1
    }

    install -m 0755 -o root -g root \
        "${tmpdir}/node_exporter-${ver}.linux-${arch}/node_exporter" \
        /usr/local/bin/node_exporter || return 1

    pnx_ensure_user node_exporter
    pnx_info "Installed node_exporter ${ver} (${arch}) to /usr/local/bin/node_exporter"

    # node_exporter needs to read the textfile directory that the monerod
    # exporter owns; adding it to that group is enough (dir is 0755 anyway).
    pnx_render "${PNX_SRC_DIR}/templates/node_exporter.service.tmpl" \
        "/etc/systemd/system/${PNX_NE_OWN_UNIT}" \
        "TEXTFILE_DIR=${PNX_TEXTFILE_DIR}" \
        "BIND=${PNX_NODE_EXPORTER_BIND}" \
        "PORT=${PNX_NODE_EXPORTER_PORT}"

    # Read back by config.sh/uninstall.sh to decide whether we own node_exporter.
    # shellcheck disable=SC2034
    PNX_NODE_EXPORTER_MANAGED="true"
    pnx_service_enable_start "${PNX_NE_OWN_UNIT}"
}

# --- Reconfigure an APT-installed node_exporter --------------------------
pnx_ne_configure_apt() {
    local defaults="/etc/default/prometheus-node-exporter"
    pnx_info "Configuring existing APT node_exporter for the textfile collector"
    pnx_backup_file "${defaults}"

    local args="--collector.textfile.directory=${PNX_TEXTFILE_DIR} --web.listen-address=${PNX_NODE_EXPORTER_BIND}:${PNX_NODE_EXPORTER_PORT}"

    if [ -f "${defaults}" ] && grep -q '^ARGS=' "${defaults}"; then
        # Replace the whole ARGS line — merging flags reliably is not worth the
        # risk of ending up with two conflicting --web.listen-address values.
        sed -i "s|^ARGS=.*|ARGS=\"${args}\"|" "${defaults}"
    else
        printf 'ARGS="%s"\n' "${args}" >> "${defaults}"
    fi

    pnx_service_enable_start "${PNX_NE_APT_UNIT}"
}

# --- Reconfigure a pre-existing custom node_exporter ---------------------
pnx_ne_configure_custom() {
    local unit_file="/etc/systemd/system/${PNX_NE_OWN_UNIT}"

    if [ ! -f "${unit_file}" ]; then
        pnx_warn "node_exporter binary found but no unit at ${unit_file}; writing one"
        pnx_ensure_user node_exporter
        pnx_render "${PNX_SRC_DIR}/templates/node_exporter.service.tmpl" "${unit_file}" \
            "TEXTFILE_DIR=${PNX_TEXTFILE_DIR}" \
            "BIND=${PNX_NODE_EXPORTER_BIND}" \
            "PORT=${PNX_NODE_EXPORTER_PORT}"
        pnx_service_enable_start "${PNX_NE_OWN_UNIT}"
        return $?
    fi

    if grep -q -- '--collector.textfile.directory' "${unit_file}"; then
        local current
        current="$(grep -o -- '--collector\.textfile\.directory=[^ \\]*' "${unit_file}" | head -1 | cut -d= -f2-)"
        if [ "${current}" = "${PNX_TEXTFILE_DIR}" ]; then
            pnx_info "Existing node_exporter already serves ${PNX_TEXTFILE_DIR}"
            systemctl is-active --quiet "${PNX_NE_OWN_UNIT}" || pnx_service_enable_start "${PNX_NE_OWN_UNIT}"
            return 0
        fi
        # It already has a textfile dir but a different one. Adopt theirs
        # rather than breaking whatever else writes there.
        pnx_warn "node_exporter already serves textfile dir '${current}'."
        pnx_warn "Using that directory for monerod metrics instead of ${PNX_TEXTFILE_DIR}."
        PNX_TEXTFILE_DIR="${current}"
        pnx_ne_prepare_textfile_dir
        systemctl is-active --quiet "${PNX_NE_OWN_UNIT}" || pnx_service_enable_start "${PNX_NE_OWN_UNIT}"
        return 0
    fi

    pnx_info "Adding the textfile collector flag to the existing node_exporter unit"
    pnx_backup_file "${unit_file}"
    sed -i "s|^\(ExecStart=.*node_exporter\)|\1 --collector.textfile.directory=${PNX_TEXTFILE_DIR}|" "${unit_file}"
    pnx_service_enable_start "${PNX_NE_OWN_UNIT}"
}

# --- Entry point ---------------------------------------------------------
pnx_node_exporter_setup() {
    pnx_ne_prepare_textfile_dir

    local flavour
    flavour="$(pnx_ne_detect)"
    pnx_info "node_exporter detection: ${flavour}"

    case "${flavour}" in
        none)   pnx_ne_install_binary   || return 1 ;;
        apt)    pnx_ne_configure_apt    || return 1 ;;
        custom) pnx_ne_configure_custom || return 1 ;;
    esac

    # Re-apply ownership: a freshly installed node_exporter may have recreated
    # the directory as root.
    pnx_ne_prepare_textfile_dir
    return 0
}

# Which unit is actually serving node_exporter right now?
pnx_ne_unit() {
    if pnx_service_exists "${PNX_NE_APT_UNIT}" && [ "$(pnx_ne_detect)" = "apt" ]; then
        printf '%s' "${PNX_NE_APT_UNIT}"
    else
        printf '%s' "${PNX_NE_OWN_UNIT}"
    fi
}

# Verify node_exporter is actually serving our metrics.
pnx_ne_verify() {
    local url="http://127.0.0.1:${PNX_NODE_EXPORTER_PORT}/metrics"

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -sf --max-time 5 "${url}" >/dev/null 2>&1; then
            pnx_info "node_exporter is responding on ${url}"
            return 0
        fi
        sleep 2
    done
    pnx_warn "node_exporter did not respond on ${url}"
    return 1
}
