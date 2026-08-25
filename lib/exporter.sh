#!/bin/bash
# lib/exporter.sh — install the monerod textfile exporter and its unit.

[ -n "${PNX_EXPORTER_SOURCED:-}" ] && return 0
PNX_EXPORTER_SOURCED=1

PNX_EXPORTER_UNIT="monerod-exporter.service"

# The exporter runs unprivileged. On PiNodeXMR the `pinodexmr` user already
# exists; on a generic monerod host we fall back to a dedicated system user.
pnx_exporter_resolve_user() {
    if id -u "${PNX_EXPORTER_USER}" >/dev/null 2>&1; then
        return 0
    fi
    pnx_warn "User '${PNX_EXPORTER_USER}' does not exist; creating a system user for the exporter"
    pnx_ensure_user "${PNX_EXPORTER_USER}"
}

pnx_exporter_install() {
    pnx_exporter_resolve_user

    # Runtime dependencies. These are the only two the exporter needs.
    pnx_apt_install jq curl || {
        pnx_error "jq and curl are required by the exporter"
        return 1
    }

    install -m 0755 -o root -g root \
        "${PNX_SRC_DIR}/exporter/monerod-exporter.sh" \
        "${PNX_EXPORTER_PATH}" || return 1
    pnx_info "Installed exporter to ${PNX_EXPORTER_PATH}"

    local grp
    grp="$(id -gn "${PNX_EXPORTER_USER}")"

    pnx_render "${PNX_SRC_DIR}/templates/monerod-exporter.service.tmpl" \
        "/etc/systemd/system/${PNX_EXPORTER_UNIT}" \
        "EXPORTER_USER=${PNX_EXPORTER_USER}" \
        "EXPORTER_GROUP=${grp}" \
        "EXPORTER_PATH=${PNX_EXPORTER_PATH}" \
        "TEXTFILE_DIR=${PNX_TEXTFILE_DIR}"

    pnx_service_enable_start "${PNX_EXPORTER_UNIT}"
}

# Confirm the exporter actually produced metrics, and surface the real reason
# when it did not — this is where a wrong RPC password shows up.
pnx_exporter_verify() {
    local prom_file="${PNX_TEXTFILE_DIR}/monerod.prom"
    :
    for _ in $(seq 1 15); do
        if [ -f "${prom_file}" ]; then
            if grep -q '^monerod_up 1' "${prom_file}" 2>/dev/null; then
                local height
                height="$(awk '/^monerod_height /{print $2}' "${prom_file}")"
                pnx_info "Exporter is healthy (monerod_up=1, height=${height:-?})"
                return 0
            fi
            if grep -q '^monerod_up 0' "${prom_file}" 2>/dev/null; then
                pnx_warn "Exporter is running but monerod RPC is unreachable (monerod_up=0)"
                return 2
            fi
        fi
        sleep 2
    done
    pnx_warn "No metrics file appeared at ${prom_file} within 30s"
    return 1
}

# A one-shot RPC probe used during configuration, so the user finds out their
# credentials are wrong at prompt time rather than after the whole install.
# pnx_exporter_test_rpc HOST PORT USER PASS AUTH
pnx_exporter_test_rpc() {
    local host="$1" port="$2" user="$3" pass="$4" auth="$5"
    local out
    out=$(curl -sf --max-time 8 --config <(pnx_curl_auth_config "${auth}" "${user}" "${pass}") \
        -X POST "http://${host}:${port}/json_rpc" \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' \
        -H 'Content-Type: application/json' 2>/dev/null) || return 1
    printf '%s' "${out}" | jq -e '.result.height' >/dev/null 2>&1 || return 1
    printf '%s' "${out}" | jq -r '.result.height'
}

# Resolve the RPC settings the exporter will actually use, honouring
# PiNodeXMR's variable files when that mode is enabled.
pnx_exporter_effective_rpc() {
    local host port user pass
    if [ "${PNX_RPC_FROM_PINODEXMR}" = "true" ]; then
        # Parsed, never sourced — these files are pinodexmr-writable and we run
        # as root (see pnx_read_var_file).
        user="$(pnx_read_var_file "${PNX_PINODEXMR_VAR_DIR}/RPCu.sh" RPCu)"
        pass="$(pnx_read_var_file "${PNX_PINODEXMR_VAR_DIR}/RPCp.sh" RPCp)"
        port="$(pnx_read_var_file "${PNX_PINODEXMR_VAR_DIR}/monero-port.sh" MONERO_PORT)"
        [ -z "${port}" ] && port="18081"
        host="$(pnx_primary_ip)"; [ -z "${host}" ] && host="127.0.0.1"
    else
        host="${PNX_RPC_HOST}"; port="${PNX_RPC_PORT}"
        user="${PNX_RPC_USER}"; pass="${PNX_RPC_PASS}"
    fi
    printf '%s\t%s\t%s\t%s' "${host}" "${port}" "${user}" "${pass}"
}
