#!/bin/bash
# install.sh — PiNodeXMR Grafana monitoring installer.
#
# Two deployment shapes:
#
#   local — Prometheus + Grafana run on the PiNodeXMR itself, on a port of your
#           choosing. Everything needed is installed and wired up, and the
#           dashboard is provisioned automatically.
#
#   agent — the device only produces metrics and reports to a Grafana stack
#           somewhere else, either by being scraped (pull) or by pushing over
#           remote_write (push, which works from behind NAT).
#
# Usage:
#   sudo ./install.sh              interactive
#   sudo ./install.sh --unattended use existing config / defaults, no prompts
#   sudo ./install.sh --status     show what is installed and healthy
#   sudo ./install.sh --uninstall  remove everything this installer added
#   sudo ./install.sh --help
#
# https://github.com/ChiefGyk3D/PiNodeXMR_Grafana_Dashboard

set -uo pipefail

PNX_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PNX_SRC_DIR

# shellcheck source=lib/common.sh
. "${PNX_SRC_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${PNX_SRC_DIR}/lib/config.sh"
# shellcheck source=lib/node-exporter.sh
. "${PNX_SRC_DIR}/lib/node-exporter.sh"
# shellcheck source=lib/exporter.sh
. "${PNX_SRC_DIR}/lib/exporter.sh"
# shellcheck source=lib/provision.sh
. "${PNX_SRC_DIR}/lib/provision.sh"
# shellcheck source=lib/stack-native.sh
. "${PNX_SRC_DIR}/lib/stack-native.sh"
# shellcheck source=lib/stack-docker.sh
. "${PNX_SRC_DIR}/lib/stack-docker.sh"
# shellcheck source=lib/agent.sh
. "${PNX_SRC_DIR}/lib/agent.sh"

PNX_TITLE="PiNodeXMR Monitoring"

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Environment detection ----------------------------------------------
pnx_detect_pinodexmr() {
    [ -d "${PNX_PINODEXMR_VAR_DIR}" ] && [ -r "${PNX_PINODEXMR_VAR_DIR}/monero-port.sh" ]
}

pnx_preflight() {
    pnx_require_root

    if ! pnx_systemd_available; then
        pnx_die "This installer requires systemd, which was not detected on this host."
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        pnx_die "This installer targets Debian/Ubuntu-based systems (PiNodeXMR's base). No apt-get found."
    fi

    mkdir -p "${PNX_STATE_DIR}"
    touch "${PNX_LOG_FILE}" 2>/dev/null || true
    chmod 0640 "${PNX_LOG_FILE}" 2>/dev/null || true

    pnx_info "=== PiNodeXMR monitoring installer starting ==="
    pnx_info "Architecture: $(uname -m) -> $(pnx_arch)"
}

# --- Interview: shared settings -----------------------------------------
pnx_ask_instance_name() {
    PNX_INSTANCE_NAME="$(pnx_input "${PNX_TITLE}" \
        "Name for this node.\n\nThis is the label the dashboard's 'instance' dropdown shows, so give each device a distinct name if you monitor more than one." \
        "${PNX_INSTANCE_NAME}")"
    # Prometheus labels are far happier without whitespace.
    PNX_INSTANCE_NAME="${PNX_INSTANCE_NAME// /-}"
}

