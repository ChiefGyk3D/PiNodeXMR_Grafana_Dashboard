#!/bin/bash
# lib/common.sh — Shared helpers for the PiNodeXMR monitoring installer.
#
# Sourced by install.sh, uninstall.sh and every lib/*.sh module.
# Provides: logging, whiptail wrappers (with a non-interactive fallback),
# architecture detection, network/port checks and small utilities.

# --- Guard against double-sourcing ---
[ -n "${PNX_COMMON_SOURCED:-}" ] && return 0
PNX_COMMON_SOURCED=1

# --- Paths ---------------------------------------------------------------
PNX_CONF_DIR="${PNX_CONF_DIR:-/etc/pinodexmr-monitoring}"
PNX_CONF_FILE="${PNX_CONF_FILE:-${PNX_CONF_DIR}/config.env}"
PNX_STATE_DIR="${PNX_STATE_DIR:-/var/lib/pinodexmr-monitoring}"
PNX_LOG_FILE="${PNX_LOG_FILE:-/var/log/pinodexmr-monitoring-install.log}"

# Repository root (directory containing install.sh), resolved by the caller.
PNX_SRC_DIR="${PNX_SRC_DIR:-}"

# --- Interactivity -------------------------------------------------------
# PNX_ASSUME_YES=1 makes every prompt take its default, so the installer can
# run unattended (CI, cloud-init, or `install.sh --unattended`).
PNX_ASSUME_YES="${PNX_ASSUME_YES:-0}"

pnx_have_whiptail() {
    [ "${PNX_ASSUME_YES}" = "1" ] && return 1
    command -v whiptail >/dev/null 2>&1 || return 1
    [ -t 0 ] || return 1
    return 0
}

# --- Logging -------------------------------------------------------------
pnx_log() {
    local level="$1"; shift
    local msg="$*"
    local line
    line="$(date -Iseconds) [${level}] ${msg}"
    # Best-effort file logging; never fail the install because logging failed.
    if [ -w "$(dirname "${PNX_LOG_FILE}")" ] 2>/dev/null; then
        printf '%s\n' "${line}" >> "${PNX_LOG_FILE}" 2>/dev/null || true
    fi
    printf '%s\n' "${line}" >&2
}

pnx_info()  { pnx_log INFO  "$@"; }
pnx_warn()  { pnx_log WARN  "$@"; }
pnx_error() { pnx_log ERROR "$@"; }

pnx_die() {
    pnx_error "$@"
    pnx_msgbox "Installation error" "$*\n\nSee ${PNX_LOG_FILE} for details."
    exit 1
}

# --- Whiptail wrappers ---------------------------------------------------
# Each falls back to plain stdio (or the default) when whiptail is absent or
# we are running unattended.

# pnx_msgbox TITLE TEXT
pnx_msgbox() {
    local title="$1" text="$2"
    if pnx_have_whiptail; then
        whiptail --title "${title}" --msgbox "${text}" 20 78
    else
        printf '\n=== %s ===\n%b\n' "${title}" "${text}"
    fi
}

