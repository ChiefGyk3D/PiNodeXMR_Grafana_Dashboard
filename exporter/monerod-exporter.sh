#!/bin/bash
# monerod-exporter.sh — Prometheus textfile collector for monerod RPC metrics.
#
# Polls the monerod JSON-RPC API on an interval and writes Prometheus-formatted
# metrics to node_exporter's textfile collector directory, where node_exporter
# serves them alongside the usual host metrics.
#
# Configuration comes from /etc/pinodexmr-monitoring/config.env (written by
# install.sh). Every value has a built-in default, so the script also runs
# standalone on a plain monerod host with no config file at all.
#
# Docs: https://github.com/ChiefGyk3D/PiNodeXMR_Grafana_Dashboard

set -uo pipefail

PNX_CONF_FILE="${PNX_CONF_FILE:-/etc/pinodexmr-monitoring/config.env}"

# --- Defaults (overridden by the config file) ----------------------------
PNX_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PNX_EXPORTER_INTERVAL=30
PNX_RPC_FROM_PINODEXMR="true"
PNX_PINODEXMR_VAR_DIR="/home/pinodexmr/variables"
PNX_RPC_HOST="127.0.0.1"
PNX_RPC_PORT="18081"
PNX_RPC_USER=""
PNX_RPC_PASS=""
PNX_RPC_AUTH="digest"

MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
FAILURE_SLEEP="${FAILURE_SLEEP:-10}"

# Read a single KEY=value assignment from a PiNodeXMR variable file WITHOUT
# executing it. These files live in /home/pinodexmr/variables and are writable
# by the pinodexmr service account; sourcing them would run whatever they
# contain, so we extract just the value we asked for. Handles optional single
# or double quotes and ignores comments.
read_var_file() {
    local file="$1" key="$2"
    [ -r "${file}" ] || return 1
    sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${key}=[\"']?([^\"'#]*)[\"']?.*/\2/p" "${file}" \
        | tail -n1 | sed -E 's/[[:space:]]+$//'
}

# --- Load configuration --------------------------------------------------
load_config() {
    if [ -r "${PNX_CONF_FILE}" ]; then
        # shellcheck disable=SC1090
        set -a; . "${PNX_CONF_FILE}"; set +a
    fi

    # PiNodeXMR mode: re-read the project's own variable files on every poll so
    # RPC credential and port changes made through the PiNodeXMR menus take
    # effect within one interval, with no restart and no duplicated config.
    # Parsed, never sourced — see read_var_file.
    if [ "${PNX_RPC_FROM_PINODEXMR}" = "true" ]; then
        RPC_USER="$(read_var_file "${PNX_PINODEXMR_VAR_DIR}/RPCu.sh" RPCu)"
        RPC_PASS="$(read_var_file "${PNX_PINODEXMR_VAR_DIR}/RPCp.sh" RPCp)"
        RPC_PORT="$(read_var_file "${PNX_PINODEXMR_VAR_DIR}/monero-port.sh" MONERO_PORT)"
        [ -z "${RPC_PORT}" ] && RPC_PORT="18081"
        # monerod binds the device's LAN address on PiNodeXMR, not loopback.
        RPC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
        [ -z "${RPC_HOST}" ] && RPC_HOST="127.0.0.1"
    else
        RPC_USER="${PNX_RPC_USER}"
        RPC_PASS="${PNX_RPC_PASS}"
        RPC_PORT="${PNX_RPC_PORT}"
        RPC_HOST="${PNX_RPC_HOST}"
    fi

    PROM_FILE="${PNX_TEXTFILE_DIR}/monerod.prom"
    TEMP_FILE="${PNX_TEXTFILE_DIR}/monerod.prom.$$.tmp"
    INTERVAL="${PNX_EXPORTER_INTERVAL}"
}

# --- Curl authentication -------------------------------------------------
# Emit a curl config file body carrying the credentials. Fed to curl via
# --config on a process-substitution FD, NEVER on the command line: argv is
# world-readable through /proc/<pid>/cmdline, and this is a long-running
# service that would otherwise expose the RPC credentials on every poll.
rpc_auth_config() {
    case "${PNX_RPC_AUTH}" in
        none) return 0 ;;
        basic) ;;
        *) printf 'digest\n' ;;
    esac
    # curl config double-quoted strings honour \" and \\ escapes; escape both
    # so a credential containing either character is passed intact.
    local u="${RPC_USER//\\/\\\\}" p="${RPC_PASS//\\/\\\\}"
    u="${u//\"/\\\"}"; p="${p//\"/\\\"}"
    printf 'user = "%s:%s"\n' "${u}" "${p}"
}