pnx_ask_rpc() {
    if pnx_detect_pinodexmr; then
        if pnx_yesno "${PNX_TITLE} — monerod RPC" \
            "PiNodeXMR was detected on this device.\n\nRead the monerod RPC port and credentials from PiNodeXMR's own variable files?\n\nRecommended: the exporter then picks up any RPC username, password or port you change through the PiNodeXMR menus automatically, with no reconfiguration here." 1; then
            PNX_RPC_FROM_PINODEXMR="true"
        else
            PNX_RPC_FROM_PINODEXMR="false"
        fi
    else
        pnx_warn "PiNodeXMR variable files not found at ${PNX_PINODEXMR_VAR_DIR}"
        pnx_msgbox "${PNX_TITLE} — monerod RPC" \
            "PiNodeXMR was not detected on this device.\n\nThat is fine — this add-on also works against a plain monerod host. You will be asked for the RPC connection details next."
        PNX_RPC_FROM_PINODEXMR="false"
    fi

    if [ "${PNX_RPC_FROM_PINODEXMR}" = "false" ]; then
        PNX_RPC_HOST="$(pnx_input "${PNX_TITLE} — monerod RPC" "monerod RPC host or IP address:" "${PNX_RPC_HOST}")"
        PNX_RPC_PORT="$(pnx_prompt_port "${PNX_TITLE} — monerod RPC" "monerod RPC port:" "${PNX_RPC_PORT}" 1)"

        local auth
        auth="$(pnx_menu "${PNX_TITLE} — monerod RPC" "How is the monerod RPC authenticated?" \
            "digest" "HTTP digest auth (monerod default with --rpc-login)" \
            "basic"  "HTTP basic auth (behind a reverse proxy)" \
            "none"   "No authentication")"
        PNX_RPC_AUTH="${auth:-digest}"

        if [ "${PNX_RPC_AUTH}" != "none" ]; then
            PNX_RPC_USER="$(pnx_input "${PNX_TITLE} — monerod RPC" "RPC username:" "${PNX_RPC_USER}")"
            local pass
            pass="$(pnx_password "${PNX_TITLE} — monerod RPC" "RPC password for '${PNX_RPC_USER}':")"
            [ -n "${pass}" ] && PNX_RPC_PASS="${pass}"
        fi
    fi

    # Probe now, so a wrong password surfaces here rather than after install.
    pnx_test_rpc_now
}

pnx_test_rpc_now() {
    command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || {
        pnx_info "Installing jq/curl so the RPC connection can be tested"
        pnx_apt_install jq curl >/dev/null 2>&1 || return 0
    }

    local rpc host port user pass height
    rpc="$(pnx_exporter_effective_rpc)"
    IFS=$'\t' read -r host port user pass <<< "${rpc}"

    pnx_info "Testing monerod RPC at ${host}:${port} (auth: ${PNX_RPC_AUTH})"
    if height="$(pnx_exporter_test_rpc "${host}" "${port}" "${user}" "${pass}" "${PNX_RPC_AUTH}")"; then
        pnx_msgbox "${PNX_TITLE} — monerod RPC" "Connected to monerod successfully.\n\nBlockchain height: ${height}"
        return 0
    fi

    pnx_warn "monerod RPC test failed at ${host}:${port}"
    pnx_yesno "${PNX_TITLE} — monerod RPC" \
        "Could not reach the monerod RPC at ${host}:${port}.\n\nThis is expected if monerod is not running yet, or still starting up. The exporter will keep retrying once installed.\n\nContinue with the installation anyway?" 1
    return $?
}

pnx_ask_interval() {
    local i
    while true; do
        i="$(pnx_input "${PNX_TITLE}" "How often should monerod be polled, in seconds?\n\n30 suits most setups. Below 15 adds load for little benefit." "${PNX_EXPORTER_INTERVAL}")"
        if [[ "${i}" =~ ^[0-9]+$ ]] && [ "${i}" -ge 5 ]; then
            PNX_EXPORTER_INTERVAL="${i}"
            break
        fi
        pnx_msgbox "${PNX_TITLE}" "Please enter a whole number of seconds, 5 or greater."
    done
}

pnx_ask_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if pnx_yesno "${PNX_TITLE} — Firewall" \
            "ufw is active on this device.\n\nShould the installer open the ports it needs?\n\nIf you decline, you will need to add the rules yourself for anything to be reachable from another machine." 1; then
            PNX_MANAGE_FIREWALL="true"
            PNX_ALLOW_CIDR="$(pnx_input "${PNX_TITLE} — Firewall" \
                "Restrict access to a specific network?\n\nEnter a CIDR such as 192.168.1.0/24 to allow only that network, or leave blank to allow from anywhere." \
                "${PNX_ALLOW_CIDR}")"
        else
            PNX_MANAGE_FIREWALL="false"
        fi
    else
        PNX_MANAGE_FIREWALL="false"
    fi
}