# pnx_yesno TITLE TEXT [DEFAULT_YES]
# Returns 0 for yes, 1 for no. Unattended runs take DEFAULT_YES (default: yes).
pnx_yesno() {
    local title="$1" text="$2" default_yes="${3:-1}"
    if pnx_have_whiptail; then
        if [ "${default_yes}" = "1" ]; then
            whiptail --title "${title}" --yesno "${text}" 20 78
        else
            whiptail --title "${title}" --yesno --defaultno "${text}" 20 78
        fi
        return $?
    fi
    if [ "${PNX_ASSUME_YES}" = "1" ]; then
        [ "${default_yes}" = "1" ] && return 0 || return 1
    fi
    local reply
    printf '\n=== %s ===\n%b\n' "${title}" "${text}"
    read -r -p "Continue? [y/N] " reply
    case "${reply}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# pnx_input TITLE TEXT DEFAULT -> echoes the value
pnx_input() {
    local title="$1" text="$2" default="$3" value
    if pnx_have_whiptail; then
        value=$(whiptail --title "${title}" --inputbox "${text}" 20 78 "${default}" 3>&1 1>&2 2>&3) || value="${default}"
    elif [ "${PNX_ASSUME_YES}" = "1" ]; then
        value="${default}"
    else
        printf '\n=== %s ===\n%b\n' "${title}" "${text}" >&2
        read -r -p "Value [${default}]: " value
    fi
    printf '%s' "${value:-${default}}"
}

# pnx_password TITLE TEXT -> echoes the value (never echoed to the terminal)
pnx_password() {
    local title="$1" text="$2" value
    if pnx_have_whiptail; then
        value=$(whiptail --title "${title}" --passwordbox "${text}" 20 78 3>&1 1>&2 2>&3) || value=""
    elif [ "${PNX_ASSUME_YES}" = "1" ]; then
        value=""
    else
        printf '\n=== %s ===\n%b\n' "${title}" "${text}" >&2
        read -r -s -p "Value (hidden): " value
        printf '\n' >&2
    fi
    printf '%s' "${value}"
}

# pnx_menu TITLE TEXT TAG1 ITEM1 [TAG2 ITEM2 ...] -> echoes the chosen tag
# Unattended runs pick the first tag.
pnx_menu() {
    local title="$1" text="$2"; shift 2
    if pnx_have_whiptail; then
        whiptail --title "${title}" --menu "${text}" 22 78 10 "$@" 3>&1 1>&2 2>&3
        return $?
    fi
    if [ "${PNX_ASSUME_YES}" = "1" ]; then
        printf '%s' "$1"
        return 0
    fi
    printf '\n=== %s ===\n%b\n' "${title}" "${text}" >&2
    local i=1 tag desc
    local -a tags=()
    while [ $# -gt 0 ]; do
        tag="$1"; desc="$2"; shift 2
        tags+=("${tag}")
        printf '  %d) %s — %s\n' "${i}" "${tag}" "${desc}" >&2
        i=$((i + 1))
    done
    local choice
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"
    printf '%s' "${tags[$((choice - 1))]}"
}

# --- Privileges ----------------------------------------------------------
pnx_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        pnx_error "This installer must run as root (try: sudo $0)"
        exit 1
    fi
}

# --- Architecture --------------------------------------------------------
# Echoes the Prometheus/Grafana release suffix for this machine.
pnx_arch() {
    local m
    m="$(uname -m)"
    case "${m}" in
        x86_64|amd64)         printf 'amd64' ;;
        aarch64|arm64)        printf 'arm64' ;;
        armv7l|armv7|armhf)   printf 'armv7' ;;
        armv6l)               printf 'armv6' ;;
        i386|i686)            printf '386'   ;;
        riscv64)              printf 'riscv64' ;;
        *)                    printf '%s' "${m}" ;;
    esac
}

# Debian package architecture (Grafana APT repo naming).
pnx_deb_arch() {
    local a
    a="$(pnx_arch)"
    case "${a}" in
        armv7|armv6) printf 'armhf' ;;
        386)         printf 'i386'  ;;
        *)           printf '%s' "${a}" ;;
    esac
}

# --- Validation ----------------------------------------------------------
pnx_is_port() {
    local p="$1"
    [[ "${p}" =~ ^[0-9]+$ ]] || return 1
    [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ]
}

# True (0) when the TCP port is already bound by something else.
pnx_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -Hltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
        return 1
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && return 0
        return 1
    fi
    # No tooling available — assume free rather than blocking the install.
    return 1
}

# Prompt for a port, re-prompting while it is invalid or occupied.
# pnx_prompt_port TITLE TEXT DEFAULT [ALLOW_IN_USE]
pnx_prompt_port() {
    local title="$1" text="$2" default="$3" allow_in_use="${4:-0}"
    local port
    while true; do
        port="$(pnx_input "${title}" "${text}" "${default}")"
        if ! pnx_is_port "${port}"; then
            pnx_msgbox "${title}" "'${port}' is not a valid TCP port (1-65535). Please try again."
            continue
        fi
        if [ "${allow_in_use}" != "1" ] && pnx_port_in_use "${port}"; then
            if pnx_yesno "${title}" "Port ${port} is already in use on this device.\n\nUse it anyway?" 0; then
                break
            fi
            continue
        fi
        break
    done
    printf '%s' "${port}"
}

pnx_is_url() {
    [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

# --- Systemd -------------------------------------------------------------
pnx_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

pnx_service_exists() {
    systemctl list-unit-files "$1" >/dev/null 2>&1 && \
        systemctl cat "$1" >/dev/null 2>&1
}

pnx_service_active() {
    systemctl is-active --quiet "$1"
}

# Enable + (re)start a unit, reporting failure with recent logs.
pnx_service_enable_start() {
    local unit="$1"
    systemctl daemon-reload
    systemctl enable "${unit}" >/dev/null 2>&1 || true
    if ! systemctl restart "${unit}"; then
        pnx_error "Failed to start ${unit}"
        journalctl -u "${unit}" -n 20 --no-pager >&2 2>/dev/null || true
        return 1
    fi
    return 0
}

# --- Package management --------------------------------------------------
pnx_apt_update_once() {
    if [ -z "${PNX_APT_UPDATED:-}" ]; then
        pnx_info "Refreshing APT package lists"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || \
            pnx_warn "apt-get update reported errors; continuing"
        PNX_APT_UPDATED=1
    fi
}

# pnx_apt_install pkg [pkg...] — installs only what is missing.
pnx_apt_install() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    pnx_apt_update_once
    pnx_info "Installing packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || {
        pnx_error "Failed to install: ${missing[*]}"
        return 1
    }
}

