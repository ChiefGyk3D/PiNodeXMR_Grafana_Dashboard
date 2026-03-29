#!/bin/bash
# monerod-exporter.sh — Prometheus textfile collector for monerod RPC metrics
# Runs as a systemd service, queries monerod JSON-RPC every 30 seconds,
# and writes metrics to node_exporter's textfile collector directory.
#
# Deployed to: /home/pinodexmr/monerod-exporter.sh
# Textfile dir: /var/lib/node_exporter/textfile_collector/
# Service:      monerod-exporter.service

set -uo pipefail

# --- Configuration ---
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${TEXTFILE_DIR}/monerod.prom"
TEMP_FILE="${TEXTFILE_DIR}/monerod.prom.tmp"
INTERVAL=30
MAX_CONSECUTIVE_FAILURES=3   # Exit after this many failures (~30s) for systemd restart
FAILURE_SLEEP=10             # Seconds to sleep between failure retries (instead of full interval)

# --- Ensure textfile directory exists ---
mkdir -p "${TEXTFILE_DIR}"

# --- Health check: consecutive failure counter ---
FAIL_COUNT=0


load_config() {
    # Re-source variables each iteration so credential/port changes are picked up
    source /home/pinodexmr/variables/RPCu.sh
    source /home/pinodexmr/variables/RPCp.sh
    source /home/pinodexmr/variables/monero-port.sh
    DEVICE_IP="$(hostname -I | awk '{print $1}')"
}