# --- Interview: local mode ----------------------------------------------
pnx_ask_stack_flavour() {
    local stack what="$1"
    stack="$(pnx_menu "${PNX_TITLE} — Flavour" \
        "How should ${what} be installed on this device?" \
        "native" "Native packages — lighter, matches PiNodeXMR's style" \
        "docker" "Docker containers — isolated, easier to remove")"
    PNX_LOCAL_STACK="${stack:-native}"

    if [ "${PNX_LOCAL_STACK}" = "docker" ] && ! command -v docker >/dev/null 2>&1; then
        pnx_yesno "${PNX_TITLE} — Flavour" \
            "Docker is not installed on this device.\n\nThe installer can install Docker Engine from get.docker.com. On a Raspberry Pi this takes several minutes and uses a few hundred MB.\n\nContinue with the Docker flavour?" 1 || PNX_LOCAL_STACK="native"
    fi
}

pnx_ask_grafana() {
    PNX_GRAFANA_PORT="$(pnx_prompt_port "${PNX_TITLE} — Grafana" \
        "Which port should Grafana listen on?\n\n3000 is Grafana's default and does not clash with PiNodeXMR's own ports (80, 18081, 18083, 18089)." \
        "${PNX_GRAFANA_PORT}")"

    local bind
    bind="$(pnx_menu "${PNX_TITLE} — Grafana" \
        "Who should be able to reach the Grafana web interface?" \
        "0.0.0.0"   "Any machine on the network (typical home LAN use)" \
        "127.0.0.1" "This device only — reach it via SSH tunnel, VPN or Tor")"
    PNX_GRAFANA_BIND="${bind:-0.0.0.0}"

    # Admin password. Required on a fresh install so no device is left on
    # Grafana's admin/admin default.
    local p1 p2
    while true; do
        p1="$(pnx_password "${PNX_TITLE} — Grafana" "Set the Grafana admin password (user: ${PNX_GRAFANA_ADMIN_USER}).\n\nLeave blank to keep the existing password if Grafana is already installed.")"
        if [ -z "${p1}" ]; then
            if [ -n "${PNX_GRAFANA_ADMIN_PASS}" ] || dpkg -s grafana >/dev/null 2>&1 || \
               [ -f "${PNX_DOCKER_DIR}/secrets/grafana_admin_password" ] || [ "${PNX_ASSUME_YES}" = "1" ]; then
                break
            fi
            pnx_msgbox "${PNX_TITLE} — Grafana" "A password is required for a new Grafana installation.\n\nOtherwise Grafana would be left on its admin/admin default, reachable by anyone who can see the port."
            continue
        fi
        if [ "${#p1}" -lt 8 ]; then
            pnx_msgbox "${PNX_TITLE} — Grafana" "Grafana requires a password of at least 8 characters."
            continue
        fi
        p2="$(pnx_password "${PNX_TITLE} — Grafana" "Confirm the admin password:")"
        if [ "${p1}" != "${p2}" ]; then
            pnx_msgbox "${PNX_TITLE} — Grafana" "The passwords did not match. Please try again."
            continue
        fi
        PNX_GRAFANA_ADMIN_PASS="${p1}"
        break
    done
}

