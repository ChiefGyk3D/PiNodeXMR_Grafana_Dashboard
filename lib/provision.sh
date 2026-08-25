#!/bin/bash
# lib/provision.sh — Grafana datasource + dashboard provisioning.
#
# The dashboard JSON in this repo is kept in Grafana's *portable* form: it
# declares an `__inputs` entry named DS_PROMETHEUS and refers to the datasource
# as "${DS_PROMETHEUS}" throughout. That form is what you want when importing
# by hand through the Grafana UI, because it makes Grafana ask which datasource
# to use.
#
# File provisioning cannot answer that question, so before dropping the
# dashboard on disk we convert it to the *provisioned* form: strip __inputs /
# __requires and bind every datasource reference to the fixed UID
# `pinodexmr-prometheus`, which is the UID the provisioned datasource declares.
# That pairing is the whole answer to "how is the database wired up" — there is
# no manual step and no UID drift between installs.

[ -n "${PNX_PROVISION_SOURCED:-}" ] && return 0
PNX_PROVISION_SOURCED=1

PNX_DS_UID="pinodexmr-prometheus"

# pnx_dashboard_to_provisioned SRC_JSON DEST_JSON
pnx_dashboard_to_provisioned() {
    local src="$1" dest="$2"
    [ -f "${src}" ] || { pnx_error "Dashboard JSON not found: ${src}"; return 1; }

    mkdir -p "$(dirname "${dest}")"

    if command -v jq >/dev/null 2>&1; then
        # Walk the whole document and rewrite every "${DS_PROMETHEUS}" string
        # (datasource uids appear in panels, targets, templating and annotations).
        jq --arg uid "${PNX_DS_UID}" '
            def rewrite:
                if type == "object" then
                    with_entries(.value |= rewrite)
                elif type == "array" then
                    map(rewrite)
                elif type == "string" then
                    if . == "${DS_PROMETHEUS}" then $uid else . end
                else . end;
            rewrite
            | del(.__inputs)
            | del(.__requires)
            | .id = null
        ' "${src}" > "${dest}" || {
            pnx_error "jq failed to transform the dashboard JSON"
            return 1
        }
    else
        # Fallback: textual substitution. Adequate because the placeholder is
        # a distinctive literal, but jq is installed by the exporter step so
        # this path is rarely taken.
        sed -e 's/\${DS_PROMETHEUS}/'"${PNX_DS_UID}"'/g' "${src}" > "${dest}"
    fi

    # Sanity-check the output really is valid JSON — a broken dashboard file
    # makes Grafana log a provisioning error and show nothing.
    if command -v jq >/dev/null 2>&1; then
        jq -e . "${dest}" >/dev/null 2>&1 || {
            pnx_error "Generated dashboard JSON is invalid: ${dest}"
            return 1
        }
    fi
    pnx_info "Prepared provisioned dashboard: ${dest}"
}

# Optional credentials for the datasource, used when the database is an
# existing one elsewhere in the lab rather than the locally managed
# Prometheus. Built with real newlines and YAML single-quoting so credentials
# survive byte-for-byte (see pnx_yaml_squote).
pnx_ds_auth_block() {
    case "${PNX_GRAFANA_DS_AUTH:-none}" in
        basic)
            cat <<EOF
    basicAuth: true
    basicAuthUser: $(pnx_yaml_squote "${PNX_GRAFANA_DS_USER}")
    secureJsonData:
      basicAuthPassword: $(pnx_yaml_squote "${PNX_GRAFANA_DS_PASS}")
EOF
            ;;
        *)
            printf '    basicAuth: false\n'
            ;;
    esac
}

pnx_ds_json_extra() {
    if [ "${PNX_GRAFANA_DS_INSECURE:-false}" = "true" ]; then
        printf '      tlsSkipVerify: true\n'
    else
        printf ''
    fi
}

# pnx_provision_grafana PROVISIONING_DIR DASHBOARD_DIR PROM_URL
#
# PROVISIONING_DIR — Grafana's provisioning root (contains datasources/, dashboards/)
# DASHBOARD_DIR    — where dashboard JSON files live, as Grafana sees the path
# PROM_URL         — the database URL, as Grafana sees it: the locally managed
#                    Prometheus, or an existing Prometheus-compatible endpoint
#                    elsewhere (with optional basic auth via PNX_GRAFANA_DS_*)
#
# For the Docker flavour the *container* paths differ from the host paths, so
# the caller passes host paths for writing and we take the container-visible
# dashboard path separately via PNX_DASHBOARD_DIR_INTERNAL.
pnx_provision_grafana() {
    local prov_dir="$1" dash_dir="$2" prom_url="$3"
    local dash_dir_internal="${PNX_DASHBOARD_DIR_INTERNAL:-${dash_dir}}"

    mkdir -p "${prov_dir}/datasources" "${prov_dir}/dashboards" "${dash_dir}"

    local auth_block json_extra
    auth_block="$(pnx_ds_auth_block)"
    json_extra="$(pnx_ds_json_extra)"

    pnx_render "${PNX_SRC_DIR}/templates/grafana-datasource.yml.tmpl" \
        "${prov_dir}/datasources/pinodexmr.yml" \
        "DS_NAME=Prometheus (PiNodeXMR)" \
        "PROM_URL=${prom_url}" \
        "SCRAPE_INTERVAL=${PNX_PROM_SCRAPE_INTERVAL}" \
        "DS_AUTH_BLOCK=${auth_block}" \
        "DS_JSON_EXTRA=${json_extra}"

    # The datasource file now may hold credentials — restrict it.
    chmod 0640 "${prov_dir}/datasources/pinodexmr.yml" 2>/dev/null || true

    pnx_render "${PNX_SRC_DIR}/templates/grafana-dashboard-provider.yml.tmpl" \
        "${prov_dir}/dashboards/pinodexmr.yml" \
        "DASHBOARD_DIR=${dash_dir_internal}"

    pnx_dashboard_to_provisioned \
        "${PNX_SRC_DIR}/dashboards/pinodexmr-dashboard.json" \
        "${dash_dir}/pinodexmr-dashboard.json" || return 1

    pnx_info "Grafana provisioning written under ${prov_dir}"
}

# Wait for Grafana to answer, so the installer can report a real URL rather
# than a hopeful one.
# pnx_grafana_wait HOST PORT
pnx_grafana_wait() {
    local host="$1" port="$2"
    [ "${host}" = "0.0.0.0" ] && host="127.0.0.1"
    for _ in $(seq 1 30); do
        if curl -sf --max-time 3 "http://${host}:${port}/api/health" >/dev/null 2>&1; then
            pnx_info "Grafana is up on ${host}:${port}"
            return 0
        fi
        sleep 2
    done
    pnx_warn "Grafana did not become healthy on ${host}:${port} within 60s"
    return 1
}