# rpc_call METHOD -> JSON on stdout; non-zero on transport failure.
rpc_call() {
    local method="$1"
    curl -sf --max-time 10 --config <(rpc_auth_config) \
        -X POST "http://${RPC_HOST}:${RPC_PORT}/json_rpc" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"${method}\"}" \
        -H 'Content-Type: application/json' 2>/dev/null
}

# rpc_get PATH -> JSON on stdout (non-json_rpc endpoints such as pool stats).
rpc_get() {
    local path="$1"
    curl -sf --max-time 10 --config <(rpc_auth_config) \
        "http://${RPC_HOST}:${RPC_PORT}/${path}" \
        -H 'Content-Type: application/json' 2>/dev/null
}

# --- SoC temperature -----------------------------------------------------
# thermal_zone0 is not always the CPU (or present at all) on every SBC, so
# prefer a zone whose type looks like a CPU/SoC sensor and fall back sensibly.
read_cpu_temp() {
    local zone type temp
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "${zone}/temp" ] || continue
        type="$(cat "${zone}/type" 2>/dev/null)"
        case "${type}" in
            *cpu*|*CPU*|*soc*|*SOC*|*x86_pkg*)
                temp="$(cat "${zone}/temp" 2>/dev/null)"
                [ -n "${temp}" ] && awk -v t="${temp}" 'BEGIN{printf "%.1f", t/1000}' && return 0
                ;;
        esac
    done
    # Fall back to the first readable zone.
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "${zone}/temp" ] || continue
        temp="$(cat "${zone}/temp" 2>/dev/null)"
        [ -n "${temp}" ] && awk -v t="${temp}" 'BEGIN{printf "%.1f", t/1000}' && return 0
    done
    printf '0'
}

# --- Write a failure-state metrics file ----------------------------------
write_down_metrics() {
    local reason="$1"
    cat > "${TEMP_FILE}" <<EOF
# HELP monerod_up Whether monerod RPC is reachable (1=up, 0=down).
# TYPE monerod_up gauge
monerod_up 0
# HELP monerod_exporter_consecutive_failures Consecutive RPC failures.
# TYPE monerod_exporter_consecutive_failures gauge
monerod_exporter_consecutive_failures ${FAIL_COUNT}
# HELP monerod_exporter_last_scrape_timestamp_seconds Unix time of the last scrape attempt.
# TYPE monerod_exporter_last_scrape_timestamp_seconds gauge
monerod_exporter_last_scrape_timestamp_seconds $(date +%s)
# ${reason}
EOF
    mv -f "${TEMP_FILE}" "${PROM_FILE}"
}