# Where should the local Grafana read its data from? Only asked when Grafana
# runs here but the database does not (viewer topology).
pnx_ask_datasource() {
    local url
    while true; do
        url="$(pnx_input "${PNX_TITLE} — Datasource" \
            "URL of your existing Prometheus-compatible database, as reachable FROM THIS DEVICE.\n\nAny Prometheus query API works: Prometheus, Mimir, VictoriaMetrics, Thanos Query.\n\nExamples:\n  http://192.168.1.10:9090\n  https://prometheus.lab.local\n  http://victoriametrics.lab.local:8428" \
            "${PNX_GRAFANA_DS_URL}")"
        if pnx_is_url "${url}"; then
            PNX_GRAFANA_DS_URL="${url}"
            break
        fi
        pnx_msgbox "${PNX_TITLE} — Datasource" "'${url}' is not a valid http:// or https:// URL."
    done

    if pnx_yesno "${PNX_TITLE} — Datasource" \
        "Does that database require a username and password?\n\n(Prometheus behind a reverse proxy, VictoriaMetrics auth, and similar.)" 0; then
        PNX_GRAFANA_DS_AUTH="basic"
        PNX_GRAFANA_DS_USER="$(pnx_input "${PNX_TITLE} — Datasource" "Username for the database:" "${PNX_GRAFANA_DS_USER}")"
        local dp
        dp="$(pnx_password "${PNX_TITLE} — Datasource" "Password for '${PNX_GRAFANA_DS_USER}':")"
        [ -n "${dp}" ] && PNX_GRAFANA_DS_PASS="${dp}"
    else
        PNX_GRAFANA_DS_AUTH="none"
    fi

    if [[ "${PNX_GRAFANA_DS_URL}" == https://* ]]; then
        if pnx_yesno "${PNX_TITLE} — Datasource" \
            "Does that endpoint use a self-signed or otherwise untrusted TLS certificate?\n\nAnswer No unless you know it does." 0; then
            PNX_GRAFANA_DS_INSECURE="true"
        else
            PNX_GRAFANA_DS_INSECURE="false"
        fi
    fi

    # Probe it now so a typo surfaces here, not as an empty dashboard later.
    local probe="${PNX_GRAFANA_DS_URL%/}/api/v1/query?query=up"
    local -a args=(-sf --max-time 8)
    [ "${PNX_GRAFANA_DS_INSECURE}" = "true" ] && args+=(-k)
    [ "${PNX_GRAFANA_DS_AUTH}" = "basic" ] && args+=(-u "${PNX_GRAFANA_DS_USER}:${PNX_GRAFANA_DS_PASS}")
    if curl "${args[@]}" "${probe}" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
        pnx_msgbox "${PNX_TITLE} — Datasource" "Connected to the database successfully."
    else
        pnx_yesno "${PNX_TITLE} — Datasource" \
            "Could not query ${PNX_GRAFANA_DS_URL} from this device.\n\nThat may just mean it is unreachable right now, or does not allow queries from here yet.\n\nContinue anyway?" 1 || exit 0
    fi
}

# EXPOSED=1 means something off this device must query Prometheus (backend
# topology), so binding to the network is the default rather than the option.
pnx_ask_prometheus() {
    local exposed="${1:-0}"

    PNX_PROM_RETENTION="$(pnx_input "${PNX_TITLE} — Prometheus" \
        "How long should metrics history be kept?\n\nExamples: 15d, 30d, 90d, 1y.\n\nOn an SD card, keeping this modest protects the card's lifespan." \
        "${PNX_PROM_RETENTION}")"
    PNX_PROM_RETENTION_SIZE="$(pnx_input "${PNX_TITLE} — Prometheus" \
        "Maximum on-disk size for the metrics database?\n\nExamples: 512MB, 2GB, 10GB. Whichever limit is hit first — time or size — wins." \
        "${PNX_PROM_RETENTION_SIZE}")"

    if [ "${exposed}" = "1" ]; then
        PNX_PROM_PORT="$(pnx_prompt_port "${PNX_TITLE} — Prometheus" \
            "Which port should Prometheus serve queries on?\n\nYour existing Grafana will use this as its datasource port." \
            "${PNX_PROM_PORT}")"
        local bind
        bind="$(pnx_menu "${PNX_TITLE} — Prometheus" \
            "Your Grafana elsewhere must be able to query this Prometheus.\n\nWho may reach it?" \
            "0.0.0.0"   "Any machine on the network (required unless you tunnel)" \
            "127.0.0.1" "This device only — you will reach it via SSH tunnel or VPN")"
        PNX_PROM_BIND="${bind:-0.0.0.0}"
    else
        if pnx_yesno "${PNX_TITLE} — Prometheus" \
            "Should the Prometheus web interface (port ${PNX_PROM_PORT}) also be reachable from the network?\n\nGrafana talks to Prometheus over loopback regardless, so answering No is the safer choice and still gives you a working dashboard." 0; then
            PNX_PROM_BIND="0.0.0.0"
        else
            PNX_PROM_BIND="127.0.0.1"
        fi
    fi
}

# --- Interview: agent mode ----------------------------------------------
pnx_ask_agent() {
    local t
    t="$(pnx_menu "${PNX_TITLE} — Agent" \
        "How should this device get its metrics to your monitoring stack?" \
        "push" "Push out (remote_write) — works from behind NAT/firewalls" \
        "pull" "Be scraped — your Prometheus connects in to this device" \
        "both" "Both push and allow scraping")"
    PNX_AGENT_TRANSPORT="${t:-push}"

    case "${PNX_AGENT_TRANSPORT}" in
        pull|both)
            PNX_NODE_EXPORTER_BIND="0.0.0.0"
            PNX_NODE_EXPORTER_PORT="$(pnx_prompt_port "${PNX_TITLE} — Agent" \
                "Which port should node_exporter listen on for your Prometheus to scrape?" \
                "${PNX_NODE_EXPORTER_PORT}")"
            ;;
        *)
            PNX_NODE_EXPORTER_BIND="127.0.0.1"
            ;;
    esac

    case "${PNX_AGENT_TRANSPORT}" in
        push|both)
            local url
            while true; do
                url="$(pnx_input "${PNX_TITLE} — Agent" \
                    "Remote write endpoint URL.\n\nExamples:\n  http://prom.example.com:9090/api/v1/write\n  https://mimir.example.com/api/v1/push\n  Grafana Cloud: https://prometheus-<region>.grafana.net/api/prom/push" \
                    "${PNX_REMOTE_WRITE_URL}")"
                if pnx_is_url "${url}"; then
                    PNX_REMOTE_WRITE_URL="${url}"
                    break
                fi
                pnx_msgbox "${PNX_TITLE} — Agent" "'${url}' is not a valid http:// or https:// URL."
            done

            local auth
            auth="$(pnx_menu "${PNX_TITLE} — Agent" \
                "How does that endpoint authenticate?" \
                "basic"  "Username and password (Grafana Cloud uses this)" \
                "bearer" "Bearer token / API key" \
                "none"   "No authentication")"
            PNX_REMOTE_WRITE_AUTH="${auth:-none}"

            case "${PNX_REMOTE_WRITE_AUTH}" in
                basic)
                    PNX_REMOTE_WRITE_USER="$(pnx_input "${PNX_TITLE} — Agent" \
                        "Username.\n\nFor Grafana Cloud this is your numeric instance ID." "${PNX_REMOTE_WRITE_USER}")"
                    local rp
                    rp="$(pnx_password "${PNX_TITLE} — Agent" "Password or API token:")"
                    [ -n "${rp}" ] && PNX_REMOTE_WRITE_PASS="${rp}"
                    ;;
                bearer)
                    local rt
                    rt="$(pnx_password "${PNX_TITLE} — Agent" "Bearer token:")"
                    [ -n "${rt}" ] && PNX_REMOTE_WRITE_TOKEN="${rt}"
                    ;;
            esac

            if [[ "${PNX_REMOTE_WRITE_URL}" == https://* ]]; then
                if pnx_yesno "${PNX_TITLE} — Agent" \
                    "Does that endpoint use a self-signed or otherwise untrusted TLS certificate?\n\nAnswer No unless you know it does — skipping verification exposes your credentials to interception." 0; then
                    PNX_REMOTE_WRITE_INSECURE="true"
                else
                    PNX_REMOTE_WRITE_INSECURE="false"
                fi
            fi
            ;;
    esac
}

# --- Interview driver ----------------------------------------------------
pnx_interview() {
    local topo
    topo="$(pnx_menu "${PNX_TITLE}" \
        "Where should each piece run?\n\nMetrics collection always runs on this device; Grafana (the dashboard) and Prometheus (the database) can each live here or elsewhere." \
        "full"    "Everything on this device (Grafana + Prometheus)" \
        "backend" "Database here — I already have Grafana elsewhere" \
        "viewer"  "Grafana here — I already have a database elsewhere" \
        "agent"   "Neither — just report metrics to a stack elsewhere")"

    case "${topo:-full}" in
        full)    PNX_INSTALL_PROMETHEUS="true";  PNX_INSTALL_GRAFANA="true"  ;;
        backend) PNX_INSTALL_PROMETHEUS="true";  PNX_INSTALL_GRAFANA="false" ;;
        viewer)  PNX_INSTALL_PROMETHEUS="false"; PNX_INSTALL_GRAFANA="true"  ;;
        agent)   PNX_INSTALL_PROMETHEUS="false"; PNX_INSTALL_GRAFANA="false" ;;
    esac

    pnx_ask_instance_name
    pnx_ask_rpc
    pnx_ask_interval

    case "${topo:-full}" in
        full)
            pnx_ask_stack_flavour "Prometheus and Grafana"
            pnx_ask_grafana
            PNX_GRAFANA_DS_URL=""   # dashboard reads the local Prometheus
            pnx_ask_prometheus 0
            PNX_NODE_EXPORTER_BIND="127.0.0.1"
            ;;
        backend)
            pnx_ask_stack_flavour "Prometheus"
            pnx_ask_prometheus 1
            PNX_NODE_EXPORTER_BIND="127.0.0.1"
            ;;
        viewer)
            pnx_ask_stack_flavour "Grafana"
            pnx_ask_grafana
            pnx_ask_datasource
            # The remote database still needs this device's metrics.
            pnx_msgbox "${PNX_TITLE}" \
                "Grafana here will read from your existing database — but that database also needs to RECEIVE this device's metrics.\n\nNext, choose how the metrics get there (push works from behind NAT; pull means your database's Prometheus scrapes this device)."
            pnx_ask_agent
            ;;
        agent)
            pnx_ask_agent
            ;;
    esac

    pnx_ask_firewall

    pnx_yesno "${PNX_TITLE} — Confirm" \
        "About to install with these settings:\n\n$(pnx_config_summary)\nProceed?" 1 || {
        pnx_info "Cancelled by user at the confirmation step"
        exit 0
    }
}