write_metrics() {
    local rpc_url="http://${DEVICE_IP}:${MONERO_PORT}/json_rpc"

    # Query get_info
    local info
    info=$(curl -sf --max-time 10 -u "${RPCu}:${RPCp}" --digest -X POST "${rpc_url}" \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' \
        -H 'Content-Type: application/json' 2>/dev/null) || {
        echo "# monerod RPC unreachable at $(date -Iseconds)" > "${TEMP_FILE}"
        echo "monerod_up 0" >> "${TEMP_FILE}"
        echo "monerod_exporter_consecutive_failures ${FAIL_COUNT}" >> "${TEMP_FILE}"
        mv "${TEMP_FILE}" "${PROM_FILE}"
        return 1
    }

    # Validate JSON — guard against partial responses during monerod startup
    if ! echo "${info}" | jq -e '.result' > /dev/null 2>&1; then
        echo "monerod-exporter: Invalid/partial JSON from RPC at $(date -Iseconds), treating as failure" >&2
        echo "# monerod RPC returned invalid JSON at $(date -Iseconds)" > "${TEMP_FILE}"
        echo "monerod_up 0" >> "${TEMP_FILE}"
        echo "monerod_exporter_consecutive_failures ${FAIL_COUNT}" >> "${TEMP_FILE}"
        mv "${TEMP_FILE}" "${PROM_FILE}"
        return 1
    fi

    # Query get_fee_estimate
    local fees
    fees=$(curl -sf --max-time 10 -u "${RPCu}:${RPCp}" --digest -X POST "${rpc_url}" \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_fee_estimate"}' \
        -H 'Content-Type: application/json' 2>/dev/null) || fees='{}'

    # Query transaction pool stats
    local pool
    pool=$(curl -sf --max-time 10 -u "${RPCu}:${RPCp}" --digest \
        "http://${DEVICE_IP}:${MONERO_PORT}/get_transaction_pool_stats" \
        -H 'Content-Type: application/json' 2>/dev/null) || pool='{}'

    # Query hard_fork_info
    local hfork
    hfork=$(curl -sf --max-time 10 -u "${RPCu}:${RPCp}" --digest -X POST "${rpc_url}" \
        -d '{"jsonrpc":"2.0","id":"0","method":"hard_fork_info"}' \
        -H 'Content-Type: application/json' 2>/dev/null) || hfork='{}'

    # Query get_last_block_header
    local lastblock
    lastblock=$(curl -sf --max-time 10 -u "${RPCu}:${RPCp}" --digest -X POST "${rpc_url}" \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_last_block_header"}' \
        -H 'Content-Type: application/json' 2>/dev/null) || lastblock='{}'

    # CPU temperature (direct read, faster than calling a script)
    local cpu_temp
    cpu_temp=$(awk '{print $1/1000}' /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null) || cpu_temp=0

    # --- Extract values with jq ---
    # get_info fields
    local height difficulty tx_count tx_pool_size
    local incoming outgoing rpc_conns
    local white_peerlist grey_peerlist
    local db_size free_space
    local busy_syncing synchronized target_height
    local version start_time cumulative_difficulty

    height=$(echo "$info" | jq -r '.result.height // 0')
    target_height=$(echo "$info" | jq -r '.result.target_height // 0')
    difficulty=$(echo "$info" | jq -r '.result.difficulty // 0')
    tx_count=$(echo "$info" | jq -r '.result.tx_count // 0')
    tx_pool_size=$(echo "$info" | jq -r '.result.tx_pool_size // 0')
    incoming=$(echo "$info" | jq -r '.result.incoming_connections_count // 0')
    outgoing=$(echo "$info" | jq -r '.result.outgoing_connections_count // 0')
    rpc_conns=$(echo "$info" | jq -r '.result.rpc_connections_count // 0')
    white_peerlist=$(echo "$info" | jq -r '.result.white_peerlist_size // 0')
    grey_peerlist=$(echo "$info" | jq -r '.result.grey_peerlist_size // 0')
    db_size=$(echo "$info" | jq -r '.result.database_size // 0')
    free_space=$(echo "$info" | jq -r '.result.free_space // 0')
    busy_syncing=$(echo "$info" | jq -r 'if .result.busy_syncing then 1 else 0 end')
    synchronized=$(echo "$info" | jq -r 'if .result.synchronized then 1 else 0 end')
    start_time=$(echo "$info" | jq -r '.result.start_time // 0')
    cumulative_difficulty=$(echo "$info" | jq -r '.result.cumulative_difficulty // 0')
    version=$(echo "$info" | jq -r '.result.version // "unknown"')
    update_available=$(echo "$info" | jq -r 'if .result.update_available then 1 else 0 end')

    # fee estimate
    local fee_per_byte
    fee_per_byte=$(echo "$fees" | jq -r '.result.fee // 0')

    # tx pool stats
    local pool_bytes pool_txs pool_fee pool_double_spends
    pool_bytes=$(echo "$pool" | jq -r '.pool_stats.bytes_total // 0')
    pool_txs=$(echo "$pool" | jq -r '.pool_stats.txs_total // 0')
    pool_fee=$(echo "$pool" | jq -r '.pool_stats.fee_total // 0')
    pool_double_spends=$(echo "$pool" | jq -r '.pool_stats.num_double_spends // 0')

    # hard fork
    local hf_version hf_voting hf_enabled
    hf_version=$(echo "$hfork" | jq -r '.result.version // 0')
    hf_voting=$(echo "$hfork" | jq -r '.result.voting // 0')
    hf_enabled=$(echo "$hfork" | jq -r 'if .result.enabled then 1 else 0 end')

    # last block header
    local block_reward block_size block_num_txes block_timestamp
    block_reward=$(echo "$lastblock" | jq -r '.result.block_header.reward // 0')
    block_size=$(echo "$lastblock" | jq -r '.result.block_header.block_size // 0')
    block_num_txes=$(echo "$lastblock" | jq -r '.result.block_header.num_txes // 0')
    block_timestamp=$(echo "$lastblock" | jq -r '.result.block_header.timestamp // 0')

    # Sync progress percentage
    local sync_pct=0
    if [ "$target_height" -gt 0 ] 2>/dev/null; then
        sync_pct=$(awk "BEGIN {printf \"%.4f\", ($height / $target_height) * 100}")
    elif [ "$synchronized" = "1" ]; then
        sync_pct=100
    fi

    # --- Write Prometheus metrics ---
    cat > "${TEMP_FILE}" <<EOF
# HELP monerod_up Whether monerod RPC is reachable (1=up, 0=down).
# TYPE monerod_up gauge
monerod_up 1

# HELP monerod_info Monerod version info label.
# TYPE monerod_info gauge
monerod_info{version="${version}"} 1

# HELP monerod_height Current blockchain height.
# TYPE monerod_height gauge
monerod_height ${height}

# HELP monerod_target_height Target sync height from peers.
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

# HELP pinodexmr_cpu_temp_celsius SoC temperature of the PiNodeXMR device.
# TYPE pinodexmr_cpu_temp_celsius gauge
pinodexmr_cpu_temp_celsius ${cpu_temp}

# HELP monerod_exporter_consecutive_failures Number of consecutive RPC failures before last success.
# TYPE monerod_exporter_consecutive_failures gauge
monerod_exporter_consecutive_failures 0
EOF

    # Atomic move to prevent partial reads
    mv "${TEMP_FILE}" "${PROM_FILE}"
}

# --- Main loop with self-healing ---
load_config
echo "monerod-exporter: Starting (interval=${INTERVAL}s, RPC=${DEVICE_IP}:${MONERO_PORT}, max_failures=${MAX_CONSECUTIVE_FAILURES})"

while true; do
    # Re-source config each iteration to pick up credential/port changes
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
        sleep "${FAILURE_SLEEP}"  # Short retry on failure instead of full interval
    fi
done