# --- Download ------------------------------------------------------------
# pnx_download URL DEST — curl or wget, whichever exists.
pnx_download() {
    local url="$1" dest="$2"
    pnx_info "Downloading ${url}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${url}" && return 0
    elif command -v wget >/dev/null 2>&1; then
        wget -q -t 3 -O "${dest}" "${url}" && return 0
    else
        pnx_error "Neither curl nor wget is available"
        return 1
    fi
    pnx_error "Download failed: ${url}"
    return 1
}

# --- Misc ----------------------------------------------------------------
# Quote a value for a YAML single-quoted scalar: the only escape that form
# needs is doubling any embedded single quote.
pnx_yaml_squote() {
    local v="$1"
    printf "'%s'" "${v//\'/\'\'}"
}

pnx_backup_file() {
    local f="$1"
    [ -f "${f}" ] || return 0
    local bak
    bak="${f}.pnx-bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${f}" "${bak}" && pnx_info "Backed up ${f} -> ${bak}"
}

pnx_ensure_user() {
    local user="$1"
    id -u "${user}" >/dev/null 2>&1 && return 0
    pnx_info "Creating system user ${user}"
    useradd --system --no-create-home --shell /usr/sbin/nologin "${user}"
}

pnx_primary_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

# Templates may carry optional sections fenced by "#@@BEGIN:NAME@@" and
# "#@@END:NAME@@" lines. pnx_strip_section removes every such section from a
# rendered file; pnx_keep_sections removes only the marker lines, keeping the
# content. A section name may appear more than once in one file.
pnx_strip_section() {
    local file="$1" name="$2"
    sed -i "/^#@@BEGIN:${name}@@\$/,/^#@@END:${name}@@\$/d" "${file}"
}

pnx_clear_section_markers() {
    local file="$1"
    sed -i '/^#@@\(BEGIN\|END\):[A-Z_]*@@$/d' "${file}"
}

# Render a .tmpl file to a destination, substituting only @@NAME@@ markers.
# Safer than envsubst: it cannot mangle YAML/JSON containing $ characters.
# pnx_render TEMPLATE DEST KEY=VALUE [KEY=VALUE ...]
pnx_render() {
    local tmpl="$1" dest="$2"; shift 2
    [ -f "${tmpl}" ] || { pnx_error "Template not found: ${tmpl}"; return 1; }
    local tmp
    tmp="$(mktemp)"
    cp "${tmpl}" "${tmp}"
    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        # Escape characters that are special on the replacement side of sed.
        value="${value//\\/\\\\}"
        value="${value//&/\\&}"
        value="${value//|/\\|}"
        value="$(printf '%s' "${value}" | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}')"
        sed -i "s|@@${key}@@|${value}|g" "${tmp}"
    done
    mkdir -p "$(dirname "${dest}")"
    mv "${tmp}" "${dest}"
}

# --- Firewall ------------------------------------------------------------
# Best-effort ufw rules. Only ever called when PNX_MANAGE_FIREWALL=true, and
# never fatal: a monitoring installer should not lock anyone out of a device.
# pnx_firewall_allow PORT [COMMENT]
pnx_firewall_allow() {
    local port="$1" comment="${2:-pinodexmr-monitoring}"
    [ "${PNX_MANAGE_FIREWALL}" = "true" ] || return 0
    command -v ufw >/dev/null 2>&1 || { pnx_warn "ufw not installed; skipping firewall rule for ${port}"; return 0; }
    ufw status 2>/dev/null | grep -q '^Status: active' || {
        pnx_warn "ufw is installed but inactive; skipping firewall rule for ${port}"
        return 0
    }
    if [ -n "${PNX_ALLOW_CIDR}" ]; then
        pnx_info "ufw: allowing ${PNX_ALLOW_CIDR} -> ${port}/tcp"
        ufw allow from "${PNX_ALLOW_CIDR}" to any port "${port}" proto tcp comment "${comment}" >/dev/null 2>&1 \
            || pnx_warn "ufw rule failed for ${port}"
    else
        pnx_info "ufw: allowing ${port}/tcp from anywhere"
        ufw allow "${port}/tcp" comment "${comment}" >/dev/null 2>&1 \
            || pnx_warn "ufw rule failed for ${port}"
    fi
}

pnx_firewall_delete() {
    local port="$1"
    command -v ufw >/dev/null 2>&1 || return 0
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    [ -n "${PNX_ALLOW_CIDR}" ] && ufw delete allow from "${PNX_ALLOW_CIDR}" to any port "${port}" proto tcp >/dev/null 2>&1 || true
    return 0
}