# --- Execution -----------------------------------------------------------
pnx_do_install() {
    pnx_config_save

    pnx_info "--- Step 1/4: node_exporter ---"
    pnx_node_exporter_setup || pnx_die "node_exporter setup failed."
    # The node_exporter step may have adopted a different textfile directory.
    pnx_config_save

    pnx_info "--- Step 2/4: monerod exporter ---"
    pnx_exporter_install || pnx_die "monerod exporter installation failed."

    pnx_info "--- Step 3/4: metrics pipeline ---"
    pnx_ne_verify || pnx_warn "node_exporter is not answering yet; continuing"
    pnx_exporter_verify
    local exporter_state=$?

    pnx_info "--- Step 4/4: $(pnx_mode_name) ---"

    # Local components, if any (each installer honours the two switches).
    if [ "${PNX_INSTALL_PROMETHEUS}" = "true" ] || [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
        case "${PNX_LOCAL_STACK}" in
            native) pnx_stack_native_install || pnx_die "Native stack installation failed." ;;
            docker) pnx_stack_docker_install || pnx_die "Docker stack installation failed." ;;
        esac
    fi

    # No database on this device means metrics must leave it — pull, push or
    # both, exactly as in pure agent setups.
    if [ "${PNX_INSTALL_PROMETHEUS}" != "true" ]; then
        pnx_agent_install || pnx_die "Metrics transport setup failed."
        case "${PNX_AGENT_TRANSPORT}" in
            push|both) pnx_agent_verify_push ;;
        esac
    fi

    # The Grafana admin password has been applied to Grafana's own database by
    # now, so drop the plaintext copy from the config file. (The Docker
    # flavour keeps it as a compose secret file instead.)
    if [ -n "${PNX_GRAFANA_ADMIN_PASS}" ] && [ "${PNX_INSTALL_GRAFANA}" = "true" ] && [ "${PNX_LOCAL_STACK}" = "native" ]; then
        PNX_GRAFANA_ADMIN_PASS=""
    fi
    pnx_config_save

    pnx_report "${exporter_state}"
}