write_metrics() {
    local scrape_start scrape_end scrape_duration
    scrape_start="$(date +%s.%N)"

    local info
    info=$(rpc_call get_info) || {
        write_down_metrics "monerod RPC unreachable at $(date -Iseconds)"
        return 1
    }

    # Guard against partial/invalid responses during monerod startup.
    if ! printf '%s' "${info}" | jq -e '.result' >/dev/null 2>&1; then
        echo "monerod-exporter: invalid/partial JSON from RPC at $(date -Iseconds)" >&2
        write_down_metrics "monerod RPC returned invalid JSON at $(date -Iseconds)"
        return 1
    fi

    # Supplementary queries — each is optional; a failure degrades to zeroes
    # rather than taking the whole scrape down.
    local fees pool hfork lastblock
    fees=$(rpc_call get_fee_estimate)          || fees='{}'
    hfork=$(rpc_call hard_fork_info)           || hfork='{}'
    lastblock=$(rpc_call get_last_block_header) || lastblock='{}'
    pool=$(rpc_get get_transaction_pool_stats) || pool='{}'

    local cpu_temp
    cpu_temp="$(read_cpu_temp)"

    # --- Extract get_info fields in a single jq pass ---
    local vals
    vals=$(printf '%s' "${info}" | jq -r '
        .result |
        [ (.height // 0),
          (.target_height // 0),
          (.difficulty // 0),
          (.tx_count // 0),
          (.tx_pool_size // 0),
          (.incoming_connections_count // 0),
          (.outgoing_connections_count // 0),
          (.rpc_connections_count // 0),
          (.white_peerlist_size // 0),
          (.grey_peerlist_size // 0),
          (.database_size // 0),
          (.free_space // 0),
          (if .busy_syncing then 1 else 0 end),
          (if .synchronized then 1 else 0 end),
          (.start_time // 0),
          (.cumulative_difficulty // 0),
          (if .update_available then 1 else 0 end),
          (.version // "unknown"),
          (if .mainnet then "mainnet" elif .testnet then "testnet" elif .stagenet then "stagenet" else "unknown" end),
          (.block_size_limit // 0),
          (.block_weight_limit // 0)
        ] | @tsv')

    local height target_height difficulty tx_count tx_pool_size
    local incoming outgoing rpc_conns white_peerlist grey_peerlist
    local db_size free_space busy_syncing synchronized start_time
    local cumulative_difficulty update_available version network
    local block_size_limit block_weight_limit
    IFS=$'\t' read -r height target_height difficulty tx_count tx_pool_size \
        incoming outgoing rpc_conns white_peerlist grey_peerlist \
        db_size free_space busy_syncing synchronized start_time \
        cumulative_difficulty update_available version network \
        block_size_limit block_weight_limit <<< "${vals}"

    # version and network become Prometheus label values, so restrict them to a
    # safe character set. Otherwise a quote or backslash from a malformed or
    # hostile monerod response would break the label syntax and make
    # node_exporter drop the whole textfile on its next scrape.
    version="${version//[^A-Za-z0-9._-]/}"
    network="${network//[^A-Za-z0-9._-]/}"
    [ -z "${version}" ] && version="unknown"
    [ -z "${network}" ] && network="unknown"

    local fee_per_byte
    fee_per_byte=$(printf '%s' "${fees}" | jq -r '.result.fee // 0')

    local pool_vals pool_bytes pool_txs pool_fee pool_double_spends
    pool_vals=$(printf '%s' "${pool}" | jq -r '
        [ (.pool_stats.bytes_total // 0),
          (.pool_stats.txs_total // 0),
          (.pool_stats.fee_total // 0),
          (.pool_stats.num_double_spends // 0) ] | @tsv')
    IFS=$'\t' read -r pool_bytes pool_txs pool_fee pool_double_spends <<< "${pool_vals}"

    local hf_vals hf_version hf_voting hf_enabled
    hf_vals=$(printf '%s' "${hfork}" | jq -r '
        [ (.result.version // 0),
          (.result.voting // 0),
          (if .result.enabled then 1 else 0 end) ] | @tsv')
    IFS=$'\t' read -r hf_version hf_voting hf_enabled <<< "${hf_vals}"

    local blk_vals block_reward block_size block_num_txes block_timestamp block_difficulty
    blk_vals=$(printf '%s' "${lastblock}" | jq -r '
        .result.block_header // {} |
        [ (.reward // 0),
          (.block_size // 0),
          (.num_txes // 0),
          (.timestamp // 0),
          (.difficulty // 0) ] | @tsv')
    IFS=$'\t' read -r block_reward block_size block_num_txes block_timestamp block_difficulty <<< "${blk_vals}"

    # Sync progress. target_height is 0 once monerod considers itself synced.
    local sync_pct=0
    if [ "${target_height:-0}" -gt 0 ] 2>/dev/null; then
        sync_pct=$(awk -v h="${height}" -v t="${target_height}" 'BEGIN {printf "%.4f", (t>0 ? (h/t)*100 : 0)}')
    elif [ "${synchronized}" = "1" ]; then
        sync_pct=100
    fi

    scrape_end="$(date +%s.%N)"
    scrape_duration=$(awk -v a="${scrape_start}" -v b="${scrape_end}" 'BEGIN{printf "%.4f", b-a}')

    cat > "${TEMP_FILE}" <<EOF
# HELP monerod_up Whether monerod RPC is reachable (1=up, 0=down).
# TYPE monerod_up gauge
monerod_up 1

# HELP monerod_info Monerod version and network info labels.
# TYPE monerod_info gauge
monerod_info{version="${version}",network="${network}"} 1

# HELP monerod_height Current blockchain height.
# TYPE monerod_height gauge
monerod_height ${height}

# HELP monerod_target_height Target sync height from peers (0 when synced).
# TYPE monerod_target_height gauge
monerod_target_height ${target_height}

# HELP monerod_sync_progress Sync progress percentage (0-100).
# TYPE monerod_sync_progress gauge
monerod_sync_progress ${sync_pct}

# HELP monerod_synchronized Whether the node is fully synchronized (1=yes, 0=no).
# TYPE monerod_synchronized gauge
monerod_synchronized ${synchronized}

# HELP monerod_busy_syncing Whether the node is currently syncing (1=yes, 0=no).
# TYPE monerod_busy_syncing gauge
monerod_busy_syncing ${busy_syncing}

# HELP monerod_difficulty Current network mining difficulty.
# TYPE monerod_difficulty gauge
monerod_difficulty ${difficulty}

# HELP monerod_cumulative_difficulty Cumulative difficulty of the chain.
# TYPE monerod_cumulative_difficulty gauge
monerod_cumulative_difficulty ${cumulative_difficulty}

# HELP monerod_tx_count Total number of transactions in the blockchain.
# TYPE monerod_tx_count gauge
monerod_tx_count ${tx_count}

# HELP monerod_tx_pool_size Number of transactions in the mempool.
# TYPE monerod_tx_pool_size gauge
monerod_tx_pool_size ${tx_pool_size}

# HELP monerod_connections_incoming Number of incoming P2P connections.
# TYPE monerod_connections_incoming gauge
monerod_connections_incoming ${incoming}

# HELP monerod_connections_outgoing Number of outgoing P2P connections.
# TYPE monerod_connections_outgoing gauge
monerod_connections_outgoing ${outgoing}

# HELP monerod_rpc_connections Number of active RPC connections.
# TYPE monerod_rpc_connections gauge
monerod_rpc_connections ${rpc_conns}

# HELP monerod_white_peerlist_size Number of peers in the white (known good) peerlist.
# TYPE monerod_white_peerlist_size gauge
monerod_white_peerlist_size ${white_peerlist}

# HELP monerod_grey_peerlist_size Number of peers in the grey (untested) peerlist.
# TYPE monerod_grey_peerlist_size gauge
monerod_grey_peerlist_size ${grey_peerlist}

# HELP monerod_database_size_bytes Size of the blockchain database in bytes.
# TYPE monerod_database_size_bytes gauge
monerod_database_size_bytes ${db_size}

# HELP monerod_free_space_bytes Free disk space on blockchain volume in bytes.
# TYPE monerod_free_space_bytes gauge
monerod_free_space_bytes ${free_space}

# HELP monerod_start_time_seconds Unix timestamp when monerod was started.
# TYPE monerod_start_time_seconds gauge
monerod_start_time_seconds ${start_time}

# HELP monerod_update_available Whether a monerod update is available (1=yes, 0=no).
# TYPE monerod_update_available gauge
monerod_update_available ${update_available}

# HELP monerod_block_size_limit Current block size limit in bytes.
# TYPE monerod_block_size_limit gauge
monerod_block_size_limit ${block_size_limit}

# HELP monerod_block_weight_limit Current block weight limit.
# TYPE monerod_block_weight_limit gauge
monerod_block_weight_limit ${block_weight_limit}

# HELP monerod_fee_per_byte_atomic Estimated fee per byte in atomic units.
# TYPE monerod_fee_per_byte_atomic gauge
monerod_fee_per_byte_atomic ${fee_per_byte}

# HELP monerod_pool_bytes_total Total bytes of transactions in the mempool.
# TYPE monerod_pool_bytes_total gauge
monerod_pool_bytes_total ${pool_bytes}

# HELP monerod_pool_txs_total Total transactions in mempool (from pool stats).
# TYPE monerod_pool_txs_total gauge
monerod_pool_txs_total ${pool_txs}

# HELP monerod_pool_fee_total Total fees of transactions in the mempool (atomic units).
# TYPE monerod_pool_fee_total gauge
monerod_pool_fee_total ${pool_fee}

# HELP monerod_pool_double_spends Number of double spend attempts in pool.
# TYPE monerod_pool_double_spends gauge
monerod_pool_double_spends ${pool_double_spends}

# HELP monerod_hardfork_version Current hard fork version.
# TYPE monerod_hardfork_version gauge
monerod_hardfork_version ${hf_version}

# HELP monerod_hardfork_voting Hard fork version being voted for.
# TYPE monerod_hardfork_voting gauge
monerod_hardfork_voting ${hf_voting}

# HELP monerod_hardfork_enabled Whether the current hard fork is enabled (1=yes, 0=no).
# TYPE monerod_hardfork_enabled gauge
monerod_hardfork_enabled ${hf_enabled}

# HELP monerod_last_block_reward Block reward of the last block in atomic units.
# TYPE monerod_last_block_reward gauge
monerod_last_block_reward ${block_reward}

# HELP monerod_last_block_size_bytes Size of the last block in bytes.
# TYPE monerod_last_block_size_bytes gauge
monerod_last_block_size_bytes ${block_size}

# HELP monerod_last_block_txes Number of transactions in the last block.
# TYPE monerod_last_block_txes gauge
monerod_last_block_txes ${block_num_txes}

# HELP monerod_last_block_timestamp Unix timestamp of the last block.
# TYPE monerod_last_block_timestamp gauge
monerod_last_block_timestamp ${block_timestamp}

# HELP monerod_last_block_difficulty Difficulty of the last block.
# TYPE monerod_last_block_difficulty gauge
monerod_last_block_difficulty ${block_difficulty}

# HELP pinodexmr_cpu_temp_celsius SoC temperature of the device.
# TYPE pinodexmr_cpu_temp_celsius gauge
pinodexmr_cpu_temp_celsius ${cpu_temp}

# HELP monerod_exporter_consecutive_failures Consecutive RPC failures before the last success.
# TYPE monerod_exporter_consecutive_failures gauge
monerod_exporter_consecutive_failures 0

# HELP monerod_exporter_scrape_duration_seconds Time taken by the last successful scrape.
# TYPE monerod_exporter_scrape_duration_seconds gauge
monerod_exporter_scrape_duration_seconds ${scrape_duration}

# HELP monerod_exporter_last_scrape_timestamp_seconds Unix time of the last successful scrape.
# TYPE monerod_exporter_last_scrape_timestamp_seconds gauge
monerod_exporter_last_scrape_timestamp_seconds $(date +%s)
EOF

    # Atomic replace so node_exporter never reads a half-written file.
    mv -f "${TEMP_FILE}" "${PROM_FILE}"
}

# --- Preflight -----------------------------------------------------------
command -v jq >/dev/null 2>&1   || { echo "monerod-exporter: jq is required"   >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "monerod-exporter: curl is required" >&2; exit 1; }

FAIL_COUNT=0
load_config
mkdir -p "${PNX_TEXTFILE_DIR}" 2>/dev/null || true

# Clean up our temp file if we are killed mid-write.
trap 'rm -f "${TEMP_FILE:-}"; exit 0' TERM INT

echo "monerod-exporter: starting (interval=${INTERVAL}s, rpc=${RPC_HOST}:${RPC_PORT}, auth=${PNX_RPC_AUTH}, textfile=${PNX_TEXTFILE_DIR})"

# --- Main loop -----------------------------------------------------------
while true; do
    # Reload every iteration so config and PiNodeXMR credential changes apply
    # without a restart.
    load_config

    if write_metrics; then
        FAIL_COUNT=0
        sleep "${INTERVAL}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "monerod-exporter: RPC query failed at $(date -Iseconds) (failure ${FAIL_COUNT}/${MAX_CONSECUTIVE_FAILURES})" >&2
        if [ "${FAIL_COUNT}" -ge "${MAX_CONSECUTIVE_FAILURES}" ]; then
            echo "monerod-exporter: ${MAX_CONSECUTIVE_FAILURES} consecutive failures, exiting for systemd restart" >&2
            exit 1
        fi
        sleep "${FAILURE_SLEEP}"
    fi
done