pnx_report() {
    local exporter_state="${1:-0}"
    local ip msg
    ip="$(pnx_primary_ip)"
    msg="Installation complete — $(pnx_mode_name).\n\n"

    case "${exporter_state}" in
        0) msg+="monerod exporter: healthy, metrics flowing\n" ;;
        2) msg+="monerod exporter: running, but monerod RPC is unreachable.\n            It will recover automatically once monerod responds.\n" ;;
        *) msg+="monerod exporter: installed, no metrics observed yet\n" ;;
    esac

    # --- Grafana on this device ---
    if [ "${PNX_INSTALL_GRAFANA}" = "true" ]; then
        local host="${ip}"
        [ "${PNX_GRAFANA_BIND}" = "127.0.0.1" ] && host="127.0.0.1"
        msg+="\nGrafana:    http://${host}:${PNX_GRAFANA_PORT}\n"
        msg+="Login:      ${PNX_GRAFANA_ADMIN_USER} / (the password you set)\n"
        msg+="Dashboard:  already provisioned under the 'PiNodeXMR' folder —\n            no manual import or datasource picking needed.\n"
        if [ -n "${PNX_GRAFANA_DS_URL}" ]; then
            msg+="Datasource: ${PNX_GRAFANA_DS_URL}\n"
        fi
        if [ "${PNX_GRAFANA_BIND}" = "127.0.0.1" ]; then
            msg+="\nGrafana is bound to localhost. Reach it with:\n  ssh -L ${PNX_GRAFANA_PORT}:127.0.0.1:${PNX_GRAFANA_PORT} pinodexmr@${ip}\nthen browse to http://127.0.0.1:${PNX_GRAFANA_PORT}\n"
        fi
    fi

    # --- Prometheus on this device, dashboard elsewhere ---
    if [ "${PNX_INSTALL_PROMETHEUS}" = "true" ] && [ "${PNX_INSTALL_GRAFANA}" != "true" ]; then
        msg+="\nDatabase ready. In your existing Grafana:\n"
        msg+="  1. Add a Prometheus datasource:  http://${ip}:${PNX_PROM_PORT}\n"
        msg+="  2. Import dashboards/pinodexmr-dashboard.json and select it\n"
        if [ "${PNX_PROM_BIND}" = "127.0.0.1" ]; then
            msg+="\nNote: Prometheus is bound to localhost, so your Grafana will need\nan SSH tunnel or VPN to reach it:\n  ssh -L ${PNX_PROM_PORT}:127.0.0.1:${PNX_PROM_PORT} pinodexmr@${ip}\n"
        fi
        printf 'Add this datasource to your Grafana:\n  URL: http://%s:%s\n  Type: Prometheus\n\nThen import dashboards/pinodexmr-dashboard.json and pick it when asked.\n' \
            "${ip}" "${PNX_PROM_PORT}" > "${PNX_STATE_DIR}/remote-grafana-setup.txt"
        msg+="\nThese steps are also saved in:\n  ${PNX_STATE_DIR}/remote-grafana-setup.txt\n"
    fi

    # --- Metrics leaving the device (no local database) ---
    if [ "${PNX_INSTALL_PROMETHEUS}" != "true" ]; then
        msg+="\nMetrics transport: ${PNX_AGENT_TRANSPORT}\n"
        case "${PNX_AGENT_TRANSPORT}" in
            pull|both)
                msg+="\nScrape this device at:  ${ip}:${PNX_NODE_EXPORTER_PORT}\n"
                msg+="The scrape_config to add to your Prometheus has been written to:\n  ${PNX_STATE_DIR}/remote-scrape-config.yml\n"
                pnx_agent_pull_snippet > "${PNX_STATE_DIR}/remote-scrape-config.yml"
                ;;
        esac
        case "${PNX_AGENT_TRANSPORT}" in
            push|both)
                msg+="\nPushing to: ${PNX_REMOTE_WRITE_URL}\n"
                msg+="Check it with: journalctl -u prometheus-agent -f\n"
                ;;
        esac
        if [ "${PNX_INSTALL_GRAFANA}" != "true" ]; then
            msg+="\nImport dashboards/pinodexmr-dashboard.json into your remote Grafana\nand point it at the database receiving these metrics.\n"
        fi
    fi

    msg+="\nConfig:  ${PNX_CONF_FILE}\nLog:     ${PNX_LOG_FILE}\nStatus:  sudo ${PNX_SRC_DIR}/install.sh --status\n"

    pnx_msgbox "${PNX_TITLE}" "${msg}"
    printf '\n%b\n' "${msg}"
}

# --- Status --------------------------------------------------------------
pnx_status() {
    pnx_config_load
    local out=""
    out+="PiNodeXMR monitoring status\n"
    out+="===========================\n\n"

    if [ ! -f "${PNX_CONF_FILE}" ]; then
        out+="Not installed — no config at ${PNX_CONF_FILE}\n"
        printf '%b\n' "${out}"
        return 0
    fi

    out+="$(pnx_config_summary)\n"
    out+="\nServices:\n"

    local unit
    for unit in monerod-exporter.service node_exporter.service prometheus-node-exporter.service prometheus.service prometheus-agent.service grafana-server.service; do
        if pnx_service_exists "${unit}"; then
            if pnx_service_active "${unit}"; then
                out+="  [ active ] ${unit}\n"
            else
                out+="  [ DOWN   ] ${unit}\n"
            fi
        fi
    done

    if { [ "${PNX_INSTALL_PROMETHEUS}" = "true" ] || [ "${PNX_INSTALL_GRAFANA}" = "true" ]; } && [ "${PNX_LOCAL_STACK}" = "docker" ]; then
        out+="\nContainers:\n"
        local c
        c="$( (cd "${PNX_DOCKER_DIR}" 2>/dev/null && pnx_compose ps --format '  {{.Name}}: {{.State}}' 2>/dev/null) )"
        out+="${c:-  (compose project not found)}\n"
    fi

    out+="\nMetrics:\n"
    local prom_file="${PNX_TEXTFILE_DIR}/monerod.prom"
    if [ -f "${prom_file}" ]; then
        local up height age
        up="$(awk '/^monerod_up /{print $2}' "${prom_file}")"
        height="$(awk '/^monerod_height /{print $2}' "${prom_file}")"
        age=$(( $(date +%s) - $(stat -c %Y "${prom_file}" 2>/dev/null || echo 0) ))
        out+="  monerod_up:     ${up:-?}\n"
        out+="  monerod_height: ${height:-?}\n"
        out+="  last written:   ${age}s ago\n"
    else
        out+="  No metrics file at ${prom_file}\n"
    fi

    if curl -sf --max-time 5 "http://127.0.0.1:${PNX_NODE_EXPORTER_PORT}/metrics" 2>/dev/null | grep -q '^monerod_'; then
        out+="  node_exporter is serving monerod_* metrics on :${PNX_NODE_EXPORTER_PORT}\n"
    else
        out+="  node_exporter is NOT serving monerod_* metrics on :${PNX_NODE_EXPORTER_PORT}\n"
    fi

    printf '%b\n' "${out}"
}

# --- Main ----------------------------------------------------------------
main() {
    local action="install"

    while [ $# -gt 0 ]; do
        case "$1" in
            --unattended|-y) PNX_ASSUME_YES=1 ;;
            --status)        action="status" ;;
            --uninstall)     action="uninstall" ;;
            --help|-h)       usage; exit 0 ;;
            *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 1 ;;
        esac
        shift
    done

    case "${action}" in
        status)
            pnx_status
            exit 0
            ;;
        uninstall)
            exec "${PNX_SRC_DIR}/uninstall.sh"
            ;;
    esac

    pnx_preflight
    pnx_config_load

    # Offer a shortcut when this is a re-run over an existing install.
    if [ -f "${PNX_CONF_FILE}" ] && [ "${PNX_ASSUME_YES}" != "1" ]; then
        local choice
        choice="$(pnx_menu "${PNX_TITLE}" \
            "Monitoring is already configured on this device.\n\nWhat would you like to do?" \
            "reconfigure" "Change settings and reinstall" \
            "repair"      "Reinstall with the current settings" \
            "status"      "Show current status" \
            "uninstall"   "Remove the monitoring add-on" \
            "cancel"      "Exit without changes")"
        case "${choice}" in
            status)    pnx_status; exit 0 ;;
            uninstall) exec "${PNX_SRC_DIR}/uninstall.sh" ;;
            cancel|"") exit 0 ;;
            repair)    pnx_do_install; exit 0 ;;
        esac
    fi

    if [ "${PNX_ASSUME_YES}" = "1" ]; then
        pnx_info "Unattended mode: using existing configuration and defaults"
    else
        pnx_interview
    fi

    pnx_do_install
}

main "$@"
